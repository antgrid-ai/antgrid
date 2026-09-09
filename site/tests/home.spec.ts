import { test, expect } from "@playwright/test";

// Behaviour only. What the page SAYS — the hero's claim, the fleet mock-up, the
// agent roster, the closing band's copy — has no test here and deliberately none
// anywhere: an assertion that restates the copy only ever reports that the copy
// changed, which git already does, and it fails the release for a word.
//
// What survives is what a reader DOES on the page: it holds its width, and every
// link on it goes somewhere. Where a link goes is pinned in contracts.spec.ts.

test("no horizontal overflow on mobile", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
  expect(overflow).toBe(false);
});

// Anchor hrefs are skipped because a fragment is never sent over HTTP; the ids
// they name are pinned in contracts.spec.ts instead. Everything else is fetched
// for real — which since the download route became a path rather than /#download
// now includes /download and each of its ?platform= links, from all three start
// pages. No filter change was needed for that: they are ordinary "/" hrefs and
// the query is inert to a static server. It is the first time a build of the
// site has proved that its own download URL resolves.
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
