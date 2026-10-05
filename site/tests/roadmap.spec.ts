import { test, expect } from "@playwright/test";

test("roadmap renders planned work, stable anchors and completed features", async ({ page }, testInfo) => {
  await page.goto("/roadmap");
  await expect(page).toHaveTitle("Roadmap — antgrid");
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute("href", /\/roadmap$/);
  await expect(page.locator("main h2")).toHaveText(["Now", "Next", "Done"]);
  const now = page.getByRole("region", { name: "Now", exact: true });
  await expect(now.locator("#public-roadmap")).toHaveCount(0);
  const completed = page.getByRole("region", { name: "Done", exact: true }).locator("#public-roadmap");
  await expect(completed).toContainText("Completed:");
  await expect(completed.getByRole("link", { name: "Discussion: Public roadmap" })).toHaveAttribute("href", "https://github.com/antgrid-ai/antgrid/pull/211");
  await expect(page.locator("main")).not.toContainText("Awaiting release");
  await expect(page.getByRole("region", { name: "Next", exact: true })).toContainText("Cross-agent and cross-machine memory");
  await expect(page.locator('main a[href="/changelog"]')).toBeVisible();
  const anchor = page.getByRole("link", { name: "Native app preview", exact: true });
  await anchor.focus();
  await expect(anchor).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/roadmap#native-app-preview$/);
  await expect(page.locator("#native-app-preview")).toBeInViewport();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.goto("/roadmap");
  await page.screenshot({ path: testInfo.outputPath("roadmap.png"), fullPage: true });
  await page.setViewportSize({ width: 320, height: 800 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test("header and footer link to roadmap beside changelog and mark the current page", async ({ page, isMobile }) => {
  await page.goto("/changelog");
  if (isMobile) await page.getByRole("button", { name: "Open menu" }).click();
  const nav = page.locator(isMobile ? "#navMenu" : "header nav");
  const link = nav.getByRole("link", { name: "Roadmap", exact: true });
  await expect(link).toHaveAttribute("href", "/roadmap");
  await expect(nav.locator('a[href="/changelog"] + a')).toHaveText("Roadmap");
  await link.click();
  await expect(page).toHaveURL(/\/roadmap$/);
  if (isMobile) await page.getByRole("button", { name: "Open menu" }).click();
  await expect(link).toHaveAttribute("aria-current", "page");
  await expect(nav.locator('[aria-current="page"]')).toHaveCount(1);
  await expect(page.locator('footer a[href="/changelog"] + a')).toHaveAttribute("href", "/roadmap");
});
