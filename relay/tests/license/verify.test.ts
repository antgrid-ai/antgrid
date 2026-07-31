import { test, expect, describe } from "bun:test";
import { SignJWT, exportJWK, generateKeyPair, type JWK } from "jose";

type SignerKey = Awaited<ReturnType<typeof generateKeyPair>>["privateKey"];
import {
  verifyDeviceToken,
  type JwksProvider,
} from "../../src/license/verify.js";
import { JwksUnavailableError } from "../../src/license/jwks-cache.js";

const ISSUER = "https://api.antgrid.test";

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

function makeProvider(keys: JWK[]): JwksProvider {
  return { getKeys: async () => keys };
}

interface SignArgs {
  privateKey: SignerKey;
  kid: string;
  issuer?: string;
  /** OAuth `deviceUuid` claim — device identity (replaces the old `sub`). */
  deviceUuid?: string | undefined;
  uid?: string | undefined;
  tier?: unknown;
  /** OAuth `azp` claim — per-credential id (replaces the old `jti`). */
  azp?: string | undefined;
  pk?: string | undefined;
  expSecondsFromNow?: number;
  extra?: Record<string, unknown>;
}

const DEFAULT_PK = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

async function sign(args: SignArgs): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  // Mirror the real oauth-provider payload: device identity + per-credential id
  // live in the `deviceUuid` / `azp` custom claims, not `sub` / `jti`.
  const payload: Record<string, unknown> = { ...(args.extra ?? {}) };
  if (args.uid !== undefined) payload.uid = args.uid;
  if (args.tier !== undefined) payload.tier = args.tier;
  if (args.pk !== undefined) payload.pk = args.pk;
  if (args.deviceUuid !== undefined) payload.deviceUuid = args.deviceUuid;
  if (args.azp !== undefined) payload.azp = args.azp;

  const builder = new SignJWT(payload).setProtectedHeader({
    alg: "EdDSA",
    kid: args.kid,
    typ: "JWT",
  });

  builder.setIssuer(args.issuer ?? ISSUER);
  builder.setIssuedAt(now);
  builder.setExpirationTime(now + (args.expSecondsFromNow ?? 3600));

  return builder.sign(args.privateKey);
}

describe("verifyDeviceToken", () => {
  test("valid token returns ok with claims", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      deviceUuid: "device-1",
      uid: "user-1",
      tier: "pro",
      azp: "client-1",
      pk: DEFAULT_PK,
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.claims.deviceUuid).toBe("device-1");
      expect(result.claims.uid).toBe("user-1");
      expect(result.claims.tier).toBe("pro");
      // `jti` is the internal revocation id, sourced from the OAuth `azp` claim.
      expect(result.claims.jti).toBe("client-1");
      expect(result.claims.pk).toBe(DEFAULT_PK);
      expect(typeof result.claims.exp).toBe("number");
    }
  });

  // The deploy-order guarantee behind retiring the worker-limit rename: web may
  // stop minting `sessionLimit` at will, and a garbage value from a token minted
  // mid-rollout must not be read as a verdict either. The relay ignores the claim
  // entirely (docs/plans/2026-07-30-worker-limit-pricing.md).
  test("no entitlement claim is required — tokens with or without sessionLimit verify", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const mint = (extra?: Record<string, unknown>) =>
      sign({
        privateKey: kp.privateKey,
        kid: "k1",
        deviceUuid: "d",
        uid: "u",
        tier: "pro",
        azp: "a",
        pk: DEFAULT_PK,
        extra,
      });

    for (const extra of [undefined, { sessionLimit: 0 }, { sessionLimit: "ten" }, { sessionLimit: -1 }]) {
      const result = await verifyDeviceToken(await mint(extra), provider, ISSUER);
      expect(result.ok).toBe(true);
    }
  });

  // Regression for hardening item 1: an unreachable JWKS with no cached keys
  // says nothing about the token's validity — retryable, not a verdict.
  test("JWKS unavailable (cold cache) -> LICENSE_UNAVAILABLE", async () => {
    const unavailable: JwksProvider = {
      async getKeys() { throw new JwksUnavailableError(new Error("network down")); },
    };
    const token = await sign({
      privateKey: (await makeKeyPair("k1")).privateKey,
      kid: "k1",
      deviceUuid: "d",
      uid: "u",
      tier: "pro",
      azp: "a",
      pk: DEFAULT_PK,
    });

    const result = await verifyDeviceToken(token, unavailable, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_UNAVAILABLE" });
  });

  test("missing pk → LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      deviceUuid: "d",
      uid: "u",
      tier: "pro",
      azp: "a",
      // pk omitted
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  test("empty pk → LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      deviceUuid: "d",
      uid: "u",
      tier: "pro",
      azp: "a",
      pk: "",
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  test("bad signature → LICENSE_INVALID", async () => {
    const signer = await makeKeyPair("k1");
    const other = await makeKeyPair("k1"); // same kid, different key
    const provider = makeProvider([other.publicJwk]); // verifier holds the WRONG public key for kid=k1
    const token = await sign({
      privateKey: signer.privateKey,
      kid: "k1",
      deviceUuid: "d",
      uid: "u",
      tier: "pro",
      azp: "a",
      pk: DEFAULT_PK,
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  test("expired token → LICENSE_EXPIRED", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      deviceUuid: "d",
      uid: "u",
      tier: "pro",
      azp: "a",
      pk: DEFAULT_PK,
      expSecondsFromNow: -10,
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_EXPIRED" });
  });

  test("wrong issuer → LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      issuer: "https://evil.example",
      deviceUuid: "d",
      uid: "u",
      tier: "pro",
      azp: "a",
      pk: DEFAULT_PK,
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  test("missing azp → LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      deviceUuid: "d",
      uid: "u",
      tier: "pro",
      pk: DEFAULT_PK,
      // azp omitted
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  test("missing/empty deviceUuid → LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      // deviceUuid omitted
      uid: "u",
      tier: "pro",
      azp: "a",
      pk: DEFAULT_PK,
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  test("bad tier → LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      deviceUuid: "d",
      uid: "u",
      tier: "enterprise",
      azp: "a",
      pk: DEFAULT_PK,
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  test("tampered claims (mutated middle segment) → LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      deviceUuid: "d",
      uid: "u",
      tier: "trial",
      azp: "a",
      pk: DEFAULT_PK,
    });

    const [h, p, s] = token.split(".");
    const decoded = JSON.parse(
      Buffer.from(p, "base64url").toString("utf8")
    ) as Record<string, unknown>;
    decoded.tier = "pro";
    const tamperedPayload = Buffer.from(JSON.stringify(decoded)).toString(
      "base64url"
    );
    const tampered = `${h}.${tamperedPayload}.${s}`;

    const result = await verifyDeviceToken(tampered, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  test("unknown kid → LICENSE_INVALID", async () => {
    const signer = await makeKeyPair("signer-kid");
    const other = await makeKeyPair("other-kid");
    const provider = makeProvider([other.publicJwk]);
    const token = await sign({
      privateKey: signer.privateKey,
      kid: "signer-kid",
      deviceUuid: "d",
      uid: "u",
      tier: "pro",
      azp: "a",
      pk: DEFAULT_PK,
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  test("missing uid → LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider = makeProvider([kp.publicJwk]);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      deviceUuid: "d",
      // uid omitted
      tier: "pro",
      azp: "a",
      pk: DEFAULT_PK,
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  // An unreachable JWKS says nothing about the credential. Reporting it as
  // LICENSE_INVALID told every agent its license was dead over what was really
  // a brief web outage — and clients treat that as terminal, so a relay restart
  // in the outage window killed the fleet permanently.
  test("unreachable JWKS (cold cache) → LICENSE_UNAVAILABLE, not LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider: JwksProvider = {
      getKeys: async () => {
        throw new JwksUnavailableError(new Error("network down"));
      },
    };
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      deviceUuid: "d",
      uid: "u",
      tier: "pro",
      azp: "a",
      pk: DEFAULT_PK,
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    // Load-bearing: jose is free to WRAP whatever the key-resolver callback
    // throws, so this also proves the cause-chain walk actually catches it.
    expect(result).toEqual({ ok: false, code: "LICENSE_UNAVAILABLE" });
  });

  test("a JWKS provider failing for any other reason stays LICENSE_INVALID", async () => {
    const kp = await makeKeyPair("k1");
    const provider: JwksProvider = {
      getKeys: async () => {
        throw new Error("some other bug");
      },
    };
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      deviceUuid: "d",
      uid: "u",
      tier: "pro",
      azp: "a",
      pk: DEFAULT_PK,
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });

  test("an unknown kid from a REACHABLE JWKS is still LICENSE_INVALID", async () => {
    // Unknown key ≠ unreachable endpoint — this one is a genuine judgment on
    // the token and must not be swept into the retryable bucket.
    const kp = await makeKeyPair("k1");
    const other = await makeKeyPair("k2");
    const provider = makeProvider([other.publicJwk]);
    const token = await sign({
      privateKey: kp.privateKey,
      kid: "k1",
      deviceUuid: "d",
      uid: "u",
      tier: "pro",
      azp: "a",
      pk: DEFAULT_PK,
    });

    const result = await verifyDeviceToken(token, provider, ISSUER);
    expect(result).toEqual({ ok: false, code: "LICENSE_INVALID" });
  });
});
