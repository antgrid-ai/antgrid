// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { composeMail } from "../../src/mail-stack.js";
import { sendNextEmail } from "../../src/auth/email-outbox.js";
import type { Env } from "../../src/env.js";
import { TEST_BETTER_AUTH_SECRET } from "../helpers/app.js";

const HOOK = "e2e-webhook-secret-key-0123456789";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

test("a recipient-side bounce refuses the next request for that address", async () => {
  const stack = composeMail({ NODE_ENV: "test", BETTER_AUTH_SECRET: TEST_BETTER_AUTH_SECRET, EMAIL_FROM: "Antgrid <no-reply@radhaai.org>", EMAIL_REPLY_TO: "contact@radhaai.com" } as Env, pg.db);
  const { app } = buildTestApp(pg.db, pg.url, { sendEmail: stack.sendEmail, mailDomain: stack.mailDomain, envOverrides: { ZEPTOMAIL_WEBHOOK_SECRET: HOOK } as Partial<Env> });
  const start = async () => {
    await pg.db.authRateBucket.deleteMany();
    return app.request("/api/auth/sign-in/cross-device/start", {
      method: "POST", headers: { "content-type": "application/json", origin: "http://localhost:8787" },
      body: JSON.stringify({ email: "gone@example.com" }),
    });
  };

  expect((await start()).status).toBe(200);
  const sent: string[] = [];
  expect(await sendNextEmail(pg.db, stack.keys, async (mail) => { sent.push(mail.to); })).toBe(true);
  expect(sent).toEqual(["gone@example.com"]);

  const job = await pg.db.emailJob.findFirstOrThrow();
  const hook = await app.request(`/webhooks/zeptomail/${HOOK}`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({
      event_name: ["hardbounce"],
      event_message: [{ email_info: { client_reference: job.reference }, event_data: [{ details: [{ reason: "unknown-user" }] }] }],
    }),
  });
  expect(hook.status).toBe(200);

  const second = await start();
  expect(second.status).toBe(400);
  expect(((await second.json()) as { code: string }).code).toBe("EMAIL_UNDELIVERABLE");
  expect(await pg.db.emailJob.count()).toBe(1);
});
