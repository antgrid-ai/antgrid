// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import type { SendEmail } from "../../src/auth/email.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

const ORIGIN = "http://localhost:8787";

function harness() {
  const sent: unknown[] = [];
  const sendEmail: SendEmail = async (args) => { sent.push(args); };
  const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
  const post = (path: string, body: Record<string, string>) => app.request(path, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", origin: ORIGIN },
    body: new URLSearchParams(body).toString(),
  });
  return { app, sent, post };
}

describe("login honeypot", () => {
  for (const path of ["/ui/login/continue", "/ui/login/start"]) {
    test(`${path} sends nothing when the hidden field is filled`, async () => {
      const { sent, post } = harness();
      const res = await post(path, { email: "bot@corp.example", ab_contact_ref: "x" });
      expect(res.status).toBe(302);
      expect(new URL(res.headers.get("location") ?? "", ORIGIN).searchParams.get("error")).toBe("Could not send link");
      expect(sent).toHaveLength(0);
      expect(await pg.db.pendingSignIn.count()).toBe(0);
    });

    test(`${path} sends as usual when the field is absent or empty`, async () => {
      for (const extra of [{}, { ab_contact_ref: "" }] as Record<string, string>[]) {
        const { sent, post } = harness();
        const res = await post(path, { email: `human+${crypto.randomUUID()}@corp.example`, ...extra });
        expect(res.headers.get("location")).toStartWith("/login/pending/");
        expect(sent).toHaveLength(1);
      }
    });
  }

  test("the login form carries the hidden field", async () => {
    const { app } = harness();
    const html = await (await app.request("/login")).text();
    expect(html).toContain('name="ab_contact_ref"');
    expect(html).toContain('tabindex="-1"');
  });
});
