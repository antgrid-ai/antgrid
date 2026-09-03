import { test, expect } from "@playwright/test";

// Release contracts: the assertions whose failure costs money or traffic — download
// targets, the sign-in CTA, and the closed paid path. They live apart from the page
// tests on purpose. Playwright aborts a test at its first failed expect, so a brittle
// copy assertion sharing a test body with these would stop them ever running; that is
// exactly how the download URLs went unverified while the suite sat red.
//
// Nothing here may assert marketing wording. Assert targets, counts and states only —
// a rule the whole suite now follows, not just this file: what a control DOES, where a
// link GOES, whether a resource RESOLVES, and the directives machines act on. Copy,
// prices and headings are checked by reading the page, not by a second copy of them.

const DOWNLOADS = {
  macos: "https://github.com/antgrid-ai/antgrid/releases/latest/download/antgrid-macos.dmg",
  windows: "https://get.microsoft.com/installer/download/9N0P7ZRL4D9W?referrer=appbadge&cid=site",
  linux: "https://github.com/antgrid-ai/antgrid/releases/latest/download/antgrid-linux.AppImage",
};

// The web service, which is a different origin from this static build.
const WAITLIST_ORIGIN = "https://app.antgrid.ai";

// The band routes through the confirmation page like the hero, so what it must
// guarantee is that every build is still REACHABLE from it and every route names
// a platform that page has a URL for. A typo'd id renders and resolves and
// downloads nothing; the artifact URLs themselves are pinned by the fire test
// below, which is the other half of this chain.
test("the download band still reaches every build, by a route that downloads", async ({ page }) => {
  await page.goto("/#download");
  const band = page.locator("#download");
  const hrefs = await band.locator("a[href^='/download/started']").evaluateAll((els) =>
    [...new Set(els.map((e) => (e as HTMLAnchorElement).getAttribute("href")!))]
  );
  expect(
    hrefs.map((h) => new URL(h, "https://antgrid.ai").searchParams.get("platform")).sort(),
    "the download band no longer offers every build"
  ).toEqual(Object.keys(DOWNLOADS).sort());

  // The band leads with the same data-os reveal as the hero, so it inherits the
  // same silent failure: a broken rule shows three stacked buttons, a broken
  // reveal shows none, and both look like a styling slip rather than a lost sale.
  await expect(band.locator("a.dl-os:visible")).toHaveCount(1);
});

// The home hero leads with the OS-matched download now, not this label, so the
// count requirement is pinned to /pricing rather than to every page: that is
// where a reader decides, and the free plan's CTA is the one live exit from the
// closed paid path. Requiring one on "/" as well is what this asserted before,
// and it was satisfied only by the nav — which is display:none at mobile width,
// so the guarantee was already narrower than it read.
//
// Both labels, because the nav says "Download free" and the free plan's card says
// "Start free" — deliberately different wording for the same destination, so a
// sweep that knows only one of them silently stops covering the other.
test("the free CTAs route to the download band wherever they appear", async ({ page }) => {
  for (const path of ["/", "/pricing"]) {
    await page.goto(path);
    const ctas = page.getByRole("link", { name: /^(Start|Download) free/ });
    for (let i = 0; i < (await ctas.count()); i++) {
      await expect(ctas.nth(i)).toHaveAttribute("href", "/#download");
    }
  }
  await page.goto("/pricing");
  const priced = page.getByRole("link", { name: /^Start free/ });
  expect(await priced.count(), "/pricing must offer a Start free CTA").toBeGreaterThan(0);
});

// Scoped to the footer, which is now the only place it is offered — unscoped,
// this would have gone on passing off the nav's copy after the nav dropped it.
test("Sign in stays wired to app login", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("footer").getByRole("link", { name: "Sign in" })).toHaveAttribute(
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

// The hero's primary CTA is three buttons with two hidden in CSS (global.css,
// keyed on the data-os Base.astro sets before paint). Both ways it can break are
// silent and both cost every download taken from the fold: a broken reveal rule
// shows none, a missing hide rule shows three stacked. Asserted by count and
// visibility rather than by which OS won, so it holds on whatever machine runs
// the suite — and the href is derived from data-os for the same reason.
test("the hero offers exactly one download button, matched to the reader's OS", async ({ page }) => {
  await page.goto("/");
  const hero = page.locator("section").first();
  await expect(hero.locator("a.dl-os")).toHaveCount(3);
  const shown = hero.locator("a.dl-os:visible");
  await expect(shown).toHaveCount(1);

  const os = await page.evaluate(() => document.documentElement.dataset.os);
  const platform = { mac: "macos", linux: "linux", win: "windows" }[os ?? "win"];
  // The query is the whole mechanism: lose it and the button silently demotes
  // itself to "look at a thank-you page", with nothing downloading and the page
  // still rendering perfectly.
  await expect(shown).toHaveAttribute("href", `/download/started?platform=${platform}`);
});

// The only reason the hero routes through a page instead of straight at the
// artifact is that the download starts anyway. If this script stops firing, every
// download taken from the fold is lost — page renders, link resolves, suite green.
test("arriving at the confirmation page with a platform starts that download", async ({ page }) => {
  for (const [platform, url] of Object.entries(DOWNLOADS)) {
    // Stubbed at the first hop rather than fetched: proving the download starts
    // must not pull three real installers over the network on every run. It is
    // answered as an attachment because that is what the live URLs answer with,
    // and it is the only thing making this a download rather than the reader
    // being navigated off the page — so the stub has to keep that property or
    // the test stops covering the case that would actually break.
    const matches = (u: URL) => u.href === url;
    await page.route(matches, (route) =>
      route.fulfill({ status: 200, headers: { "content-disposition": "attachment" }, body: "stub" })
    );
    const started = page.waitForEvent("download");

    await page.goto(`/download/started?platform=${platform}`);
    expect((await started).url(), `${platform} downloaded the wrong artifact`).toBe(url);
    // The panel that names the artifact and carries the manual retry — the only
    // thing standing between a blocked download and a reader sitting on a page
    // that insists it worked.
    await expect(page.locator(`.dl-note-${platform}`)).toBeVisible();
    await expect(page.locator(".dl-idle").first()).toBeHidden();
    // The parameter is spent. Left in the address bar, a reload or a Back onto
    // this entry fetches a second copy of the installer.
    expect(new URL(page.url()).searchParams.get("platform"), `${platform} left its parameter behind`).toBeNull();

    await page.unroute(matches);
  }
});

// The guard on that script is the whole safety property. Broken, every arrival
// without a platform — a shared link, a trimmed URL, a crawl — becomes an
// unrequested .exe, which is both a trust failure and the fastest way to get a
// domain flagged. An unknown platform must be as inert as no platform, and both
// must leave a reader something that works: the pick-a-build state.
test("the confirmation page downloads nothing it was not asked for", async ({ page }) => {
  const fired: string[] = [];
  for (const url of Object.values(DOWNLOADS)) {
    await page.route(
      (u) => u.href === url,
      (route) => {
        fired.push(route.request().url());
        return route.fulfill({ status: 200, headers: { "content-disposition": "attachment" }, body: "stub" });
      }
    );
  }

  for (const path of ["/download/started", "/download/started?platform=solaris"]) {
    await page.goto(path);
    // The script waits for load and then a beat, so an assertion made straight
    // after goto() would pass even with the guard removed.
    await page.waitForTimeout(1200);
    await expect(page.locator(".dl-idle").first(), `${path} offers no way to download`).toBeVisible();
    await expect(page.locator(".dl-note:visible"), `${path} claims a download started`).toHaveCount(0);
  }

  expect(fired, "the confirmation page downloaded without being asked").toEqual([]);
});

// The cards on the confirmation page are the reader's whole route out of it, and
// they deep-link INTO the guide. The dead-link sweep in home.spec.ts resolves
// links over HTTP, where a fragment is never sent, so a renamed step heading
// strands every fresh downloader at the top of the guide with the suite green.
test("every step on the confirmation page lands on a step of the setup guide", async ({ page }) => {
  await page.goto("/download/started");
  const hrefs = await page.locator("ol a[href^='/get-started#']").evaluateAll((els) =>
    els.map((e) => (e as HTMLAnchorElement).getAttribute("href")!)
  );
  expect(hrefs.length, "the confirmation page offers no next steps at all").toBe(3);

  await page.goto("/get-started");
  for (const href of hrefs) {
    const id = href.split("#")[1];
    await expect(page.locator(`#${id}`), `nothing on the setup guide has id="${id}"`).toHaveCount(1);
  }
});

// A thank-you page for a download nobody started is the worst thing this could
// rank for, and it is one deleted attribute away at all times.
test("the confirmation page is kept out of the index", async ({ page }) => {
  await page.goto("/download/started");
  await expect(page.locator('meta[name="robots"]')).toHaveAttribute("content", /noindex/);
});

test("the paid path stays closed: no checkout links anywhere", async ({ page }) => {
  for (const path of ["/", "/pricing"]) {
    await page.goto(path);
    await expect(page.locator('a[href*="checkout"]'), `live checkout link on ${path}`).toHaveCount(0);
  }
});

test("charging plans capture interest, never a live checkout CTA", async ({ page }) => {
  await page.goto("/pricing");

  // Any card carrying `comingSoon` (pricing.ts) must swap its checkout link for the
  // founding-price capture. Asserted by state, not by label — copy is BETA_FREE-gated.
  const yearlyCard = page.locator("span.font-mono", { hasText: /^Pro$/ }).locator("..").locator("..");
  const capture = yearlyCard.locator("form[data-waitlist]");
  await expect(capture).toHaveCount(1);
  // The address goes to the web service, cross-origin from this static site.
  await expect(capture).toHaveAttribute("action", `${WAITLIST_ORIGIN}/api/waitlist`);
  await expect(capture).toHaveAttribute("data-waitlist", "pricing");
  await expect(yearlyCard.locator("a[href]")).toHaveCount(0);
  // The capture ships disabled so a scriptless reader is told to email instead; once
  // the page's script has run nothing in the card may still be inert, or the dead
  // paid CTA is back under a new name.
  await expect(yearlyCard.locator("button[disabled]")).toHaveCount(0);

  // The free card is the one plan whose CTA stays live.
  const freeCard = page.locator("span.font-mono", { hasText: /^Free$/ }).locator("..").locator("..");
  await expect(freeCard.getByRole("link", { name: /^Start free/ })).toHaveCount(1);
});

// The filename tracks what the card SAYS (Seo.astro), so a recut renames it —
// and the rename is a string in Seo.astro that nothing else checks. Get it wrong
// and og:image 404s: every shared link loses its preview, on every page at once,
// with the site otherwise green. Assert the file, never the name.
test("the social card the meta tag names is actually in the build", async ({ page }) => {
  await page.goto("/");
  const src = await page.locator('meta[property="og:image"]').getAttribute("content");
  const res = await page.request.get(new URL(src!).pathname);
  expect(res.status(), `og:image is missing from the build: ${src}`).toBe(200);
});

// Every in-page anchor the site links to must exist. home.spec.ts's dead-link
// sweep skips "/#..." hrefs — it resolves them over HTTP, where the fragment is
// never sent — so a renamed section id breaks navigation with nothing red. These
// are the only links on the site that can rot silently.
test("every in-page anchor the nav and footer offer has a section to land on", async ({ page }) => {
  await page.goto("/");
  const fragments = await page.locator("a[href^='/#'], a[href^='#']").evaluateAll((els) =>
    [...new Set(els.map((e) => (e as HTMLAnchorElement).getAttribute("href")!.split("#")[1]))]
  );
  expect(fragments.length, "the home page offers no in-page anchors at all").toBeGreaterThan(0);
  for (const id of fragments) {
    await expect(page.locator(`#${id}`), `nothing on the page has id="${id}"`).toHaveCount(1);
  }
});

// Features has to open on the paid feature. Handler is the only thing anyone pays
// for and its section sits ABOVE the fleet view, so aiming this at #fleet scrolled
// the reader straight past it — a revenue link that resolved fine and pointed at
// the wrong thing, which is why it is pinned by target here rather than by wording.
test("Features opens the section that sells Handler", async ({ page }) => {
  await page.goto("/");
  const features = page.getByRole("link", { name: /^Features$/ });
  expect(await features.count(), "no Features link").toBeGreaterThan(0);
  for (let i = 0; i < (await features.count()); i++) {
    await expect(features.nth(i)).toHaveAttribute("href", "/#handler");
  }
});

// The 404 template answers EVERY unknown path, so without this a mistyped inbound
// link can be indexed under its own URL as a page that says nothing exists.
test("the not-found page is kept out of the index", async ({ page }) => {
  await page.goto("/404");
  await expect(page.locator('meta[name="robots"]')).toHaveAttribute("content", /noindex/);

  // Real pages must NOT inherit it — a stray default here delists the whole site.
  await page.goto("/");
  await expect(page.locator('meta[name="robots"]')).toHaveCount(0);
});
