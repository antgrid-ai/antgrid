import { Hono } from "hono";
import { isAPIError } from "better-auth/api";
import type { Auth } from "../auth/better-auth.js";

/**
 * Better-Auth's social sign-in sets the session cookie via `Set-Cookie` on its
 * own redirect response, then bounces the browser to `callbackURL`. A native
 * deep link (`antgrid://auth/callback`) can't read cookies, so the app passes
 * the same-origin relative `callbackURL=/oauth/handoff` instead. The browser
 * arrives here with the freshly-issued session cookie attached.
 *
 * We do NOT forward the raw session token: a custom-scheme deep link can be
 * hijacked by any app registering `antgrid://`, and the URL can land in logs. We
 * instead mint a single-use, short-lived one-time token (OTT) bound to this
 * session and put *that* in the deep link. The app redeems it over its own
 * HTTPS client (`POST /api/auth/one-time-token/verify`), receiving the real
 * session via `Set-Cookie`. A hijacked OTT is consumed on first redemption and
 * expires within minutes, so an intercept yields nothing replayable.
 */
const DEEP_LINK = "antgrid://auth/callback";

export function oauthHandoffRoutes(deps: { auth: Auth }) {
  const r = new Hono();
  r.get("/oauth/handoff", async (c) => {
    let token: string;
    try {
      const res = await deps.auth.api.generateOneTimeToken({
        headers: c.req.raw.headers,
      });
      token = res.token;
    } catch (err) {
      // sessionMiddleware throws APIError("UNAUTHORIZED") when there's no
      // session; anything else is an unexpected server-side failure. Always
      // bounce back to the app (so it regains the foreground), but distinguish
      // the two so a real error isn't masked as "not signed in".
      const noSession = isAPIError(err) && err.status === "UNAUTHORIZED";
      return c.redirect(
        `${DEEP_LINK}?error=${noSession ? "no_session" : "server_error"}`
      );
    }
    c.header("Cache-Control", "no-store");
    return c.redirect(`${DEEP_LINK}?token=${encodeURIComponent(token)}`);
  });
  return r;
}
