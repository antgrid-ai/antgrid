import { Hono } from "hono";
import { isAPIError } from "better-auth/api";
import type { Auth } from "../auth/better-auth.js";

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
const PROVIDERS = new Set(["github", "google"]);

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
  return raw && /^\/(?![/\\])/.test(raw) ? raw : "/dashboard";
}

export function oauthStartRoutes(deps: { auth: Auth }) {
  const r = new Hono();
  r.get("/oauth/start", async (c) => {
    const provider = c.req.query("provider") ?? "";
    if (!PROVIDERS.has(provider)) {
      return c.text(`Unknown provider: ${provider || "(none)"}`, 400);
    }
    // Restrict the post-login redirect to a same-origin relative path. Do NOT
    // rely on Better-Auth's trusted-origin check here — it's bypassed on this
    // server-side + GET-callback path (see safeCallbackURL).
    const callbackURL = safeCallbackURL(c.req.query("callbackURL"));

    try {
      const { headers, response } = await deps.auth.api.signInSocial({
        body: { provider: provider as "github" | "google", callbackURL },
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
  return r;
}
