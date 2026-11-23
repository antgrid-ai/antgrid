// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createOutboxSender, EmailKeyring, expireEmailPayloads, sendNextEmail, startEmailOutbox } from "../../src/auth/email-outbox.js";
import { recipientDigest } from "../../src/auth/recipient-key.js";
import { createPending, findByIdWithHashes } from "../../src/models/pending-sign-in.js";
import { createInvite, inviteEmailReference } from "../../src/models/account-invite.js";
import { createTestUser } from "../helpers/fixtures.js";
import { ensureProductAccount } from "../../src/models/product-account.js";
import { TEST_BETTER_AUTH_SECRET } from "../helpers/app.js";
import { authScope } from "../../src/auth/transaction.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });
const keys = new EmailKeyring("v1", { v1: Buffer.alloc(32, 7).toString("base64") });

test("expiry clears payload and lease without changing accepted delivery outcomes", async () => {
  const send = createOutboxSender(pg.db, keys);
  const journey = await pg.db.authJourney.create({ data: { origin: { surface: "unknown" } } });
  const flow = await pg.db.authFlow.create({ data: { journeyId: journey.id, expiresAt: new Date(0) } });
  await authScope.run({ tx: pg.db, flowId: flow.id, charged: new Set() },() => send({ to: "expired@example.com", subject: "Review", text: "private", expiresAt: new Date(0) }));
  const job = await pg.db.emailJob.findFirstOrThrow();
  await pg.db.emailJob.update({ where: { id: job.id }, data: { state: "sending", leaseId: crypto.randomUUID(), leaseUntil: new Date(Date.now()+30000) } });
  await expireEmailPayloads(pg.db);
  expect(await pg.db.emailJob.findFirstOrThrow()).toMatchObject({ state: "expired", payload: null, keyVersion: null, leaseId: null, leaseUntil: null });
  expect((await pg.db.authFlowEvent.findUniqueOrThrow({ where: { flowId_stage: { flowId: flow.id, stage: "mail_failed" } } })).failure).toBe("expired");
  await pg.db.emailJob.update({ where: { id: job.id }, data: { state: "provider_accepted" } });
  await expireEmailPayloads(pg.db);
  expect((await pg.db.emailJob.findFirstOrThrow()).state).toBe("provider_accepted");
});

test("rollback pause stops claims while expiry maintenance continues", async () => {
  await createOutboxSender(pg.db, keys)({ to: "expired@example.com", subject: "Review", text: "private", expiresAt: new Date(0) });
  let sends = 0;
  const stop = startEmailOutbox(pg.db, keys, async () => { sends++; }, true);
  try {
    const deadline = Date.now()+3000;
    while ((await pg.db.emailJob.findFirstOrThrow()).state !== "expired" && Date.now() < deadline) await Bun.sleep(20);
    expect((await pg.db.emailJob.findFirstOrThrow()).payload).toBeNull();
    expect(sends).toBe(0);
  } finally { stop(); }
});

const SECRET = "outbox-recipient-secret-0123456789abcdef";
const suppress = (email: string, over: Record<string, unknown> = {}) => pg.db.emailSuppression.create({ data: { recipientHash: recipientDigest(SECRET, email), reason: "recipient", expiresAt: new Date(Date.now() + 86400000), ...over } });

test("the sender writes a recipient digest only when given a secret", async () => {
  await createOutboxSender(pg.db, keys, { recipientSecret: SECRET })({ to: "Hash@Example.com", subject: "s", text: "t" });
  await createOutboxSender(pg.db, keys)({ to: "plain@example.com", subject: "s", text: "t" });
  const jobs = await pg.db.emailJob.findMany({ orderBy: { createdAt: "asc" } });
  expect(Buffer.from(jobs[0].recipientHash!).equals(Buffer.from(recipientDigest(SECRET, "hash@example.com")))).toBe(true);
  expect(jobs[1].recipientHash).toBeNull();
});

test("a suppressed recipient is never sent and the job is recorded as suppressed", async () => {
  const journey = await pg.db.authJourney.create({ data: { origin: { surface: "unknown" } } });
  const flow = await pg.db.authFlow.create({ data: { journeyId: journey.id, expiresAt: new Date(Date.now() + 3600000) } });
  const enqueue = createOutboxSender(pg.db, keys, { recipientSecret: SECRET });
  await authScope.run({ tx: pg.db, flowId: flow.id, charged: new Set() }, () => enqueue({ to: "dead@example.com", subject: "s", text: "t" }));
  await suppress("dead@example.com");
  let sends = 0;
  expect(await sendNextEmail(pg.db, keys, async () => { sends++; })).toBe(true);
  expect(sends).toBe(0);
  expect(await pg.db.emailJob.findFirstOrThrow()).toMatchObject({ state: "failed", failure: "suppressed", payload: null, keyVersion: null, leaseId: null });
  expect((await pg.db.authFlowEvent.findUniqueOrThrow({ where: { flowId_stage: { flowId: flow.id, stage: "mail_failed" } } })).failure).toBe("suppressed");
  expect(await pg.db.authRateBucket.count({ where: { key: "email-sender-paused" } })).toBe(0);
});

test("a suppressed job marks its magic-link row and its invitation bounced", async () => {
  const pending = await createPending(pg.db, { email: "dead@example.com", nonce: "n", browserToken: "b", secret: TEST_BETTER_AUTH_SECRET, requesterUa: null, requesterIp: null });
  const owner = await createTestUser(pg.db);
  const account = await ensureProductAccount(pg.db, owner.id);
  const invite = await createInvite(pg.db, { accountId: account.id, createdBy: owner.id, email: "dead@example.com", role: "member", token: "token", secret: TEST_BETTER_AUTH_SECRET });
  const enqueue = createOutboxSender(pg.db, keys, { recipientSecret: SECRET });
  await enqueue({ to: "dead@example.com", subject: "s", text: "t", clientReference: pending.id });
  await enqueue({ to: "dead@example.com", subject: "s", text: "t", clientReference: inviteEmailReference(invite.id) });
  await suppress("dead@example.com");
  await sendNextEmail(pg.db, keys, async () => {});
  await sendNextEmail(pg.db, keys, async () => {});
  expect((await findByIdWithHashes(pg.db, pending.id))?.deliveryStatus).toBe("bounced");
  expect((await pg.db.accountInvite.findUniqueOrThrow({ where: { id: invite.id } })).deliveryStatus).toBe("bounced");
});

test("a suppressed job past its expiry window is recorded as suppressed, not expired", async () => {
  await createOutboxSender(pg.db, keys, { recipientSecret: SECRET })({ to: "dead@example.com", subject: "s", text: "t", expiresAt: new Date(0) });
  await suppress("dead@example.com");
  await sendNextEmail(pg.db, keys, async () => {});
  expect(await pg.db.emailJob.findFirstOrThrow()).toMatchObject({ state: "failed", failure: "suppressed" });
});

test("expired, lifted and unkeyed suppressions send normally", async () => {
  const enqueue = createOutboxSender(pg.db, keys, { recipientSecret: SECRET });
  await enqueue({ to: "old@example.com", subject: "s", text: "t" });
  await enqueue({ to: "lifted@example.com", subject: "s", text: "t" });
  await createOutboxSender(pg.db, keys)({ to: "nokey@example.com", subject: "s", text: "t" });
  await suppress("old@example.com", { expiresAt: new Date(Date.now() - 1000) });
  await suppress("lifted@example.com", { liftedAt: new Date() });
  await suppress("nokey@example.com");
  let sends = 0;
  for (let i = 0; i < 3; i++) await sendNextEmail(pg.db, keys, async () => { sends++; });
  expect(sends).toBe(3);
  expect(await pg.db.emailJob.count({ where: { state: "provider_accepted" } })).toBe(3);
});
