// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { TEST_BETTER_AUTH_SECRET, buildTestApp } from "../helpers/app.js";
import { createTestUser } from "../helpers/fixtures.js";
import { EmailKeyring, createOutboxSender } from "../../src/auth/email-outbox.js";
import { recipientDigest } from "../../src/auth/recipient-key.js";
import { authScope } from "../../src/auth/transaction.js";
import type { MailDomainCheck, MailDomainVerdict } from "../../src/auth/mail-domain.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

const keys = new EmailKeyring("v1", { v1: Buffer.alloc(32, 1).toString("base64") });
const PASSWORD = "first-password-one";

type Mail = { path: string; body: (email: string) => Record<string, string> };
const MAIL_PATHS: Mail[] = [
  { path: "/api/auth/sign-in/cross-device/start", body: (email) => ({ email }) },
  { path: "/api/auth/sign-up/email", body: (email) => ({ email, name: "Test", password: PASSWORD }) },
  { path: "/api/auth/request-password-reset", body: (email) => ({ email }) },
  { path: "/api/auth/send-verification-email", body: (email) => ({ email }) },
];
const START = MAIL_PATHS[0];
const SIGN_UP = MAIL_PATHS[1];
const RESET = MAIL_PATHS[2];

function appWith(mailDomain?: MailDomainCheck) {
  return buildTestApp(pg.db, pg.url, {
    sendEmail: createOutboxSender(pg.db, keys, { recipientSecret: TEST_BETTER_AUTH_SECRET }),
    mailDomain,
  });
}

async function send(app: ReturnType<typeof appWith>["app"], mail: Mail, email: string) {
  // Each request spends the per-IP and per-recipient buckets; these tests are
  // about admission, not throttling.
  await pg.db.authRateBucket.deleteMany();
  const response = await app.request(mail.path, {
    method: "POST",
    headers: { "content-type": "application/json", origin: "http://localhost:8787" },
    body: JSON.stringify(mail.body(email)),
  });
  const text = await response.text();
  return { status: response.status, text, code: (JSON.parse(text || "null") as { code?: string } | null)?.code };
}

const suppress = (email: string) => pg.db.emailSuppression.create({
  data: { recipientHash: recipientDigest(TEST_BETTER_AUTH_SECRET, email), reason: "recipient", expiresAt: new Date(Date.now() + 86400000) },
});

describe("suppressed recipients", () => {
  test("every mail path refuses a suppressed address and queues nothing", async () => {
    const { app } = appWith();
    await suppress("User@Example.com");
    for (const mail of MAIL_PATHS) {
      const result = await send(app, mail, "user@example.com");
      expect(result.status).toBe(400);
      expect(result.code).toBe("EMAIL_UNDELIVERABLE");
    }
    expect(await pg.db.emailJob.count()).toBe(0);
  });

  test("positive control: an unsuppressed address queues one job", async () => {
    const { app } = appWith();
    await suppress("other@example.com");
    const result = await send(app, START, "fresh@example.com");
    expect(result.status).toBe(200);
    expect(await pg.db.emailJob.count()).toBe(1);
    expect((await pg.db.pendingSignIn.findFirstOrThrow()).requesterEntry).toBe("api");
  });

  test("the refusal is identical whether or not an account exists", async () => {
    const { app } = appWith();
    await createTestUser(pg.db, "owner@example.com");
    await suppress("owner@example.com");
    await suppress("ghost@example.com");
    for (const mail of [RESET, SIGN_UP, START]) {
      const existing = await send(app, mail, "owner@example.com");
      const unknown = await send(app, mail, "ghost@example.com");
      expect(existing.status).toBe(400);
      expect(existing).toEqual(unknown);
    }
  });

  test("a Gmail dot or +tag variant shares the suppression", async () => {
    const { app } = appWith();
    await suppress("jeff@gmail.com");
    const result = await send(app, RESET, "J.e.f.f+news@googlemail.com");
    expect(result.status).toBe(400);
    expect(result.code).toBe("EMAIL_UNDELIVERABLE");
  });

  test("password sign-in never returns an admission code", async () => {
    const { app, auth } = appWith();
    const user = await createTestUser(pg.db, "owner@example.com");
    await pg.db.account.create({ data: {
      id: crypto.randomUUID(), accountId: user.id, providerId: "credential", userId: user.id,
      password: await (await auth.$context).password.hash(PASSWORD),
    } });
    await suppress("owner@example.com");
    await pg.db.authRateBucket.deleteMany();
    const response = await app.request("/api/auth/sign-in/email", {
      method: "POST",
      headers: { "content-type": "application/json", origin: "http://localhost:8787" },
      body: JSON.stringify({ email: "owner@example.com", password: PASSWORD }),
    });
    expect(response.status).toBe(200);
    expect(await response.text()).not.toContain("EMAIL_UNDELIVERABLE");
  });
});

describe("domain check", () => {
  const verdict = (v: MailDomainVerdict | "throw") => {
    const calls: string[] = [];
    const scopes: unknown[] = [];
    const check: MailDomainCheck = async (email) => {
      calls.push(email);
      scopes.push(authScope.getStore());
      if (v === "throw") throw new Error("resolver down");
      return v;
    };
    return { check, calls, scopes };
  };

  test("no_mail is refused on all four paths", async () => {
    const stub = verdict("no_mail");
    const { app } = appWith(stub.check);
    for (const mail of MAIL_PATHS) {
      const result = await send(app, mail, "someone@dead.example");
      expect(result.status).toBe(400);
      expect(result.code).toBe("EMAIL_DOMAIN_UNDELIVERABLE");
    }
    expect(await pg.db.emailJob.count()).toBe(0);
  });

  test("the lookup runs outside the auth transaction, over HTTP and in process", async () => {
    const stub = verdict("deliverable");
    const { app, auth } = appWith(stub.check);
    expect((await send(app, RESET, "a@corp.example")).status).toBe(200);
    await pg.db.authRateBucket.deleteMany();
    const response = await auth.api.requestPasswordReset({
      body: { email: "b@corp.example" }, headers: new Headers(), asResponse: true,
    });
    expect(response.status).toBe(200);
    expect(stub.calls).toEqual(["a@corp.example", "b@corp.example"]);
    expect(stub.scopes).toEqual([undefined, undefined]);
  });

  test("a throwing check fails open", async () => {
    const { app } = appWith(verdict("throw").check);
    const result = await send(app, START, "a@corp.example");
    expect(result.status).toBe(200);
  });

  test("a malformed address never reaches the check", async () => {
    const stub = verdict("no_mail");
    const { app } = appWith(stub.check);
    await send(app, RESET, "not-an-email");
    expect(stub.calls).toHaveLength(0);
  });

  test("a form-encoded sign-up is checked like a JSON one", async () => {
    const stub = verdict("no_mail");
    const { app } = appWith(stub.check);
    await pg.db.authRateBucket.deleteMany();
    const response = await app.request(SIGN_UP.path, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(SIGN_UP.body("someone@dead.example")).toString(),
    });
    expect(response.status).toBe(400);
    expect(((await response.json()) as { code?: string }).code).toBe("EMAIL_DOMAIN_UNDELIVERABLE");
    expect(stub.calls).toEqual(["someone@dead.example"]);
    expect(await pg.db.emailJob.count()).toBe(0);
  });

  test("a client over its lookup budget no longer reaches the check", async () => {
    const stub = verdict("deliverable");
    const { app, auth } = appWith(stub.check);
    for (let i = 0; i < 40; i++) {
      await pg.db.authRateBucket.deleteMany();
      await app.request(RESET.path, {
        method: "POST",
        headers: { "content-type": "application/json", origin: "http://localhost:8787", "x-forwarded-for": "203.0.113.9" },
        body: JSON.stringify(RESET.body(`u${i}@corp.example`)),
      });
    }
    expect(stub.calls.length).toBeGreaterThan(0);
    expect(stub.calls.length).toBeLessThan(30);
    const before = stub.calls.length;
    await pg.db.authRateBucket.deleteMany();
    // The app strips a header it cannot trust, so a second client is only
    // expressible by calling the handler with the resolved hop already set.
    await auth.handler(new Request("http://localhost:8787" + RESET.path, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "http://localhost:8787", "x-forwarded-for": "198.51.100.7" },
      body: JSON.stringify(RESET.body("other@corp.example")),
    }));
    expect(stub.calls.length).toBe(before + 1);
  });

  test("password sign-in does not consult the check", async () => {
    const stub = verdict("no_mail");
    const { app } = appWith(stub.check);
    await pg.db.authRateBucket.deleteMany();
    const response = await app.request("/api/auth/sign-in/email", {
      method: "POST",
      headers: { "content-type": "application/json", origin: "http://localhost:8787" },
      body: JSON.stringify({ email: "x@dead.example", password: PASSWORD }),
    });
    expect(stub.calls).toHaveLength(0);
    expect(await response.text()).not.toContain("EMAIL_DOMAIN_UNDELIVERABLE");
  });
});

describe("Gmail addresses use Google sign-in", () => {
  const GMAIL = ["x@gmail.com", "X.Y+z@GoogleMail.com", "je.f.f.spea.k.m.a.n@gmail.com",
    "s.haqu.i.t.a.73.0.8@gmail.com", "su.p.e.r.sh.an.03@gmail.com"];

  test("cross-device start and sign-up refuse them without queueing mail", async () => {
    const { app } = appWith();
    for (const mail of [START, SIGN_UP]) {
      for (const email of GMAIL) {
        const result = await send(app, mail, email);
        expect(result.status).toBe(400);
        expect(result.code).toBe("EMAIL_USE_GOOGLE");
      }
    }
    expect(await pg.db.emailJob.count()).toBe(0);
  });

  test("reset and verification resend are unaffected", async () => {
    const { app } = appWith();
    for (const mail of [RESET, MAIL_PATHS[3]]) {
      const result = await send(app, mail, "x@gmail.com");
      expect(result.status).toBe(200);
    }
  });

  test("a non-Gmail address passes", async () => {
    const { app } = appWith();
    expect((await send(app, START, "x@outlook.example")).status).toBe(200);
    expect((await send(app, SIGN_UP, "y@outlook.example")).status).toBe(200);
  });

  test("the answer is byte-identical whether or not a Gmail account exists", async () => {
    const { app } = appWith();
    await createTestUser(pg.db, "known@gmail.com");
    for (const mail of [START, SIGN_UP]) {
      const known = await send(app, mail, "known@gmail.com");
      const unknown = await send(app, mail, "nobody@gmail.com");
      expect(known.status).toBe(400);
      expect(known).toEqual(unknown);
    }
  });

  test("the rule fires before any domain lookup", async () => {
    const calls: string[] = [];
    const { app } = appWith(async (email) => { calls.push(email); return "deliverable"; });
    await send(app, START, "x@gmail.com");
    await send(app, RESET, "x@googlemail.com");
    expect(calls).toHaveLength(0);
  });

  test("an existing Gmail user's password sign-in still works", async () => {
    const { app, auth } = appWith();
    const user = await createTestUser(pg.db, "known@gmail.com");
    await pg.db.account.create({ data: {
      id: crypto.randomUUID(), accountId: user.id, providerId: "credential", userId: user.id,
      password: await (await auth.$context).password.hash(PASSWORD),
    } });
    await pg.db.authRateBucket.deleteMany();
    const response = await app.request("/api/auth/sign-in/email", {
      method: "POST",
      headers: { "content-type": "application/json", origin: "http://localhost:8787" },
      body: JSON.stringify({ email: "known@gmail.com", password: PASSWORD }),
    });
    expect(response.status).toBe(200);
  });
});
