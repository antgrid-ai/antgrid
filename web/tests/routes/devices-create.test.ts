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
    // No subscription created → provisioned as free (sessionLimit 0, deviceLimit 10).

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
