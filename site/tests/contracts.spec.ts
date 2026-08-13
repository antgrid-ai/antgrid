import { test, expect } from "@playwright/test";

// Release contracts: the assertions whose failure costs money or traffic — download
// targets, the sign-in CTA, and the closed paid path. They live apart from the page
// tests on purpose. Playwright aborts a test at its first failed expect, so a brittle
// copy assertion sharing a test body with these would stop them ever running; that is
// exactly how the download URLs went unverified while the suite sat red.
//
// Nothing here may assert marketing wording. Assert targets, counts and states only.

const DOWNLOADS = {
  macos: "https://github.com/antgrid-ai/antgrid-releases/releases/latest/download/antgrid-macos.dmg",
  windows: "https://get.microsoft.com/installer/download/9N0P7ZRL4D9W?referrer=appbadge&cid=site",
  linux: "https://github.com/antgrid-ai/antgrid-releases/releases/latest/download/antgrid-linux.AppImage",
};

test("desktop downloads point at the published release artifacts", async ({ page }) => {
  await page.goto("/#download");
  const band = page.locator("#download");
  await expect(band.getByRole("link", { name: /download for macos/i })).toHaveAttribute("href", DOWNLOADS.macos);
  await expect(band.getByRole("link", { name: /download for windows/i })).toHaveAttribute("href", DOWNLOADS.windows);
  await expect(band.getByRole("link", { name: /download for linux/i })).toHaveAttribute("href", DOWNLOADS.linux);

  // Windows ships as a live Store installer link, so it must not also appear among the
  // "coming soon" store chips — that pairing tells visitors it is unavailable.
  await expect(band.getByText("Microsoft Store")).toHaveCount(0);
});

test("Start free routes to the download band on both pages", async ({ page }) => {
  for (const path of ["/", "/pricing"]) {
    await page.goto(path);
    const ctas = page.getByRole("link", { name: /^Start free/ });
    expect(await ctas.count(), `${path} must offer a Start free CTA`).toBeGreaterThan(0);
    for (let i = 0; i < (await ctas.count()); i++) {
      await expect(ctas.nth(i)).toHaveAttribute("href", "/#download");
    }
  }
});

test("Sign in stays wired to app login", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("link", { name: "Sign in" }).first()).toHaveAttribute(
    "href",
    /app\.antgrid\.ai\/login/
  );
});

test("get-started download links point at the published release artifacts", async ({ page }) => {
  await page.goto("/get-started");
  await expect(page.getByRole("link", { name: /download for windows/i })).toHaveAttribute("href", DOWNLOADS.windows);
  await expect(page.getByRole("link", { name: /download the \.dmg/i })).toHaveAttribute("href", DOWNLOADS.macos);
  await expect(page.getByRole("link", { name: /download the appimage/i })).toHaveAttribute("href", DOWNLOADS.linux);
});

test("the paid path stays closed: no checkout links anywhere", async ({ page }) => {
  for (const path of ["/", "/pricing"]) {
    await page.goto(path);
    await expect(page.locator('a[href*="checkout"]'), `live checkout link on ${path}`).toHaveCount(0);
  }
});

test("charging plans render a disabled button, never a live CTA", async ({ page }) => {
  await page.goto("/pricing");

  // Any card carrying `comingSoon` (pricing.ts) must swap its checkout link for a
  // disabled button. Asserted by state, not by label — the label is BETA_FREE-gated.
  const yearlyCard = page.locator("span.font-mono", { hasText: /^Pro Yearly$/ }).locator("..").locator("..");
  await expect(yearlyCard.locator("button[disabled]")).toHaveCount(1);
  await expect(yearlyCard.locator("a[href]")).toHaveCount(0);

  // The free card is the one plan whose CTA stays live.
  const freeCard = page.locator("span.font-mono", { hasText: /^Free$/ }).locator("..").locator("..");
  await expect(freeCard.getByRole("link", { name: /^Start free/ })).toHaveCount(1);
});

// /privacy is excluded on purpose — it says "lifetime of the session", not a plan.
for (const path of ["/pricing", "/terms", "/refunds", "/support"]) {
  test(`lifetime is not offered on ${path}`, async ({ page }) => {
    // There is no lifetime plan and no one-time-payment path. The word reappearing
    // on a legal or marketing page promises terms nothing can honour.
    await page.goto(path);
    await expect(page.locator("body")).not.toContainText(/lifetime/i);
  });
}
