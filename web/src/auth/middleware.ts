import type { Context, MiddlewareHandler } from "hono";
import type { Auth } from "./better-auth.js";

export type AuthVars = {
  userId: string;
  sessionId: string;
  userEmail: string | null;
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

/** Gate a UI route. Redirects to /login when unauthenticated. */
export function requireUserOrRedirect(deps: { auth: Auth }): MiddlewareHandler<{ Variables: AuthVars }> {
  return async (c, next) => {
    const s = await loadSession(deps.auth, c);
    if (!s) return c.redirect("/login");
    setAuthVars(c, s);
    await next();
  };
}
