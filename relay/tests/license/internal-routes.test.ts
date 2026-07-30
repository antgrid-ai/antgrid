import { test, expect } from "bun:test";
import { createHmac } from "node:crypto";
import { generateKeyPair, exportJWK, SignJWT } from "jose";
import { startServer as startServerReal, type RelayServer, type RelayServerDeps } from "../../src/server.js";
import { LicenseCache } from "../../src/license/cache.js";
import { createLicenseGate } from "../../src/license/gate.js";
import type { JwksProvider } from "../../src/license/verify.js";
import type { JWK } from "jose";
import {
  defaultConfig,
  connect,
  generateKeyPair as genRelayKeyPair,
  makeHello,
  waitForMessage,
  waitForType,
} from "../helpers/relay-harness.js";

// `licenseIssuerUrl` is the bare origin; the gate derives the token issuer as
// `${origin}/api/auth` (Better-Auth's mount). Sign fixtures with that shape.
const ISSUER = "http://license-api.test";
const TOKEN_ISS = `${ISSUER}/api/auth`;
const SECRET = defaultConfig.relayInternalSecret;

const baseConfig = { ...defaultConfig, licenseIssuerUrl: ISSUER, relayInternalSecret: SECRET };

interface SignerCtx {
  signer: { privateKey: CryptoKey; publicJwk: JWK; kid: string };
  jwks: JwksProvider;
}

async function makeSigner(): Promise<SignerCtx> {
  const { privateKey, publicKey } = await generateKeyPair("EdDSA", { extractable: true });
  const publicJwk = (await exportJWK(publicKey)) as JWK;
  const kid = "test-kid-1";
  publicJwk.kid = kid;
  publicJwk.alg = "EdDSA";
  const jwks: JwksProvider = {
    async getKeys() {
      return [publicJwk];
    },
  };
  return { signer: { privateKey, publicJwk, kid }, jwks };
}

interface MintOpts {
  deviceUuid: string;
  uid?: string;
  tier?: "trial" | "pro";
  azp?: string;
  expSecondsFromNow?: number;
  pk: string;
}

async function mintToken(signer: SignerCtx["signer"], opts: MintOpts): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const exp = now + (opts.expSecondsFromNow ?? 3600);
  // Mirror the real oauth-provider payload: deviceUuid + azp custom claims,
  // no `sub`, no `jti`; sessionLimit is required (no tier fallback).
  return new SignJWT({
    uid: opts.uid ?? "user-1",
    tier: opts.tier ?? "pro",
    pk: opts.pk,
    deviceUuid: opts.deviceUuid,
    azp: opts.azp ?? `client-${Math.random().toString(36).slice(2)}`,
    sessionLimit: 10,
  })
    .setProtectedHeader({ alg: "EdDSA", kid: signer.kid })
    .setIssuer(TOKEN_ISS)
    .setExpirationTime(exp)
    .sign(signer.privateKey);
}

function startWith(deps: RelayServerDeps): RelayServer {
  return startServerReal(baseConfig, deps);
}

interface MessageEventLike {
  msg?: Record<string, unknown>;
  closeCode?: number;
}

function nextMessageOrClose(ws: WebSocket, timeoutMs = 2000): Promise<MessageEventLike> {
  return new Promise((resolve, reject) => {
    let msg: Record<string, unknown> | undefined;
    let closeCode: number | undefined;
    let settled = false;
    const settle = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ msg, closeCode });
    };
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      reject(new Error(`nextMessageOrClose timed out (msg=${msg ? "yes" : "no"}, close=${closeCode ?? "no"})`));
    }, timeoutMs);
    ws.onmessage = (e) => {
      msg = JSON.parse(e.data as string);
      if (closeCode !== undefined) settle();
    };
    ws.onclose = (e) => {
      closeCode = e.code;
      if (msg !== undefined) settle();
    };
  });
}

/** Signs + connects an agent against the REAL license gate (for revoke/expire
 *  assertions, which key off the license cache's jti/userId bookkeeping). */
async function helloAgent(opts: {
  relay: RelayServer;
  signer: SignerCtx["signer"];
  deviceId: string;
  uid?: string;
  azp?: string;
}): Promise<{ ws: WebSocket; publicKeyBase64: string; privateSeed: Uint8Array }> {
  const identity = await genRelayKeyPair();
  const token = await mintToken(opts.signer, {
    deviceUuid: opts.deviceId,
    uid: opts.uid,
    azp: opts.azp,
    pk: identity.publicKeyBase64,
  });
  const { hello } = await makeHello(opts.relay, {
    deviceId: opts.deviceId,
    deviceType: "agent",
    licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64,
    privateSeed: identity.privateSeed,
  });
  const ws = await connect(opts.relay);
  const welcome = waitForMessage(ws);
  ws.send(JSON.stringify(hello));
  // toMatchObject, not `.type` equality: an admission failure here is a typed
  // error frame, and its `code` is the whole diagnosis.
  expect(await welcome).toMatchObject({ type: "welcome" });
  return { ws, publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed };
}

async function helloApp(opts: {
  relay: RelayServer;
  signer: SignerCtx["signer"];
  deviceId: string;
  uid?: string;
  azp?: string;
  /** The token's `deviceUuid` claim when it differs from the id dialled with —
   *  the real shape once the app addresses each machine on its own relay slot
   *  (`verifyAppToken` deliberately does not bind the two). */
  tokenDeviceUuid?: string;
}): Promise<{ ws: WebSocket; publicKeyBase64: string; privateSeed: Uint8Array }> {
  const identity = await genRelayKeyPair();
  const token = await mintToken(opts.signer, {
    deviceUuid: opts.tokenDeviceUuid ?? opts.deviceId,
    uid: opts.uid,
    azp: opts.azp,
    pk: identity.publicKeyBase64,
  });
  const { hello } = await makeHello(opts.relay, {
    deviceId: opts.deviceId,
    deviceType: "app",
    licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64,
    privateSeed: identity.privateSeed,
  });
  const ws = await connect(opts.relay);
  const welcome = waitForMessage(ws);
  ws.send(JSON.stringify(hello));
  // toMatchObject, not `.type` equality: an admission failure here is a typed
  // error frame, and its `code` is the whole diagnosis.
  expect(await welcome).toMatchObject({ type: "welcome" });
  return { ws, publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed };
}

function sign(body: string): string {
  return createHmac("sha256", SECRET).update(body).digest("hex");
}

async function postInternal(port: number, path: string, body: unknown, signature?: string): Promise<Response> {
  const raw = JSON.stringify(body);
  return fetch(`http://localhost:${port}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-antgrid-signature": signature ?? sign(raw) },
    body: raw,
  });
}

// ============== /internal/revoke ==============

test("revoke: bad signature -> 401, no side effects", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  await helloAgent({ relay: r, signer, deviceId: "dev-1", azp: "client-1" });

  const res = await postInternal(r.server.port!, "/internal/revoke", { deviceId: "dev-1" }, "deadbeef");
  expect(res.status).toBe(401);
  expect(cache.get("dev-1")?.revoked).toBe(false);

  r.stop();
});

test("revoke: closes the agent ws 4002 with a typed LICENSE_REVOKED error first, and its same-account phone gets peer-offline and stays alive", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  // No pairing, no grant — mayRoute's account match (both default to
  // uid "user-1") is the only thing that ever linked these two.
  const agent = await helloAgent({ relay: r, signer, deviceId: "dev-2", azp: "client-2" });
  const phone = await helloApp({ relay: r, signer, deviceId: "phone-2", uid: "user-1", azp: "phone-client-2" });

  const agentEvt = nextMessageOrClose(agent.ws);
  const phonePeerOffline = waitForType(phone.ws, "peer-offline");

  const res = await postInternal(r.server.port!, "/internal/revoke", { deviceId: "dev-2" });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true });

  const result = await agentEvt;
  expect(result.msg).toMatchObject({ type: "error", code: "LICENSE_REVOKED", retryable: false });
  expect(result.closeCode).toBe(4002);
  expect(cache.get("dev-2")?.revoked).toBe(true);

  expect(await phonePeerOffline).toEqual({ type: "peer-offline", peerId: "dev-2" });
  expect(phone.ws.readyState).toBe(1);

  r.stop();
});

test("revoke: device not connected -> still 200, cache marked", async () => {
  const cache = new LicenseCache({ maxEntries: 100 });
  cache.set({ jti: "jti-orphan", deviceId: "dev-orphan", userId: "user-1", tier: "pro", sessionLimit: 10, pk: "pk-orphan", revoked: false });
  const r = startServerReal(baseConfig, { licenseCache: cache });

  const res = await postInternal(r.server.port!, "/internal/revoke", { deviceId: "dev-orphan" });
  expect(res.status).toBe(200);
  expect(cache.get("dev-orphan")?.revoked).toBe(true);

  r.stop();
});

test("revoke: subsequent hello with the same revoked token -> LICENSE_REVOKED", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const identity = await genRelayKeyPair();
  const token = await mintToken(signer, { deviceUuid: "dev-revoke", azp: "client-revoke-flow", pk: identity.publicKeyBase64 });
  const { hello: hello1 } = await makeHello(r, {
    deviceId: "dev-revoke", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  const ws1 = await connect(r);
  const welcome1 = waitForMessage(ws1);
  ws1.send(JSON.stringify(hello1));
  expect((await welcome1).type).toBe("welcome");

  const evt = nextMessageOrClose(ws1);
  const res = await postInternal(r.server.port!, "/internal/revoke", { deviceId: "dev-revoke" });
  expect(res.status).toBe(200);
  expect((await evt).closeCode).toBe(4002);
  // Let the server-side close handler (which removes the connections-table
  // entry) settle before reconnecting — its ordering relative to the
  // client-visible close event isn't guaranteed.
  await new Promise((resolve) => setTimeout(resolve, 50));

  // A higher epoch so the (now-closed) prior connection can't cause a spurious
  // SUPERSEDED before the license check runs.
  const { hello: hello2 } = await makeHello(r, {
    deviceId: "dev-revoke", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
    epoch: Math.floor(Date.now() / 1000) + 10,
  });
  const ws2 = await connect(r);
  const evt2 = nextMessageOrClose(ws2);
  ws2.send(JSON.stringify(hello2));
  const finalEvt = await evt2;
  expect(finalEvt.msg).toMatchObject({ type: "error", code: "LICENSE_REVOKED" });
  expect(finalEvt.closeCode).toBe(1008);

  r.stop();
});

// ============== /internal/expire ==============

test("expire: multi-device user -> all closed and revoked", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const a = await helloAgent({ relay: r, signer, deviceId: "dev-A", uid: "shared-user", azp: "client-A" });
  const b = await helloAgent({ relay: r, signer, deviceId: "dev-B", uid: "shared-user", azp: "client-B" });

  const evtA = nextMessageOrClose(a.ws);
  const evtB = nextMessageOrClose(b.ws);

  const res = await postInternal(r.server.port!, "/internal/expire", { userId: "shared-user" });
  expect(res.status).toBe(200);

  const [resA, resB] = await Promise.all([evtA, evtB]);
  expect(resA.msg).toMatchObject({ type: "error", code: "LICENSE_EXPIRED", retryable: false });
  expect(resA.closeCode).toBe(4002);
  expect(resB.msg).toMatchObject({ type: "error", code: "LICENSE_EXPIRED" });
  expect(resB.closeCode).toBe(4002);
  expect(cache.get("dev-A")?.revoked).toBe(true);
  expect(cache.get("dev-B")?.revoked).toBe(true);

  r.stop();
});

test("expire: closes only the target user's connections; a different uid stays open", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const agent = await helloAgent({ relay: r, signer, deviceId: "dev-expire-user", uid: "expire-user", azp: "client-expire" });
  const other = await helloApp({ relay: r, signer, deviceId: "dev-other-uid", uid: "other-user", azp: "client-other" });

  const agentEvt = nextMessageOrClose(agent.ws);

  const res = await postInternal(r.server.port!, "/internal/expire", { userId: "expire-user" });
  expect(res.status).toBe(200);

  const result = await agentEvt;
  expect(result.msg).toMatchObject({ type: "error", code: "LICENSE_EXPIRED", retryable: false });
  expect(result.closeCode).toBe(4002);

  expect(other.ws.readyState).toBe(1);

  r.stop();
});

test("expire: bad signature -> 401", async () => {
  const cache = new LicenseCache({ maxEntries: 100 });
  cache.set({ jti: "jti-x", deviceId: "dev-x", userId: "user-x", tier: "pro", sessionLimit: 10, pk: "pk-x", revoked: false });
  const r = startServerReal(baseConfig, { licenseCache: cache });

  const res = await postInternal(r.server.port!, "/internal/expire", { userId: "user-x" }, "bad");
  expect(res.status).toBe(401);
  expect(cache.get("dev-x")?.revoked).toBe(false);

  r.stop();
});

test("expire: no matching devices -> 200 no errors", async () => {
  const cache = new LicenseCache({ maxEntries: 100 });
  const r = startServerReal(baseConfig, { licenseCache: cache });

  const res = await postInternal(r.server.port!, "/internal/expire", { userId: "ghost-user" });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ ok: true });

  r.stop();
});

test("non-POST -> 405", async () => {
  const r = startServerReal(baseConfig, {});
  const res = await fetch(`http://localhost:${r.server.port!}/internal/revoke`, { method: "GET" });
  expect(res.status).toBe(405);
  r.stop();
});

// ============== /internal/connections ==============

test("connections: returns identity-free liveness rows for live devices", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  await helloAgent({ relay: r, signer, deviceId: "conn-1", azp: "client-1" });

  const res = await postInternal(r.server.port!, "/internal/connections", { issuedAt: Date.now() });
  expect(res.status).toBe(200);
  const body = (await res.json()) as { connections: Array<Record<string, unknown>> };
  const row = body.connections.find((c) => c.deviceId === "conn-1");
  expect(row).toBeDefined();
  expect(row).toMatchObject({ deviceId: "conn-1", deviceType: "agent", openStreamCount: 0 });
  for (const leak of ["ip", "publicKey", "jti", "userId", "tier"]) {
    expect(row).not.toHaveProperty(leak);
  }

  r.stop();
});

test("connections: bad signature -> 401", async () => {
  const r = startServerReal(baseConfig, {});
  const res = await postInternal(r.server.port!, "/internal/connections", { issuedAt: Date.now() }, "bad");
  expect(res.status).toBe(401);
  r.stop();
});

test("connections: stale issuedAt -> 401 (replay bound)", async () => {
  const r = startServerReal(baseConfig, {});
  const stale = Date.now() - 60_000; // outside the 30s skew window
  const res = await postInternal(r.server.port!, "/internal/connections", { issuedAt: stale });
  expect(res.status).toBe(401);
  expect(await res.json()).toEqual({ error: "STALE_REQUEST" });
  r.stop();
});

test("connections: empty registry -> 200 with empty list", async () => {
  const r = startServerReal(baseConfig, {});
  const res = await postInternal(r.server.port!, "/internal/connections", { issuedAt: Date.now() });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ connections: [] });
  r.stop();
});

test("connections: GET -> 405", async () => {
  const r = startServerReal(baseConfig, {});
  const res = await fetch(`http://localhost:${r.server.port!}/internal/connections`, { method: "GET" });
  expect(res.status).toBe(405);
  r.stop();
});

test("connections: userId scopes to that user's connections (identity-free)", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  await helloAgent({ relay: r, signer, deviceId: "scope-A", uid: "user-A", azp: "client-A" });
  await helloAgent({ relay: r, signer, deviceId: "scope-B", uid: "user-B", azp: "client-B" });

  const res = await postInternal(r.server.port!, "/internal/connections", { issuedAt: Date.now(), userId: "user-A" });
  expect(res.status).toBe(200);
  const body = (await res.json()) as { connections: Array<Record<string, unknown>> };
  const ids = body.connections.map((c) => c.deviceId);
  expect(ids).toContain("scope-A");
  expect(ids).not.toContain("scope-B");
  const row = body.connections.find((c) => c.deviceId === "scope-A");
  for (const leak of ["ip", "publicKey", "jti", "userId", "tier"]) {
    expect(row).not.toHaveProperty(leak);
  }

  r.stop();
});

// Web reads its "N / sessionLimit running" straight off this projection, so the
// count here must be the same one `countOpenStreamsForUser` admits against.
test("connections: openStreamCount tracks live streams without exposing stream ids", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const { ws } = await helloAgent({ relay: r, signer, deviceId: "streamer", uid: "user-S", azp: "client-S" });

  for (const streamId of ["stream-alpha", "stream-beta"]) {
    const opened = waitForType(ws, "stream-opened");
    ws.send(JSON.stringify({ type: "stream-open", streamId }));
    expect(await opened).toMatchObject({ streamId });
  }

  const res = await postInternal(r.server.port!, "/internal/connections", { issuedAt: Date.now(), userId: "user-S" });
  const raw = await res.text();
  const body = JSON.parse(raw) as { connections: Array<Record<string, unknown>> };
  expect(body.connections.find((c) => c.deviceId === "streamer")).toMatchObject({ openStreamCount: 2 });
  expect(raw).not.toContain("stream-alpha");

  const closed = waitForType(ws, "stream-closed");
  ws.send(JSON.stringify({ type: "stream-close", streamId: "stream-alpha" }));
  await closed;

  const after = await postInternal(r.server.port!, "/internal/connections", { issuedAt: Date.now(), userId: "user-S" });
  const afterBody = (await after.json()) as { connections: Array<Record<string, unknown>> };
  expect(afterBody.connections.find((c) => c.deviceId === "streamer")).toMatchObject({ openStreamCount: 1 });

  ws.close();
  r.stop();
});

test("connections: unknown userId -> 200 with empty list", async () => {
  const r = startServerReal(baseConfig, {});
  const res = await postInternal(r.server.port!, "/internal/connections", { issuedAt: Date.now(), userId: "ghost-user" });
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ connections: [] });
  r.stop();
});

// Per-machine relay slots: an app's `hello.deviceId` is
// `<accountDeviceUuid>#<machineDeviceUuid>`, so revocation — which web issues
// against the bare account device — must reach every slot the app holds. A
// bare-id lookup finds none of them and leaves a revoked phone routing.
test("revoke: closes every per-machine slot an app holds under the revoked account device", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  // One phone, two machines open at once — two sockets, one account device.
  const slotA = await helloApp({ relay: r, signer, deviceId: "phone-slots#machine-a", tokenDeviceUuid: "phone-slots", uid: "user-slots", azp: "phone-client-slots" });
  const slotB = await helloApp({ relay: r, signer, deviceId: "phone-slots#machine-b", tokenDeviceUuid: "phone-slots", uid: "user-slots", azp: "phone-client-slots" });
  // A same-account phone that was NOT revoked must be left alone.
  const bystander = await helloApp({ relay: r, signer, deviceId: "phone-other#machine-a", tokenDeviceUuid: "phone-other", uid: "user-slots", azp: "phone-client-other" });

  const evtA = nextMessageOrClose(slotA.ws);
  const evtB = nextMessageOrClose(slotB.ws);

  const res = await postInternal(r.server.port!, "/internal/revoke", { deviceId: "phone-slots" });
  expect(res.status).toBe(200);

  for (const evt of [await evtA, await evtB]) {
    expect(evt.msg).toMatchObject({ type: "error", code: "LICENSE_REVOKED", retryable: false });
    expect(evt.closeCode).toBe(4002);
  }
  expect(bystander.ws.readyState).toBe(1);

  r.stop();
});
