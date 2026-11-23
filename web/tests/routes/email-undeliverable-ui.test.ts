// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { TEST_BETTER_AUTH_SECRET, buildTestApp } from "../helpers/app.js";
import { EmailKeyring, createOutboxSender } from "../../src/auth/email-outbox.js";
import { recipientDigest } from "../../src/auth/recipient-key.js";
import type { MailDomainCheck, MailDomainVerdict } from "../../src/auth/mail-domain.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

const ORIGIN = "http://localhost:8787";
const keys = new EmailKeyring("v1", { v1: Buffer.alloc(32, 1).toString("base64") });
const DOMAIN_COPY = "That email domain can't receive mail. Check the part after the @.";
const ADDRESS_COPY = "We can't send email to that address. Check the spelling, or sign in another way.";
const GMAIL_COPY = "Gmail addresses sign in with Google. Use Continue with Google.";

function appWith(verdict: MailDomainVerdict = "deliverable") {
  const mailDomain: MailDomainCheck = async () => verdict;
  return buildTestApp(pg.db, pg.url, {
    sendEmail: createOutboxSender(pg.db, keys, { recipientSecret: TEST_BETTER_AUTH_SECRET }),
    mailDomain,
  });
}
type TestApp = ReturnType<typeof appWith>["app"];

async function post(app: TestApp, path: string, body: Record<string, string> = {}) {
  // Admission is not what these tests are about, and every request spends a bucket.
  await pg.db.authRateBucket.deleteMany();
  return app.request(path, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", origin: ORIGIN },
    body: new URLSearchParams(body).toString(),
  });
}
const where = (res: Response) => new URL(res.headers.get("location") ?? "", ORIGIN);
const suppress = (email: string) => pg.db.emailSuppression.create({
  data: { recipientHash: recipientDigest(TEST_BETTER_AUTH_SECRET, email), reason: "recipient", expiresAt: new Date(Date.now() + 86400000) },
});

describe("magic link entry points", () => {
  for (const path of ["/ui/login/continue", "/ui/login/start"]) {
    test(`${path} names a dead domain and keeps the address`, async () => {
      const { app } = appWith("no_mail");
      const res = await post(app, path, { email: "a@dead.example" });
      expect(res.status).toBe(302);
      const url = where(res);
      expect(url.pathname).toBe("/login");
      expect(url.searchParams.get("error")).toBe(DOMAIN_COPY);
      expect(url.searchParams.get("email")).toBe("a@dead.example");
    });

    test(`${path} names a suppressed address and keeps it`, async () => {
      const { app } = appWith();
      await suppress("bounced@corp.example");
      const res = await post(app, path, { email: "bounced@corp.example" });
      const url = where(res);
      expect(url.pathname).toBe("/login");
      expect(url.searchParams.get("error")).toBe(ADDRESS_COPY);
      expect(url.searchParams.get("email")).toBe("bounced@corp.example");
    });

    test(`${path} sends a Gmail address to Google`, async () => {
      const { app } = appWith();
      const res = await post(app, path, { email: "x.y+z@gmail.com" });
      const url = where(res);
      expect(url.searchParams.get("error")).toBe(GMAIL_COPY);
      expect(url.searchParams.get("email")).toBe("x.y+z@gmail.com");
      expect(await pg.db.emailJob.count()).toBe(0);
    });
  }

  test("the login page offers Continue with Google next to that copy", async () => {
    const { app } = appWith();
    const html = await (await app.request(`/login?error=${encodeURIComponent(GMAIL_COPY)}&email=x%40gmail.com`)).text();
    expect(html).toContain("provider=google");
    expect(html).toContain("Gmail addresses sign in with Google.");
  });

  test("a start from the web form is attributed to the UI", async () => {
    const { app } = appWith();
    const res = await post(app, "/ui/login/start", { email: "fresh@corp.example" });
    expect(where(res).pathname).toStartWith("/login/pending/");
    expect((await pg.db.pendingSignIn.findFirstOrThrow()).requesterEntry).toBe("ui");
  });

  test("a raw API call cannot claim the web form", async () => {
    const { app } = appWith();
    await pg.db.authRateBucket.deleteMany();
    const res = await app.request("/api/auth/sign-in/cross-device/start", {
      method: "POST",
      headers: { "content-type": "application/json", origin: ORIGIN, "x-antgrid-entry": "ui" },
      body: JSON.stringify({ email: "fresh@corp.example" }),
    });
    expect(res.status).toBe(200);
    expect((await pg.db.pendingSignIn.findFirstOrThrow()).requesterEntry).toBe("api");
  });
});

describe("/ui/signup", () => {
  const form = { email: "new@corp.example", password: "first-password-one", confirmPassword: "first-password-one" };

  test("a dead domain keeps the address", async () => {
    const { app } = appWith("no_mail");
    const url = where(await post(app, "/ui/signup", form));
    expect(url.pathname).toBe("/signup");
    expect(url.searchParams.get("error")).toBe(DOMAIN_COPY);
    expect(url.searchParams.get("email")).toBe("new@corp.example");
  });

  test("a suppressed address keeps the address", async () => {
    const { app } = appWith();
    await suppress("new@corp.example");
    const url = where(await post(app, "/ui/signup", form));
    expect(url.searchParams.get("error")).toBe(ADDRESS_COPY);
    expect(url.searchParams.get("email")).toBe("new@corp.example");
  });

  test("a Gmail address is sent to Google, and the sign-up page offers that button", async () => {
    const { app } = appWith();
    const url = where(await post(app, "/ui/signup", { ...form, email: "someone@gmail.com" }));
    expect(url.pathname).toBe("/signup");
    expect(url.searchParams.get("error")).toBe(GMAIL_COPY);
    expect(url.searchParams.get("email")).toBe("someone@gmail.com");
    expect(await pg.db.user.count()).toBe(0);
    const html = await (await app.request(`/signup?error=${encodeURIComponent(GMAIL_COPY)}&email=someone%40gmail.com`)).text();
    expect(html).toContain("provider=google");
    expect(html).toContain("Continue with Google");
  });
});

describe("/ui/forgot-password", () => {
  test("names the refusal without echoing the address", async () => {
    const { app } = appWith("no_mail");
    const res = await post(app, "/ui/forgot-password", { email: "a@dead.example" });
    expect(res.headers.get("location")).not.toContain("dead.example");
    expect(where(res).searchParams.get("error")).toBe("That email domain can't receive mail. Check the address and try again.");
  });

  test("names a suppressed address", async () => {
    const { app } = appWith();
    await suppress("bounced@corp.example");
    const res = await post(app, "/ui/forgot-password", { email: "bounced@corp.example" });
    expect(res.headers.get("location")).not.toContain("corp.example");
    expect(where(res).searchParams.get("error")).toBe("We can't send email to that address. Check the spelling.");
  });

  test("a Gmail address still gets a reset", async () => {
    const { app } = appWith();
    const res = await post(app, "/ui/forgot-password", { email: "someone@gmail.com" });
    expect(where(res).pathname).toBe("/forgot-password/sent");
  });
});

describe("verification resend", () => {
  test("/ui/verify-email/resend lands on the check-email page with the copy", async () => {
    const { app } = appWith("no_mail");
    const res = await post(app, `/ui/verify-email/resend?email=${encodeURIComponent("a@dead.example")}`);
    const url = where(res);
    expect(url.pathname).toBe("/login/check-email");
    expect(url.searchParams.get("undeliverable")).toBe("domain");
    expect(url.searchParams.get("throttled")).toBeNull();
    const html = await (await app.request(url.pathname + url.search)).text();
    expect(html).toContain("That email domain can&#39;t receive mail.");
  });

  test("a suppressed address renders the address copy", async () => {
    const { app } = appWith();
    await suppress("bounced@corp.example");
    const res = await post(app, `/ui/verify-email/resend?email=${encodeURIComponent("bounced@corp.example")}`);
    const url = where(res);
    expect(url.searchParams.get("undeliverable")).toBe("address");
    const html = await (await app.request(url.pathname + url.search)).text();
    expect(html).toContain("We can&#39;t send email to that address.");
  });

  test("the unverified-password resend maps the same way", async () => {
    const { app, auth } = appWith();
    const email = "unverified@corp.example";
    const id = crypto.randomUUID();
    await pg.db.user.create({ data: { id, email, name: email, emailVerified: false } });
    await pg.db.account.create({ data: {
      id: crypto.randomUUID(), accountId: id, providerId: "credential", userId: id,
      password: await (await auth.$context).password.hash("first-password-one"),
    } });
    await suppress(email);
    const res = await post(app, "/ui/login/password", { email, password: "first-password-one" });
    const url = where(res);
    expect(url.pathname).toBe("/login/check-email");
    expect(url.searchParams.get("undeliverable")).toBe("address");
    expect(url.searchParams.get("throttled")).toBeNull();
  });
});
