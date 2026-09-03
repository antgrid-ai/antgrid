import { test, expect } from "@playwright/test";

// Where the header's controls go, and the one control that has behaviour. Names
// appear here only as locators — the way a reader finds the control — never as
// the thing under assertion.

test("desktop nav CTA routes to the download band", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/");
  const cta = page.locator("header nav").getByRole("link", { name: "Download free" });
  await expect(cta).toHaveAttribute("href", "/#download");
});

test("desktop nav routes to the repository", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/");
  // Scoped to the nav because the footer offers this too, and matched by
  // accessible name because the item is the bare octocat — the aria-label IS the
  // name. Drop the label and the link is unnamed to a screen reader with nothing
  // else on the page turning red.
  const github = page.locator("header nav").getByRole("link", { name: /github/i });
  await expect(github).toHaveAttribute("href", /github\.com/);
});

test("mobile menu toggles open", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await page.goto("/");
  const menu = page.locator("#navMenu");
  const toggle = page.locator("#navToggle");
  await expect(menu).toBeHidden();
  await toggle.click();
  await expect(menu).toBeVisible();
  // The control describes itself to a screen reader as it goes; state that
  // stops moving with the drawer offers "Open menu" on an open menu.
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
  await toggle.click();
  await expect(menu).toBeHidden();
});

test("mobile menu closes when a link in it is followed", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await page.goto("/");
  const menu = page.locator("#navMenu");
  await page.locator("#navToggle").click();
  // A same-page anchor navigates without a reload, so nothing else tears the
  // drawer down — left open, it sits over the section just asked for. The CTA is
  // the one item in the drawer that does this; the rest leave the page.
  await menu.getByRole("link", { name: "Download free" }).click();
  await expect(menu).toBeHidden();
});

test("Escape closes the mobile menu", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await page.goto("/");
  const menu = page.locator("#navMenu");
  await page.locator("#navToggle").click();
  await page.keyboard.press("Escape");
  await expect(menu).toBeHidden();
  // Focus returns to the control that opened it, or a keyboard reader is left
  // at the top of the document with no idea where they are.
  await expect(page.locator("#navToggle")).toBeFocused();
});

test("the nav marks the page the reader is on", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/pricing");
  const nav = page.locator("header nav");
  await expect(nav.getByRole("link", { name: "Pricing" })).toHaveAttribute("aria-current", "page");
  // And only ever one — the CTA and the repo are not locations the reader can
  // be at.
  await expect(nav.locator("[aria-current='page']")).toHaveCount(1);
});
