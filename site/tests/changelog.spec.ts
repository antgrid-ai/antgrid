import { test, expect } from "@playwright/test";
import { ENTRIES, ORPHAN_NOTES, releaseStrip, STRIP_DAYS } from "../src/data/changelog";

// Notes are keyed by tag and the page joins them to the release spine silently.
// A key matching no release renders nowhere and reports nothing, so a typo'd tag
// or a release deleted upstream costs someone their writing with nothing red
// anywhere. changelog.ts says this is pinned; this is where.
test("every hand-written note reaches a release", () => {
  expect(ORPHAN_NOTES, "note keys matching no published release").toEqual([]);
});

// Not that the loop runs — that the join holds. A release the spine carries must
// have a row under its own anchor, because support replies and update prompts
// link straight at one; and a release someone has written up must be showing the
// writing rather than the fallback that says nobody has.
test("every release has its own row, and the three states match the data", async ({ page }) => {
  await page.goto("/changelog");
  await expect(page.locator("main article")).toHaveCount(ENTRIES.length);

  for (const entry of ENTRIES) {
    await expect(page.locator(`main article[id="${entry.version}"]`)).toHaveCount(1);
  }

  const written = ENTRIES.filter((entry) => entry.note);
  await expect(page.getByText("Maintenance build.")).toHaveCount(
    ENTRIES.filter((entry) => !entry.note && entry.maintenance).length,
  );
  await expect(page.getByText("We haven't written this one up.")).toHaveCount(
    ENTRIES.length - written.length - ENTRIES.filter((entry) => !entry.note && entry.maintenance).length,
  );

  // Verbatim, on the entry a reader lands on first: the lines are prose in a
  // data file, and nothing else on the page would notice them rendering empty.
  const latest = written[0];
  const row = page.locator(`main article[id="${latest.version}"]`);
  for (const [, text] of latest.note!.lines) await expect(row.getByText(text, { exact: true })).toBeVisible();
});

// The strip is a picture of the shipping record, and a wrong picture is worse
// than none: it is the one claim on the page a reader cannot check without
// counting every row of the ledger. The days are derived rather than stored, so
// the derivation is the thing that has to hold.
test("the cadence strip is one contiguous day per tick, bounded and lossless", () => {
  const strip = releaseStrip();
  expect(strip.length).toBeGreaterThan(0);
  expect(strip.length, "an axis longer than this draws ticks thinner than its gaps").toBeLessThanOrEqual(STRIP_DAYS);

  const asMs = (date: string) => Date.parse(`${date}T00:00:00Z`);
  for (let i = 1; i < strip.length; i += 1) {
    expect(asMs(strip[i].date) - asMs(strip[i - 1].date), "a day is missing from the axis").toBe(86_400_000);
  }

  // Ends on the newest build, and every release inside the window is on it
  // exactly once. A release that falls through renders as a gap, which is the
  // strip saying we went quiet on a day we shipped.
  expect(asMs(strip[strip.length - 1].date)).toBe(Math.max(...ENTRIES.map((entry) => asMs(entry.date))));
  expect(strip.flatMap((day) => day.releases.map((release) => release.version)).sort()).toEqual(
    ENTRIES.filter((entry) => entry.date >= strip[0].date).map((entry) => entry.version).sort(),
  );
});

test("every lit tick lands on a row that exists", async ({ page }) => {
  await page.goto("/changelog");
  const strip = releaseStrip();
  await expect(page.locator("main header ul > li")).toHaveCount(strip.length);

  const lit = page.locator("main header ul a");
  await expect(lit).toHaveCount(strip.filter((day) => day.releases.length > 0).length);

  // The strip is the header's only control, so a tick pointing at an anchor the
  // page does not carry is a dead end rather than a cosmetic fault.
  for (const href of await lit.evaluateAll((links) => links.map((link) => link.getAttribute("href")))) {
    await expect(page.locator(`main article[id="${href!.slice(1)}"]`)).toHaveCount(1);
  }
});

// What a deep link is for, and it is drawn by a scoped rule rather than by the
// markup: a class renamed on one side of changelog.astro and not the other
// leaves every support reply landing on an unmarked row, with nothing red.
test("the release you linked to is the one marked", async ({ page }) => {
  const [, second] = ENTRIES;
  await page.goto(`/changelog#${second.version}`);

  // Against a sibling rather than against a hex: what has to be true is that
  // the targeted row reads differently from the eighteen around it, and pinning
  // the accent here would fail the day the ramp is retuned for no real reason.
  const colourOf = (version: string) =>
    page.locator(`main article[id="${version}"] h2 a`).evaluate((node) => getComputedStyle(node).color);
  expect(await colourOf(second.version)).not.toBe(await colourOf(ENTRIES[0].version));

  // And the marker the rule hangs in the gutter, which is the part a reader
  // catches before they have read the version back.
  const marker = await page
    .locator(`main article[id="${second.version}"] h2 a`)
    .evaluate((node) => getComputedStyle(node, "::before").content);
  expect(marker, "no marker on the targeted row").not.toBe("none");
});
