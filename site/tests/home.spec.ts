import { test, expect } from "@playwright/test";

test.describe("home head", () => {
  test("has title, description and og:image", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveTitle(/antgrid/i);
    const desc = page.locator('meta[name="description"]');
    await expect(desc).toHaveAttribute("content", /end-to-end encrypted/i);
    const og = page.locator('meta[property="og:image"]');
    await expect(og).toHaveAttribute("content", /while-you-slept\.png/);
  });
});

test("hero headline, E2E clause and CTAs", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(/stop babysitting your coding agents/i);
  await expect(page.locator("section").first()).toContainText("End-to-end encrypted");
  await expect(page.getByRole("link", { name: /^Start free/ }).last()).toHaveAttribute("href", /app\.antgrid\.ai\/login/);
  await expect(page.getByText("woke you", { exact: false }).first()).toBeVisible();
});

test("fleet groups by machine and floats needs-you", async ({ page }) => {
  await page.goto("/#fleet");
  const fleet = page.locator("#fleet");
  await expect(fleet.getByRole("heading", { name: /every agent\. every machine\. one screen\./i })).toBeVisible();
  await expect(fleet).toContainText("studio-workstation");
  await expect(fleet).toContainText("Needs you — which migration strategy?");
});

test("privacy shows relay's-eye view and crypto chips", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: /the relay can't read a byte\./i })).toBeVisible();
  await expect(page.getByText("What the relay sees")).toBeVisible();
  await expect(page.getByText("AES-256-GCM")).toBeVisible();
});

test("cross-agent shows agents and the 3 steps", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: /bring the agent you already use\./i })).toBeVisible();
  await expect(page.getByText("any terminal agent")).toBeVisible();
  await expect(page.getByText("Windows, macOS, Linux")).toBeVisible();
  await expect(page.getByText("Take it with you")).toBeVisible();
});

test("closing CTA: Start free, direct downloads, store chips, correct pricing copy", async ({ page }) => {
  await page.goto("/#download");
  const band = page.locator("#download");
  await expect(band).toContainText("Free on 2 machines");
  await expect(band.getByRole("link", { name: /^Start free/ })).toHaveAttribute("href", /app\.antgrid\.ai\/login/);
  await expect(band.getByRole("link", { name: /download for macos/i })).toHaveAttribute(
    "href",
    "https://github.com/Radha-AI-Products/antgrid-releases/releases/latest/download/antgrid-macos.dmg"
  );
  await expect(band.getByRole("link", { name: /download for windows/i })).toHaveAttribute(
    "href",
    "https://get.microsoft.com/installer/download/9N0P7ZRL4D9W?referrer=appbadge&cid=site"
  );
  await expect(band.getByRole("link", { name: /download for linux/i })).toHaveAttribute(
    "href",
    "https://github.com/Radha-AI-Products/antgrid-releases/releases/latest/download/antgrid-linux.AppImage"
  );
  await expect(band.getByText("Microsoft Store")).toHaveCount(0);
  await expect(band.getByText("soon").first()).toBeVisible();
});

test("no horizontal overflow on mobile", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
  expect(overflow).toBe(false);
});

test("internal links resolve (no dangling hrefs to missing pages)", async ({ page }) => {
  const removedPages = ["/docs", "/security"];

  for (const startPath of ["/", "/pricing"]) {
    await page.goto(startPath);
    const hrefs = await page.locator("a[href^='/']").evaluateAll((els) =>
      [...new Set(els.map((e) => (e as HTMLAnchorElement).getAttribute("href")!))].filter((h) => !h.startsWith("/#"))
    );

    // Confirm removed stub pages are not linked from either page.
    for (const removed of removedPages) {
      expect(hrefs, `${startPath} must not link to removed page ${removed}`).not.toContain(removed);
    }

    // All remaining internal links must resolve.
    for (const href of hrefs) {
      const res = await page.request.get(href);
      expect(res.status(), `dead link on ${startPath}: ${href}`).toBeLessThan(400);
    }
  }
});
