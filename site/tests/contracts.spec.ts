import { test, expect } from "@playwright/test";

// Release contracts: the assertions whose failure costs money or traffic — download
// targets, the sign-in CTA, and the closed paid path. They live apart from the page
// tests on purpose. Playwright aborts a test at its first failed expect, so a brittle
// copy assertion sharing a test body with these would stop them ever running; that is
// exactly how the download URLs went unverified while the suite sat red.
//
// Nothing here may assert marketing wording. Assert targets, counts and states only.

const DOWNLOADS = {
  macos: "https://github.com/antgrid-ai/antgrid/releases/latest/download/antgrid-macos.dmg",
  windows: "https://get.microsoft.com/installer/download/9N0P7ZRL4D9W?referrer=appbadge&cid=site",
  linux: "https://github.com/antgrid-ai/antgrid/releases/latest/download/antgrid-linux.AppImage",
};

// The web service, which is a different origin from this static build.
const WAITLIST_ORIGIN = "https://app.antgrid.ai";

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

// /privacy is excluded on purpose — it says "lifetime of the session", not a plan.
for (const path of ["/pricing", "/terms", "/refunds", "/support"]) {
  test(`lifetime is not offered on ${path}`, async ({ page }) => {
    // There is no lifetime plan and no one-time-payment path. The word reappearing
    // on a legal or marketing page promises terms nothing can honour.
    await page.goto(path);
    await expect(page.locator("body")).not.toContainText(/lifetime/i);
  });
}

// Indexed pages. og-card is excluded on purpose: it is the screenshot source for
// the social card, already noindex and filtered out of the sitemap.
const INDEXED = ["/", "/pricing", "/get-started", "/support", "/privacy", "/terms", "/refunds", "/security"];

test("every indexed page ships a description search engines will show whole", async ({ page }) => {
  // 155 is where Google starts truncating. Social previews cut earlier — mobile
  // link cards show roughly 125 — so pages people actually share are written
  // tighter than this; the gate is the hard bound, not the target.
  for (const path of INDEXED) {
    await page.goto(path);
    const description = await page.locator('meta[name="description"]').getAttribute("content");
    expect(description, `${path} has no meta description`).toBeTruthy();
    expect(description!.length, `${path} description is ${description!.length} chars`).toBeLessThanOrEqual(155);
  }
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

test("the social card declares its dimensions so previews reserve the box", async ({ page }) => {
  // Without these a client fetches the PNG before it can size the card, and the
  // preview reflows around it — or renders the link bare while it waits.
  await page.goto("/");
  await expect(page.locator('meta[property="og:image:width"]')).toHaveAttribute("content", "1200");
  await expect(page.locator('meta[property="og:image:height"]')).toHaveAttribute("content", "630");
  const alt = await page.locator('meta[property="og:image:alt"]').getAttribute("content");
  expect(alt, "the card carries no alt text").toBeTruthy();
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
  await expect(page.locator("#handler")).toContainText("Handler");
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
