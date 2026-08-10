import { test, expect } from "@playwright/test";

test("get-started has a single h1 and the AppImage chmod step", async ({ page }) => {
  await page.goto("/get-started");
  const h1 = page.getByRole("heading", { level: 1 });
  await expect(h1).toHaveCount(1);
  // Functional instruction, not copy: Linux users cannot launch the AppImage without it.
  await expect(page.locator("body")).toContainText("chmod +x");
});

test("get-started covers the three-step spine", async ({ page }) => {
  // Assert structure (three step headings + the agent prerequisite), not wording.
  await page.goto("/get-started");
  await expect(page.getByRole("heading", { name: /step 1/i })).toBeVisible();
  await expect(page.getByRole("heading", { name: /step 2/i })).toBeVisible();
  await expect(page.getByRole("heading", { name: /step 3/i })).toBeVisible();
  await expect(page.getByRole("heading", { name: /before you start/i })).toBeVisible();
});
