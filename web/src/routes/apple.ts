// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { Hono } from "hono";
import { z } from "zod";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import type { AppleTokenClient } from "../auth/apple-tokens.js";
import { requireUser, type AuthVars } from "../auth/middleware.js";
import { storeAppleNativeAuthorization } from "../services/apple-account.js";
import { tokenBucket } from "../util/rate-limit.js";

const Body = z.object({ code: z.string().min(1).max(4096) });

/**
 * `POST /account/apple/authorization-code` — the native app's second step of
 * Sign in with Apple. After signing in with the id token it posts the
 * authorization code from the same Apple sheet, on the session it just got,
 * so the account keeps a refresh token that deletion can revoke.
 *
 * A failure here leaves the user signed in; they only lose revocation on
 * deletion, so the app treats this call as best-effort.
 */
export function appleRoutes(deps: { db: DB; auth: Auth; apple?: AppleTokenClient }) {
  const r = new Hono<{ Variables: AuthVars }>();
  r.use("/account/apple/authorization-code", requireUser({ auth: deps.auth }));

  // Each call spends a single-use code on a round trip to Apple; one per
  // sign-in is the legitimate rate.
  const limiter = tokenBucket(5, 0.05);

  r.post("/account/apple/authorization-code", async (c) => {
    const apple = deps.apple;
    if (!apple) return c.json({ error: "APPLE_NOT_CONFIGURED" }, 404);
    const userId = c.get("userId");
    if (!limiter(userId)) return c.json({ error: "RATE_LIMITED" }, 429);
    const parsed = Body.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST" }, 400);

    let result;
    try {
      result = await storeAppleNativeAuthorization(deps.db, apple, {
        userId,
        code: parsed.data.code,
      });
    } catch (err) {
      console.error("[apple] authorization code exchange failed", {
        userId,
        error: err instanceof Error ? err.message : String(err),
      });
      return c.json({ error: "APPLE_UNAVAILABLE" }, 502);
    }
    if (result === "invalid_code") return c.json({ error: "INVALID_CODE" }, 400);
    if (result === "not_this_user") return c.json({ error: "APPLE_ACCOUNT_MISMATCH" }, 409);
    return c.body(null, 204);
  });
  return r;
}
