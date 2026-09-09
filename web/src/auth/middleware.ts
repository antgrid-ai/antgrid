import type { Context, MiddlewareHandler } from "hono";
import type { Auth } from "./better-auth.js";
import type { DB } from "../db/index.js";
import type { Env } from "../env.js";
import { requireBearerJwt } from "./jwt-bearer.js";

export type AuthVars = {
  userId: string;
  sessionId: string;
  userEmail: string | null;
  /**
   * The caller's live device, set only by `requireBearerJwt`. Its presence is
   * the actor-type signal — a Bearer-gated request leaves `sessionId` empty, so
   * the credential is all that distinguishes a bridge from a browser session.
   */
  deviceId?: string;
};

type Session = { sessionId: string; userId: string; email: string | null };

async function loadSession(auth: Auth, c: Context): Promise<Session | null> {
  const res = await auth.api.getSession({ headers: c.req.raw.headers });
  if (!res?.session || !res.user) return null;
  return {
    sessionId: res.session.id,
    userId: res.user.id,
    email: res.user.email ?? null,
  };
}

function setAuthVars(c: Context<{ Variables: AuthVars }>, s: Session): void {
  c.set("userId", s.userId);
  c.set("sessionId", s.sessionId);
  c.set("userEmail", s.email);
}

/** Gate a JSON route. Returns 401 when unauthenticated. */
export function requireUser(deps: { auth: Auth }): MiddlewareHandler<{ Variables: AuthVars }> {
  return async (c, next) => {
    const s = await loadSession(deps.auth, c);
    if (!s) return c.json({ error: "UNAUTHENTICATED" }, 401);
    setAuthVars(c, s);
    await next();
  };
}

/**
 * Gate a route both a human client and the bridge reach, each with its own
 * carrier — cookie from the app and browser, device JWT from the bridge.
 *
 * An `Authorization: Bearer` header is terminal. A request that presents a
 * device token and fails on it must not be rescued by a session cookie riding
 * along in the same request, or a revoked device keeps working the moment its
 * user happens to be signed in somewhere.
 *
 * The two gates stay distinguishable downstream: only the Bearer path sets
 * `deviceId`, so a route that must not be reachable programmatically can still
 * refuse on its presence.
 */
export function requireUserOrBearer(deps: {
  auth: Auth;
  db: DB;
  env: Env;
}): MiddlewareHandler<{ Variables: AuthVars }> {
  // Built once: the bearer gate caches the JWKS per instance, and rebuilding it
  // per request would refetch on every call.
  const bearer = requireBearerJwt(deps);
  const cookie = requireUser({ auth: deps.auth });
  return async (c, next) => {
    // One lookup: `header()` reads through the Fetch Headers API, which folds
    // case itself.
    const authz = c.req.header("authorization");
    if (authz && authz.toLowerCase().startsWith("bearer ")) return bearer(c, next);
    return cookie(c, next);
  };
}

/** Gate a UI route. Redirects to /login when unauthenticated. */
export function requireUserOrRedirect(deps: { auth: Auth }): MiddlewareHandler<{ Variables: AuthVars }> {
  return async (c, next) => {
    const s = await loadSession(deps.auth, c);
    if (!s) return c.redirect("/login");
    setAuthVars(c, s);
    await next();
  };
}
