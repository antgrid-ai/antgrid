// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { randomBytes, randomUUID } from "node:crypto";
import { getPublicKeyAsync } from "@noble/ed25519";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { Hono } from "hono";
import { MachineDirectorySchema } from "antgrid-wire";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { provisionProductAccountForUser } from "../../src/models/subscription.js";
import { peerAuthorizationRoutes } from "../../src/routes/peer-authorization.js";
import { PeerAuthorizationError, registerBusKey } from "../../src/models/peer-authorization.js";
import { rejection } from "../helpers/rejection.js";
import type { Auth } from "../../src/auth/better-auth.js";
import type { Env } from "../../src/env.js";

const issuer = "https://account.example/api/auth";
const prefix = "/account/devices/me";
const busKey = (fill: number) => Buffer.alloc(32, fill).toString("base64");

let pg: PgHandle;
let app: Hono;
let signingKey: CryptoKey;
let userId: string;

beforeAll(async () => {
  pg = await startTestPg();
  const signing = await generateKeyPair("EdDSA");
  signingKey = signing.privateKey as CryptoKey;
  const jwk = await exportJWK(signing.publicKey);
  const auth = { handler: async () => Response.json({ keys: [{ ...jwk, kid: "test", alg: "EdDSA" }] }) } as unknown as Auth;
  app = new Hono().route("/", peerAuthorizationRoutes({ db: pg.db, auth,
    env: { BETTER_AUTH_URL: "https://account.example", EXTRA_TOKEN_AUDIENCES: [], IROH_RELAY_URLS: [] } as unknown as Env }));
});
afterAll(async () => { await pg?.stop(); });
beforeEach(async () => {
  await pg.truncate();
  userId = randomUUID();
  await pg.db.user.create({ data: { id: userId, name: "test", email: `${userId}@example.com`, emailVerified: true } });
  await provisionProductAccountForUser(pg.db, userId);
});

async function makeDevice(kind: "agent" | "app", extra: { busFill?: number; orchestrator?: boolean;
  busControl?: boolean; machineName?: string; bindCredential?: boolean } = {}) {
  const publicKey = await getPublicKeyAsync(randomBytes(32));
  const deviceId = randomUUID(), enrollmentId = randomUUID();
  const device = await pg.db.device.create({ data: { userId, deviceId, publicKey: Buffer.from(publicKey),
    oauthClientId: enrollmentId, kind, platform: kind === "agent" ? "windows" : "android",
    displayName: `${kind}-${deviceId.slice(0, 4)}`, machineName: extra.machineName,
    busPublicKey: extra.busFill === undefined ? undefined : new Uint8Array(32).fill(extra.busFill), orchestrator: extra.orchestrator ?? false,
    busControl: extra.busControl ?? false } });
  await pg.db.oauthClient.create({ data: { id: enrollmentId, clientId: enrollmentId,
    scopes: ["agent"], grantTypes: ["client_credentials"], redirectUris: [], responseTypes: [],
    postLogoutRedirectUris: [], contacts: [], metadata: { userId, deviceUuid: deviceId,
      ed25519Pub: extra.bindCredential === false ? busKey(9) : Buffer.from(publicKey).toString("base64") } } });
  const token = await new SignJWT({ uid: userId, deviceUuid: deviceId, azp: enrollmentId,
    pk: Buffer.from(publicKey).toString("base64") })
    .setProtectedHeader({ alg: "EdDSA", kid: "test" }).setIssuer(issuer).setAudience(issuer)
    .setIssuedAt().setExpirationTime("5m").sign(signingKey);
  return { device, headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    publicKey: Buffer.from(publicKey).toString("base64") };
}

describe("GET /account/devices/me/machines", () => {
  test("an agent sees the other credential-bound agents, never itself or phones", async () => {
    const self = await makeDevice("agent", { busFill: 7, busControl: true });
    const other = await makeDevice("agent", { orchestrator: true, machineName: "box" });
    const keyed = await makeDevice("agent", { busFill: 3 });
    await makeDevice("app");
    await makeDevice("agent", { bindCredential: false });
    const revoked = await makeDevice("agent");
    await pg.db.device.update({ where: { id: revoked.device.id }, data: { revokedAt: new Date() } });

    const res = await app.request(`${prefix}/machines`, { headers: self.headers });
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    const dir = MachineDirectorySchema.parse(await res.json());
    expect(dir.allowed).toBe(true);
    expect(dir.deviceId).toBe(self.device.deviceId);
    expect(dir.self).toEqual({ busPublicKey: busKey(7), orchestrator: false, busControl: true });
    expect(dir.machines.map((m) => m.deviceId).sort()).toEqual([other.device.deviceId, keyed.device.deviceId].sort());
    const o = dir.machines.find((m) => m.deviceId === other.device.deviceId)!;
    expect(o).toMatchObject({ busPublicKey: null, orchestrator: true, busControl: false, machineName: "box",
      ed25519Pub: other.publicKey });
    expect(dir.machines.find((m) => m.deviceId === keyed.device.deviceId)!.busPublicKey).toBe(busKey(3));
  });

  test("an app caller is refused with 403", async () => {
    const phone = await makeDevice("app");
    const res = await app.request(`${prefix}/machines`, { headers: phone.headers });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "NOT_AGENT" });
  });

  test("a disallowed account gets an empty machine list", async () => {
    const self = await makeDevice("agent");
    await makeDevice("agent");
    await pg.db.subscription.updateMany({ data: { status: "canceled" } });
    const dir = MachineDirectorySchema.parse(await (await app.request(`${prefix}/machines`, { headers: self.headers })).json());
    expect(dir.allowed).toBe(false);
    expect(dir.machines).toEqual([]);
  });

  test("requires a bearer token", async () => {
    expect((await app.request(`${prefix}/machines`)).status).toBe(401);
  });

  test("exhausting the machines bucket does not 429 the authorization lease", async () => {
    const self = await makeDevice("agent");
    const statuses: number[] = [];
    for (let i = 0; i < 14; i++) statuses.push((await app.request(`${prefix}/machines`, { headers: self.headers })).status);
    expect(statuses).toContain(429);
    expect((await app.request(`${prefix}/authorization`, { headers: self.headers })).status).toBe(200);
  });
});

describe("POST /account/devices/me/bus-key", () => {
  const post = (headers: Record<string, string>, body: unknown) =>
    app.request(`${prefix}/bus-key`, { method: "POST", headers, body: JSON.stringify(body) });

  test("persists the key on the token's own device only", async () => {
    const self = await makeDevice("agent");
    const other = await makeDevice("agent");
    const res = await post(self.headers, { busPublicKey: busKey(5) });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
    const row = await pg.db.device.findUniqueOrThrow({ where: { id: self.device.id } });
    expect(Buffer.from(row.busPublicKey!).toString("base64")).toBe(busKey(5));
    expect((await pg.db.device.findUniqueOrThrow({ where: { id: other.device.id } })).busPublicKey).toBeNull();
  });

  test("an app device is refused with 403 and stores nothing", async () => {
    const phone = await makeDevice("app");
    const res = await post(phone.headers, { busPublicKey: busKey(5) });
    expect(res.status).toBe(403);
    expect((await pg.db.device.findUniqueOrThrow({ where: { id: phone.device.id } })).busPublicKey).toBeNull();
  });

  test("a malformed key or extra field is 400", async () => {
    const self = await makeDevice("agent");
    expect((await post(self.headers, { busPublicKey: "short" })).status).toBe(400);
    expect((await post(self.headers, { busPublicKey: Buffer.alloc(31).toString("base64") })).status).toBe(400);
    expect((await post(self.headers, { busPublicKey: busKey(5), deviceId: randomUUID() })).status).toBe(400);
  });

  test("an identity checked before a re-key cannot write onto the re-keyed row", async () => {
    const self = await makeDevice("agent");
    const identity = { id: self.device.id, deviceId: self.device.deviceId, enrollmentId: self.device.oauthClientId!,
      publicKey: self.device.publicKey, kind: self.device.kind, userId };
    await pg.db.device.update({ where: { id: self.device.id },
      data: { publicKey: Buffer.from(await getPublicKeyAsync(randomBytes(32))) } });
    const err = await rejection(registerBusKey(pg.db, identity, busKey(5)));
    expect((err as PeerAuthorizationError).code).toBe("UNAUTHENTICATED");
    expect((await pg.db.device.findUniqueOrThrow({ where: { id: self.device.id } })).busPublicKey).toBeNull();
  });

  test("does not advance policyGeneration or enqueue a policy push", async () => {
    const self = await makeDevice("agent");
    const lease = async () => (await (await app.request(`${prefix}/authorization`, { headers: self.headers })).json() as
      { policyGeneration: string }).policyGeneration;
    const before = await lease();
    const outboxBefore = await pg.db.peerAuthorizationOutbox.count({ where: { userId } });
    expect((await post(self.headers, { busPublicKey: busKey(5) })).status).toBe(200);
    expect(await lease()).toBe(before);
    expect(await pg.db.peerAuthorizationOutbox.count({ where: { userId } })).toBe(outboxBefore);
  });
});
