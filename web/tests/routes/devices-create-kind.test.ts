import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession, createTestSubscription } from "../helpers/fixtures.js";
import { listAppDeviceKeys } from "../../src/models/device.js";

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

describe("POST /account/devices — explicit kind override", () => {
  test("explicit kind:'app' on a desktop platform creates an app device served by the peers set", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "controller@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro" });

    const controllerPub = Buffer.alloc(32, 5);
    const deviceUuid = crypto.randomUUID();
    const res = await app.request("/account/devices", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({
        deviceUuid,
        ed25519Pub: controllerPub.toString("base64"),
        x25519Pub: Buffer.alloc(32, 6).toString("base64"),
        platform: "windows",
        displayName: "Desk controller",
        kind: "app",
      }),
    });
    expect(res.status).toBe(201);

    const dev = await pg.db.device.findFirst({ where: { deviceId: deviceUuid } });
    expect(dev?.kind).toBe("app");

    // The end the kind serves: a desktop-platform controller must reach the
    // same-account membership peer set despite its platform, same as a phone.
    const keys = await listAppDeviceKeys(pg.db, user.id);
    expect(keys.map((k) => k.toString("base64"))).toContain(controllerPub.toString("base64"));
  });

  test("omitted kind keeps the platform derivation (windows -> agent)", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "desktop-default@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro" });

    const deviceUuid = crypto.randomUUID();
    const res = await app.request("/account/devices", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({
        deviceUuid,
        ed25519Pub: Buffer.alloc(32, 1).toString("base64"),
        x25519Pub: Buffer.alloc(32, 2).toString("base64"),
        platform: "windows",
        displayName: "Plain PC",
      }),
    });
    expect(res.status).toBe(201);

    const dev = await pg.db.device.findFirst({ where: { deviceId: deviceUuid } });
    expect(dev?.kind).toBe("agent");
  });
});
