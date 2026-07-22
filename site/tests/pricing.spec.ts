import { test, expect } from "@playwright/test";

test("pricing reflects real plans/prices and correct CTAs", async ({ page }) => {
  await page.goto("/pricing");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(/local is free\. pay only to go remote\./i);

  // Free is local-only and never says "N agents free"
  await expect(page.getByText("Unlimited local agents")).toBeVisible();
  await expect(page.locator("body")).not.toContainText(/first agents are free/i);

  // Locate each plan card by its heading span (font-mono text-ink inside the card).
  // Using .locator("..") to go up to the card root so price assertions stay within one card.
  const yearlyCard = page.locator("span.font-mono", { hasText: /^Pro Yearly$/ }).locator("..").locator("..");
  const lifetimeCard = page.locator("span.font-mono", { hasText: /^Pro Lifetime$/ }).locator("..").locator("..");

  // Yearly card: $49 offer price (the large price span) + $99 struck list price
  await expect(yearlyCard.locator("span.text-3xl", { hasText: "$49" })).toBeVisible();
  await expect(yearlyCard.locator("span.line-through", { hasText: "$99" })).toBeVisible();

  // Lifetime card: $99 price (the large price span)
  await expect(lifetimeCard.locator("span.text-3xl", { hasText: "$99" })).toBeVisible();

  // Supervisor is a Pro feature, cap is "concurrent remote agents"
  await expect(page.getByText(/AI supervisor/)).toBeVisible();
  await expect(page.getByText(/concurrent remote agents/).first()).toBeVisible();

  // Lifetime recommended + correct checkout links
  await expect(page.getByText("RECOMMENDED")).toBeVisible();
  await expect(page.getByRole("link", { name: "Start 7-day trial" })).toHaveAttribute("href", /checkout\?planId=trial/);
  await expect(page.getByRole("link", { name: "Get Lifetime" })).toHaveAttribute("href", /checkout\?planId=pro_lifetime/);
  await expect(page.getByRole("link", { name: "Start free" }).first()).toHaveAttribute("href", /app\.antgrid\.ai\/login/);
});
