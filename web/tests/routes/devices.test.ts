import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession, createTestDevice } from "../helpers/fixtures.js";

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

describe("/account/devices", () => {
  test("GET returns the user's active devices", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestDevice(pg.db, { userId: user.id, deviceId: "d-1", kind: "agent", platform: "macos", displayName: "Mac" });
    await createTestDevice(pg.db, { userId: user.id, deviceId: "d-2", kind: "app", platform: "ios", displayName: "iPhone" });

    const res = await app.request("/account/devices", { headers: { cookie } });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.devices).toHaveLength(2);
  });

  test("DELETE revokes and hides the device from subsequent lists", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);
    const { cookie } = await createTestSession(pg.db, user.id);
    const { id } = await createTestDevice(pg.db, { userId: user.id, deviceId: "d-1", kind: "agent", platform: "macos", displayName: "Mac" });

    const delRes = await app.request(`/account/devices/${id}`, { method: "DELETE", headers: { cookie } });
    expect(delRes.status).toBe(200);

    const list = await app.request("/account/devices", { headers: { cookie } });
    const body = await list.json();
    expect(body.devices).toHaveLength(0);

    const row = await pg.db.device.findUnique({ where: { id }, select: { revokedAt: true } });
    expect(row?.revokedAt).not.toBeNull();
  });

  test("DELETE requires auth", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request(`/account/devices/${crypto.randomUUID()}`, { method: "DELETE" });
    expect(res.status).toBe(401);
  });

  test("DELETE only revokes devices owned by the caller", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const a = await createTestUser(pg.db);
    const b = await createTestUser(pg.db);
    const { cookie } = await createTestSession(pg.db, a.id);
    const { id } = await createTestDevice(pg.db, { userId: b.id, deviceId: "d-1", kind: "agent", platform: "macos", displayName: "Mac" });
    const res = await app.request(`/account/devices/${id}`, { method: "DELETE", headers: { cookie } });
    expect(res.status).toBe(404);
  });
});
