import { test, expect, describe } from "bun:test";
import { SignJWT, exportJWK, generateKeyPair, type JWK } from "jose";

import { createLicenseGate } from "../../src/license/gate.js";
import { LicenseCache } from "../../src/license/cache.js";
import { JwksUnavailableError } from "../../src/license/jwks-cache.js";
import type { JwksProvider } from "../../src/license/verify.js";

type SignerKey = Awaited<ReturnType<typeof generateKeyPair>>["privateKey"];

// `licenseIssuerUrl` is the bare origin; the gate derives the token issuer as
// `${origin}/api/auth` (Better-Auth's mount). Sign fixtures with that shape.
//
// Real Better-Auth `client_credentials` tokens carry device identity in the
// `deviceUuid` custom claim and the per-credential id in `azp` (OAuth client
// id) — there is NO `sub` (no user in M2M) and NO `jti`. Mint fixtures the same
// way so the gate's verification is exercised against the production shape.
const ISSUER = "https://api.antgrid.test";
const TOKEN_ISS = `${ISSUER}/api/auth`;
const DEVICE_ID = "device-1";
const CLIENT_ID = "client-1";
const USER_ID = "user-1";
const PK = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const OTHER_PK = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";

interface KeyPair {
  privateKey: SignerKey;
  publicJwk: JWK;
}

async function makeKeyPair(kid: string): Promise<KeyPair> {
  const { privateKey, publicKey } = await generateKeyPair("EdDSA", {
    extractable: true,
  });
  const jwk = await exportJWK(publicKey);
  jwk.kid = kid;
  jwk.alg = "EdDSA";
  return { privateKey, publicJwk: jwk };
}

interface SignArgs {
  privateKey: SignerKey;
  kid: string;
  /** OAuth `deviceUuid` claim — the device the agent registers as. */
  deviceUuid?: string;
  uid?: string;
  tier?: "trial" | "pro";
  /** OAuth `azp` claim — the device's OAuth client id (per-credential id). */
  azp?: string;
  pk?: string;
  expSecondsFromNow?: number;
  sessionLimit?: number;
  /** Set true to exercise the (no-fallback) missing-sessionLimit rejection. */
  omitSessionLimit?: boolean;
}

async function sign(args: SignArgs): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  // Mirror the real oauth-provider payload: deviceUuid + azp custom claims,
  // no `sub`, no `jti`. sessionLimit is required — pre-release there are no
  // tokens predating the claim, so tests always mint it unless explicitly
  // testing its absence.
  const payload: Record<string, unknown> = {
    uid: args.uid ?? USER_ID,
    tier: args.tier ?? "pro",
    pk: args.pk ?? PK,
    deviceUuid: args.deviceUuid ?? DEVICE_ID,
    azp: args.azp ?? CLIENT_ID,
  };
  if (!args.omitSessionLimit) {
    payload.sessionLimit = args.sessionLimit ?? 10;
  }
  return new SignJWT(payload)
    .setProtectedHeader({ alg: "EdDSA", kid: args.kid, typ: "JWT" })
    .setIssuer(TOKEN_ISS)
    .setIssuedAt(now)
    .setExpirationTime(now + (args.expSecondsFromNow ?? 3600))
    .sign(args.privateKey);
}

interface CountingProvider extends JwksProvider {
  fetchCount: number;
}

function makeProvider(keys: JWK[]): CountingProvider {
  const p: CountingProvider = {
    fetchCount: 0,
    getKeys: async () => {
      p.fetchCount++;
      return keys;
    },
  };
  return p;
}

function makeGate(jwks: JwksProvider, cache?: LicenseCache) {
  return createLicenseGate({
    licenseIssuerUrl: ISSUER,
    jwks,
    cache: cache ?? new LicenseCache({ maxEntries: 16 }),
  });
}

describe("createLicenseGate", () => {
  test("valid token + matching pk → ok, cached by deviceId", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const cache = new LicenseCache({ maxEntries: 16 });
    const gate = makeGate(provider, cache);
    const token = await sign({ privateKey: kp.privateKey, kid: "k1" });

    const result = await gate.verify(token, DEVICE_ID, PK);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.entry.deviceId).toBe(DEVICE_ID);
      expect(result.entry.userId).toBe(USER_ID);
      expect(result.entry.tier).toBe("pro");
      expect(result.entry.pk).toBe(PK);
      expect(result.entry.jti).toBe(CLIENT_ID);
      expect(result.entry.revoked).toBe(false);
    }
    expect(cache.get(DEVICE_ID)?.jti).toBe(CLIENT_ID);
  });

  test("presented pk differs from claim pk → LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const gate = makeGate(provider);
    const token = await sign({ privateKey: kp.privateKey, kid: "k1", pk: PK });

    const result = await gate.verify(token, DEVICE_ID, OTHER_PK);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  test("cached revoked entry → LICENSE_REVOKED", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const cache = new LicenseCache({ maxEntries: 16 });
    const gate = makeGate(provider, cache);
    const token = await sign({ privateKey: kp.privateKey, kid: "k1" });

    // Prime cache with a revoked entry for this device. The revoke sticks only
    // when the cached id matches the token's azp (same credential).
    cache.set({
      jti: CLIENT_ID,
      deviceId: DEVICE_ID,
      userId: USER_ID,
      tier: "pro",
      sessionLimit: 10,
      pk: PK,
      revoked: true,
    });

    const result = await gate.verify(token, DEVICE_ID, PK);
    expect(result).toEqual({ ok: false, code: "LICENSE_REVOKED" });
  });

  test("claims.sub differs from deviceId arg → LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const gate = makeGate(provider);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      deviceUuid: "different-device",
    });

    const result = await gate.verify(token, DEVICE_ID, PK);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  // v3 deletes the `.projectId` registrationId split (R1): there is no
  // compound registration id anymore, and the bare deviceId is compared to
  // claims.deviceUuid LITERALLY — a dot-suffixed deviceId is a plain mismatch,
  // not a project agent whose suffix gets stripped.
  test("a dot-suffixed deviceId is compared literally — no v2-style projectId split", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const gate = makeGate(provider);
    const token = await sign({ privateKey: kp.privateKey, kid: "k1" }); // deviceUuid = DEVICE_ID

    const result = await gate.verify(token, `${DEVICE_ID}.proj-abc`, PK);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  test("re-provision with new azp bypasses stale revoked cache entry", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const cache = new LicenseCache({ maxEntries: 16 });
    const gate = makeGate(provider, cache);

    // Stale revoked entry from a prior session (old OAuth client).
    cache.set({
      jti: "client-old",
      deviceId: DEVICE_ID,
      userId: USER_ID,
      tier: "pro",
      sessionLimit: 10,
      pk: PK,
      revoked: true,
    });

    // Re-provisioned device → same deviceUuid, fresh OAuth client → new azp.
    const token = await sign({ privateKey: kp.privateKey, kid: "k1", azp: "client-new" });
    const result = await gate.verify(token, DEVICE_ID, PK);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.entry.jti).toBe("client-new");
  });

  test("expired token → LICENSE_EXPIRED", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const gate = makeGate(provider);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      expSecondsFromNow: -10,
    });

    const result = await gate.verify(token, DEVICE_ID, PK);
    expect(result).toEqual({ ok: false, code: "LICENSE_EXPIRED" });
  });

  // Pre-release there are no tokens predating the `sessionLimit` claim (R1
  // deletes `defaultSessionLimitForTier`) — a missing claim is a verification
  // failure, not a tier-based guess.
  test("missing sessionLimit claim → LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const gate = makeGate(provider);
    const token = await sign({ privateKey: kp.privateKey, kid: "k1", omitSessionLimit: true });

    const result = await gate.verify(token, DEVICE_ID, PK);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  // Regression for hardening item 1: a JWKS outage must surface as the
  // retryable LICENSE_UNAVAILABLE, never the terminal LICENSE_INVALID — a
  // client mustn't be told its credential is dead over a web outage.
  test("JWKS unreachable (cold cache) → LICENSE_UNAVAILABLE", async () => {
    const kp = await makeKeyPair("k1");
    const unavailable: JwksProvider = {
      async getKeys() { throw new JwksUnavailableError(new Error("boom")); },
    };
    const gate = makeGate(unavailable);
    const token = await sign({ privateKey: kp.privateKey, kid: "k1" });

    const result = await gate.verify(token, DEVICE_ID, PK);
    expect(result).toEqual({ ok: false, code: "LICENSE_UNAVAILABLE" });
  });

  test("verifyAppToken also surfaces LICENSE_UNAVAILABLE on a JWKS outage", async () => {
    const kp = await makeKeyPair("k1");
    const unavailable: JwksProvider = {
      async getKeys() { throw new JwksUnavailableError(new Error("boom")); },
    };
    const gate = makeGate(unavailable);
    const token = await sign({ privateKey: kp.privateKey, kid: "k1" });

    const result = await gate.verifyAppToken(token);
    expect(result).toEqual({ ok: false, code: "LICENSE_UNAVAILABLE" });
  });

  // verifyAppToken is the phone (app) path: full crypto verification but NO
  // slot-binding. A same-account phone registers its relay slot under a pairing
  // identity (sub-deviceId + pairing key) decoupled from the account device the
  // token attests, so `verify`'s deviceUuid/pk binds would reject it. These
  // assert the binds are skipped while signature/issuer/exp/revocation stay.
  describe("verifyAppToken", () => {
    test("valid token → ok regardless of relay slot identity (no deviceUuid/pk bind)", async () => {
      const kp = await makeKeyPair("k1");
      const provider = makeProvider([kp.publicJwk]);
      const cache = new LicenseCache({ maxEntries: 16 });
      const gate = makeGate(provider, cache);
      // Token attests the ACCOUNT device; the phone's relay slot (pairing id +
      // pairing key) is something else entirely and is not passed here at all.
      const token = await sign({
        privateKey: kp.privateKey,
        kid: "k1",
        deviceUuid: "account-device-uuid",
        pk: "account-device-pk",
      });

      const result = await gate.verifyAppToken(token);
      expect(result.ok).toBe(true);
      if (result.ok) {
        expect(result.entry.userId).toBe(USER_ID);
        expect(result.entry.tier).toBe("pro");
        expect(result.entry.deviceId).toBe("account-device-uuid");
        expect(result.entry.jti).toBe(CLIENT_ID);
      }
      // Cached by the token's own account deviceUuid (for revocation).
      expect(cache.get("account-device-uuid")?.jti).toBe(CLIENT_ID);
    });

    test("revoked account device → LICENSE_REVOKED", async () => {
      const kp = await makeKeyPair("k1");
      const provider = makeProvider([kp.publicJwk]);
      const cache = new LicenseCache({ maxEntries: 16 });
      const gate = makeGate(provider, cache);
      cache.set({
        jti: CLIENT_ID,
        deviceId: DEVICE_ID,
        userId: USER_ID,
        tier: "pro",
        sessionLimit: 10,
        pk: PK,
        revoked: true,
      });
      const token = await sign({ privateKey: kp.privateKey, kid: "k1" });

      const result = await gate.verifyAppToken(token);
      expect(result).toEqual({ ok: false, code: "LICENSE_REVOKED" });
    });

    test("expired token → LICENSE_EXPIRED (crypto verification preserved)", async () => {
      const kp = await makeKeyPair("k1");
      const provider = makeProvider([kp.publicJwk]);
      const gate = makeGate(provider);
      const token = await sign({
        privateKey: kp.privateKey,
        kid: "k1",
        expSecondsFromNow: -10,
      });

      const result = await gate.verifyAppToken(token);
      expect(result).toEqual({ ok: false, code: "LICENSE_EXPIRED" });
    });

    test("token signed by an unknown key → LICENSE_INVALID", async () => {
      const signer = await makeKeyPair("k1");
      const stranger = await makeKeyPair("k2");
      // JWKS only knows k1; sign with k2's private key under kid k1.
      const provider = makeProvider([signer.publicJwk]);
      const gate = makeGate(provider);
      const token = await sign({ privateKey: stranger.privateKey, kid: "k1" });

      const result = await gate.verifyAppToken(token);
      expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
    });
  });

  test("verify never makes HTTP calls beyond JWKS provider", async () => {
    // Spy on global fetch — gate must not invoke it.
    const originalFetch = globalThis.fetch;
    let fetchCalls = 0;
    globalThis.fetch = (async (...args: Parameters<typeof fetch>) => {
      fetchCalls++;
      return originalFetch(...args);
    }) as typeof fetch;
    try {
      const kp = await makeKeyPair("k1");
      const provider = makeProvider([kp.publicJwk]);
      const gate = makeGate(provider);
      const token = await sign({ privateKey: kp.privateKey, kid: "k1" });

      const result = await gate.verify(token, DEVICE_ID, PK);
      expect(result.ok).toBe(true);
      expect(fetchCalls).toBe(0);
      // JWKS provider was consulted (but only via the stub, not HTTP).
      expect(provider.fetchCount).toBeGreaterThan(0);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
