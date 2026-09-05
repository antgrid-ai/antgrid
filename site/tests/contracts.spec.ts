import { test, expect, type Page } from "@playwright/test";

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

// The raw artifacts — what a click has to actually FETCH. These are what the
// download page fires, and the only thing that counts as a download starting.
const DOWNLOADS = {
  macos: "https://github.com/antgrid-ai/antgrid/releases/latest/download/antgrid-macos.dmg",
  windows: "https://get.microsoft.com/installer/download/9N0P7ZRL4D9W?referrer=appbadge&cid=site",
  linux: "https://github.com/antgrid-ai/antgrid/releases/latest/download/antgrid-linux.AppImage",
};

// The Microsoft Store's web LISTING, which is a different thing from the stub
// installer in DOWNLOADS.windows and is not interchangeable with it — see the
// all-builds test below for the measured reason.
const STORE_LISTING = "https://apps.microsoft.com/detail/9N0P7ZRL4D9W";

// What each build is OFFERED as to a reader who is not on that OS: a link they
// can click, mail themselves, or open on another machine. Only Windows differs
// from its artifact URL.
const OFFERED = {
  windows: STORE_LISTING,
  macos: DOWNLOADS.macos,
  linux: DOWNLOADS.linux,
};

const MOBILE_INVITE = "mailto:contact@radhaai.com?subject=Antgrid%20mobile%20invite";

// The web service, which is a different origin from this static build.
const WAITLIST_ORIGIN = "https://app.antgrid.ai";

// Which build this machine is offered, read from the page rather than from the
// runner: Base.astro sets data-os from the UA before paint, and Playwright's
// `mobile` project is a Pixel 7 whose UA carries both "Linux" and "Android" —
// which that script deliberately resolves to "win". Hardcoding an expectation
// here would pin the suite to whichever machine last ran it.
const readerPlatform = async (page: Page): Promise<keyof typeof DOWNLOADS> => {
  const os = await page.evaluate(() => document.documentElement.dataset.os);
  const byOs: Record<string, keyof typeof DOWNLOADS> = { mac: "macos", linux: "linux", win: "windows" };
  // Windows is the fallback here because it is the fallback in Base.astro too —
  // a reader whose script never ran carries no data-os and is shown the Windows
  // build, so a test that guessed differently would be testing a page nobody has.
  return byOs[os ?? "win"] ?? "windows";
};

// The OTHER axis Base.astro publishes, and the reason data-os alone cannot gate a
// download: data-os answers which build to OFFER, so it files Android under "win"
// and iPhone under "mac" on purpose. A phone therefore never looks like a
// mismatch — it looks like a match — and the firing tests have to tell the two
// apart from the page, exactly as the page's own script does.
const isPhone = (page: Page) => page.evaluate(() => document.documentElement.dataset.form === "mobile");

// Every URL the download page could possibly send a reader to, stubbed so a run
// never pulls a real installer — or a real Store page — over the network. The
// handler records what was asked for, which is how "downloaded nothing" is
// proved rather than assumed.
const watchDownloads = async (page: Page, fired: string[]) => {
  for (const url of [...Object.values(DOWNLOADS), STORE_LISTING]) {
    await page.route(
      (u) => u.href === url,
      (route) => {
        fired.push(route.request().url());
        // Answered as an attachment because that is what the live artifact URLs
        // answer with, and it is the only thing making this a download rather
        // than the reader being navigated off the page — so the stub has to keep
        // that property or the test stops covering the case that would break.
        return route.fulfill({ status: 200, headers: { "content-disposition": "attachment" }, body: "stub" });
      }
    );
  }
};

// The band routes through the download page like the hero, so what it must
// guarantee is that every build is still REACHABLE from it and every route names
// a platform that page has a URL for. A typo'd id renders and resolves and
// downloads nothing; the artifact URLs themselves are pinned by the fire test
// below, which is the other half of this chain.
//
// Matched on the query rather than on the path prefix: /download is now also the
// bare address of the download page itself (the nav CTA and the footer both
// point at it), and a prefix selector would count those as builds on offer.
test("the download band still reaches every build, by a route that downloads", async ({ page }) => {
  await page.goto("/#download");
  const band = page.locator("#download");
  const hrefs = await band.locator("a[href^='/download?platform=']").evaluateAll((els) =>
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
//
// The destination is a PATH now, not the home page's #download band. A fragment
// never reaches a server (RFC 9112 §3.2.1), so as /#download neither of these
// CTAs was addressable, loggable or indexable; they are the site's two loudest
// download controls and both were pointing at something no analytics tool could
// see. The band still exists — this is where it stopped being the address.
test("the free CTAs route to the download page wherever they appear", async ({ page }) => {
  for (const path of ["/", "/pricing"]) {
    await page.goto(path);
    const ctas = page.getByRole("link", { name: /^(Start|Download) free/ });
    for (let i = 0; i < (await ctas.count()); i++) {
      await expect(ctas.nth(i)).toHaveAttribute("href", "/download");
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

  const platform = await readerPlatform(page);
  // The query is the whole mechanism: lose it and the button silently demotes
  // itself to "look at the download page", with nothing downloading and the page
  // still rendering perfectly. The hero routes through the page rather than
  // straight at the artifact on purpose — /download is where the reader is told
  // what just landed and what to do with it.
  await expect(shown).toHaveAttribute("href", `/download?platform=${platform}`);
});

// /download is the site's one addressable download URL: the nav CTA, the free
// plan's CTA, the footer and every ?platform= link resolve to it. It used to be
// /download/started, a noindex thank-you page nobody could link to; a page that
// 404s or that quietly keeps the old noindex costs every download the site has
// plus the "antgrid download" search that should land on it.
//
// The page-specific assertion comes FIRST, and that ordering is the point. The
// 404 template answers every unknown path and carries its own noindex, so a
// robots assertion made against a moved page passes green while the reader gets
// nothing — which is exactly how this test survived the move it was written for.
// `a.dl-os` exists on this page, the home page and nowhere else; a 404 has none.
test("/download resolves at its own address and is indexable", async ({ page }) => {
  const res = await page.goto("/download");
  expect(res?.status(), "/download does not resolve").toBe(200);
  await expect(page.locator("a.dl-os"), "this is not the download page").toHaveCount(3);

  await expect(page.locator('meta[name="robots"]'), "/download is delisted").toHaveCount(0);
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute("href", "https://antgrid.ai/download");
  // The one string here that is read by a machine rather than by a reader: it is
  // the search result's heading. Anchored at the start so the tail stays free.
  await expect(page).toHaveTitle(/^Download antgrid/);
});

// The idle page — no ?platform=, which is how every shared link, trimmed URL and
// crawl arrives. It must offer all three builds, and it must offer Windows as
// the Store LISTING rather than as the stub installer in DOWNLOADS.windows.
//
// That distinction is the whole test, and it is measured, not stylistic:
// get.microsoft.com/installer/download/<product> answers
// `Content-Disposition: attachment` to EVERY user agent — no sniffing, no
// redirect — so a Mac, a phone or a Linux box that follows it receives an 815KB
// Windows .exe it cannot run. apps.microsoft.com/detail/<product> is an ordinary
// web page everywhere and still launches the Store app on Windows, which is also
// what survives a reader mailing the link to the machine they actually want it
// on. Collapsing the two back into one URL "for simplicity" is silent: the link
// resolves, the file arrives, and only the reader knows it was junk.
test("the download page offers every build, and Windows as a listing not a stub", async ({ page }) => {
  await page.goto("/download");

  // The same data-os reveal the hero and the band use, with one difference that
  // matters: this button points STRAIGHT at the artifact rather than back at
  // ?platform=. A reader who is already here has nothing left to be told, and a
  // real click is a user gesture — which is what Chrome's download protection
  // wants before it will trust a cross-origin attachment, and what the script's
  // automatic fire does not have. Pointed back at ?platform= it would also be a
  // link from this page to this page, which is a reload, not a download.
  const shown = page.locator("a.dl-os:visible");
  await expect(shown).toHaveCount(1);
  await expect(shown).toHaveAttribute("href", DOWNLOADS[await readerPlatform(page)]);

  // Everything that is not the OS-matched button and not inside a per-platform
  // note panel — i.e. the all-builds list, which is the only place a reader who
  // is not on this OS can name their own build. Filtered by href rather than by
  // container so a re-layout of the page cannot quietly empty this out.
  const offered = await page.locator("a[href]").evaluateAll((els) =>
    els
      .filter((e) => !e.classList.contains("dl-os") && !e.closest(".dl-note"))
      .map((e) => (e as HTMLAnchorElement).getAttribute("href")!)
  );
  const builds = [...new Set(offered.filter((h) => h.includes("microsoft.com") || h.includes("/releases/latest/")))];
  expect(builds.sort(), "the all-builds list no longer offers exactly the three builds").toEqual(
    Object.values(OFFERED).sort()
  );

  // The mobile half of the product. Invites are open, so a download page that
  // says nothing about the phone tells a reader the half it is FOR does not
  // exist yet.
  expect(
    await page.locator(`a[href="${MOBILE_INVITE}"]`).count(),
    "the download page stopped offering the mobile invite"
  ).toBeGreaterThan(0);
});

// The only reason the hero routes through a page instead of straight at the
// artifact is that the download starts anyway. If this script stops firing, every
// download taken from the fold is lost — page renders, link resolves, suite green.
//
// One platform, not three: the guard below only fires a build the reader can
// actually run, so this is the reader's OWN build and the other two belong to
// the cross-OS test that follows.
test("arriving at /download with the reader's own build starts that download", async ({ page }) => {
  await page.goto("/download");
  // Firing is a desktop-only claim. A phone is offered its build and never sent
  // one, so the phone half of this contract is the test directly below rather
  // than a branch inside this one — the two assert opposite outcomes and reading
  // them as one test hid which of them was actually covered.
  test.skip(await isPhone(page), "a phone is offered a build, never fired one");
  const platform = await readerPlatform(page);
  const url = DOWNLOADS[platform];

  const fired: string[] = [];
  await watchDownloads(page, fired);
  const started = page.waitForEvent("download");

  await page.goto(`/download?platform=${platform}`);
  expect((await started).url(), `${platform} downloaded the wrong artifact`).toBe(url);
  // The panel that names the artifact and carries the manual retry — the only
  // thing standing between a blocked download and a reader sitting on a page
  // that insists it worked.
  await expect(page.locator(`.dl-note-${platform}`)).toBeVisible();
  await expect(page.locator(".dl-idle").first()).toBeHidden();
  // The parameter is spent. Left in the address bar, a reload or a Back onto
  // this entry fetches a second copy of the installer.
  expect(new URL(page.url()).searchParams.get("platform"), `${platform} left its parameter behind`).toBeNull();
  // And exactly one thing was fetched. A second entry here is the page firing
  // twice, which is two installers in the reader's downloads folder.
  expect(fired, `${platform} fired something other than its own build`).toEqual([url]);
});

// The worst case the OS match can produce, and it is not an edge: because
// data-os files Android under "win" and iPhone under "mac", a phone tapping the
// PRIMARY download CTA used to satisfy every "does this build match" test the
// page could run and fire anyway — an 815KB Windows .exe onto Android, a 94MB
// .dmg onto an iPhone, out of the reader's data allowance, for a file neither
// device can open. Nothing may auto-download while data-form says mobile.
test("a phone is offered its own build, never fired one", async ({ page }) => {
  await page.goto("/download");
  test.skip(!(await isPhone(page)), "the desktop half of this contract is the test above");
  const platform = await readerPlatform(page);

  const fired: string[] = [];
  await watchDownloads(page, fired);
  await page.goto(`/download?platform=${platform}`);
  // Long enough to outlast the page's own fire delay, so this proves nothing
  // started rather than racing it.
  await page.waitForTimeout(1500);

  expect(fired, "a phone was sent a desktop build").toEqual([]);
  await expect(page.locator(".dl-idle").first()).toBeVisible();
  // Offered, not merely withheld: the reader asked for a specific build and has
  // to leave with a link to it, or the guard has turned a working link into a
  // dead end.
  await expect(page.locator(`.dl-ask-${platform}`)).toBeVisible();
});

// A ?platform= link is the most shared thing on the site — it is what the hero,
// the band and the hero's build menu all emit — so it lands on machines that are
// not the one it was made on constantly. Firing on it regardless is not a
// cosmetic mismatch: DOWNLOADS.windows serves a Windows .exe to every caller
// including phones, so a colleague's "grab antgrid: <link>" used to drop an inert
// 815KB binary onto a Mac and then thank them for it.
//
// What replaces it is a link, not a download: the reader is shown the build they
// asked for and clicks it themselves, which is also the user gesture Chrome's
// download protection wants before it will trust a cross-origin fetch.
test("a build the reader is not on is offered, never fired", async ({ page }) => {
  await page.goto("/download");
  const mine = await readerPlatform(page);
  const away = (Object.keys(DOWNLOADS) as Array<keyof typeof DOWNLOADS>).filter((p) => p !== mine);
  expect(away.length, "there is no other platform to test against").toBe(2);

  const fired: string[] = [];
  await watchDownloads(page, fired);

  for (const platform of away) {
    await page.goto(`/download?platform=${platform}`);
    // The script waits for load and then a beat, so an assertion made straight
    // after goto() would pass even with the guard removed.
    await page.waitForTimeout(1200);
    // The pick-a-build state, which is the same thing an arrival with no
    // platform gets. Its visibility is the assertion that nothing was claimed:
    // the fired headline and the idle one are two elements switched by whether
    // `data-dl` exists at all (global.css), so they cannot both be showing.
    await expect(page.locator(".dl-idle").first(), `${platform} left no way to download`).toBeVisible();
    // Counted over the VISIBLE matches rather than asserted on `.first()`: the
    // hidden dl-os button for that platform carries the same href on two of the
    // three OSes, so a positional locator would keep resolving to a button CSS
    // has switched off and report the offer as missing.
    expect(
      await page.locator(`a[href="${OFFERED[platform]}"]:visible`).count(),
      `${platform} was refused without being offered a way to get it`
    ).toBeGreaterThan(0);
  }

  expect(fired, "a build was fired at a reader who cannot run it").toEqual([]);
});

// Both Playwright projects resolve to data-os="win" — Desktop Chrome by being
// Windows, Pixel 7 because its UA carries "Linux" AND "Android", which
// Base.astro deliberately files under win. So the case awayUrl exists for — a
// reader who is NOT on Windows meeting the Windows build — is the one case the
// suite could not otherwise reach, and it is the case the whole distinction was
// built for. Overriding the UA is cheaper than a third project: nothing else
// here is OS-dependent, and a project would run all 30 tests to cover one.
test.describe("a reader on macOS", () => {
  test.use({
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
  });

  test("meeting the Windows build gets the Store listing, never the stub", async ({ page }) => {
    const fired: string[] = [];
    await watchDownloads(page, fired);
    await page.goto("/download?platform=windows");
    await page.waitForTimeout(1500);

    expect(await page.evaluate(() => document.documentElement.dataset.os), "the Mac UA was not detected").toBe("mac");
    // The measured reason this test exists: DOWNLOADS.windows answers
    // Content-Disposition: attachment to EVERY user agent with no sniffing and
    // no redirect, so a Mac reaching it downloads an 815KB Windows .exe. The
    // listing is an ordinary page everywhere and still opens the Store app on
    // Windows, which is why it is safe to hand to anyone.
    expect(fired, "a Mac was sent the Windows stub installer").toEqual([]);
    await expect(page.locator(".dl-ask-windows")).toBeVisible();
    expect(
      await page.locator(`a[href="${STORE_LISTING}"]:visible`).count(),
      "a Mac asking for Windows was not offered the Store listing"
    ).toBeGreaterThan(0);
    expect(
      await page.locator(`a[href="${DOWNLOADS.windows}"]:visible`).count(),
      "the stub installer is reachable by a reader who is not on Windows"
    ).toBe(0);
  });
});

// The guard on that script is the whole safety property. Broken, every arrival
// without a platform — a shared link, a trimmed URL, a crawl — becomes an
// unrequested .exe, which is both a trust failure and the fastest way to get a
// domain flagged. An unknown platform must be as inert as no platform, and both
// must leave a reader something that works: the pick-a-build state.
test("the download page downloads nothing it was not asked for", async ({ page }) => {
  const fired: string[] = [];
  await watchDownloads(page, fired);

  for (const path of ["/download", "/download?platform=solaris"]) {
    await page.goto(path);
    // The script waits for load and then a beat, so an assertion made straight
    // after goto() would pass even with the guard removed.
    await page.waitForTimeout(1200);
    await expect(page.locator(".dl-idle").first(), `${path} offers no way to download`).toBeVisible();
    await expect(page.locator(".dl-note:visible"), `${path} claims a download started`).toHaveCount(0);
  }

  expect(fired, "the download page downloaded without being asked").toEqual([]);
});

// The cards on the download page are the reader's whole route out of it, and
// they deep-link INTO the guide. The dead-link sweep in home.spec.ts resolves
// links over HTTP, where a fragment is never sent, so a renamed step heading
// strands every fresh downloader at the top of the guide with the suite green.
test("every step on the download page lands on a step of the setup guide", async ({ page }) => {
  await page.goto("/download");
  const hrefs = await page.locator("ol a[href^='/get-started#']").evaluateAll((els) =>
    els.map((e) => (e as HTMLAnchorElement).getAttribute("href")!)
  );
  expect(hrefs.length, "the download page offers no next steps at all").toBe(3);

  await page.goto("/get-started");
  for (const href of hrefs) {
    const id = href.split("#")[1];
    await expect(page.locator(`#${id}`), `nothing on the setup guide has id="${id}"`).toHaveCount(1);
  }
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
//
// The download route used to be in here as /#download and is deliberately no
// longer: it is a path now, which means home.spec.ts's dead-link sweep resolves
// it for real and the /download tests above pin what it does on arrival. This
// sweep is left broad rather than narrowed to what happens to be on the page
// today — its job is to catch the NEXT fragment link somebody adds, and pinning
// the current set would only turn every addition red.
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
