// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { beforeAll, afterAll, beforeEach, describe, test, expect } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession } from "../helpers/fixtures.js";
import { EmailKeyring, createOutboxSender, sendNextEmail } from "../../src/auth/email-outbox.js";
import { digest } from "../../src/auth/native-plugin.js";
import { EmailProviderError } from "../../src/auth/email.js";
import { AuthReportQuery, loadAuthReport } from "../../src/models/auth-report.js";
import { safeReturnPath } from "../../src/auth/contracts.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });
const keys = new EmailKeyring("v1", { v1: Buffer.alloc(32, 1).toString("base64") });
const json = (body: unknown, cookie?: string) => ({ method: "POST", headers: { "content-type": "application/json", origin: "http://localhost:8787", ...cookie ? { cookie } : {} }, body: JSON.stringify(body) });
const cookies = (r: Response) => r.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");

async function started(email = "alice@example.com", userAgent?: string) {
  const mail: { text: string }[] = [];
  const { app } = buildTestApp(pg.db, pg.url, { sendEmail: async (m) => { mail.push(m); } });
  const request = json({ email });
  if (userAgent) Object.assign(request.headers, { "user-agent": userAgent });
  const response = await app.request("/api/auth/sign-in/cross-device/start", request);
  expect(response.status).toBe(200);
  const body = await response.json();
  const link = new URL(mail[0].text.match(/https?:\/\/\S+/)![0]);
  return { app, body, binding: cookies(response), token: link.searchParams.get("t"), link, mail };
}

describe("authentication flow boundaries", () => {
  for (const path of ["/dashboard", "/account", "/devices"]) {
    test(`browser navigation to ${path} completes its flow once`, async () => {
      const { app, body, binding, token, link } = await started("alice@example.com", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
      await app.request(link.toString());
      await app.request(path);
      expect(await pg.db.authFlowEvent.count({ where: { stage: "first_client_use" } })).toBe(0);
      expect((await app.request("/api/auth/sign-in/cross-device/approve", json({ id: body.id, token }))).status).toBe(200);
      const redeemed = await app.request(`/api/auth/sign-in/cross-device/status?id=${body.id}`, { headers: { cookie: binding } });
      expect((await redeemed.json()).status).toBe("ready");
      expect(await pg.db.authFlowEvent.count({ where: { stage: "first_client_use" } })).toBe(0);
      const filter = AuthReportQuery.parse({ surface: "web" });
      expect((await loadAuthReport(pg.db, filter)).rows[0].completed).toBe(0);
      const sessionCookie = cookies(redeemed);
      for (let visit = 0; visit < 2; visit++) {
        expect((await app.request(path, { headers: { cookie: sessionCookie } })).status).toBe(200);
      }
      expect(await pg.db.authFlowEvent.count({ where: { flowId: body.id, stage: "first_client_use" } })).toBe(1);
      const report = await loadAuthReport(pg.db, filter);
      expect(report.rows[0].completed).toBe(1);
      expect(report.rows[0].pending).toBe(0);
      expect(report.rows[0].stalled).toBe(0);
    });
  }

  test("polls require the exact binding; simultaneous polls issue one recoverable session", async () => {
    const { app, body, binding, token } = await started();
    const other = await app.request("/api/auth/sign-in/cross-device/start", json({ email: "bob@example.com" }, binding));
    expect(other.status).toBe(200);
    const unbound = await app.request(`/api/auth/sign-in/cross-device/status?id=${body.id}`, { headers: { cookie: cookies(other) } });
    expect((await unbound.json()).status).toBe("unbound");
    const approvals = await Promise.all([1, 2].map(() => app.request("/api/auth/sign-in/cross-device/approve", json({ id: body.id, token }))));
    expect(approvals.map((r) => r.status).sort()).toEqual([200, 400]);
    const poll = () => app.request(`/api/auth/sign-in/cross-device/status?id=${body.id}`, { headers: { cookie: binding } });
    const responses = await Promise.all([poll(), poll(), poll()]);
    expect(await pg.db.session.count()).toBe(1);
    expect(new Set(responses.map(cookies)).size).toBe(1);
    await pg.db.session.deleteMany();
    expect((await (await poll()).json()).status).toBe("consumed");
    expect(await pg.db.session.count()).toBe(0);
  });

  test("scanner GETs never approve, including with the initiating browser binding", async () => {
    const { app, body, binding, link } = await started();
    const review = await app.request(link.toString(), { headers: { cookie: binding } });
    expect(review.status).toBe(200);
    expect(await pg.db.user.count()).toBe(0);
    expect((await pg.db.pendingSignIn.findUniqueOrThrow({ where: { id: body.id } })).approvedAt).toBeNull();
    expect(review.headers.get("referrer-policy")).toBe("no-referrer");
    expect(await review.text()).not.toContain("wa.radhaai.com/s.js");
  });

  test("signup enqueues atomically, review requires CSRF and verification alone creates no session", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: createOutboxSender(pg.db, keys) });
    const result = await app.request("/api/auth/sign-up/email", json({ email: "owner@example.com", name: "Owner", password: "safe-password-123" }));
    expect(result.status).toBe(200);
    expect(await pg.db.productAccount.count()).toBe(0);
    const job = await pg.db.emailJob.findFirstOrThrow();
    const mail = keys.open(job.id, job.keyVersion!, job.payload!);
    expect(Buffer.from(job.payload!).toString()).not.toContain("owner@example.com");
    const link = mail.text.match(/https?:\/\/\S+/)![0];
    const verificationUrl = new URL(link);
    for (const path of ["/api/auth/verify-email/", "/api/auth//verify-email", "/api/auth/%76erify-email"]) {
      await app.request(path + verificationUrl.search);
      expect((await pg.db.user.findFirstOrThrow()).emailVerified).toBe(false);
      expect(await pg.db.session.count()).toBe(0);
    }
    const review = await app.request(link);
    const html = await review.text();
    expect((await pg.db.user.findFirstOrThrow()).emailVerified).toBe(false);
    const fields = { token: new URL(link).searchParams.get("token")!, csrf: html.match(/name="csrf" value="([^"]+)"/)![1] };
    const submit = (cookie?: string) => app.request("/ui/verify-email/confirm", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", origin: "http://localhost:8787", ...cookie ? { cookie } : {} }, body: new URLSearchParams(fields) });
    expect((await submit()).status).toBe(403);
    expect((await submit(cookies(review))).status).toBe(302);
    expect((await pg.db.user.findFirstOrThrow()).emailVerified).toBe(true);
    expect(await pg.db.session.count()).toBe(0);
    expect(await pg.db.productAccount.count()).toBe(1);
  });

  test("enqueue failure rolls back user, credential and flow; no recovery mail is detached", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: async () => { throw new Error("outbox unavailable"); } });
    const response = await app.request("/api/auth/sign-up/email", json({ email: "fail@example.com", name: "Fail", password: "safe-password-123" }));
    expect(response.status).toBeGreaterThanOrEqual(400);
    expect(await pg.db.user.count()).toBe(0);
    expect(await pg.db.account.count()).toBe(0);
    expect(await pg.db.authFlow.count()).toBe(0);
  });

  test("native codes need the correct verifier, cannot use legacy OTT, and never replace revoked sessions", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const verifier = "a".repeat(43);
    const start = await app.request("/api/auth/sign-in/native/start", json({ provider: "github", challenge: digest(verifier).toString("base64url") }));
    const { id } = await start.json();
    const user = await createTestUser(pg.db, "native@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    const session = await pg.db.session.findFirstOrThrow();
    const binding = "browser-binding";
    await pg.db.authFlow.update({ where: { id }, data: { bindingHash: digest(binding), sessionId: session.id } });
    const complete = await app.request("/api/auth/sign-in/native/complete", json({ id }, cookie + `; antgrid.native.${id}=${binding}`));
    expect(complete.status).toBe(200);
    const { code } = await complete.json();
    expect((await app.request("/api/auth/one-time-token/verify", json({ token: code }))).status).toBeGreaterThanOrEqual(400);
    expect((await app.request("/api/auth/sign-in/native/redeem", json({ id, code, verifier: "b".repeat(43) }))).status).toBe(400);
    expect((await app.request("/api/auth/sign-in/native/redeem", json({ id, code, verifier }))).status).toBe(200);
    await pg.db.session.delete({ where: { id: session.id } });
    expect((await app.request("/api/auth/sign-in/native/redeem", json({ id, code, verifier }))).status).toBeGreaterThanOrEqual(400);
    expect(await pg.db.session.count()).toBe(0);
  });

  test("recipient limits are shared across app instances and unknown-address reset requests", async () => {
    const a = buildTestApp(pg.db, pg.url).app;
    const b = buildTestApp(pg.db, pg.url).app;
    expect((await a.request("/api/auth/request-password-reset", json({ email: "missing@example.com" }))).status).toBe(200);
    const response = await b.request("/api/auth/send-verification-email", json({ email: "missing@example.com" }));
    expect(response.status).toBe(429);
    expect(Number(response.headers.get("retry-after"))).toBeGreaterThan(0);
  });

  test("reciprocal account recovery locks in one order and revokes both original sessions", async () => {
    const mail: { to: string; text: string }[] = [];
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: async (message) => { mail.push(message); } });
    const a = await createTestUser(pg.db, "a@example.com");
    const b = await createTestUser(pg.db, "b@example.com");
    const aSession = await createTestSession(pg.db, a.id);
    const bSession = await createTestSession(pg.db, b.id);
    for (const user of [a, b]) {
      expect((await app.request("/api/auth/request-password-reset", json({ email: user.email }))).status).toBe(200);
    }
    const token = (email: string) => mail.find((message) => message.to === email)!.text.match(/\/api\/auth\/reset-password\/([^?\s]+)/)![1];
    const responses = await Promise.all([
      app.request("/api/auth/reset-password", json({ token: token(b.email), newPassword: "safe-new-password-123" }, aSession.cookie)),
      app.request("/api/auth/reset-password", json({ token: token(a.email), newPassword: "safe-new-password-456" }, bSession.cookie)),
    ]);
    expect(responses.map((response) => response.status)).toEqual([200, 200]);
    expect(await pg.db.session.count()).toBe(0);
  });
});

describe("durable email execution", () => {
  test("retry keeps ciphertext and reference; acceptance deletes sensitive payload", async () => {
    await createOutboxSender(pg.db, keys)({ to: "mail@example.com", subject: "Review", text: "https://antgrid.ai/secret", expiresAt: new Date(Date.now() + 600000) });
    const job = await pg.db.emailJob.findFirstOrThrow();
    await sendNextEmail(pg.db, keys, async () => { throw new EmailProviderError("transient"); });
    const retry = await pg.db.emailJob.findFirstOrThrow();
    expect(retry.state).toBe("queued"); expect(retry.payload).toEqual(job.payload);
    await pg.db.emailJob.update({ where: { id: job.id }, data: { nextAt: new Date(0) } });
    const references: string[] = [];
    await Promise.all([1, 2].map(() => sendNextEmail(pg.db, keys, async (m) => { references.push(m.clientReference!); return { providerId: "accepted" }; })));
    expect(references).toEqual([job.reference]);
    const accepted = await pg.db.emailJob.findFirstOrThrow();
    expect(accepted.state).toBe("provider_accepted"); expect(accepted.payload).toBeNull();
  });

  test("expired leases recover and configuration failure pauses every worker", async () => {
    await createOutboxSender(pg.db, keys)({ to: "mail@example.com", subject: "Review", text: "link" });
    const job = await pg.db.emailJob.findFirstOrThrow();
    await pg.db.emailJob.update({ where: { id: job.id }, data: { state: "sending", leaseUntil: new Date(0) } });
    await sendNextEmail(pg.db, keys, async () => { throw new EmailProviderError("configuration"); });
    expect((await pg.db.emailJob.findFirstOrThrow()).payload).not.toBeNull();
    expect(await sendNextEmail(pg.db, keys, async () => { throw new Error("must not send"); })).toBe(false);
  });

  test("rotation reads queued jobs using old keys and authenticates ciphertext", () => {
    const payload = keys.seal("job", { to: "mail@example.com", subject: "Review", text: "secret" });
    const rotated = new EmailKeyring("v2", { v1: Buffer.alloc(32, 1).toString("base64"), v2: Buffer.alloc(32, 2).toString("base64") });
    expect(rotated.open("job", "v1", payload).text).toBe("secret");
    expect(() => rotated.open("another-job", "v1", payload)).toThrow();
  });
});

test("return destinations reject encoding, backslashes and auth loops", () => {
  for (const path of ["https://evil.test", "//evil.test", "/\\evil.test", "/%2f%2fevil.test", "/x/../oauth/start", "/%6cogin", "/%255cfoo"]) expect(safeReturnPath(path)).toBe("/dashboard");
  expect(safeReturnPath("/pricing?plan=pro&email=secret")).toBe("/pricing?plan=pro");
});

test("webhook batches deduplicate recipient events without changing authentication state", async () => {
  const secret = "webhook-secret-long-enough";
  const { app } = buildTestApp(pg.db,pg.url,{ envOverrides: { ZEPTOMAIL_WEBHOOK_SECRET: secret } as never });
  await createOutboxSender(pg.db,keys)({ to: "mail@example.com",subject: "Review",text: "private" });
  const job = await pg.db.emailJob.findFirstOrThrow();
  await pg.db.emailJob.update({ where: { id: job.id },data: { state: "provider_accepted",providerId: "provider-id",payload: null,keyVersion: null } });
  const events = [{ event_name: ["softbounce","fbl_complaint"],event_message: [{ request_id: "provider-id" }] },
    { event_name: ["hardbounce"],event_message: [{ email_info: { client_reference: job.reference } }] }];
  for (let i=0;i<2;i++) expect((await app.request(`/webhooks/zeptomail/${secret}`,json(events))).status).toBe(200);
  expect(await pg.db.emailRecipientEvent.count()).toBe(3);
  expect((await pg.db.emailJob.findFirstOrThrow()).state).toBe("provider_accepted");
  expect(await pg.db.session.count()).toBe(0);
});

test("permanent rejection and expiry erase payloads without generating replacement links", async () => {
  let sent = 0;
  await createOutboxSender(pg.db,keys)({ to: "mail@example.com",subject: "Review",text: "same-link" });
  await sendNextEmail(pg.db,keys,async () => { sent++; throw new EmailProviderError("permanent"); });
  expect((await pg.db.emailJob.findFirstOrThrow()).state).toBe("failed");
  expect((await pg.db.emailJob.findFirstOrThrow()).payload).toBeNull();
  await createOutboxSender(pg.db,keys)({ to: "mail@example.com",subject: "Review",text: "expired-link",expiresAt: new Date(Date.now()+30000) });
  await sendNextEmail(pg.db,keys,async () => { sent++; });
  expect(sent).toBe(1);
  expect(await pg.db.emailJob.count({ where: { state: "expired",payload: null } })).toBe(1);
});
