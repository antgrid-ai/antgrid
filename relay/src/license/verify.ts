import {
  decodeJwt,
  decodeProtectedHeader,
  errors as joseErrors,
  importJWK,
  jwtVerify,
  type JWK,
  type JWTPayload,
} from "jose";
import { JwksUnavailableError } from "./jwks-cache.js";
import { logger } from "../logger.js";

type VerifyKey = Awaited<ReturnType<typeof importJWK>>;

export interface DeviceClaims {
  /**
   * The device record id the agent registers with the relay as (its
   * registration id is `${deviceUuid}.${projectId}`). Sourced from the OAuth
   * `deviceUuid` custom claim — NOT the JWT `sub`. Better-Auth
   * `client_credentials` tokens have no user, so `sub` is absent; device
   * identity lives in the `deviceUuid` claim that `oauth-provider.ts` injects.
   */
  deviceUuid: string;
  uid: string;
  tier: "free" | "trial" | "pro";
  /**
   * Per-credential revocation discriminator. Sourced from the OAuth `azp`
   * claim (the device's OAuth client id) — NOT a JWT `jti` (Better-Auth
   * client_credentials tokens carry none). `azp` is stable across token
   * re-mints and rotates only when the device is re-provisioned (a fresh OAuth
   * client, same `deviceUuid`). That is exactly the old per-jti
   * "re-activation bypasses a stale revoke" semantic the gate relies on.
   */
  jti: string;
  pk: string;
  exp: number;
}

export type VerifyFailureCode =
  | "LICENSE_INVALID"
  | "LICENSE_EXPIRED"
  | "LICENSE_UNAVAILABLE";

export type VerifyResult =
  | { ok: true; claims: DeviceClaims }
  | { ok: false; code: VerifyFailureCode };

/**
 * Minimal interface satisfied by `JwksCache`. Kept here so tests can pass a
 * fake without subclassing.
 */
export interface JwksProvider {
  /** When [opts.forKid] is unknown to the cache, the provider may refresh before answering. */
  getKeys(opts?: { forKid?: string }): Promise<JWK[]>;
}

/**
 * Better-Auth mounts its handler (and the OAuth provider / JWKS) under
 * `/api/auth`, and stamps that same base onto every token's `iss` claim
 * (`ctx.context.baseURL` = `${BETTER_AUTH_URL}/api/auth`). So the expected
 * issuer is web's PUBLIC origin + `/api/auth` — callers must pass
 * `licenseIssuerUrl` (which defaults to `BETTER_AUTH_URL`), NOT the relay's
 * `licenseApiUrl`, which may instead be an internal address used purely to
 * fetch JWKS efficiently (docker-internal DNS on the VM deploy). Conflating
 * the two made every hello fail issuer verification on any deployment where
 * they differ — see gate.ts's `licenseIssuerUrl` wiring. This mirrors web's
 * own `jwt-bearer.ts`, which verifies the very same OAuth `client_credentials`
 * access tokens for the agent heartbeat endpoint. Keep the two in lockstep.
 */
const AUTH_BASE_PATH = "/api/auth";

export function deviceTokenIssuer(issuerBaseUrl: string): string {
  return `${issuerBaseUrl.replace(/\/+$/, "")}${AUTH_BASE_PATH}`;
}

function isNonEmptyString(v: unknown): v is string {
  return typeof v === "string" && v.length > 0;
}

function isValidTier(v: unknown): v is "free" | "trial" | "pro" {
  return v === "free" || v === "trial" || v === "pro";
}

export async function verifyDeviceToken(
  token: string,
  jwks: JwksProvider,
  expectedIssuer: string
): Promise<VerifyResult> {
  try {
    const getKey = async (protectedHeader: {
      kid?: string;
    }): Promise<VerifyKey> => {
      const kid = protectedHeader.kid;
      if (!isNonEmptyString(kid)) {
        throw new Error("missing kid in protected header");
      }
      const keys = await jwks.getKeys({ forKid: kid });
      const matched = keys.find((k) => k.kid === kid);
      if (!matched) {
        throw new Error(`no jwk matches kid=${kid}`);
      }
      return importJWK(matched, "EdDSA");
    };

    const { payload }: { payload: JWTPayload } = await jwtVerify(
      token,
      getKey,
      {
        issuer: expectedIssuer,
        algorithms: ["EdDSA"],
      }
    );

    const claims = payload as unknown as Record<string, unknown>;

    if (!isNonEmptyString(claims.deviceUuid)) {
      return failInvalid("deviceUuid missing or empty");
    }
    if (!isNonEmptyString(claims.azp)) {
      return failInvalid("azp missing or empty");
    }
    if (!isNonEmptyString(claims.uid)) {
      return failInvalid("uid missing or empty");
    }
    if (!isValidTier(claims.tier)) {
      return failInvalid("tier invalid");
    }
    if (!isNonEmptyString(claims.pk)) {
      return failInvalid("pk missing or empty");
    }
    if (typeof claims.exp !== "number") {
      return failInvalid("exp missing or non-numeric");
    }
    return {
      ok: true,
      claims: {
        deviceUuid: claims.deviceUuid,
        uid: claims.uid,
        tier: claims.tier,
        jti: claims.azp,
        pk: claims.pk,
        exp: claims.exp,
      },
    };
  } catch (err) {
    // Must precede the expired/invalid split: an unreachable JWKS says nothing
    // about the credential, and calling it LICENSE_INVALID makes clients stop
    // reconnecting forever over a transient web outage.
    if (isJwksUnavailable(err)) {
      return logVerifyFail(
        "LICENSE_UNAVAILABLE",
        "jwks unreachable and no cached keys — token validity unknown",
        token,
        expectedIssuer
      );
    }
    const expired = err instanceof joseErrors.JWTExpired;
    const code = expired ? "LICENSE_EXPIRED" : "LICENSE_INVALID";
    const reason = err instanceof Error ? err.message : String(err);
    return logVerifyFail(code, reason, token, expectedIssuer);
  }
}

/**
 * jose is free to wrap whatever the key-resolver callback throws, so match on
 * the cause chain rather than the top-level instance. Bounded depth: a
 * self-referential `cause` would otherwise spin the verify path.
 */
function isJwksUnavailable(err: unknown): boolean {
  let cur: unknown = err;
  for (let depth = 0; depth < 5 && cur != null; depth++) {
    if (cur instanceof JwksUnavailableError) return true;
    cur = (cur as { cause?: unknown }).cause;
  }
  return false;
}

function failInvalid(reason: string): VerifyResult {
  logger.warn("license verify failed", { code: "LICENSE_INVALID", reason });
  return { ok: false, code: "LICENSE_INVALID" };
}

/**
 * `tokenHeader`/`tokenPayload` are pulled with jose's unverified decoders
 * purely for diagnostics — never trusted for control flow. Logged at debug
 * because they're large and only useful when actively debugging a verify
 * failure; the warn line carries the actionable code/reason.
 */
function logVerifyFail(
  code: VerifyFailureCode,
  reason: string,
  token: string,
  expectedIssuer: string,
): VerifyResult {
  logger.warn("license verify failed", { code, reason, expectedIssuer });
  let header: unknown, payload: unknown;
  try { header = decodeProtectedHeader(token); } catch { /* ignore */ }
  try { payload = decodeJwt(token); } catch { /* ignore */ }
  logger.debug("license verify failed (token)", {
    code,
    tokenHeader: header,
    tokenPayload: payload,
  });
  return { ok: false, code };
}
