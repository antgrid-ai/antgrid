import { test, expect } from "@playwright/test";

// Page-level structure, the positioning claims the product is sold on, and page health.
// Marketing wording is deliberately NOT asserted: it changes constantly, and a test that
// restates the copy only ever reports that the copy changed — which git already does.
// Anything whose failure costs money or traffic lives in contracts.spec.ts.

test.describe("home head", () => {
  test("has title, description and an absolute og:image", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveTitle(/antgrid/i);
    const desc = page.locator('meta[name="description"]');
    await expect(desc).toHaveAttribute("content", /end-to-end encrypted/i);
    // Absolute URL rather than a specific filename — social scrapers reject a relative
    // og:image, and the artwork is expected to be re-cut without touching this test.
    const og = page.locator('meta[property="og:image"]');
    await expect(og).toHaveAttribute("content", /^https?:\/\/.+\.(png|jpe?g|webp)$/);
  });
});

test("hero has a single non-empty h1 and leads with the E2E claim", async ({ page }) => {
  await page.goto("/");
  const h1 = page.getByRole("heading", { level: 1 });
  await expect(h1).toHaveCount(1);
  expect((await h1.innerText()).trim().length).toBeGreaterThan(0);
  await expect(page.locator("section").first()).toContainText("End-to-end encrypted");
});

test("fleet groups by machine and floats needs-you", async ({ page }) => {
  await page.goto("/#fleet");
  const fleet = page.locator("#fleet");
  await expect(fleet.getByRole("heading", { name: /never below the fold\./i })).toBeVisible();
  await expect(fleet).toContainText("studio-workstation");
  await expect(fleet).toContainText("Needs you — which migration strategy?");
});

test("privacy shows relay's-eye view and crypto chips", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: /the relay can't read a byte\./i })).toBeVisible();
  await expect(page.getByText("What the relay sees")).toBeVisible();
  await expect(page.getByText("AES-256-GCM")).toBeVisible();
});

// The roster lives in #agents now, not in the cross-agent band — asserting the
// chip from an unscoped page locator kept this test green off the OTHER section.
test("cross-agent shows the 3 steps", async ({ page }) => {
  await page.goto("/");
  const section = page.locator("section").filter({ hasText: "Bring the agent you already use." });
  await expect(section.getByRole("heading", { name: /bring the agent you already use\./i })).toBeVisible();
  await expect(section.getByText("Windows, macOS, Linux")).toBeVisible();
  await expect(section.getByText("Take it with you")).toBeVisible();
});

// The only wording assertion in this file, and it is not marketing copy: the
// supervised three are whatever `handlerObservable` answers true for in
// bridge/src/agents/registry.ts, so a fourth chip going accent — or the prose
// falling out of step with the chips — is a false capability claim, not a
// rewrite. The catch-all chip is the free-tier promise beside it.
test("the agent roster names the supervised three and a catch-all", async ({ page }) => {
  await page.goto("/#agents");
  const agents = page.locator("#agents");
  for (const name of ["Claude Code", "Codex", "opencode"]) {
    await expect(agents.getByText(name, { exact: true })).toHaveCount(2);
  }
  await expect(agents.getByText("any terminal agent")).toBeVisible();
});

test("closing CTA band renders with app stores still pending", async ({ page }) => {
  await page.goto("/#download");
  const band = page.locator("#download");
  await expect(band).toBeVisible();
  await expect(band.getByText("soon").first()).toBeVisible();
});

test("no horizontal overflow on mobile", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
  expect(overflow).toBe(false);
});

test("internal links resolve (no dangling hrefs to missing pages)", async ({ page }) => {
  const removedPages = ["/docs"];

  for (const startPath of ["/", "/pricing", "/get-started"]) {
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
