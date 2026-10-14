// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { z } from "zod";
import { getCookie } from "hono/cookie";
import type { DB } from "../db/index.js";
import { nativeCookie, matches } from "../auth/native-plugin.js";
import { recordStage } from "../auth/flows.js";
import { Hono } from "hono";
import { isAPIError } from "better-auth/api";
import type { Auth } from "../auth/better-auth.js";

// Native handoff carries a verifier-bound code; legacy issuance stays gated
// until updated clients ship and previously issued tokens have drained.
const DEEP_LINK = "antgrid://auth/callback";

export function oauthHandoffRoutes(deps: { auth: Auth; db?: DB; legacy?: boolean }) {
  const r = new Hono();
  r.get("/oauth/handoff", async (c) => {
    const flow = c.req.query("flow");
    if (flow) {
      if (!z.uuid().safeParse(flow).success || !deps.db) return c.text("Invalid sign-in attempt",400);
      const attempt = await deps.db.authFlow.findUnique({ where: { id: flow } });
      if (!attempt || attempt.expiresAt <= new Date() || !matches(attempt.bindingHash,getCookie(c,nativeCookie(flow)) ?? "")) return c.text("Invalid or expired sign-in attempt",400);
      if (c.req.query("error")) await recordStage(deps.db,flow,"auth_failed","provider_cancelled_or_failed");
      let code: string;
      try {
        if (c.req.query("error")) throw new Error("provider cancellation");
        const result = await deps.auth.api.nativeComplete({ headers: c.req.raw.headers, body: { id: flow } });
        code = result.code;
      } catch { return c.redirect(`${DEEP_LINK}?flow=${encodeURIComponent(flow)}&error=sign_in_failed`); }
      return c.redirect(`${DEEP_LINK}?flow=${encodeURIComponent(flow)}&code=${encodeURIComponent(code)}`);
    }
    if (deps.legacy === false) return c.text("Update Antgrid to continue signing in.", 426);
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
