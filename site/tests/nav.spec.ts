import { test, expect } from "@playwright/test";

// Where the header's controls go, and the one control that has behaviour. Names
// appear here only as locators — the way a reader finds the control — never as
// the thing under assertion.

// A path, not the home page's #download band. A fragment never reaches a server
// (RFC 9112 §3.2.1), so as /#download the site's most-clicked control had no
// address anything could log, index or link to — and from any page other than
// "/" it was a full document load that then scrolled, which is what the band's
// own tests were measuring instead of this.
test("desktop nav CTA routes to the download page", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/");
  const cta = page.locator("header nav").getByRole("link", { name: "Download free" });
  await expect(cta).toHaveAttribute("href", "/download");
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

// Nav.astro closes the drawer from a click listener on #navMenu itself. Nothing
// in the drawer is a same-page anchor any more — the CTA was the last one, and
// it is a path now — so every item leaves the page and a fresh document renders
// a fresh, closed drawer regardless. Clicking and then asserting on the page
// that arrives therefore proves NOTHING about the handler: it passes just as
// green with the listener deleted.
//
// What the handler still buys is the interval between the tap and that document
// arriving, which on a phone is the entire visible response to the tap: without
// it the drawer sits over the old page for the whole of a cold navigation, and
// the reader taps again. So the navigation is cancelled here rather than waited
// on. preventDefault in a CAPTURE-phase listener on the document runs before the
// bubble-phase listener on #navMenu and does not stop propagation, so the real
// handler still receives the click — only the browser's default action is lost.
test("the mobile menu closes on the tap itself, not on the page that follows", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await page.goto("/");
  const menu = page.locator("#navMenu");
  await page.locator("#navToggle").click();
  await expect(menu).toBeVisible();

  await page.evaluate(() => document.addEventListener("click", (e) => e.preventDefault(), true));
  await menu.getByRole("link", { name: "Download free" }).click();

  // Still the document the tap happened on — if this navigated, the assertion
  // below is measuring a brand new drawer and this test is hollow again.
  expect(new URL(page.url()).pathname, "the navigation was not cancelled").toBe("/");
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

test("the nav marks the page the reader is on, and never more than one", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/pricing");
  const nav = page.locator("header nav");
  await expect(nav.getByRole("link", { name: "Pricing" })).toHaveAttribute("aria-current", "page");
  // And only ever one. Two marks is the failure a reader is actually misled by:
  // a screen reader announces both as the current page and neither is trusted
  // again.
  await expect(nav.locator("[aria-current='page']")).toHaveCount(1);

  // /download is a location the reader can now BE at — Nav.astro's isCurrent
  // skips any href containing "#", which is what excluded the CTA for as long as
  // it was /#download, and links.startFree is a plain path now. It still comes
  // out unmarked, because Nav.astro passes aria-current to the navItems loop and
  // never to the <Button>. That is a gap rather than a contract, so it is not
  // asserted as correct here — what IS asserted is the invariant that survives
  // either answer: this page must never end up claiming two current locations.
  await page.goto("/download");
  expect(
    await nav.locator("[aria-current='page']").count(),
    "the nav marks more than one current page on /download"
  ).toBeLessThanOrEqual(1);
});
