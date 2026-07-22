import { test, expect } from "@playwright/test";

test("desktop nav shows Start free pointing at app login", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/");
  const cta = page.getByRole("link", { name: "Start free" }).first();
  await expect(cta).toHaveAttribute("href", /app\.antgrid\.ai\/login/);
});

test("mobile menu toggles open", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await page.goto("/");
  const menu = page.locator("#navMenu");
  await expect(menu).toBeHidden();
  await page.locator("#navToggle").click();
  await expect(menu).toBeVisible();
});

test("footer has E2E badge", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("footer")).toContainText("zero-knowledge relay");
});
