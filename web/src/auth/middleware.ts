// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { Context, MiddlewareHandler } from "hono";
import { safeReturnPath } from "./contracts.js";
import { recordStage } from "./flows.js";
import type { Auth } from "./better-auth.js";
import { getSignedCookie } from "hono/cookie";
import type { DB } from "../db/index.js";

export type AuthVars = {
  userId: string;
  sessionId: string;
  userEmail: string | null;
  userName: string | null;
  deviceAuthorization?: {
    id: string;
    deviceId: string;
    enrollmentId: string;
    publicKey: Uint8Array;
    kind: string;
  };
};

type Session = {
  sessionId: string;
  userId: string;
  email: string | null;
  name: string | null;
};

async function loadSession(auth: Auth, c: Context): Promise<Session | null> {
  const res = await auth.api.getSession({ headers: c.req.raw.headers });
  if (!res?.session || !res.user) return null;
  return {
    sessionId: res.session.id,
    userId: res.user.id,
    email: res.user.email ?? null,
    name: res.user.name ?? null,
  };
}

function setAuthVars(c: Context<{ Variables: AuthVars }>, s: Session): void {
  c.set("userId", s.userId);
  c.set("sessionId", s.sessionId);
  c.set("userEmail", s.email);
  c.set("userName", s.name);
}

/** Gate a JSON route. Returns 401 when unauthenticated. */
export function requireUser(deps: { auth: Auth; db?: DB }): MiddlewareHandler<{ Variables: AuthVars }> {
  return async (c, next) => {
    const s = await loadSession(deps.auth, c);
    if (!s) return c.json({ error: "UNAUTHENTICATED" }, 401);
    setAuthVars(c, s);
    if (deps.db) {
      const flows = await deps.db.authFlow.findMany({ where: { sessionId: s.sessionId }, select: { id: true } });
      for (const flow of flows) await recordStage(deps.db, flow.id, "first_client_use");
    }
    await next();
  };
}

/** Gate a UI route. Redirects to /login when unauthenticated. */
export function requireUserOrRedirect(deps: { auth: Auth; db: DB }): MiddlewareHandler<{ Variables: AuthVars }> {
  return async (c, next) => {
    const s = await loadSession(deps.auth, c);
    if (!s) return c.redirect("/login?returnPath=" + encodeURIComponent(safeReturnPath(new URL(c.req.url).pathname + new URL(c.req.url).search)));
    setAuthVars(c, s);
    if (deps.db) {
      const flows = await deps.db.authFlow.findMany({ where: { sessionId: s.sessionId }, select: { id: true } });
      for (const flow of flows) await recordStage(deps.db, flow.id, "first_client_use");
    }
    await next();
  };
}

export function requireReadOnlyUserOrRedirect(deps: { auth: Auth; db: DB }): MiddlewareHandler<{ Variables: AuthVars }> {
  return async (c, next) => {
    // Better-Auth's getSession refreshes old sessions and deletes expired ones.
    // Operator observations must not change the records they inspect.
    const context = await deps.auth.$context;
    const token = await getSignedCookie(c, context.secret, context.authCookies.sessionToken.name);
    if (!token) return c.redirect("/login");
    const row = await deps.db.session.findUnique({
      where: { token },
      select: {
        id: true, expiresAt: true,
        user: { select: { id: true, email: true, name: true } },
      },
    });
    if (!row || row.expiresAt <= new Date()) return c.redirect("/login");
    setAuthVars(c, { sessionId: row.id, userId: row.user.id, email: row.user.email, name: row.user.name });
    await next();
  };
}
