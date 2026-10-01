// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { describe, test, expect } from "bun:test";
import { Hono } from "hono";
import { contextStorage } from "hono/context-storage";
import { Layout } from "../../src/ui/layout.js";
import { HIDE_PRICING_COOKIE, hidePricingMiddleware } from "../../src/ui/pricing-visibility.js";

const gita = { id: "user-1", email: "gita@example.com" };

function app(): Hono {
  const a = new Hono();
  a.use(contextStorage());
  a.use(hidePricingMiddleware());
  a.get("/account", (c) => c.html(Layout({ title: "Account", user: gita, children: "x" }).toString()));
  // Stands in for the signed-out bounce: the query is gone by the next hop.
  a.get("/signed-out", (c) => c.redirect("/login"));
  a.get("/pricing", (c) => c.text("pricing"));
  a.get("/checkout", (c) => c.text("checkout"));
  return a;
}

const PRICING_LINK = 'href="/pricing"';

describe("hidePricing", () => {
  test("without the flag the nav offers Pricing and /pricing is served", async () => {
    expect(await (await app().request("/account")).text()).toContain(PRICING_LINK);
    expect(await (await app().request("/pricing")).text()).toBe("pricing");
  });

  test("the query hides Pricing from the page it lands on", async () => {
    const res = await app().request("/account?hidePricing=1");
    expect(await res.text()).not.toContain(PRICING_LINK);
  });

  test("the query sets the cookie even on a request that redirects", async () => {
    const res = await app().request("/signed-out?hidePricing=1");
    expect(res.status).toBe(302);
    expect(res.headers.get("set-cookie")).toContain(`${HIDE_PRICING_COOKIE}=1`);
  });

  test("the cookie alone keeps Pricing hidden on later pages", async () => {
    const res = await app().request("/account", { headers: { cookie: `${HIDE_PRICING_COOKIE}=1` } });
    expect(await res.text()).not.toContain(PRICING_LINK);
  });

  test("purchase pages send a hidden-pricing reader to the dashboard", async () => {
    for (const path of ["/pricing", "/checkout?planId=pro", "/upgrade"]) {
      const res = await app().request(path, { headers: { cookie: `${HIDE_PRICING_COOKIE}=1` } });
      expect(res.status).toBe(302);
      expect(res.headers.get("location")).toBe("/dashboard");
    }
  });

  test("any other value is ignored", async () => {
    const res = await app().request("/account?hidePricing=0", {
      headers: { cookie: `${HIDE_PRICING_COOKIE}=yes` },
    });
    expect(await res.text()).toContain(PRICING_LINK);
  });
});
