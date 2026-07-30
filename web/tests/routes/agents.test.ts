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
 * Provision a device through the real session-authenticated route, then mint
 * an OAuth `client_credentials` JWT via the real token endpoint. Returns the
 * Bearer token plus the device's UUID — same path the agent takes in prod.
 */
async function provisionAndMintToken(
  app: ReturnType<typeof buildTestApp>["app"],
  cookie: string
): Promise<{ token: string; deviceUuid: string; pub: string }> {
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
      displayName: "heartbeat-test-agent",
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
  return { token: tokenJson.access_token, deviceUuid: creds.deviceUuid, pub };
}

describe("GET /account/agents", () => {
  test("returns mobile-enabled agent devices only", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "alice@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);

    const enabledId = crypto.randomUUID();
    const disabledId = crypto.randomUUID();

    // Create a mobile-enabled agent device
    await createTestDevice(pg.db, {
      userId: user.id,
      deviceId: enabledId,
      kind: "agent",
      platform: "linux",
      displayName: "Alice's Agent",
    });
    await pg.db.device.update({
      where: { userId_deviceId: { userId: user.id, deviceId: enabledId } },
      data: { mobileAccessEnabled: true, relayUrl: "wss://relay.example.com" },
    });

    // Create a mobile-disabled agent device
    await createTestDevice(pg.db, {
      userId: user.id,
      deviceId: disabledId,
      kind: "agent",
      platform: "macos",
      displayName: "Alice's Other Agent",
    });
    // mobileAccessEnabled defaults to false — leave it

    const res = await app.request("/account/agents", {
      method: "GET",
      headers: { cookie },
    });

    expect(res.status).toBe(200);
    const json = (await res.json()) as { agents: Record<string, unknown>[] };
    expect(json.agents).toHaveLength(1);
    expect(json.agents[0].deviceUuid).toBe(enabledId);
    expect(json.agents[0].displayName).toBe("Alice's Agent");
    expect(json.agents[0].relayUrl).toBe("wss://relay.example.com");
    expect(typeof json.agents[0].ed25519Pub).toBe("string");
  });

  test("excludes revoked devices even if mobileAccessEnabled was true", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "bob@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);

    const deviceId = crypto.randomUUID();
    await createTestDevice(pg.db, {
      userId: user.id,
      deviceId,
      kind: "agent",
      platform: "linux",
      displayName: "Bob's Agent",
    });
    await pg.db.device.update({
      where: { userId_deviceId: { userId: user.id, deviceId } },
      data: { mobileAccessEnabled: true, revokedAt: new Date() },
    });

    const res = await app.request("/account/agents", {
      method: "GET",
      headers: { cookie },
    });

    expect(res.status).toBe(200);
    const json = (await res.json()) as { agents: unknown[] };
    expect(json.agents).toHaveLength(0);
  });

  test("returns 401 when unauthenticated", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/account/agents", { method: "GET" });
    expect(res.status).toBe(401);
  });

  test("returns empty list when user has no mobile-enabled agents", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "carol@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);

    const res = await app.request("/account/agents", {
      method: "GET",
      headers: { cookie },
    });

    expect(res.status).toBe(200);
    const json = (await res.json()) as { agents: unknown[] };
    expect(json.agents).toHaveLength(0);
  });
});

describe("POST /account/devices/me/heartbeat", () => {
  test("updates lastSeenAt, mobileAccessEnabled, and relayUrl when authenticated with Bearer JWT", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "dave@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);

    const { token, deviceUuid } = await provisionAndMintToken(app, cookie);

    const before = await pg.db.device.findUnique({
      where: { userId_deviceId: { userId: user.id, deviceId: deviceUuid } },
      select: { lastSeenAt: true },
    });
    expect(before?.lastSeenAt).toBeNull();

    const res = await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceUuid,
        mobileAccessEnabled: true,
        relayUrl: "wss://relay.antgrid.ai",
      }),
    });

    expect(res.status).toBe(200);
    const json = await res.json();
    expect((json as { ok: boolean }).ok).toBe(true);

    const after = await pg.db.device.findUnique({
      where: { userId_deviceId: { userId: user.id, deviceId: deviceUuid } },
      select: { lastSeenAt: true, mobileAccessEnabled: true, relayUrl: true },
    });
    expect(after?.lastSeenAt).not.toBeNull();
    expect(after?.mobileAccessEnabled).toBe(true);
    expect(after?.relayUrl).toBe("wss://relay.antgrid.ai");
  });

  test("persists machineName and /account/agents echoes it", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "heidi@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);

    const { token, deviceUuid } = await provisionAndMintToken(app, cookie);

    const res = await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceUuid,
        mobileAccessEnabled: true,
        machineName: "Mac Studio",
      }),
    });
    expect(res.status).toBe(200);

    const inventory = await app.request("/account/agents", {
      method: "GET",
      headers: { cookie },
    });
    expect(inventory.status).toBe(200);
    const json = (await inventory.json()) as {
      agents: { deviceUuid: string; machineName: string | null }[];
    };
    const entry = json.agents.find((a) => a.deviceUuid === deviceUuid);
    expect(entry).toBeDefined();
    expect(entry?.machineName).toBe("Mac Studio");
  });

  test("a heartbeat without machineName does not clobber a known value", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "ivan@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);

    const { token, deviceUuid } = await provisionAndMintToken(app, cookie);

    // First heartbeat sets machineName.
    await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ deviceUuid, mobileAccessEnabled: true, machineName: "Mac Studio" }),
    });

    // Second heartbeat omits machineName — must not null it out.
    await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ deviceUuid, mobileAccessEnabled: true }),
    });

    const after = await pg.db.device.findUnique({
      where: { userId_deviceId: { userId: user.id, deviceId: deviceUuid } },
      select: { machineName: true },
    });
    expect(after?.machineName).toBe("Mac Studio");
  });

  test("a minimal heartbeat (deviceUuid only, as an app/phone sends) updates "
    + "lastSeenAt without requiring mobileAccessEnabled and without clobbering "
    + "an agent's existing fields", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "judy@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);

    const { token, deviceUuid } = await provisionAndMintToken(app, cookie);

    // Establish agent-set fields first, as the bridge would.
    await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({
        deviceUuid,
        mobileAccessEnabled: true,
        relayUrl: "wss://relay.antgrid.ai",
        machineName: "Mac Studio",
      }),
    });

    // App/phone heartbeat sends only deviceUuid.
    const res = await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ deviceUuid }),
    });
    expect(res.status).toBe(200);

    const after = await pg.db.device.findUnique({
      where: { userId_deviceId: { userId: user.id, deviceId: deviceUuid } },
      select: { lastSeenAt: true, mobileAccessEnabled: true, relayUrl: true, machineName: true },
    });
    expect(after?.lastSeenAt).not.toBeNull();
    expect(after?.mobileAccessEnabled).toBe(true);
    expect(after?.relayUrl).toBe("wss://relay.antgrid.ai");
    expect(after?.machineName).toBe("Mac Studio");
  });

  test("mobileAccessEnabled:false and relayUrl:null turn remote access back off", async () => {
    // The three optional fields are NOT applied uniformly, and the asymmetry is
    // deliberate: `false`/`null` are how the bridge reports remote access being
    // switched off, so those two must reach the row. machineName has no "clear
    // it" story (the bridge always sends one), so its `!= null` guard treats an
    // explicit null as absent — asserted below so a uniformity refactor trips.
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "judy2@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);

    const { token, deviceUuid } = await provisionAndMintToken(app, cookie);
    const beat = (extra: Record<string, unknown>) =>
      app.request("/account/devices/me/heartbeat", {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify({ deviceUuid, ...extra }),
      });

    await beat({
      mobileAccessEnabled: true,
      relayUrl: "wss://relay.antgrid.ai",
      machineName: "Mac Studio",
    });

    const res = await beat({
      mobileAccessEnabled: false,
      relayUrl: null,
      machineName: null,
    });
    expect(res.status).toBe(200);

    const after = await pg.db.device.findUnique({
      where: { userId_deviceId: { userId: user.id, deviceId: deviceUuid } },
      select: { mobileAccessEnabled: true, relayUrl: true, machineName: true },
    });
    expect(after?.mobileAccessEnabled).toBe(false);
    expect(after?.relayUrl).toBeNull();
    expect(after?.machineName).toBe("Mac Studio");
  });

  test("rejects a session cookie (heartbeat is Bearer-only)", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "dave2@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);

    const deviceId = crypto.randomUUID();
    await createTestDevice(pg.db, {
      userId: user.id,
      deviceId,
      kind: "agent",
      platform: "linux",
      displayName: "Dave's Agent",
    });

    const res = await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({
        deviceUuid: deviceId,
        mobileAccessEnabled: true,
      }),
    });
    expect(res.status).toBe(401);
  });

  test("returns 404 when deviceUuid is not owned by the caller", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const alice = await createTestUser(pg.db, "alice2@example.com");
    await createTestSubscription(pg.db, alice.id, { tier: "pro" });
    const bob = await createTestUser(pg.db, "bob2@example.com");
    const { cookie: aliceCookie } = await createTestSession(pg.db, alice.id);

    const { token } = await provisionAndMintToken(app, aliceCookie);

    // Bob has his own device that Alice's token must not be able to touch.
    const bobDeviceId = crypto.randomUUID();
    await createTestDevice(pg.db, {
      userId: bob.id,
      deviceId: bobDeviceId,
      kind: "agent",
      platform: "linux",
      displayName: "Bob's Device",
    });

    const res = await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceUuid: bobDeviceId,
        mobileAccessEnabled: true,
      }),
    });

    expect(res.status).toBe(404);
  });

  test("returns 404 when device is revoked", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "eve@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);

    const { token, deviceUuid } = await provisionAndMintToken(app, cookie);
    await pg.db.device.update({
      where: { userId_deviceId: { userId: user.id, deviceId: deviceUuid } },
      data: { revokedAt: new Date() },
    });

    const res = await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceUuid,
        mobileAccessEnabled: true,
      }),
    });

    expect(res.status).toBe(404);
  });

  test("returns 400 on invalid body", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "frank@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);

    const { token } = await provisionAndMintToken(app, cookie);

    const res = await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ deviceUuid: "not-a-uuid" }),
    });

    expect(res.status).toBe(400);
  });

  test("returns 401 when unauthenticated", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ deviceUuid: crypto.randomUUID(), mobileAccessEnabled: true }),
    });
    expect(res.status).toBe(401);
  });

  test("returns 401 when Bearer token is malformed", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: {
        authorization: "Bearer not-a-real-jwt",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceUuid: crypto.randomUUID(),
        mobileAccessEnabled: true,
      }),
    });
    expect(res.status).toBe(401);
  });

  test("returns 401 when Bearer token has a bad signature", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "grace@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const { cookie } = await createTestSession(pg.db, user.id);

    const { token } = await provisionAndMintToken(app, cookie);
    // Replace the signature segment with a different valid-base64url string
    // of the same length so jose's decode succeeds but the Ed25519 verify
    // fails — exercising the bad-signature path rather than a parse failure.
    const parts = token.split(".");
    expect(parts).toHaveLength(3);
    const tamperedSig = "A".repeat(parts[2].length);
    expect(tamperedSig).not.toBe(parts[2]);
    const tampered = `${parts[0]}.${parts[1]}.${tamperedSig}`;

    const res = await app.request("/account/devices/me/heartbeat", {
      method: "POST",
      headers: {
        authorization: `Bearer ${tampered}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceUuid: crypto.randomUUID(),
        mobileAccessEnabled: true,
      }),
    });
    expect(res.status).toBe(401);
  });
});
