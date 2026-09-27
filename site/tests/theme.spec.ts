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

const COOKIE = "antgrid-theme";
const html = (page: Page) => page.locator("html");
const meta = (page: Page, scheme: "light" | "dark") =>
  page.locator(`meta[name="theme-color"][data-scheme="${scheme}"]`);
const choice = (page: Page, label: string) =>
  page.locator("[data-theme-toggle]").getByRole("button", { name: label, exact: true });

for (const scheme of ["light", "dark"] as const) {
  test.describe(`a ${scheme} OS`, () => {
    test.use({ colorScheme: scheme });

    test(`gets the ${scheme} page and app window with no override set`, async ({ page }) => {
      await page.goto("/");
      await expect(html(page)).not.toHaveAttribute("data-theme", /./);
      expect(await bodyBg(page)).toBe(PAGE[scheme]);
      expect(await windowBg(page)).toBe(WINDOW[scheme]);
    });
  });
}

test.describe("the footer toggle, on a light OS", () => {
  test.use({ colorScheme: "light" });

  test("pins the scheme, keeps it across pages, and hands it back to the OS", async ({ page, context }) => {
    await page.goto("/");
    await choice(page, "Dark").click();
    await expect(html(page)).toHaveAttribute("data-theme", "dark");
    expect(await bodyBg(page)).toBe(PAGE.dark);
    await expect(choice(page, "Dark")).toHaveAttribute("aria-pressed", "true");
    await expect(choice(page, "System")).toHaveAttribute("aria-pressed", "false");
    // The override is expressed on the metas by `media`, never by reordering:
    // Chrome takes the first one whose media matches.
    await expect(meta(page, "dark")).toHaveAttribute("media", "all");
    await expect(meta(page, "light")).toHaveAttribute("media", "not all");
    expect((await context.cookies()).find((c) => c.name === COOKIE)?.value).toBe("dark");

    await page.goto("/pricing");
    await expect(html(page)).toHaveAttribute("data-theme", "dark");
    expect(await bodyBg(page)).toBe(PAGE.dark);

    // "System" has to clear the cookie with the scope that stored it, or the
    // next load pins dark again.
    await choice(page, "System").click();
    await expect(html(page)).not.toHaveAttribute("data-theme", /./);
    expect(await bodyBg(page)).toBe(PAGE.light);
    await expect(meta(page, "light")).toHaveAttribute("media", "(prefers-color-scheme: light)");
    expect((await context.cookies()).find((c) => c.name === COOKIE)).toBeUndefined();
    await page.reload();
    await expect(html(page)).not.toHaveAttribute("data-theme", /./);
  });
});

test.describe("a stored override, on a dark OS", () => {
  test.use({ colorScheme: "dark" });

  test("beats the OS and lands before the body exists", async ({ page, context, baseURL }) => {
    await context.addCookies([{ name: COOKIE, value: "light", url: baseURL! }]);
    // Observes the attribute landing and records whether the body had been
    // parsed yet: a pin that arrives after the body is a flash of the wrong
    // scheme, which no screenshot of the settled page can show.
    // On the document, not documentElement: the init script runs before the
    // <html> element has been parsed, so there is nothing else to observe yet.
    await page.addInitScript(() => {
      new MutationObserver((_, observer) => {
        if (document.documentElement?.dataset.theme) {
          (window as { __pinnedBeforeBody?: boolean }).__pinnedBeforeBody = document.body === null;
          observer.disconnect();
        }
      }).observe(document, { attributes: true, subtree: true, attributeFilter: ["data-theme"] });
    });
    await page.goto("/");
    await expect(html(page)).toHaveAttribute("data-theme", "light");
    expect(await bodyBg(page)).toBe(PAGE.light);
    expect(await windowBg(page)).toBe(WINDOW.light);
    await expect(meta(page, "light")).toHaveAttribute("media", "all");
    expect(
      await page.evaluate(() => (window as { __pinnedBeforeBody?: boolean }).__pinnedBeforeBody),
    ).toBe(true);
    await expect(choice(page, "Light")).toHaveAttribute("aria-pressed", "true");
  });
});
