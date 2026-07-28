import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import {
  createTestUser,
  createTestSession,
  createTestSubscription,
  createTestDevice,
} from "../helpers/fixtures.js";

const AGENT_RESOURCE = "http://localhost:8787/api/auth";

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

/**
 * Provision an agent device and mint a Bearer JWT for it — the same path the
 * agent/bridge uses in prod. Returns the token and deviceUuid.
 */
async function provisionAndMintToken(
  app: ReturnType<typeof buildTestApp>["app"],
  cookie: string
): Promise<{ token: string; deviceUuid: string }> {
  const deviceUuid = crypto.randomUUID();
  const pub = Buffer.alloc(32, 0xab).toString("base64");
  const provision = await app.request("/account/devices", {
    method: "POST",
    headers: { cookie, "content-type": "application/json" },
    body: JSON.stringify({
      deviceUuid,
      ed25519Pub: pub,
      x25519Pub: Buffer.alloc(32, 0xcd).toString("base64"),
      platform: "linux",
      displayName: "peers-test-agent",
    }),
  });
  if (provision.status !== 201) {
    throw new Error(`provision failed: ${provision.status} ${await provision.text()}`);
  }
  const creds = (await provision.json()) as {
    deviceUuid: string;
    clientId: string;
    clientSecret: string;
  };
  const mint = await app.request("/api/auth/oauth2/token", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization:
        "Basic " +
        Buffer.from(`${creds.clientId}:${creds.clientSecret}`).toString("base64"),
    },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      scope: "agent",
      resource: AGENT_RESOURCE,
    }).toString(),
  });
  if (mint.status !== 200) {
    throw new Error(`mint failed: ${mint.status} ${await mint.text()}`);
  }
  const tokenJson = (await mint.json()) as { access_token: string };
  return { token: tokenJson.access_token, deviceUuid: creds.deviceUuid };
}

describe("GET /account/devices/me/peers", () => {
  test("returns base64 ed25519 keys of the caller's non-revoked app devices", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "alice@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);
    const { token } = await provisionAndMintToken(app, cookie);

    const appKey = Buffer.alloc(32, 1);
    const appDeviceId = crypto.randomUUID();

    // Included: app kind, non-revoked
    await createTestDevice(pg.db, {
      userId: user.id,
      deviceId: appDeviceId,
      kind: "app",
      platform: "ios",
      displayName: "Alice's iPhone",
      publicKey: appKey,
    });

    // Excluded: agent kind
    await createTestDevice(pg.db, {
      userId: user.id,
      deviceId: crypto.randomUUID(),
      kind: "agent",
      platform: "linux",
      displayName: "Alice's Agent",
      publicKey: Buffer.alloc(32, 2),
    });

    // Excluded: app kind but revoked
    const revokedId = crypto.randomUUID();
    await createTestDevice(pg.db, {
      userId: user.id,
      deviceId: revokedId,
      kind: "app",
      platform: "android",
      displayName: "Alice's Old Phone",
      publicKey: Buffer.alloc(32, 3),
    });
    await pg.db.device.update({
      where: { userId_deviceId: { userId: user.id, deviceId: revokedId } },
      data: { revokedAt: new Date() },
    });

    const res = await app.request("/account/devices/me/peers", {
      headers: { authorization: `Bearer ${token}` },
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      keys: string[];
      devices: { deviceId: string; ed25519Pub: string }[];
    };
    expect(body.keys).toEqual([appKey.toString("base64")]);
    // devices[] carries deviceId alongside the key (for Task 5/6 inventory
    // admission); revoked/non-app devices excluded same as keys[].
    expect(body.devices).toEqual([
      { deviceId: appDeviceId, ed25519Pub: appKey.toString("base64") },
    ]);
  });

  test("returns empty array when no app devices exist", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "bob@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);
    const { token } = await provisionAndMintToken(app, cookie);

    const res = await app.request("/account/devices/me/peers", {
      headers: { authorization: `Bearer ${token}` },
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      keys: string[];
      devices: { deviceId: string; ed25519Pub: string }[];
    };
    expect(body.keys).toEqual([]);
    expect(body.devices).toEqual([]);
  });

  test("returns 401 when unauthenticated", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/account/devices/me/peers");
    expect(res.status).toBe(401);
  });

  test("rejects a session cookie (peers is Bearer-only)", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "carol@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);

    const res = await app.request("/account/devices/me/peers", {
      headers: { cookie },
    });

    expect(res.status).toBe(401);
  });

  test("does not return another user's app devices", async () => {
    const { app } = buildTestApp(pg.db, pg.url);

    // Alice: caller
    const alice = await createTestUser(pg.db, "alice2@example.com");
    await createTestSubscription(pg.db, alice.id, { tier: "pro" });
    const { cookie: aliceCookie } = await createTestSession(pg.db, alice.id);
    const { token } = await provisionAndMintToken(app, aliceCookie);

    // Bob: has an app device Alice must NOT see
    const bob = await createTestUser(pg.db, "bob2@example.com");
    await createTestDevice(pg.db, {
      userId: bob.id,
      deviceId: crypto.randomUUID(),
      kind: "app",
      platform: "ios",
      displayName: "Bob's iPhone",
      publicKey: Buffer.alloc(32, 0xff),
    });

    const res = await app.request("/account/devices/me/peers", {
      headers: { authorization: `Bearer ${token}` },
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { keys: string[] };
    expect(body.keys).toEqual([]);
  });
});
