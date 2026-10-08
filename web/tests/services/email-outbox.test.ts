// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createOutboxSender, EmailKeyring, expireEmailPayloads, startEmailOutbox } from "../../src/auth/email-outbox.js";
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
