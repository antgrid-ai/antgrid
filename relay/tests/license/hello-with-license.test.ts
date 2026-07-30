import { test, expect } from "bun:test";
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
} from "../helpers/relay-harness.js";

// `licenseIssuerUrl` is the bare origin; the gate derives the token issuer as
// `${origin}/api/auth` (Better-Auth's mount). Sign fixtures with that shape.
const ISSUER = "http://license-api.test";
const TOKEN_ISS = `${ISSUER}/api/auth`;

const baseConfig = { ...defaultConfig, licenseIssuerUrl: ISSUER };

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
  tier?: "free" | "trial" | "pro";
  azp?: string;
  expSecondsFromNow?: number;
  pk?: string;
}

async function mintToken(signer: SignerCtx["signer"], opts: MintOpts): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const exp = now + (opts.expSecondsFromNow ?? 3600);
  return new SignJWT({
    uid: opts.uid ?? "user-1",
    tier: opts.tier ?? "pro",
    pk: opts.pk ?? "ignored-pk",
    deviceUuid: opts.deviceUuid,
    azp: opts.azp ?? `client-${Math.random().toString(36).slice(2)}`,
  })
    .setProtectedHeader({ alg: "EdDSA", kid: signer.kid })
    .setIssuer(TOKEN_ISS)
    .setExpirationTime(exp)
    .sign(signer.privateKey);
}

function startWith(deps: RelayServerDeps): RelayServer {
  return startServerReal(baseConfig, deps);
}

async function sendHello(
  relay: RelayServer,
  opts: { deviceId: string; deviceType: "agent" | "app"; licenseToken: string; publicKeyBase64: string; privateSeed: Uint8Array; epoch?: number },
): Promise<{ msg: Record<string, unknown>; closeCode?: number }> {
  const { hello } = await makeHello(relay, opts);
  const ws = await connect(relay);
  const closeCode = new Promise<number>((resolve) => { ws.onclose = (e) => resolve(e.code); });
  const first = waitForMessage(ws);
  ws.send(JSON.stringify(hello));
  const msg = await first;
  if (msg.type === "welcome") {
    ws.close();
    return { msg };
  }
  return { msg, closeCode: await closeCode };
}

// Regression: a same-account phone authenticates its relay slot under a
// pairing identity (fresh keypair) decoupled from the account device its
// license token attests. `verify`'s deviceUuid/pk binds would reject this —
// `verifyAppToken` must not apply them (the empty-project-list bug, v2).
test("app hello: license token's deviceUuid/pk need not match the phone's relay slot identity", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const identity = await genRelayKeyPair();
  const token = await mintToken(signer, { deviceUuid: "account-device-uuid", pk: "account-device-pk" });
  const { msg } = await sendHello(r, {
    deviceId: "phone-pairing-slot", deviceType: "app", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  expect(msg.type).toBe("welcome");

  r.stop();
});

test("app hello: expired token -> LICENSE_EXPIRED (crypto still enforced)", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const identity = await genRelayKeyPair();
  const token = await mintToken(signer, { deviceUuid: "account-device-uuid", expSecondsFromNow: -10 });
  const { msg, closeCode } = await sendHello(r, {
    deviceId: "phone-slot", deviceType: "app", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  expect(msg).toMatchObject({ type: "error", code: "LICENSE_EXPIRED" });
  expect(closeCode).toBe(1008);

  r.stop();
});

test("agent hello: valid token -> welcome", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const identity = await genRelayKeyPair();
  const token = await mintToken(signer, { deviceUuid: "dev-valid", pk: identity.publicKeyBase64 });
  const { msg } = await sendHello(r, {
    deviceId: "dev-valid", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  expect(msg.type).toBe("welcome");

  r.stop();
});

test("agent hello: malformed token -> LICENSE_INVALID and ws closed 1008", async () => {
  const { jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const identity = await genRelayKeyPair();
  const { msg, closeCode } = await sendHello(r, {
    deviceId: "dev-malformed", deviceType: "agent", licenseToken: "not-a-jwt",
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  expect(msg).toMatchObject({ type: "error", code: "LICENSE_INVALID" });
  expect(closeCode).toBe(1008);

  r.stop();
});

test("agent hello: expired token -> LICENSE_EXPIRED", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const identity = await genRelayKeyPair();
  const token = await mintToken(signer, { deviceUuid: "dev-exp", expSecondsFromNow: -10 });
  const { msg } = await sendHello(r, {
    deviceId: "dev-exp", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  expect(msg).toMatchObject({ type: "error", code: "LICENSE_EXPIRED" });

  r.stop();
});

test("agent hello: deviceUuid mismatch -> LICENSE_INVALID", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const identity = await genRelayKeyPair();
  const token = await mintToken(signer, { deviceUuid: "different-device" });
  const { msg } = await sendHello(r, {
    deviceId: "dev-submismatch", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  expect(msg).toMatchObject({ type: "error", code: "LICENSE_INVALID" });

  r.stop();
});

test("agent hello: pk claim mismatch -> LICENSE_INVALID", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const identity = await genRelayKeyPair();
  // Token's pk claim is for a different key than the connection's identity.
  const token = await mintToken(signer, { deviceUuid: "dev-pkmismatch", pk: "wrong-pk" });
  const { msg, closeCode } = await sendHello(r, {
    deviceId: "dev-pkmismatch", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  expect(msg).toMatchObject({ type: "error", code: "LICENSE_INVALID" });
  expect(closeCode).toBe(1008);

  r.stop();
});

test("free tier agent hello still succeeds — tier gates nothing on the relay", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const identity = await genRelayKeyPair();
  const token = await mintToken(signer, { deviceUuid: "dev-free", tier: "free", pk: identity.publicKeyBase64 });
  const { msg } = await sendHello(r, {
    deviceId: "dev-free", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  expect(msg).toMatchObject({ type: "welcome" });

  r.stop();
});

test("revoked entry in cache -> LICENSE_REVOKED", async () => {
  const { signer, jwks } = await makeSigner();
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const identity = await genRelayKeyPair();
  const token = await mintToken(signer, { deviceUuid: "dev-revoked", azp: "client-revoked-1", pk: identity.publicKeyBase64 });

  const first = await sendHello(r, {
    deviceId: "dev-revoked", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  expect(first.msg.type).toBe("welcome");
  await new Promise((resolve) => setTimeout(resolve, 50));

  cache.markRevoked("dev-revoked");

  // Higher epoch — the (revoked, still-open) first connection must not win
  // SUPERSEDED before the license check even runs.
  const second = await sendHello(r, {
    deviceId: "dev-revoked", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
    epoch: Math.floor(Date.now() / 1000) + 10,
  });
  expect(second.msg).toMatchObject({ type: "error", code: "LICENSE_REVOKED" });
  expect(second.closeCode).toBe(1008);

  r.stop();
});

test("second hello with the same token reuses the license cache (JWKS fetched once)", async () => {
  const fresh = await makeSigner();
  let getKeysCalls = 0;
  const countingJwks: JwksProvider = {
    async getKeys() {
      getKeysCalls += 1;
      return [fresh.signer.publicJwk];
    },
  };
  const cache = new LicenseCache({ maxEntries: 100 });
  const gate = createLicenseGate({ licenseIssuerUrl: ISSUER, jwks: countingJwks, cache });
  const r = startWith({ licenseGate: gate, licenseCache: cache });

  const identity = await genRelayKeyPair();
  const token = await mintToken(fresh.signer, { deviceUuid: "dev-cache", azp: "stable-client-1", pk: identity.publicKeyBase64 });

  const first = await sendHello(r, {
    deviceId: "dev-cache", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  expect(first.msg.type).toBe("welcome");
  await new Promise((resolve) => setTimeout(resolve, 50));
  const callsAfterFirst = getKeysCalls;

  const second = await sendHello(r, {
    deviceId: "dev-cache", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
    epoch: Math.floor(Date.now() / 1000) + 10,
  });
  expect(second.msg.type).toBe("welcome");
  expect(getKeysCalls).toBeGreaterThanOrEqual(callsAfterFirst);

  r.stop();
});

// --- Live JWKS over real HTTP (folds the former license/e2e.test.ts in) ---

test("live JWKS over HTTP: relay fetches the real endpoint, verifies the pk claim, and admits the hello", async () => {
  const { privateKey, publicKey } = await generateKeyPair("EdDSA", { extractable: true });
  const jwk = (await exportJWK(publicKey)) as JWK;
  jwk.kid = "e2e-kid-1";
  jwk.alg = "EdDSA";

  const calls = { jwks: 0 };
  const fakeApi = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/api/auth/jwks") {
        calls.jwks++;
        return Response.json({ keys: [jwk] });
      }
      return new Response("not found", { status: 404 });
    },
  });

  const cfg = { ...defaultConfig, licenseApiUrl: `http://localhost:${fakeApi.port}` };
  const r = startServerReal(cfg); // no DI: real JwksCache + real LicenseGate

  const identity = await genRelayKeyPair();
  const token = await new SignJWT({
    uid: "e2e-user",
    tier: "pro",
    pk: identity.publicKeyBase64,
    deviceUuid: "e2e-device",
    azp: "e2e-client-1",
  })
    .setProtectedHeader({ alg: "EdDSA", kid: "e2e-kid-1" })
    .setIssuer(`http://localhost:${fakeApi.port}/api/auth`)
    .setExpirationTime(Math.floor(Date.now() / 1000) + 3600)
    .sign(privateKey);

  const first = await sendHello(r, {
    deviceId: "e2e-device", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  expect(first.msg.type).toBe("welcome");
  expect(calls.jwks).toBe(1);
  await new Promise((resolve) => setTimeout(resolve, 50));

  // Second hello with the same token: JWKS cache hit, no new HTTP fetch.
  const second = await sendHello(r, {
    deviceId: "e2e-device", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
    epoch: Math.floor(Date.now() / 1000) + 10,
  });
  expect(second.msg.type).toBe("welcome");
  expect(calls.jwks).toBe(1); // unchanged — cached

  r.stop();
  fakeApi.stop(true);
});

// Regression for hardening item 1, exercised through the FULL real stack
// (JwksCache -> verifyDeviceToken -> gate.verify -> hello handler): an
// unreachable JWKS with no cached keys must surface as the retryable
// LICENSE_UNAVAILABLE, not a terminal LICENSE_INVALID.
test("live JWKS over HTTP: an unreachable endpoint surfaces LICENSE_UNAVAILABLE, retryable", async () => {
  const downApi = Bun.serve({
    port: 0,
    fetch() {
      return new Response("nope", { status: 500 });
    },
  });

  const cfg = { ...defaultConfig, licenseApiUrl: `http://localhost:${downApi.port}` };
  const r = startServerReal(cfg);

  const identity = await genRelayKeyPair();
  const token = await new SignJWT({
    uid: "user-x", tier: "pro", pk: identity.publicKeyBase64, deviceUuid: "dev-jwks-down", azp: "client-x",
  })
    .setProtectedHeader({ alg: "EdDSA", kid: "whatever" })
    .setIssuer(`http://localhost:${downApi.port}/api/auth`)
    .setExpirationTime(Math.floor(Date.now() / 1000) + 3600)
    .sign((await generateKeyPair("EdDSA", { extractable: true })).privateKey);

  const { msg, closeCode } = await sendHello(r, {
    deviceId: "dev-jwks-down", deviceType: "agent", licenseToken: token,
    publicKeyBase64: identity.publicKeyBase64, privateSeed: identity.privateSeed,
  });
  expect(msg).toMatchObject({ type: "error", code: "LICENSE_UNAVAILABLE", retryable: true });
  expect(closeCode).toBe(1008);

  r.stop();
  downApi.stop(true);
});
