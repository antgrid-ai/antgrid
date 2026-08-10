import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
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

test("signed-in user sees the devices table on /devices", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db);
  await createTestSubscription(pg.db, user.id);
  await createTestDevice(pg.db, { userId: user.id, deviceId: "uuid-a", displayName: "My Mac" });
  const { cookie } = await createTestSession(pg.db, user.id);

  const res = await app.request("/devices", { headers: { cookie } });
  expect(res.status).toBe(200);
  const html = await res.text();
  expect(html).toContain("My Mac");
  expect(html).toContain("Revoke");
});

test("empty devices page shows the download card, not pairing instructions", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db);
  await createTestSubscription(pg.db, user.id);
  const { cookie } = await createTestSession(pg.db, user.id);

  const res = await app.request("/devices", { headers: { cookie } });
  const html = await res.text();
  expect(html).toContain("Download the desktop app");
  // The pairing CLI was never the shipped flow; keep it from resurfacing.
  expect(html).not.toContain("antgrid pair");
});

test("unauthenticated → redirect to /login", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const res = await app.request("/devices");
  expect(res.status).toBe(302);
  expect(res.headers.get("location")).toBe("/login");
});

describe("DELETE /ui/devices/:id", () => {
  test("revokes the device; it no longer appears in listActiveDevices", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);
    await createTestSubscription(pg.db, user.id);
    const { cookie } = await createTestSession(pg.db, user.id);
    const deviceUuid = crypto.randomUUID();
    await createTestDevice(pg.db, { userId: user.id, deviceId: deviceUuid, displayName: "Test Device" });
    const row = await pg.db.device.findFirstOrThrow({ where: { deviceId: deviceUuid } });

    const res = await app.request(`/ui/devices/${row.id}`, {
      method: "DELETE",
      headers: { cookie },
    });
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("");

    // Device should be revoked (revokedAt set); listActiveDevices filters it out.
    const after = await pg.db.device.findUniqueOrThrow({ where: { id: row.id } });
    expect(after.revokedAt).not.toBeNull();
  });

  test("non-UUID id → 404", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);
    const { cookie } = await createTestSession(pg.db, user.id);

    const res = await app.request("/ui/devices/not-a-uuid", {
      method: "DELETE",
      headers: { cookie },
    });
    expect(res.status).toBe(404);
  });
});
