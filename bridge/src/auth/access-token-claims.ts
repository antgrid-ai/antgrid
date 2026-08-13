// bridge/src/auth/access-token-claims.ts

// Read the claims the bridge itself needs off a device access token.
//
// DECODE, NEVER VERIFY, and that is the whole security story. The token arrived
// over TLS from web into this process's own memory, and the only adversary a
// bridge-side entitlement gate faces is the machine's owner — who can patch the
// binary regardless. Signature verification is the relay's job
// (relay/src/license/verify.ts), which holds the JWKS; duplicating it here would
// add an online dependency to a local feature and buy nothing.

/** Clock-skew allowance on `exp`. A device whose clock runs fast must not lose
 *  a capability its server-signed token still grants; an hour of TTL is the
 *  budget this is spent out of. */
const EXP_SKEW_MS = 60_000;

export interface AccessTokenClaims {
  /** The product line web signed onto this token, or null when the payload
   *  carried none. */
  tier: string | null;
  /** JWT `exp`, in seconds. Null when absent — see {@link liveTier}. */
  exp: number | null;
}

/** Parse a JWT's payload segment. Null for anything that is not three
 *  base64url-joined segments with a JSON object in the middle. */
export function decodeAccessTokenClaims(token: string): AccessTokenClaims | null {
  const parts = token.split(".");
  if (parts.length !== 3 || !parts[1]) return null;
  let payload: unknown;
  try {
    payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    return null;
  }
  if (typeof payload !== "object" || payload === null) return null;
  const rec = payload as Record<string, unknown>;
  return {
    tier: typeof rec.tier === "string" ? rec.tier : null,
    exp: typeof rec.exp === "number" ? rec.exp : null,
  };
}

/**
 * The tier this token still asserts, or null when it asserts nothing usable.
 *
 * Expiry is re-evaluated on every call rather than folded into the decode: a
 * decoded payload is immutable but its validity is not, and the whole point of
 * honouring `exp` is that it is what bounds a downgrade to one token lifetime.
 * A token with no `exp` reads as already dead — one that cannot say when it
 * stops being true cannot be trusted about what it grants.
 */
export function liveTier(claims: AccessTokenClaims | null, nowMs: number = Date.now()): string | null {
  if (!claims || claims.tier === null || claims.exp === null) return null;
  if (claims.exp * 1000 + EXP_SKEW_MS <= nowMs) return null;
  return claims.tier;
}
