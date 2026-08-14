import { test, expect } from "@playwright/test";

// Prices and the tier axis. KEEP IN LOCKSTEP with src/data/pricing.ts, which is itself
// pinned to the shipped catalog by web/tests/billing/site-pricing-lockstep.test.ts —
// this file only proves the page renders what that file says, so a number that is wrong
// in both is caught over there, not here. CTA wiring and the closed paid path are
// asserted in contracts.spec.ts — a wrong number here is a pricing bug, a wrong link
// there is a revenue bug, and they should not be able to mask each other.

test("pricing is sold on the seat axis", async ({ page }) => {
  await page.goto("/pricing");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(/priced per person/i);
});

test("plan cards carry the real prices, machine allowances and seat ceiling", async ({ page }) => {
  await page.goto("/pricing");

  // Locate each plan card by its heading span (font-mono text-ink inside the card).
  // Using .locator("..") to go up to the card root so price assertions stay within one card.
  const freeCard = page.locator("span.font-mono", { hasText: /^Free$/ }).locator("..").locator("..");
  const yearlyCard = page.locator("span.font-mono", { hasText: /^Pro$/ }).locator("..").locator("..");

  await expect(freeCard.locator("span.text-3xl", { hasText: "$0" })).toBeVisible();
  await expect(freeCard.getByText("1 worker machine")).toBeVisible();

  // Yearly card: $49 offer price (the large price span) + $99 struck list price, both
  // per seat — the unit is the claim, so it is asserted beside the number.
  await expect(yearlyCard.locator("span.text-3xl", { hasText: "$49" })).toBeVisible();
  await expect(yearlyCard.locator("span.line-through", { hasText: "$99" })).toBeVisible();
  await expect(yearlyCard.getByText("/ seat / year")).toBeVisible();
  await expect(yearlyCard.getByText("Up to 10 worker machines per person")).toBeVisible();
  await expect(yearlyCard.getByText(/Up to 25 seats/)).toBeVisible();
});

test("the FAQ answers the seat and machine questions in place", async ({ page }) => {
  await page.goto("/pricing");
  await expect(page.getByRole("heading", { name: /what counts as a seat\?/i })).toBeVisible();
  await expect(page.getByRole("heading", { name: /what counts as a worker machine\?/i })).toBeVisible();

  // The FAQPage schema ships with the questions so the two cannot answer differently;
  // a malformed blob is invisible on the page and costs the rich result.
  const raw = await page.locator('script[type="application/ld+json"]').last().textContent();
  const schema = JSON.parse(raw ?? "");
  expect(schema["@type"]).toBe("FAQPage");
  expect(schema.mainEntity.length).toBeGreaterThan(0);
});
