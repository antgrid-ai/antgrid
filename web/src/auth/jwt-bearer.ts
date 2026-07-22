import type { Context, MiddlewareHandler } from "hono";
import {
  createLocalJWKSet,
  jwtVerify,
  type JSONWebKeySet,
  type JWTPayload,
} from "jose";
import type { Auth } from "./better-auth.js";
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
 *  - On any verify failure (missing header, bad shape, expired, bad signature,
 *    wrong issuer, missing uid) responds 401 — no claims are trusted.
 *
 * Returns 401 with `{ error: "UNAUTHENTICATED" }` to match `requireUser`'s
 * shape so client error handling is uniform across the two auth modes.
 */
export function requireBearerJwt(deps: {
  auth: Auth;
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

    c.set("userId", uid);
    c.set("sessionId", "");
    c.set("userEmail", typeof claims.email === "string" ? claims.email : null);
    await next();
  };
}
