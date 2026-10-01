// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { describe, test, expect, beforeAll, afterAll, beforeEach, spyOn } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession } from "../helpers/fixtures.js";

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});
beforeEach(async () => {
  await pg.truncate();
});

const OPERATOR = "bharathm@radhaai.com";

test("operator email → 200 renders the connections page", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db, OPERATOR);
  const { cookie } = await createTestSession(pg.db, user.id);

  const res = await app.request("/internal/connections", { headers: { cookie } });
  expect(res.status).toBe(200);
  expect(await res.text()).toContain("Relay connections");
});

// Every operator page shares one gate (`requireOperator` in routes/ui.tsx).
for (const page of ["connections", "stats"]) {
  const path = `/internal/${page}`;
  describe(path, () => {
    test("operator email is matched case-insensitively", async () => {
      const { app } = buildTestApp(pg.db, pg.url);
      const user = await createTestUser(pg.db, "BharathM@Radhaai.com");
      const { cookie } = await createTestSession(pg.db, user.id);

      const res = await app.request(path, { headers: { cookie } });
      expect(res.status).toBe(200);
    });

    test("signed-in non-operator → 404 (route existence not revealed), logged as denied", async () => {
      const { app } = buildTestApp(pg.db, pg.url);
      const user = await createTestUser(pg.db, "someone-else@test.local");
      const { cookie } = await createTestSession(pg.db, user.id);

      const warn = spyOn(console, "warn").mockImplementation(() => {});
      try {
        const res = await app.request(path, { headers: { cookie } });
        expect(res.status).toBe(404);
        const evt = `internal.${page}.denied`;
        const hit = warn.mock.calls.map((a) => String(a[0])).find((l) => l.includes(evt));
        expect(hit).toBeDefined();
        expect(JSON.parse(hit!)).toMatchObject({ evt, userId: user.id, email: user.email });
      } finally {
        warn.mockRestore();
      }
    });

    test("unauthenticated → redirect to /login", async () => {
      const { app } = buildTestApp(pg.db, pg.url);
      const res = await app.request(path);
      expect(res.status).toBe(302);
      expect(res.headers.get("location")).toBe("/login");
    });
  });
}
