import { test, expect } from "@playwright/test";

// The page only works if a reader can go and check it, so what is asserted here
// is the structure that makes that possible: the sections a sceptical reader is
// sent to, the outbound links that let them read the crypto themselves, and
// security.txt actually being served. Prose inside the sections is deliberately
// not asserted — see the note at the top of home.spec.ts.

const REPO = "https://github.com/antgrid-ai/antgrid";

test("security page renders with one h1 and the sections it promises", async ({ page }) => {
  await page.goto("/security");
  const h1 = page.getByRole("heading", { level: 1 });
  await expect(h1).toHaveCount(1);
  expect((await h1.innerText()).trim().length).toBeGreaterThan(0);

  await expect(page.getByRole("heading", { name: /what the relay does see/i })).toBeVisible();
  await expect(page.getByRole("heading", { name: /three things have to be true/i })).toBeVisible();
  await expect(page.getByRole("heading", { name: /exist yet/i })).toBeVisible();
  await expect(page.getByRole("heading", { name: /reporting a vulnerability/i })).toBeVisible();

  // The relay section is the page's central claim: both halves of the ledger
  // must render, not just the flattering one.
  const relay = page.locator("#relay");
  await expect(relay.getByText("in cleartext at the relay")).toBeVisible();
  await expect(relay.getByText("never at the relay")).toBeVisible();
});

test("the verification links point at the public repository", async ({ page }) => {
  await page.goto("/security");
  // Asserted as targets rather than fetched: these are third-party URLs, and a
  // GitHub outage must not be able to fail the site suite. `.first()` because
  // each of these is offered twice — once above the fold, once in the verify
  // list — and a second copy appearing is not a regression.
  await expect(page.getByRole("link", { name: "Repository" }).first()).toHaveAttribute("href", REPO);
  await expect(page.getByRole("link", { name: "SECURITY.md" }).first()).toHaveAttribute(
    "href",
    `${REPO}/blob/HEAD/SECURITY.md`
  );
  await expect(page.getByRole("link", { name: "packages/antgrid_relay_client" }).first()).toHaveAttribute(
    "href",
    `${REPO}/tree/HEAD/packages/antgrid_relay_client`
  );
  await expect(page.getByRole("link", { name: /report a vulnerability/i })).toHaveAttribute(
    "href",
    `${REPO}/security/advisories/new`
  );
  await expect(page.getByRole("link", { name: "contact@radhaai.com" })).toHaveAttribute(
    "href",
    /^mailto:contact@radhaai\.com/
  );
});

test("every internal link on the page resolves", async ({ page }) => {
  await page.goto("/security");
  const hrefs = await page.locator("a[href^='/']").evaluateAll((els) =>
    [...new Set(els.map((e) => (e as HTMLAnchorElement).getAttribute("href")!))].filter((h) => !h.startsWith("/#"))
  );
  expect(hrefs.length).toBeGreaterThan(0);
  for (const href of hrefs) {
    const res = await page.request.get(href);
    expect(res.status(), `dead link on /security: ${href}`).toBeLessThan(400);
  }
});

test("security.txt is served with the fields a scanner reads", async ({ page }) => {
  const res = await page.request.get("/.well-known/security.txt");
  expect(res.status()).toBe(200);
  const body = await res.text();
  expect(body).toContain("Contact: mailto:contact@radhaai.com");
  expect(body).toContain("Canonical: https://antgrid.ai/.well-known/security.txt");
  expect(body).toContain("Preferred-Languages:");
  // RFC 9116 treats an expired file as stale, so the date has to stay ahead of
  // the reader — bump it, never drop the field.
  const expires = body.match(/^Expires: (.+)$/m);
  expect(expires, "security.txt has no Expires field").toBeTruthy();
  expect(new Date(expires![1]).getTime()).toBeGreaterThan(Date.now());
});

test("the footer routes readers to the security page", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("footer").getByRole("link", { name: "Security" })).toHaveAttribute("href", "/security");
});

test("no horizontal overflow on mobile", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/security");
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
  expect(overflow).toBe(false);
});
