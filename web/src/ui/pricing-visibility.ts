// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { MiddlewareHandler } from "hono";
import { tryGetContext } from "hono/context-storage";
import { getCookie, setCookie } from "hono/cookie";

/** `?hidePricing=1` is how the iOS app opens this service inside its in-app
 *  Safari sheet. App Store guideline 3.1.1 rejects an app that leads to a web
 *  purchase, so every way to a plan disappears for the rest of that browsing
 *  session. */
export const HIDE_PRICING_QUERY = "hidePricing";

/** Carries the query past the sign-in redirect, which drops it, and onto every
 *  page reached by a link. A session cookie in the sheet's own cookie jar,
 *  which Safari proper does not share. */
export const HIDE_PRICING_COOKIE = "antgrid-hide-pricing";

const PURCHASE_PATHS = new Set(["/pricing", "/upgrade", "/checkout"]);

/** True when the request being rendered came from the iOS app's sheet. Read
 *  through context storage for the same reason as `currentTheme()`; outside a
 *  request nothing is hidden. */
export function pricingHidden(): boolean {
  const c = tryGetContext();
  if (!c) return false;
  return c.req.query(HIDE_PRICING_QUERY) === "1" || getCookie(c, HIDE_PRICING_COOKIE) === "1";
}

/** Must run before the routes: it sets the cookie on the very request that
 *  carries the query, which for a signed-out reader is the one about to be
 *  redirected to /login. */
export function hidePricingMiddleware(): MiddlewareHandler {
  return async (c, next) => {
    if (c.req.query(HIDE_PRICING_QUERY) === "1") {
      setCookie(c, HIDE_PRICING_COOKIE, "1", { path: "/", httpOnly: true, sameSite: "Lax" });
    }
    if (c.req.method === "GET" && PURCHASE_PATHS.has(c.req.path) && pricingHidden()) {
      return c.redirect("/dashboard");
    }
    await next();
  };
}
