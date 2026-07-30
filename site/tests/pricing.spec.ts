import { test, expect } from "@playwright/test";

test("pricing reflects real plans/prices and correct CTAs", async ({ page }) => {
  await page.goto("/pricing");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(/priced by machines/i);

  // Lifetime is retired from marketing (existing holders keep entitlement server-side).
  await expect(page.locator("body")).not.toContainText(/lifetime/i);

  // Locate each plan card by its heading span (font-mono text-ink inside the card).
  // Using .locator("..") to go up to the card root so price assertions stay within one card.
  const freeCard = page.locator("span.font-mono", { hasText: /^Free$/ }).locator("..").locator("..");
  const yearlyCard = page.locator("span.font-mono", { hasText: /^Pro Yearly$/ }).locator("..").locator("..");

  await expect(freeCard.locator("span.text-3xl", { hasText: "$0" })).toBeVisible();
  await expect(freeCard.getByText("Up to 2 worker machines")).toBeVisible();

  // Yearly card: $49 offer price (the large price span) + $99 struck list price
  await expect(yearlyCard.locator("span.text-3xl", { hasText: "$49" })).toBeVisible();
  await expect(yearlyCard.locator("span.line-through", { hasText: "$99" })).toBeVisible();
  await expect(yearlyCard.getByText("Up to 3 worker machines")).toBeVisible();
  await expect(page.getByText(/AI supervisor/).first()).toBeVisible();

  // Checkout is unwired this release: paid CTAs are disabled buttons, not links.
  await expect(page.locator('a[href*="checkout"]')).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Coming soon" })).toHaveCount(2);
  await expect(page.getByRole("button", { name: "Coming soon" }).first()).toBeDisabled();

  // Free's CTA is a sign-in link and stays live.
  await expect(page.getByRole("link", { name: "Start free" }).first()).toHaveAttribute("href", /app\.antgrid\.ai\/login/);
});
