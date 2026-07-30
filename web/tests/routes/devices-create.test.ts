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

describe("POST /account/devices", () => {
  test("creates an OAuth client + device row, returns clientId/clientSecret", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "alice@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro" });

    const body = {
      deviceUuid: crypto.randomUUID(),
      ed25519Pub: Buffer.alloc(32, 1).toString("base64"),
      x25519Pub: Buffer.alloc(32, 2).toString("base64"),
      platform: "macos",
      displayName: "Alice's Mac",
    };

    const res = await app.request("/account/devices", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify(body),
    });

    expect(res.status).toBe(201);
    const json = (await res.json()) as Record<string, string>;
    expect(json.deviceUuid).toBe(body.deviceUuid);
    expect(typeof json.clientId).toBe("string");
    expect(json.clientId.length).toBeGreaterThan(0);
    expect(typeof json.clientSecret).toBe("string");
    expect(json.clientSecret.length).toBeGreaterThan(0);

    const dev = await pg.db.device.findFirst({ where: { deviceId: body.deviceUuid } });
    expect(dev?.oauthClientId).toBe(json.clientId);
  });

  test("re-provisioning an existing device returns a fresh OAuth client secret", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "alice2@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro" });

    const body = {
      deviceUuid: crypto.randomUUID(),
      ed25519Pub: Buffer.alloc(32, 1).toString("base64"),
      x25519Pub: Buffer.alloc(32, 2).toString("base64"),
      platform: "macos",
      displayName: "Alice's Mac",
    };

    const first = await app.request("/account/devices", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const second = await app.request("/account/devices", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify(body),
    });

    expect(first.status).toBe(201);
    expect(second.status).toBe(200);

    const j1 = (await first.json()) as Record<string, unknown>;
    const j2 = (await second.json()) as Record<string, unknown>;
    expect(j2.clientId).not.toBe(j1.clientId);
    expect(typeof j2.clientSecret).toBe("string");
    expect((j2.clientSecret as string).length).toBeGreaterThan(0);
  });

  test("provisions a phone (ios/android) as kind 'app' so it joins the peer set", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "phone@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro" });

    const phonePub = Buffer.alloc(32, 7);
    const phone = {
      deviceUuid: crypto.randomUUID(),
      ed25519Pub: phonePub.toString("base64"),
      x25519Pub: Buffer.alloc(32, 8).toString("base64"),
      platform: "ios",
      displayName: "Alice's iPhone",
    };
    const res = await app.request("/account/devices", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify(phone),
    });
    expect(res.status).toBe(201);

    const dev = await pg.db.device.findFirst({ where: { deviceId: phone.deviceUuid } });
    expect(dev?.kind).toBe("app");

    // The end the kind serves: a phone's key must reach the same-account
    // membership peer set (else its control-plane auto-pair is rejected).
    const keys = await listAppDeviceKeys(pg.db, user.id);
    expect(keys.map((k) => k.toString("base64"))).toContain(phonePub.toString("base64"));
  });

  test("provisions a desktop (macos/windows/linux) as kind 'agent'", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "desktop@example.com");
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
        displayName: "Alice's PC",
      }),
    });
    expect(res.status).toBe(201);

    const dev = await pg.db.device.findFirst({ where: { deviceId: deviceUuid } });
    expect(dev?.kind).toBe("agent");
  });

  test("rejects requests without a session cookie", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/account/devices", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ deviceUuid: crypto.randomUUID() }),
    });
    expect(res.status).toBe(401);
  });

  test("free tier may register a device (fair-use device cap, not the paid axis)", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "bob@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    // No subscription created → provisioned by the default grant, whose caps are
    // generous enough that a first device is never the thing that trips them.

    const res = await app.request("/account/devices", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({
        deviceUuid: crypto.randomUUID(),
        ed25519Pub: Buffer.alloc(32, 1).toString("base64"),
        x25519Pub: Buffer.alloc(32, 2).toString("base64"),
        platform: "linux",
        displayName: "Bob's box",
      }),
    });
    expect(res.status).toBe(201);
  });

  test("returns 402 DEVICE_CAP when account exceeds the fair-use device limit", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "carol@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro", deviceLimit: 3 });

    for (let i = 0; i < 3; i++) {
      const res = await app.request("/account/devices", {
        method: "POST",
        headers: { cookie, "content-type": "application/json" },
        body: JSON.stringify({
          deviceUuid: crypto.randomUUID(),
          ed25519Pub: Buffer.alloc(32, i + 1).toString("base64"),
          x25519Pub: Buffer.alloc(32, i + 10).toString("base64"),
          platform: "linux",
          displayName: `Device ${i + 1}`,
        }),
      });
      expect(res.status).toBe(201);
    }

    const capped = await app.request("/account/devices", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({
        deviceUuid: crypto.randomUUID(),
        ed25519Pub: Buffer.alloc(32, 99).toString("base64"),
        x25519Pub: Buffer.alloc(32, 98).toString("base64"),
        platform: "linux",
        displayName: "One too many",
      }),
    });
    expect(capped.status).toBe(402);
    const body = (await capped.json()) as { error: string; limit: number };
    expect(body.error).toBe("DEVICE_CAP");
    expect(body.limit).toBe(3);
  });
});

type CapBody = {
  error: string;
  limit: number;
  devices: { id: string; device_id: string; display_name: string }[];
};

let seed = 0;
function registerBody(overrides: Record<string, unknown> = {}) {
  seed += 1;
  return {
    deviceUuid: crypto.randomUUID(),
    ed25519Pub: Buffer.alloc(32, seed % 251).toString("base64"),
    x25519Pub: Buffer.alloc(32, (seed + 97) % 251).toString("base64"),
    platform: "linux",
    displayName: `Device ${seed}`,
    ...overrides,
  };
}

type TestApp = ReturnType<typeof buildTestApp>["app"];

async function register(app: TestApp, cookie: string, body: Record<string, unknown>) {
  return app.request("/account/devices", {
    method: "POST",
    headers: { cookie, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("POST /account/devices — worker cap", () => {
  test("returns 402 WORKER_CAP listing only agent rows once the worker cap is full", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "workers@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro", workerLimit: 2, deviceLimit: 10 });

    const first = await register(app, cookie, registerBody({ displayName: "Worker one" }));
    const second = await register(app, cookie, registerBody({ displayName: "Worker two" }));
    expect(first.status).toBe(201);
    expect(second.status).toBe(201);

    // A phone consumes device_limit but never worker_limit, and must not be
    // offered as something to sign out.
    const phone = await register(
      app,
      cookie,
      registerBody({ platform: "ios", displayName: "Phone" })
    );
    expect(phone.status).toBe(201);

    const capped = await register(app, cookie, registerBody({ displayName: "Worker three" }));
    expect(capped.status).toBe(402);
    const body = (await capped.json()) as CapBody;
    expect(body.error).toBe("WORKER_CAP");
    expect(body.limit).toBe(2);
    expect(body.devices.map((d) => d.display_name).sort()).toEqual(["Worker one", "Worker two"]);
  });

  test("an already-active worker re-registers at the cap", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "reconnect@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro", workerLimit: 2, deviceLimit: 10 });

    const existing = registerBody({ displayName: "Worker one" });
    expect((await register(app, cookie, existing)).status).toBe(201);
    expect((await register(app, cookie, registerBody({ displayName: "Worker two" }))).status).toBe(
      201
    );

    // The cap is full, but a machine that already holds a slot must never be
    // locked out of its own re-provisioning.
    const again = await register(app, cookie, existing);
    expect(again.status).toBe(200);
  });

  test("an app device registers freely while the worker cap is full", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "apps@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro", workerLimit: 1, deviceLimit: 10 });

    expect((await register(app, cookie, registerBody({ displayName: "Worker" }))).status).toBe(201);

    const phone = await register(
      app,
      cookie,
      registerBody({ platform: "android", displayName: "Phone" })
    );
    expect(phone.status).toBe(201);

    // The desktop controller registers as kind:"app" on a desktop platform —
    // the case where only the explicit kind keeps it off the worker meter.
    const controller = await register(
      app,
      cookie,
      registerBody({ platform: "macos", kind: "app", displayName: "Desktop controller" })
    );
    expect(controller.status).toBe(201);
  });

  // `kind` and `deviceUuid` are both client-supplied, so the reactivation
  // exemption has to be scoped to agent rows. Exempting any active row would
  // let an account at its cap register cheap app rows and promote them,
  // raising the paid axis to device_limit.
  test("an active app row cannot be flipped to a worker while the cap is full", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "flip@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro", workerLimit: 1, deviceLimit: 10 });

    expect((await register(app, cookie, registerBody({ displayName: "Worker" }))).status).toBe(201);

    const phone = registerBody({ platform: "ios", displayName: "Phone" });
    expect((await register(app, cookie, phone)).status).toBe(201);

    const flipped = await register(app, cookie, { ...phone, kind: "agent" });
    expect(flipped.status).toBe(402);
    expect(((await flipped.json()) as CapBody).error).toBe("WORKER_CAP");

    // And the row must not have been promoted on the way out.
    const row = await pg.db.device.findUnique({
      where: { userId_deviceId: { userId: user.id, deviceId: phone.deviceUuid as string } },
    });
    expect(row?.kind).toBe("app");
  });

  test("the device cap still fires first when workers are under their own limit", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "independent@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro", workerLimit: 5, deviceLimit: 2 });

    expect((await register(app, cookie, registerBody())).status).toBe(201);
    expect((await register(app, cookie, registerBody())).status).toBe(201);

    const capped = await register(app, cookie, registerBody());
    expect(capped.status).toBe(402);
    const body = (await capped.json()) as CapBody;
    expect(body.error).toBe("DEVICE_CAP");
    expect(body.limit).toBe(2);
  });
});
