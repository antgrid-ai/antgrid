import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { randomBytes, randomUUID } from "node:crypto";
import { getPublicKeyAsync, signAsync } from "@noble/ed25519";
import { endpointChallengeBytes } from "antgrid-wire";
import { Hono } from "hono";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createEndpointChallenge, registerEndpoint, admitRelayEndpoint } from "../../src/models/peer-authorization.js";
import { provisionProductAccountForUser } from "../../src/models/subscription.js";
import { buildTestApp } from "../helpers/app.js";
import { irohAccessRoutes } from "../../src/routes/iroh-access.js";
import type { Env } from "../../src/env.js";

let pg: PgHandle;
const deviceSecret = randomBytes(32);
let identity: { id: string; deviceId: string; userId: string; enrollmentId: string; publicKey: Uint8Array; kind: string };

const token = "iroh-access-test-bearer-token-32";
const relayUrl = "https://relay.example/";
const PATH = "/internal/iroh-access";

beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg?.stop(); });
beforeEach(async () => {
  await pg.truncate();
  const publicKey = await getPublicKeyAsync(deviceSecret);
  const userId = randomUUID(), deviceId = randomUUID(), enrollmentId = randomUUID();
  await pg.db.user.create({ data: { id: userId, name: "test", email: `${userId}@example.com`, emailVerified: true } });
  const device = await pg.db.device.create({ data: { userId, deviceId, publicKey: Buffer.from(publicKey),
    oauthClientId: enrollmentId, kind: "app", platform: "windows", displayName: "test" } });
  await pg.db.oauthClient.create({ data: { id: enrollmentId, clientId: enrollmentId,
    scopes: ["agent"], grantTypes: ["client_credentials"], redirectUris: [], responseTypes: [],
    postLogoutRedirectUris: [], contacts: [], metadata: { userId, deviceUuid: deviceId,
      ed25519Pub: Buffer.from(publicKey).toString("base64") } } });
  identity = { id: device.id, deviceId, userId, enrollmentId, publicKey, kind: "app" };
});

/** Registers a live, admitted endpoint under `identity` and returns its id. */
async function admittedEndpoint(): Promise<string> {
  await provisionProductAccountForUser(pg.db, identity.userId);
  const secret = randomBytes(32);
  const endpointId = Buffer.from(await getPublicKeyAsync(secret)).toString("hex");
  const challenge = await createEndpointChallenge(pg.db, identity, { endpointId, expectedGeneration: "0" });
  const bytes = endpointChallengeBytes(challenge);
  await registerEndpoint(pg.db, identity, { challengeId: challenge.challengeId,
    deviceSignature: Buffer.from(await signAsync(bytes, deviceSecret)).toString("base64"),
    endpointSignature: Buffer.from(await signAsync(bytes, secret)).toString("base64") });
  return endpointId;
}

function buildApp(envOverrides: Partial<Env> = {}, admit?: Parameters<typeof irohAccessRoutes>[1]) {
  const env = { IROH_RELAY_URLS: [relayUrl], PEER_RELAY_ACCESS_TOKEN: token,
    ANTGRID_DEV_INSECURE_RELAY: false, ...envOverrides } as Env;
  return admit === undefined
    ? new Hono().route("/", irohAccessRoutes({ db: pg.db, env }))
    : new Hono().route("/", irohAccessRoutes({ db: pg.db, env }, admit));
}

function request(app: Hono, opts: { bearer?: string; nodeId?: string; relay?: string } = {}) {
  const url = new URL(`http://test${PATH}`);
  if (opts.relay !== undefined) url.searchParams.set("relay", opts.relay);
  const headers: Record<string, string> = {};
  if (opts.bearer !== undefined) headers.authorization = `Bearer ${opts.bearer}`;
  if (opts.nodeId !== undefined) headers["x-iroh-nodeid"] = opts.nodeId;
  return app.request(url.pathname + url.search, { method: "POST", headers });
}

describe("POST /internal/iroh-access", () => {
  test("allows an admitted endpoint with the body text exactly 'true'", async () => {
    const endpointId = await admittedEndpoint();
    const app = buildApp();
    const res = await request(app, { bearer: token, nodeId: endpointId, relay: relayUrl });
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(await res.text()).toBe("true");
  });

  test("a trailing-slash variant of an approved relay is allowed", async () => {
    const endpointId = await admittedEndpoint();
    const app = buildApp(); // configured relay is "https://relay.example/"
    const res = await request(app, { bearer: token, nodeId: endpointId, relay: "https://relay.example" });
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("true");
  });

  test("denies a missing, wrong or malformed bearer", async () => {
    const endpointId = await admittedEndpoint();
    const app = buildApp();
    for (const bearer of [undefined, "wrong-token-entirely", token.slice(0, -1)]) {
      const res = await request(app, { bearer, nodeId: endpointId, relay: relayUrl });
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("false");
    }
  });

  test("denies every request when no token is configured", async () => {
    const endpointId = await admittedEndpoint();
    const app = buildApp({ PEER_RELAY_ACCESS_TOKEN: undefined });
    const res = await request(app, { bearer: token, nodeId: endpointId, relay: relayUrl });
    expect(await res.text()).toBe("false");
  });

  test("denies a missing or malformed endpoint id header", async () => {
    const app = buildApp();
    for (const nodeId of [undefined, "not-hex-at-all", "ab".repeat(31)]) {
      const res = await request(app, { bearer: token, nodeId, relay: relayUrl });
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("false");
    }
  });

  test("denies a missing, malformed or unapproved relay query", async () => {
    const endpointId = await admittedEndpoint();
    const app = buildApp();
    for (const relay of [undefined, "not-a-url", "https://unapproved.example/", "http://relay.example/"]) {
      const res = await request(app, { bearer: token, nodeId: endpointId, relay });
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("false");
    }
  });

  test("denies a non-local http relay query even with the dev flag on", async () => {
    const endpointId = await admittedEndpoint();
    const app = buildApp({ ANTGRID_DEV_INSECURE_RELAY: true, IROH_RELAY_URLS: ["http://8.8.8.8/"] });
    const res = await request(app, { bearer: token, nodeId: endpointId, relay: "http://8.8.8.8/" });
    expect(await res.text()).toBe("false");
  });

  test("allows a local http relay when this process enables the dev flag", async () => {
    const endpointId = await admittedEndpoint();
    const local = "http://127.0.0.1:3340/";
    const app = buildApp({ ANTGRID_DEV_INSECURE_RELAY: true, IROH_RELAY_URLS: [local] });
    const res = await request(app, { bearer: token, nodeId: endpointId, relay: local });
    expect(await res.text()).toBe("true");
  });

  test("requests answered at the deadline keep their slot until the stalled check settles", async () => {
    const endpointId = await admittedEndpoint();
    const resolvers: Array<() => void> = [];
    const stalledAdmit: Parameters<typeof irohAccessRoutes>[1] = () => new Promise((resolve) => {
      resolvers.push(() => resolve(true));
    });
    const app = buildApp({}, stalledAdmit);
    const timedOut = await Promise.all(Array.from({ length: 32 },
      () => request(app, { bearer: token, nodeId: endpointId, relay: relayUrl })));
    for (const res of timedOut) expect(await res.text()).toBe("false");
    // Every client has its answer, but Prisma work cannot be cancelled, so
    // the bound must still count it.
    expect((await request(app, { bearer: token, nodeId: endpointId, relay: relayUrl })).status).toBe(503);
    resolvers.forEach((resolve) => resolve());
    await new Promise((resolve) => setTimeout(resolve, 10));
    const after = request(app, { bearer: token, nodeId: endpointId, relay: relayUrl });
    await new Promise((resolve) => setTimeout(resolve, 10));
    resolvers.at(-1)!();
    const res = await after;
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("true");
  });

  test("the mounted app never redirects, including a trailing-slash path", async () => {
    const endpointId = await admittedEndpoint();
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: {
      PEER_RELAY_ACCESS_TOKEN: token, IROH_RELAY_URLS: [relayUrl] } });
    const query = `?relay=${encodeURIComponent(relayUrl)}`;
    const headers = { authorization: `Bearer ${token}`, "x-iroh-nodeid": endpointId };
    const allowed = await app.request(PATH + query, { method: "POST", headers });
    expect(allowed.status).toBe(200);
    expect(await allowed.text()).toBe("true");
    const slashed = await app.request(`${PATH}/${query}`, { method: "POST", headers });
    expect(slashed.status).not.toBe(200);
    expect(slashed.status < 300 || slashed.status >= 400).toBe(true);
  });

  test("a stalled admission check answers false within the deadline and holds pending until it settles", async () => {
    const endpointId = await admittedEndpoint();
    let settled = false;
    const slowAdmit: Parameters<typeof irohAccessRoutes>[1] = () => new Promise((resolve) => {
      setTimeout(() => { settled = true; resolve(true); }, 2_500);
    });
    const app = buildApp({}, slowAdmit);
    const startedAt = Date.now();
    const res = await request(app, { bearer: token, nodeId: endpointId, relay: relayUrl });
    const elapsed = Date.now() - startedAt;
    expect(await res.text()).toBe("false");
    // Answers at the deadline, not once the slow work eventually settles.
    expect(elapsed).toBeGreaterThanOrEqual(1_900);
    expect(elapsed).toBeLessThan(2_400);
    expect(settled).toBe(false);
    await new Promise((resolve) => setTimeout(resolve, 800));
    expect(settled).toBe(true);
  });

  test("the 33rd concurrent request is denied while 32 are in flight, and succeeds once they settle", async () => {
    const endpointId = await admittedEndpoint();
    const resolvers: Array<() => void> = [];
    const slowAdmit: Parameters<typeof irohAccessRoutes>[1] = () => new Promise((resolve) => {
      resolvers.push(() => resolve(true));
    });
    const app = buildApp({}, slowAdmit);
    const inFlight = Array.from({ length: 32 },
      () => request(app, { bearer: token, nodeId: endpointId, relay: relayUrl }));
    // Give the 32 handlers' synchronous prefix (auth/relay checks, the
    // `pending++`) a turn to run before the 33rd is sent.
    await new Promise((resolve) => setTimeout(resolve, 20));
    const overflow = await request(app, { bearer: token, nodeId: endpointId, relay: relayUrl });
    expect(overflow.status).toBe(503);
    expect(await overflow.text()).toBe("false");
    resolvers.forEach((resolve) => resolve());
    for (const res of await Promise.all(inFlight)) {
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("true");
    }
  });

  test("relayConfigHash regression: admitting via either configured relay leaves the account's policy generation alone", async () => {
    const relayA = "https://relay-a.example/";
    const relayB = "https://relay-b.example/";
    const endpointId = await admittedEndpoint();
    // Seed the policy against the full two-relay set once, as `authorizationSnapshot` would on first contact.
    await admitRelayEndpoint(pg.db, endpointId, relayA, [relayA, relayB]);
    const policyBefore = await pg.db.peerAuthorizationPolicy.findUniqueOrThrow({ where: { userId: identity.userId } });
    const outboxBefore = await pg.db.peerAuthorizationOutbox.count();

    const app = buildApp({ IROH_RELAY_URLS: [relayA, relayB] });
    expect(await (await request(app, { bearer: token, nodeId: endpointId, relay: relayB })).text()).toBe("true");
    expect(await (await request(app, { bearer: token, nodeId: endpointId, relay: relayA })).text()).toBe("true");

    const policyAfter = await pg.db.peerAuthorizationPolicy.findUniqueOrThrow({ where: { userId: identity.userId } });
    expect(policyAfter.generation).toBe(policyBefore.generation);
    expect(await pg.db.peerAuthorizationOutbox.count()).toBe(outboxBefore);
  });
});
