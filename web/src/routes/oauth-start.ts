// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { getCookie, setCookie } from "hono/cookie";
import { randomBytes } from "node:crypto";
import { z } from "zod";
import { scopedAuthDb, authTransaction } from "../auth/transaction.js";
import { nativeCookie, digest, matches } from "../auth/native-plugin.js";
import { createFlow, linkFlowUser } from "../auth/flows.js";
import { authScope } from "../auth/transaction.js";
import { requestOrigin, safeReturnPath } from "../auth/contracts.js";
import { pruneBrowserBindings } from "../auth/browser-bindings.js";
import type { DB } from "../db/index.js";
import { Hono } from "hono";
import { isAPIError } from "better-auth/api";
import { appleSignInConfigured, type Auth } from "../auth/better-auth.js";
import type { Env } from "../env.js";

/**
 * Browser-navigable entry point for social sign-in.
 *
 * Better-Auth exposes social sign-in only as `POST /api/auth/sign-in/social`
 * with a JSON body `{ provider, callbackURL }`, returning `{ url }` for the
 * caller to redirect to. A browser GET (an `<a href>` on the web login, or the
 * app opening the system browser) can't drive a POST-and-read-JSON endpoint, so
 * navigating straight at `/api/auth/sign-in/social/<provider>` 404s.
 *
 * This route bridges the gap: it calls `signInSocial` server-side and 302s the
 * browser to the provider's authorize URL. Any `Set-Cookie` the call emits
 * (OAuth state / PKCE verifier) MUST be forwarded, or the provider callback's
 * state validation fails — hence `returnHeaders: true`.
 */
type SocialProvider = "github" | "google" | "apple";

function providers(env: Env): ReadonlySet<SocialProvider> {
  const enabled: SocialProvider[] = ["github", "google"];
  if (appleSignInConfigured(env)) enabled.push("apple");
  return new Set(enabled);
}

/**
 * Accept ONLY a same-origin relative path as the post-login redirect target.
 *
 * Better-Auth threads `callbackURL` through the signed OAuth state and 302s the
 * (now-authenticated) browser to it after the provider callback — but its
 * trusted-origin check (`originCheckMiddleware`) is skipped for server-side
 * `auth.api.*` calls and for GET callbacks, so an absolute external URL would
 * sail through as an authenticated open redirect (phishing handoff). We gate it
 * here instead: the value must start with a single "/" and not "//" or "/\"
 * (which browsers treat as a protocol-relative external URL). Anything else
 * (absolute URLs, backslash tricks, missing value) falls back to the dashboard.
 */
export function safeCallbackURL(raw: string | undefined): string {
  return safeReturnPath(raw);
}

export function oauthStartRoutes(deps: { auth: Auth; env: Env; db?: DB }) {
  const enabled = providers(deps.env);
  const r = new Hono();
  r.get("/oauth/start", async (c) => {
    const provider = (c.req.query("provider") ?? "") as SocialProvider;
    if (!enabled.has(provider)) {
      return c.text(`Unknown provider: ${provider || "(none)"}`, 400);
    }
    // Restrict the post-login redirect to a same-origin relative path. Do NOT
    // rely on Better-Auth's trusted-origin check here — it's bypassed on this
    // server-side + GET-callback path (see safeCallbackURL).
    let callbackURL = safeCallbackURL(c.req.query("callbackURL") === "/dashboard" ? getCookie(c,"antgrid.return_path") : c.req.query("callbackURL"));
    const flowId = c.req.query("flow");
    if (flowId) {
      if (!deps.db || !z.uuid().safeParse(flowId).success) return c.text("Invalid sign-in attempt", 400);
      const db = scopedAuthDb(deps.db);
      const binding = randomBytes(32).toString("base64url");
      const accepted = await authTransaction(db, async () => {
        await db.$queryRaw`SELECT id FROM auth_flows WHERE id=${flowId}::uuid FOR UPDATE`;
        const flow = await db.authFlow.findUnique({ where: { id: flowId }, include: { journey: true } });
        if (!flow || flow.state !== "pending" || flow.expiresAt <= new Date() ||
            (flow.journey.origin as { method: string }).method !== provider || !matches(flow.launchHash, c.req.query("launch") ?? "")) return false;
        await pruneBrowserBindings(db, deps.env.BETTER_AUTH_SECRET, c.req.raw.headers, (name) => getCookie(c, name),
          (name, value, maxAge) => setCookie(c, name, value, { httpOnly: true, secure: deps.env.BETTER_AUTH_URL.startsWith("https:"), sameSite: "lax", path: "/", maxAge }),
          { id: flow.id, kind: "native", expiresAt: flow.expiresAt, value: binding });
        await db.authFlow.update({ where: { id: flowId }, data: { launchHash: null, bindingHash: digest(binding) } });
        return true;
      });
      if (!accepted) return c.text("Invalid or expired sign-in attempt", 400);
      setCookie(c, nativeCookie(flowId), binding, { httpOnly: true, secure: deps.env.BETTER_AUTH_URL.startsWith("https:"), sameSite: "lax", path: "/", maxAge: 600 });
      callbackURL = `/oauth/handoff?flow=${flowId}`;
    } else if (c.req.query("callbackURL")?.startsWith("/oauth/handoff")) {
      if (deps.env.LEGACY_NATIVE_OAUTH === false || deps.env.LEGACY_NATIVE_OAUTH_ISSUANCE === false) return c.text("Update Antgrid to continue signing in.", 426);
      callbackURL = "/oauth/handoff";
    } else if (deps.db) {
      const db = scopedAuthDb(deps.db);
      const flow = await authTransaction(db, async () => {
        const created = await createFlow(db, requestOrigin(c.req.raw.headers, provider), 600);
        await db.authFlow.update({ where: { id: created.id }, data: { returnPath: callbackURL } });
        return created;
      });
      callbackURL = `/oauth/web-complete?flow=${flow.id}`;
    }

    try {
      const { headers, response } = await deps.auth.api.signInSocial({
        body: { provider, callbackURL, errorCallbackURL: flowId ? `/oauth/handoff?flow=${flowId}&error=provider` : "/login?error=Sign-in%20did%20not%20complete" },
        headers: c.req.raw.headers,
        returnHeaders: true,
      });
      if (!response?.url) {
        return c.text("Sign-in did not return a redirect URL", 502);
      }
      for (const sc of headers.getSetCookie()) {
        c.header("set-cookie", sc, { append: true });
      }
      c.header("Cache-Control", "no-store");
      return c.redirect(response.url);
    } catch (err) {
      // Better-Auth validation rejections are expected (bad provider/config) →
      // friendly 400. Anything else is unexpected → central onError logs it.
      if (isAPIError(err)) return c.text("Could not start social sign-in", 400);
      throw err;
    }
  });
  r.get("/oauth/web-complete", async (c) => {
    const id = c.req.query("flow");
    if (!id || !z.uuid().safeParse(id).success || !deps.db) return c.redirect("/login");
    const db = scopedAuthDb(deps.db);
    const session = await deps.auth.api.getSession({ headers: c.req.raw.headers });
    const flow = await db.authFlow.findUnique({ where: { id } });
    if (!flow || !session || flow.sessionId !== session.session.id || flow.expiresAt <= new Date()) return c.redirect("/login");
    await authTransaction(db, async () => {
      authScope.getStore()!.flowId = id;
      await linkFlowUser(db, session.user.id, "ownership_verified");
    });
    return c.redirect(safeReturnPath(flow.returnPath));
  });
  return r;
}
