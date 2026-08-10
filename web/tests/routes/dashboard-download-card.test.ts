import { test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import {
  createTestUser,
  createTestSession,
  createTestSubscription,
  createTestDevice,
} from "../helpers/fixtures.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

test("dashboard without workers shows the download card", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db);
  await createTestSubscription(pg.db, user.id);
  const { cookie } = await createTestSession(pg.db, user.id);

  const res = await app.request("/dashboard", { headers: { cookie } });
  expect(res.status).toBe(200);
  const html = await res.text();
  expect(html).toContain("Download the desktop app");
  expect(html).toContain("https://antgrid.ai/get-started");
});

test("dashboard with an agent machine hides the download card", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db);
  await createTestSubscription(pg.db, user.id);
  await createTestDevice(pg.db, { userId: user.id, deviceId: crypto.randomUUID() });
  const { cookie } = await createTestSession(pg.db, user.id);

  const res = await app.request("/dashboard", { headers: { cookie } });
  const html = await res.text();
  expect(html).not.toContain("Download the desktop app");
});

test("dashboard with only an app device still shows the card", async () => {
  // Pins that the gate is the worker axis, not any registered device.
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db);
  await createTestSubscription(pg.db, user.id);
  await createTestDevice(pg.db, {
    userId: user.id,
    deviceId: crypto.randomUUID(),
    kind: "app",
  });
  const { cookie } = await createTestSession(pg.db, user.id);

  const res = await app.request("/dashboard", { headers: { cookie } });
  const html = await res.text();
  expect(html).toContain("Download the desktop app");
});
