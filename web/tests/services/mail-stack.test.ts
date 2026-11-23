// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { TEST_BETTER_AUTH_SECRET } from "../helpers/app.js";
import { composeMail } from "../../src/mail-stack.js";
import { acceptAllMailDomains } from "../../src/auth/mail-domain.js";
import { recipientDigest } from "../../src/auth/recipient-key.js";
import type { Env } from "../../src/env.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

const realFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = realFetch; });

const envWith = (over: Partial<Env> = {}) => ({
  NODE_ENV: "test", BETTER_AUTH_SECRET: TEST_BETTER_AUTH_SECRET, EMAIL_FROM: "Antgrid <no-reply@radhaai.org>",
  EMAIL_REPLY_TO: "contact@radhaai.com", ...over,
}) as Env;

test("without a provider token the domain check accepts everything, and queued jobs carry a digest", async () => {
  const stack = composeMail(envWith(), pg.db);
  expect(stack.mailDomain).toBe(acceptAllMailDomains);
  await stack.sendEmail({ to: "Someone@Example.com", subject: "s", text: "t" });
  const job = await pg.db.emailJob.findFirstOrThrow();
  expect(job.recipientHash).not.toBeNull();
  expect(Buffer.from(job.recipientHash!).equals(Buffer.from(recipientDigest(TEST_BETTER_AUTH_SECRET, "someone@example.com")))).toBe(true);
});

test("with a provider token the real domain check is wired", () => {
  expect(composeMail(envWith({ ZEPTOMAIL_TOKEN: "token" }), pg.db).mailDomain).not.toBe(acceptAllMailDomains);
});

async function sentSubject(env: Env): Promise<string> {
  let body = "";
  globalThis.fetch = (async (_url: unknown, init?: RequestInit) => {
    body = String(init?.body);
    return new Response(JSON.stringify({ data: [{ message_id: "m" }] }), { status: 200, headers: { "content-type": "application/json" } });
  }) as typeof fetch;
  await composeMail(env, pg.db).providerSend({ to: "a@example.com", subject: "Hello", text: "t" });
  return JSON.parse(body).subject;
}

test("non-production stacks that really send tag the subject; production does not", async () => {
  expect(await sentSubject(envWith({ NODE_ENV: "staging", ZEPTOMAIL_TOKEN: "token" }))).toBe("[staging] Hello");
  expect(await sentSubject(envWith({ NODE_ENV: "production", ZEPTOMAIL_TOKEN: "token" }))).toBe("Hello");
});
