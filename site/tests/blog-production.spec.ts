import { test, expect } from "@playwright/test";

test("production blog is discoverable and never publishes synthetic fixtures", async ({ page, request }) => {
  await page.goto("/blog");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Blog");
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute("href", "https://antgrid.ai/blog");
  await expect(page.locator("body > footer").getByRole("link", { name: "Blog", exact: true })).toHaveAttribute("href", "/blog");
  expect(await page.locator("main").innerText()).not.toMatch(/synthetic|DRAFT_SENTINEL/);
  for (const slug of ["rendering-check", "latest-note", "earlier-engineering", "unpublished-draft"]) expect((await request.get(`/blog/${slug}`)).status()).toBe(404);
  if (await page.locator(".blog-empty").count()) {
    await expect(page.locator(".blog-empty")).toHaveText("Articles are on the way.");
    await expect(page.locator("header nav").getByRole("link", { name: "Blog", exact: true })).toHaveCount(0);
  }
});
