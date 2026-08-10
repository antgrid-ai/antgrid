import { test, expect } from "@playwright/test";

// Prices and the tier axis. KEEP IN LOCKSTEP with src/data/pricing.ts, which is itself
// pinned to web/src/billing/plans.ts. CTA wiring and the closed paid path are asserted
// in contracts.spec.ts — a wrong number here is a pricing bug, a wrong link there is a
// revenue bug, and they should not be able to mask each other.

test("pricing is sold on the worker-machine axis", async ({ page }) => {
  await page.goto("/pricing");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(/priced by machines/i);
});

test("plan cards carry the real prices and worker caps", async ({ page }) => {
  await page.goto("/pricing");

  // Locate each plan card by its heading span (font-mono text-ink inside the card).
  // Using .locator("..") to go up to the card root so price assertions stay within one card.
  const freeCard = page.locator("span.font-mono", { hasText: /^Free$/ }).locator("..").locator("..");
  const yearlyCard = page.locator("span.font-mono", { hasText: /^Pro Yearly$/ }).locator("..").locator("..");

  await expect(freeCard.locator("span.text-3xl", { hasText: "$0" })).toBeVisible();
  await expect(freeCard.getByText("Up to 2 worker machines")).toBeVisible();

  // Yearly card: $49 offer price (the large price span) + $99 struck list price.
  await expect(yearlyCard.locator("span.text-3xl", { hasText: "$49" })).toBeVisible();
  await expect(yearlyCard.locator("span.line-through", { hasText: "$99" })).toBeVisible();
  await expect(yearlyCard.getByText("Up to 3 worker machines")).toBeVisible();
});
