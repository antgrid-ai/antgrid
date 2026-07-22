import { test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import {
  createTestUser,
  createTestSession,
  createTestSubscription,
} from "../helpers/fixtures.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

// buildTestApp leaves the relay unconfigured, so listUserSessions returns null
// (relay unreachable). The dashboard must still render and show the section.
test("pro dashboard renders the active-sessions section (relay unreachable → notice)", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db);
  await createTestSubscription(pg.db, user.id, { tier: "pro" });
  const { cookie } = await createTestSession(pg.db, user.id);

  const res = await app.request("/dashboard", { headers: { cookie } });
  expect(res.status).toBe(200);
  const html = await res.text();
  expect(html).toContain("Active sessions");
  expect(html).toContain("reach the relay");
});

test("dashboard no longer renders the devices table", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db);
  await createTestSubscription(pg.db, user.id, { tier: "pro" });
  const { cookie } = await createTestSession(pg.db, user.id);

  const res = await app.request("/dashboard", { headers: { cookie } });
  const html = await res.text();
  // The devices explainer string lives on /devices now, not the dashboard.
  expect(html).not.toContain("POST /account/devices");
});
