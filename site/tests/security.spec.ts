import { test, expect } from "@playwright/test";

// The page's whole argument is that a reader can go and check it, so what is
// tested is the going: the outbound targets, every internal link resolving, and
// security.txt being served to the scanner that asks for it. The claims
// themselves are prose and have no test — see the note at the top of home.spec.ts.

const REPO = "https://github.com/antgrid-ai/antgrid";

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

// The one file on the site whose reader is a machine, so its fields are a
// contract rather than content: a scanner that cannot find Contact treats the
// site as having no disclosure channel, and RFC 9116 treats an expired file as
// stale outright.
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
