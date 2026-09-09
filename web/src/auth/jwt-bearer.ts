import type { Context, MiddlewareHandler } from "hono";
import {
  createLocalJWKSet,
  jwtVerify,
  type JSONWebKeySet,
  type JWTPayload,
} from "jose";
import type { Auth } from "./better-auth.js";
import type { DB } from "../db/index.js";
import type { Env } from "../env.js";
import type { AuthVars } from "./middleware.js";

/**
 * Issuer pinned by Better-Auth's `jwt` plugin: `${baseURL}/api/auth`.
 * Mirrors the value the relay verifies against; see
 * `tests/integration/oauth-end-to-end.test.ts` for cross-reference.
 */
function expectedIssuer(env: Env): string {
  return `${env.BETTER_AUTH_URL.replace(/\/+$/, "")}/api/auth`;
}

/**
 * The only scope `auth/oauth-provider.ts` declares, and the only one a device
 * client is registered with — the token endpoint refuses any other value, so a
 * JWT lacking it did not come from that provider.
 */
const REQUIRED_SCOPE = "agent";

/**
 * Better-Auth stamps `scope` as the space-delimited OAuth string. The array
 * form is tolerated as well, so a library-side shape change degrades to a
 * working gate rather than a 401 for every device in the field.
 */
function tokenScopes(claim: unknown): string[] {
  if (typeof claim === "string") return claim.split(" ").filter((s) => s.length > 0);
  if (Array.isArray(claim)) return claim.filter((s): s is string => typeof s === "string");
  return [];
}

interface CachedJwks {
  set: ReturnType<typeof createLocalJWKSet>;
  fetchedAt: number;
}

const JWKS_TTL_MS = 5 * 60 * 1000;

/**
 * Fetches the JWKS in-process by hitting Better-Auth's own handler.
 *
 * Using `auth.handler` avoids both a self-HTTP round trip (which would need
 * the server to be reachable on its own port) and the need to read the JWK
 * out of the DB and re-encode it. The handler's response is the exact JWKS
 * the relay reads at `${baseURL}/api/auth/jwks`.
 */
async function fetchJwks(auth: Auth, env: Env): Promise<JSONWebKeySet> {
  const url = `${env.BETTER_AUTH_URL.replace(/\/+$/, "")}/api/auth/jwks`;
  const res = await auth.handler(new Request(url, { method: "GET" }));
  if (!res.ok) {
    throw new Error(`jwks fetch failed: ${res.status}`);
  }
  const body = (await res.json()) as JSONWebKeySet;
  if (!body || !Array.isArray(body.keys)) {
    throw new Error("jwks response missing keys array");
  }
  return body;
}

/**
 * Verifies an `Authorization: Bearer <jwt>` token against the web's
 * own JWKS (the same keys Better-Auth's `jwt` plugin uses to sign OAuth
 * `client_credentials` access tokens — and the same keys the relay verifies
 * against in production).
 *
 * Security invariants:
 *  - alg pinned to `EdDSA` (Better-Auth jwt plugin's only configured alg).
 *  - Issuer pinned to `${BETTER_AUTH_URL}/api/auth` (oauth-provider's default
 *    audience and the issuer Better-Auth stamps onto the token).
 *  - `uid` (verified claim) is the only source of `userId` set on the context.
 *  - `scope` must carry `agent`.
 *  - The `deviceUuid` claim must resolve to a live device OWNED BY `uid`.
 *    Device tokens live an hour (`m2mAccessTokenExpiresIn`), so without this a
 *    revoked device would keep its access until the token expired on its own;
 *    it is deliberately part of the one gate rather than a composable second
 *    middleware, because a route added later cannot forget what it never had
 *    to remember. The resolved id lands on the context as `deviceId`.
 *  - On any failure (missing header, bad shape, expired, bad signature,
 *    wrong issuer, missing uid, missing scope, dead device) responds 401 — no
 *    claims are trusted.
 *
 * Returns 401 with `{ error: "UNAUTHENTICATED" }` to match `requireUser`'s
 * shape so client error handling is uniform across the two auth modes.
 */
export function requireBearerJwt(deps: {
  auth: Auth;
  db: DB;
  env: Env;
}): MiddlewareHandler<{ Variables: AuthVars }> {
  let cache: CachedJwks | undefined;

  async function getKeySet(forceRefresh: boolean) {
    const now = Date.now();
    if (!forceRefresh && cache && now - cache.fetchedAt < JWKS_TTL_MS) {
      return cache.set;
    }
    const jwks = await fetchJwks(deps.auth, deps.env);
    cache = { set: createLocalJWKSet(jwks), fetchedAt: now };
    return cache.set;
  }

  return async (c: Context<{ Variables: AuthVars }>, next) => {
    const authz = c.req.header("authorization") ?? c.req.header("Authorization");
    if (!authz || !authz.toLowerCase().startsWith("bearer ")) {
      return c.json({ error: "UNAUTHENTICATED" }, 401);
    }
    const token = authz.slice("bearer ".length).trim();
    if (!token) return c.json({ error: "UNAUTHENTICATED" }, 401);

    const issuer = expectedIssuer(deps.env);

    let payload: JWTPayload | null = null;
    for (const refresh of [false, true]) {
      try {
        const keySet = await getKeySet(refresh);
        const verified = await jwtVerify(token, keySet, {
          algorithms: ["EdDSA"],
          issuer,
        });
        payload = verified.payload;
        break;
      } catch (err) {
        // Retry once with a forced JWKS refresh in case of kid rotation; any
        // other failure (expired, bad sig, wrong issuer) terminates.
        const msg = err instanceof Error ? err.message : String(err);
        const looksLikeKidMiss =
          msg.includes("kid") || msg.includes("no applicable key");
        if (refresh || !looksLikeKidMiss) {
          return c.json({ error: "UNAUTHENTICATED" }, 401);
        }
      }
    }

    if (!payload) {
      return c.json({ error: "UNAUTHENTICATED" }, 401);
    }

    const claims = payload as Record<string, unknown>;
    const uid = claims.uid;
    if (typeof uid !== "string" || uid.length === 0) {
      return c.json({ error: "UNAUTHENTICATED" }, 401);
    }

    if (!tokenScopes(claims.scope).includes(REQUIRED_SCOPE)) {
      return c.json({ error: "UNAUTHENTICATED" }, 401);
    }

    // Reading `deviceUuid` off the token is safe in a way a body-supplied id is
    // not: it is only ever a lookup key scoped by the already-verified `uid`,
    // so a claim naming a foreign device resolves to nothing.
    const deviceUuid = claims.deviceUuid;
    if (typeof deviceUuid !== "string" || deviceUuid.length === 0) {
      return c.json({ error: "UNAUTHENTICATED" }, 401);
    }
    const device = await deps.db.device.findFirst({
      where: { userId: uid, deviceId: deviceUuid, revokedAt: null },
      select: { deviceId: true },
    });
    if (!device) {
      return c.json({ error: "UNAUTHENTICATED" }, 401);
    }

    c.set("userId", uid);
    c.set("sessionId", "");
    c.set("userEmail", typeof claims.email === "string" ? claims.email : null);
    c.set("deviceId", device.deviceId);
    await next();
  };
}
