import { test, expect } from "@playwright/test";

test("production blog is discoverable and handles an empty collection", async ({ page }) => {
  await page.goto("/blog");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Blog");
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute("href", "https://antgrid.ai/blog");
  await expect(page.locator("body > footer").getByRole("link", { name: "Blog", exact: true })).toHaveAttribute("href", "/blog");
  if (await page.locator(".blog-empty").count()) {
    await expect(page.locator(".blog-empty")).toHaveText("Articles are on the way.");
    await expect(page.locator("header nav").getByRole("link", { name: "Blog", exact: true })).toHaveCount(0);
  }
});
