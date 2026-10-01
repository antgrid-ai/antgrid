// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { MiddlewareHandler } from "hono";
import { normalizePathname } from "@better-auth/core/utils/url";
import type { ClientIpResolver } from "../util/client-ip.js";
import { tokenBucket } from "../util/rate-limit.js";

// Older apps mint on each ~20s lease refresh. Shared-IP traffic needs a
// continuously refilling budget, not Better-Auth's idle-reset counter.
// 120/minute supports 40 such clients, with a burst for reconnects.
export const OAUTH_TOKEN_BURST = 120;
const REFILL_PER_SECOND = OAUTH_TOKEN_BURST / 60;

export function oauthTokenRateLimit(clientIp: ClientIpResolver): MiddlewareHandler {
  const allow = tokenBucket(OAUTH_TOKEN_BURST, REFILL_PER_SECOND);
  return async (c, next) => {
    if (
      c.req.method === "POST" &&
      normalizePathname(c.req.url, "/api/auth") === "/oauth2/token" &&
      !allow(clientIp(c) ?? "unknown")
    ) {
      const retryAfter = String(Math.ceil(1 / REFILL_PER_SECOND));
      c.header("Retry-After", retryAfter);
      c.header("X-Retry-After", retryAfter);
      return c.json({
        error: "temporarily_unavailable",
        error_description: "Too many token requests",
      }, 429);
    }
    await next();
  };
}
