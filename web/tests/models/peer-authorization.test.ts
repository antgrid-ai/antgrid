import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { createHmac, randomBytes, randomUUID } from "node:crypto";
import { getPublicKeyAsync, signAsync } from "@noble/ed25519";
import { endpointChallengeBytes } from "antgrid-wire";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { rejection } from "../helpers/rejection.js";
import { createEndpointChallenge, registerEndpoint, peerAuthorizationSnapshot, peerRelayAdmission } from "../../src/models/peer-authorization.js";
import { buildTestApp } from "../helpers/app.js";
import { peerAdmissionRoutes } from "../../src/routes/peer-admission.js";
import { provisionProductAccountForUser } from "../../src/models/subscription.js";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { Hono } from "hono";
import { peerAuthorizationRoutes } from "../../src/routes/peer-authorization.js";
import type { Auth } from "../../src/auth/better-auth.js";
import type { Env } from "../../src/env.js";

let pg: PgHandle;
const deviceSecret = randomBytes(32);
let identity: { id: string; deviceId: string; userId: string; enrollmentId: string; publicKey: Uint8Array; kind: string };
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

async function signed(expectedGeneration = "0", secret = randomBytes(32)) {
  const endpointId = Buffer.from(await getPublicKeyAsync(secret)).toString("hex");
  const challenge = await createEndpointChallenge(pg.db, identity, { endpointId, expectedGeneration });
  const bytes = endpointChallengeBytes(challenge);
  return { endpointId, input: { challengeId: challenge.challengeId,
    deviceSignature: Buffer.from(await signAsync(bytes, deviceSecret)).toString("base64"),
    endpointSignature: Buffer.from(await signAsync(bytes, secret)).toString("base64") } };
}

describe("relay endpoint admission", () => {
  const relayUrl = "https://relay.example/";
  const input = (endpointId: string) => ({ endpointId, relayUrl, requestId: randomUUID(), issuedAt: Date.now() });

  test("live enrollment is admitted with exact generation and historical endpoints stay denied", async () => {
    await provisionProductAccountForUser(pg.db, identity.userId);
    const first = await signed();
    await registerEndpoint(pg.db, identity, first.input);
    const admitted = await peerRelayAdmission(pg.db, input(first.endpointId), [relayUrl]);
    expect(admitted.allowed).toBe(true);
    if (!admitted.allowed) throw new Error("expected admission");
    expect(admitted.userId).toBe(identity.userId);
    expect(admitted.deviceId).toBe(identity.deviceId);
    expect(admitted.enrollmentId).toBe(identity.enrollmentId);
    expect(admitted.registrationGeneration).toBe("1");
    expect(admitted.leaseMs).toBeGreaterThan(0);
    expect(admitted.leaseMs).toBeLessThanOrEqual(60_000);
    const next = await signed("1");
    await registerEndpoint(pg.db, identity, next.input);
    expect((await peerRelayAdmission(pg.db, input(first.endpointId), [relayUrl])).allowed).toBe(false);
    const rotated = await peerRelayAdmission(pg.db, input(next.endpointId), [relayUrl]);
    expect(rotated.allowed).toBe(true);
    if (rotated.allowed) {
      expect(rotated.registrationGeneration).toBe("2");
      expect(BigInt(rotated.policyGeneration)).toBeGreaterThan(BigInt(admitted.policyGeneration));
    }
  });

  test("denies unapproved relay, absent entitlement and disabled bound credentials", async () => {
    const proof = await signed();
    await registerEndpoint(pg.db, identity, proof.input);
    expect((await peerRelayAdmission(pg.db, input(proof.endpointId), [relayUrl])).allowed).toBe(false);
    await provisionProductAccountForUser(pg.db, identity.userId);
    expect((await peerRelayAdmission(pg.db, input(proof.endpointId), [])).allowed).toBe(false);
    await pg.db.oauthClient.update({ where: { clientId: identity.enrollmentId }, data: { disabled: true } });
    expect((await peerRelayAdmission(pg.db, input(proof.endpointId), [relayUrl])).allowed).toBe(false);
  });

  test("rejects credential metadata impersonation even with a live registration", async () => {
    await provisionProductAccountForUser(pg.db, identity.userId);
    const proof = await signed();
    await registerEndpoint(pg.db, identity, proof.input);
    await pg.db.oauthClient.update({ where: { clientId: identity.enrollmentId }, data: { metadata: {
      userId: identity.userId, deviceUuid: randomUUID(), ed25519Pub: Buffer.from(identity.publicKey).toString("base64"),
    } } });
    expect((await peerRelayAdmission(pg.db, input(proof.endpointId), [relayUrl])).allowed).toBe(false);
  });

  test("subscription removal and account deletion deny the next admission", async () => {
    const account = await provisionProductAccountForUser(pg.db, identity.userId);
    const proof = await signed();
    await registerEndpoint(pg.db, identity, proof.input);
    expect((await peerRelayAdmission(pg.db, input(proof.endpointId), [relayUrl])).allowed).toBe(true);
    await pg.db.subscription.updateMany({ where: { accountId: account.id }, data: { status: "canceled" } });
    expect((await peerRelayAdmission(pg.db, input(proof.endpointId), [relayUrl])).allowed).toBe(false);
    await pg.db.productAccount.update({ where: { id: account.id }, data: { deletedAt: new Date() } });
    expect((await peerRelayAdmission(pg.db, input(proof.endpointId), [relayUrl])).allowed).toBe(false);
  });

  test("real HTTP app route authenticates exact bytes and bounds freshness/body", async () => {
    await provisionProductAccountForUser(pg.db, identity.userId);
    const proof = await signed();
    await registerEndpoint(pg.db, identity, proof.input);
    const secret = "test-relay-service-secret";
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: { RELAY_INTERNAL_SECRET: secret, IROH_RELAY_URLS: [relayUrl] } });
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: app.fetch });
    const request = (body: string, signedBody = body, key = secret) => fetch(`http://127.0.0.1:${server.port}/internal/peer-admission`, {
      method: "POST", body, headers: { "content-type": "application/json",
        "x-antgrid-signature": createHmac("sha256", key).update(signedBody).digest("hex") },
    });
    try {
      const value = input(proof.endpointId);
      const body = JSON.stringify(value);
      const admitted = await request(body);
      expect(admitted.status).toBe(200);
      expect(admitted.headers.get("cache-control")).toBe("no-store");
      expect((await admitted.json()).allowed).toBe(true);
      expect((await request(body, body, "wrong")).status).toBe(401);
      expect((await request(body + " ", body)).status).toBe(401);
      expect((await request(JSON.stringify({ ...value, extra: true }))).status).toBe(400);
      expect((await request("x".repeat(4097))).status).toBe(413);
      for (const issuedAt of [Date.now() - 31_000, Date.now() + 31_000]) {
        expect(await (await request(JSON.stringify({ ...value, issuedAt }))).json()).toEqual({ allowed: false, requestId: value.requestId });
      }
      const unapproved = await request(JSON.stringify({ ...value, relayUrl: "https://unapproved.example/" }));
      expect(await unapproved.json()).toEqual({ allowed: false, requestId: value.requestId });
    } finally { server.stop(true); }
    const missingSecret = new Hono().route("/", peerAdmissionRoutes({ db: pg.db,
      env: { IROH_RELAY_URLS: [relayUrl] } as Env }));
    expect((await missingSecret.request("/internal/peer-admission", { method: "POST" })).status).toBe(401);
  });
});

describe("endpoint enrollment transactions", () => {
  test("mounted routes bind bearer identity and preserve typed registration errors", async () => {
    const signing = await generateKeyPair("EdDSA");
    const jwk = await exportJWK(signing.publicKey);
    const auth = { handler: async () => Response.json({ keys: [{ ...jwk, kid: "test", alg: "EdDSA" }] }) } as unknown as Auth;
    const issuer = "https://account.example/api/auth";
    const token = await new SignJWT({ uid: identity.userId, deviceUuid: identity.deviceId,
      azp: identity.enrollmentId, pk: Buffer.from(identity.publicKey).toString("base64") })
      .setProtectedHeader({ alg: "EdDSA", kid: "test" }).setIssuer(issuer).setAudience(issuer)
      .setIssuedAt().setExpirationTime("1m").sign(signing.privateKey);
    const app = new Hono().route("/", peerAuthorizationRoutes({ db: pg.db, auth,
      env: { BETTER_AUTH_URL: "https://account.example", EXTRA_TOKEN_AUDIENCES: [], IROH_RELAY_URLS: [] } as unknown as Env }));
    const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };
    const proof = await signed();
    const response = await app.request("/account/devices/me/endpoint-registration", { method: "POST", headers,
      body: JSON.stringify({ ...proof.input, endpointSignature: Buffer.alloc(64).toString("base64") }) });
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "INVALID_SIGNATURE" });
    const registered = await app.request("/account/devices/me/endpoint-registration", { method: "POST", headers,
      body: JSON.stringify(proof.input) });
    expect(registered.status).toBe(200);
    expect(registered.headers.get("cache-control")).toBe("no-store");
    expect((await app.request("/account/devices/me/authorization", { headers })).status).toBe(200);
    expect((await app.request("/account/devices/me/authorization")).status).toBe(401);
  });
  test("requires both signatures and does not consume on invalid proof", async () => {
    const proof = await signed();
    const error = await rejection(registerEndpoint(pg.db, identity,
      { ...proof.input, endpointSignature: Buffer.alloc(64).toString("base64") }));
    expect((error as Error).message).toBe("INVALID_SIGNATURE");
    expect(await registerEndpoint(pg.db, identity, proof.input)).toEqual({ endpointId: proof.endpointId, generation: "1" });
  });
  test("single-use under concurrent requests; rotation retains revoked history", async () => {
    const proof = await signed();
    const results = await Promise.allSettled([registerEndpoint(pg.db, identity, proof.input), registerEndpoint(pg.db, identity, proof.input)]);
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const next = await signed("1");
    expect((await registerEndpoint(pg.db, identity, next.input)).generation).toBe("2");
    const history = await pg.db.peerEndpointRegistration.findMany({ orderBy: { generation: "asc" } });
    expect(history).toHaveLength(2);
    expect(history[0].revokedAt).not.toBeNull();
    expect(history[1].revokedAt).toBeNull();
    expect(await pg.db.peerAuthorizationOutbox.count()).toBeGreaterThan(0);
  });
  test("rejects expired, cross-account and stale-generation challenges", async () => {
    const proof = await signed();
    expect((await rejection(registerEndpoint(pg.db, { ...identity, userId: "other" }, proof.input)) as Error).message).toBe("UNAUTHENTICATED");
    await pg.db.peerEndpointChallenge.update({ where: { id: proof.input.challengeId }, data: { expiresAt: new Date(0) } });
    expect((await rejection(registerEndpoint(pg.db, identity, proof.input)) as Error).message).toBe("INVALID_CHALLENGE");
    expect((await rejection(createEndpointChallenge(pg.db, identity, { endpointId: proof.endpointId, expectedGeneration: "1" })) as Error).message).toBe("STALE_GENERATION");
  });
  test("never reuses an endpoint even after rotation", async () => {
    const secret = randomBytes(32);
    const proof = await signed("0", secret);
    await registerEndpoint(pg.db, identity, proof.input);
    const reused = await signed("1", secret);
    expect((await rejection(registerEndpoint(pg.db, identity, reused.input)) as Error).message).toBe("ENDPOINT_REUSED");
  });
  test("credential disable revokes endpoint and rechecks the transaction identity", async () => {
    const proof = await signed();
    await registerEndpoint(pg.db, identity, proof.input);
    await pg.db.oauthClient.update({ where: { clientId: identity.enrollmentId }, data: { disabled: true } });
    expect((await pg.db.peerEndpointRegistration.findUniqueOrThrow({ where: { endpointId: proof.endpointId } })).revokedAt).not.toBeNull();
    expect((await rejection(peerAuthorizationSnapshot(pg.db, identity, [])) as Error).message).toBe("UNAUTHENTICATED");
  });
  test("no entitlement yields authoritative denial without relay discovery", async () => {
    const snapshot = await peerAuthorizationSnapshot(pg.db, identity, ["https://relay.example/"]);
    expect(snapshot.allowed).toBe(false);
    expect(snapshot.leaseMs).toBe(0);
    expect(snapshot.peers).toEqual([]);
    expect(snapshot.relayUrls).toEqual([]);
    expect(typeof snapshot.policyGeneration).toBe("string");
    expect(snapshot.registrationGeneration).toBe("0");
  });
  test("revoked endpoint retains the enrollment generation in snapshots", async () => {
    const proof = await signed();
    await registerEndpoint(pg.db, identity, proof.input);
    await pg.db.peerEndpointRegistration.update({ where: { endpointId: proof.endpointId }, data: { revokedAt: new Date() } });
    const snapshot = await peerAuthorizationSnapshot(pg.db, identity, []);
    expect(snapshot.endpoint).toBeNull();
    expect(snapshot.registrationGeneration).toBe("1");
  });
  test("eligible peers require active bound credentials and live remote access", async () => {
    await provisionProductAccountForUser(pg.db, identity.userId);
    const peerId = randomUUID(), enrollmentId = randomUUID();
    await pg.db.device.create({ data: { userId: identity.userId, deviceId: peerId,
      publicKey: Buffer.from(identity.publicKey), oauthClientId: enrollmentId, kind: "agent",
      platform: "linux", displayName: "machine", mobileAccessEnabled: true } });
    await pg.db.oauthClient.create({ data: { id: enrollmentId, clientId: enrollmentId,
      scopes: [], grantTypes: ["client_credentials"], redirectUris: [], responseTypes: [],
      postLogoutRedirectUris: [], contacts: [], metadata: { userId: identity.userId, deviceUuid: peerId,
        ed25519Pub: Buffer.from(identity.publicKey).toString("base64") } } });
    const snapshot = await peerAuthorizationSnapshot(pg.db, identity, ["https://relay.example/"]);
    expect(snapshot.allowed).toBe(true);
    expect(snapshot.leaseMs).toBeGreaterThan(0);
    expect(snapshot.leaseMs).toBeLessThanOrEqual(60_000);
    expect(snapshot.peers.map((peer) => peer.deviceId)).toEqual([peerId]);
    expect(snapshot.peers[0].endpoint).toBeNull();
    await pg.db.device.update({ where: { oauthClientId: enrollmentId }, data: { mobileAccessEnabled: false } });
    const revoked = await peerAuthorizationSnapshot(pg.db, identity, []);
    expect(revoked.peers).toEqual([]);
    expect(BigInt(revoked.policyGeneration)).toBeGreaterThan(BigInt(snapshot.policyGeneration));
  });
  test("heartbeat timestamps do not churn policy; subscription denial does", async () => {
    const account = await provisionProductAccountForUser(pg.db, identity.userId);
    const proof = await signed();
    await registerEndpoint(pg.db, identity, proof.input);
    const before = await peerAuthorizationSnapshot(pg.db, identity, []);
    await pg.db.device.update({ where: { id: identity.id }, data: { mobileAccessEnabled: false, lastSeenAt: new Date() } });
    expect((await peerAuthorizationSnapshot(pg.db, identity, [])).policyGeneration).toBe(before.policyGeneration);
    await pg.db.subscription.updateMany({ where: { accountId: account.id }, data: { status: "canceled" } });
    const after = await peerAuthorizationSnapshot(pg.db, identity, []);
    expect(after.allowed).toBe(false);
    expect(BigInt(after.policyGeneration)).toBeGreaterThan(BigInt(before.policyGeneration));
  });
  test("a no-op account_id write leaves the policy generation alone", async () => {
    await provisionProductAccountForUser(pg.db, identity.userId);
    const before = await peerAuthorizationSnapshot(pg.db, identity, []);
    await pg.db.$executeRawUnsafe('UPDATE "user" SET account_id = account_id');
    expect((await peerAuthorizationSnapshot(pg.db, identity, [])).policyGeneration).toBe(before.policyGeneration);
  });
  test("a billing change invalidates that account's users and no one else", async () => {
    const account = await provisionProductAccountForUser(pg.db, identity.userId);
    const strangerId = randomUUID();
    await pg.db.user.create({ data: { id: strangerId, name: "stranger", email: `${strangerId}@example.com`, emailVerified: true } });
    await provisionProductAccountForUser(pg.db, strangerId);
    const mine = await peerAuthorizationSnapshot(pg.db, identity, []);
    const theirs = await pg.db.peerAuthorizationPolicy.upsert({ where: { userId: strangerId },
      create: { userId: strangerId }, update: {} });
    await pg.db.subscription.updateMany({ where: { accountId: account.id }, data: { status: "canceled" } });
    const after = await peerAuthorizationSnapshot(pg.db, identity, []);
    expect(BigInt(after.policyGeneration)).toBeGreaterThan(BigInt(mine.policyGeneration));
    expect((await pg.db.peerAuthorizationPolicy.findUniqueOrThrow({ where: { userId: strangerId } })).generation)
      .toBe(theirs.generation);
  });
  test("approved relay configuration advances policy even without an enrolled endpoint", async () => {
    const before = await peerAuthorizationSnapshot(pg.db, identity, []);
    const after = await peerAuthorizationSnapshot(pg.db, identity, ["https://relay.example/"]);
    expect(BigInt(after.policyGeneration)).toBeGreaterThan(BigInt(before.policyGeneration));
    expect((await peerAuthorizationSnapshot(pg.db, identity, ["https://relay.example/"])).policyGeneration).toBe(after.policyGeneration);
  });
});
