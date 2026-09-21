import { test, expect, type Page } from "@playwright/test";

// The two halves of --color-page and --color-ab-deep in src/styles/global.css,
// as the browser reports them. Read from the rendered page rather than the
// sheet: a light-dark() pair that never resolves reads back as the raw string,
// which is exactly the failure this file exists to catch.
const PAGE = { light: "rgb(247, 244, 238)", dark: "rgb(19, 17, 16)" };
const WINDOW = { light: "rgb(245, 245, 245)", dark: "rgb(12, 12, 15)" };

const bodyBg = (page: Page) =>
  page.evaluate(() => getComputedStyle(document.body).backgroundColor);
const windowBg = (page: Page) =>
  page.locator(".appwin").first().evaluate((el) => getComputedStyle(el).backgroundColor);

for (const scheme of ["light", "dark"] as const) {
  test.describe(`a ${scheme} OS`, () => {
    test.use({ colorScheme: scheme });

    test(`gets the ${scheme} page and app window with no override set`, async ({ page }) => {
      await page.goto("/");
      await expect(page.locator("html")).not.toHaveAttribute("data-theme", /./);
      expect(await bodyBg(page)).toBe(PAGE[scheme]);
      expect(await windowBg(page)).toBe(WINDOW[scheme]);
    });
  });
}
