import { describe, test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// Parsed out of the shipped stylesheets rather than restated here: a test
// carrying its own copy of the palette passes while the real colours drift.
//
// The marketing site is read from here too. Someone signing in crosses from
// antgrid.ai into this service mid-flow — the same reason the font faces above
// are duplicated verbatim — so the two ramps are one palette in two files, and
// only a test that reads both can catch them diverging.
const SHEETS = {
  web: resolve(import.meta.dir, "../../src/ui/styles.css"),
  site: resolve(import.meta.dir, "../../../site/src/styles/global.css"),
} as const;

const css = Object.fromEntries(
  Object.entries(SHEETS).map(([k, p]) => [k, readFileSync(p, "utf8")]),
) as Record<keyof typeof SHEETS, string>;

function token(sheet: keyof typeof SHEETS, name: string): string {
  const m = css[sheet].match(
    new RegExp(`--color-${name}:\\s*(#[0-9a-fA-F]{6})\\s*;`),
  );
  if (!m) throw new Error(`${sheet}: --color-${name} is missing or not a hex`);
  return m[1];
}

/** WCAG 2.x relative luminance of a #rrggbb literal. */
function luminance(hex: string): number {
  const lin = [1, 3, 5]
    .map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
}

function contrast(a: string, b: string): number {
  const la = luminance(a) + 0.05;
  const lb = luminance(b) + 0.05;
  return la > lb ? la / lb : lb / la;
}

describe("Signal accent ramp", () => {
  for (const sheet of Object.keys(SHEETS) as (keyof typeof SHEETS)[]) {
    // `signal` carries text — links, counts, the active nav item — so it owes
    // the 4.5:1 body floor on every surface it can land on, not the 3:1
    // non-text one. Chrome is the tightest of the three, which is why pure
    // #d2542a cannot be the text tier.
    for (const surface of ["page", "panel", "chrome"]) {
      test(`${sheet}: signal reads as text on ${surface}`, () => {
        expect(
          contrast(token(sheet, "signal"), token(sheet, surface)),
        ).toBeGreaterThanOrEqual(4.5);
      });
    }

    // The button fill is the pure brand orange, light enough that white fails
    // AA on it — so its label is page ink instead, on both the idle fill and
    // the lighter `signal` hover. This is the pairing that breaks silently if
    // signalbtn is ever lightened.
    test(`${sheet}: signalbtn carries page ink, not white`, () => {
      const page = token(sheet, "page");
      for (const fill of ["signalbtn", "signal"]) {
        expect(contrast(page, token(sheet, fill))).toBeGreaterThanOrEqual(4.5);
      }
      expect(contrast("#ffffff", token(sheet, "signalbtn"))).toBeLessThan(4.5);
    });

    // signal2 is the focus-ring colour on page, and the text daisyUI puts on
    // `secondary` (= signaldeep) — so it owes the non-text floor on one
    // surface and the text floor on the other.
    test(`${sheet}: signal2 clears the focus-ring and on-deep floors`, () => {
      expect(
        contrast(token(sheet, "signal2"), token(sheet, "page")),
      ).toBeGreaterThanOrEqual(3);
      expect(
        contrast(token(sheet, "signal2"), token(sheet, "signaldeep")),
      ).toBeGreaterThanOrEqual(4.5);
    });
  }

  test("daisyUI puts page ink on the primary fill, not its default white", () => {
    expect(css.web).toContain("--color-primary: var(--color-signalbtn)");
    expect(css.web).toContain("--color-primary-content: var(--color-page)");
  });

  // Only the tokens both sheets define; the site adds a third tint and a
  // second deep that this service has no surface for.
  test("both sheets ship the same ramp", () => {
    for (const name of [
      "page",
      "panel",
      "chrome",
      "signal",
      "signal2",
      "signalbtn",
      "signaldeep",
    ]) {
      expect(`${name}=${token("web", name)}`).toBe(
        `${name}=${token("site", name)}`,
      );
    }
  });
});
