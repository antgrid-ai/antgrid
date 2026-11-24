// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { TEST_BETTER_AUTH_SECRET, buildTestApp } from "../helpers/app.js";
import { recipientLimit } from "../../src/auth/recipient-limit.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

const resetFor = (app: ReturnType<typeof buildTestApp>["app"], email: string) =>
  app.request("/api/auth/request-password-reset", {
    method: "POST",
    headers: { "content-type": "application/json", origin: "http://localhost:8787" },
    body: JSON.stringify({ email }),
  });

describe("recipientLimit", () => {
  test("dot and +tag variants of one Gmail mailbox share a bucket", async () => {
    const variants = ["jeff@gmail.com", "j.e.f.f@gmail.com", "jeff+a@gmail.com", "J.eff+b@googlemail.com", "je.ff@gmail.com"];
    for (const email of variants) {
      expect(await recipientLimit(pg.db, TEST_BETTER_AUTH_SECRET, email)).toBe(0);
      // Clear the 45 s cooldown only, so the hourly count keeps accumulating.
      const [row] = await pg.db.authRateBucket.findMany();
      await pg.db.authRateBucket.update({ where: { key: row.key }, data: { stamps: row.stamps.map((s) => new Date(s.getTime() - 60000)) } });
    }
    expect(await pg.db.authRateBucket.count()).toBe(1);
    expect(await recipientLimit(pg.db, TEST_BETTER_AUTH_SECRET, "j.e.f.f+z@gmail.com")).toBeGreaterThan(0);
  });

  test("the sixth request for one mailbox over HTTP is 429 EMAIL_THROTTLED", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const variants = ["jeff@gmail.com", "j.e.f.f@gmail.com", "jeff+a@gmail.com", "J.eff+b@googlemail.com", "je.ff@gmail.com"];
    for (const email of variants) {
      expect((await resetFor(app, email)).status).toBe(200);
      // Age the recipient bucket past its 45 s cooldown and refill the IP bucket,
      // so only the hourly count can refuse the sixth request.
      await pg.db.authRateBucket.deleteMany({ where: { key: { startsWith: "ip:" } } });
      for (const row of await pg.db.authRateBucket.findMany()) {
        await pg.db.authRateBucket.update({ where: { key: row.key }, data: { stamps: row.stamps.map((s) => new Date(s.getTime() - 60000)) } });
      }
    }
    const sixth = await resetFor(app, "j.e.f.f+z@gmail.com");
    expect(sixth.status).toBe(429);
    expect(((await sixth.json()) as { code: string }).code).toBe("EMAIL_THROTTLED");
  });

  test("other providers keep dots and tags distinct", async () => {
    await recipientLimit(pg.db, TEST_BETTER_AUTH_SECRET, "first.last@outlook.example");
    await recipientLimit(pg.db, TEST_BETTER_AUTH_SECRET, "firstlast@outlook.example");
    expect(await pg.db.authRateBucket.count()).toBe(2);
  });
});
