// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { describe, test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// Parsed out of the shipped stylesheets rather than restated here: a test
// carrying its own copy of the palette passes while the real colours drift.
//
// The marketing site is read from here too. Someone signing in crosses from
// antgrid.ai into this service mid-flow — the same reason the font faces above
// are duplicated verbatim — so the two accent ramps are one palette in two
// files, and only a test that reads both can catch them diverging.
const SHEETS = {
  web: resolve(import.meta.dir, "../../src/ui/styles.css"),
  site: resolve(import.meta.dir, "../../../site/src/styles/global.css"),
} as const;
type Sheet = keyof typeof SHEETS;

const SCHEMES = ["light", "dark"] as const;
type Scheme = (typeof SCHEMES)[number];

const css = Object.fromEntries(
  Object.entries(SHEETS).map(([k, p]) => [k, readFileSync(p, "utf8")]),
) as Record<Sheet, string>;

const HEX = "#[0-9a-fA-F]{6}";

/** A token is either a `light-dark(#hex, #hex)` pair or one hex for both. */
function token(sheet: Sheet, name: string): Record<Scheme, string> {
  const m = css[sheet].match(
    new RegExp(
      `--color-${name}:\\s*(?:light-dark\\(\\s*(${HEX})\\s*,\\s*(${HEX})\\s*\\)|(${HEX}))\\s*;`,
    ),
  );
  if (!m) {
    throw new Error(
      `${sheet}: --color-${name} is missing, or not a hex / light-dark(hex, hex) pair`,
    );
  }
  return m[3] ? { light: m[3], dark: m[3] } : { light: m[1], dark: m[2] };
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

/** Contrast of two tokens in one scheme. */
function ratio(sheet: Sheet, scheme: Scheme, a: string, b: string): number {
  return contrast(token(sheet, a)[scheme], token(sheet, b)[scheme]);
}

describe("Signal accent ramp", () => {
  for (const sheet of Object.keys(SHEETS) as Sheet[]) {
    for (const scheme of SCHEMES) {
      const t = `${sheet}/${scheme}`;

      // `signal` carries text — links, counts, the active nav item — so it
      // owes the 4.5:1 body floor on every surface it can land on, not the
      // 3:1 non-text one. Chrome is the tightest of the three in the dark
      // half, which is why pure #d2542a cannot be the text tier.
      for (const surface of ["page", "panel", "chrome"]) {
        test(`${t}: signal reads as text on ${surface}`, () => {
          expect(ratio(sheet, scheme, "signal", surface)).toBeGreaterThanOrEqual(4.5);
        });
      }

      // The label on a Signal fill is `signalink`, on both the idle fill and
      // the lighter `signal` hover. This is the pairing that breaks silently
      // if either signalbtn half is lightened.
      test(`${t}: signalink reads on signalbtn and signal`, () => {
        for (const fill of ["signalbtn", "signal"]) {
          expect(ratio(sheet, scheme, "signalink", fill)).toBeGreaterThanOrEqual(4.5);
        }
      });

      // signal2 is the focus-ring colour on page, and the text daisyUI puts on
      // `secondary` (= signaldeep) — so it owes the non-text floor on one
      // surface and the text floor on the other. signal itself also lands on
      // the deep tint (badges, the pricing "current" chip).
      test(`${t}: signal2 clears the focus-ring and on-deep floors`, () => {
        expect(ratio(sheet, scheme, "signal2", "page")).toBeGreaterThanOrEqual(3);
        expect(ratio(sheet, scheme, "signal2", "signaldeep")).toBeGreaterThanOrEqual(4.5);
        expect(ratio(sheet, scheme, "signal", "signaldeep")).toBeGreaterThanOrEqual(4.5);
      });

      // muted2 is the quietest text tier (AA body) and faint the quietest
      // UI tier (AA non-text), both picked against page.
      test(`${t}: muted2 and faint clear their floors on page`, () => {
        expect(ratio(sheet, scheme, "muted2", "page")).toBeGreaterThanOrEqual(4.5);
        expect(ratio(sheet, scheme, "faint", "page")).toBeGreaterThanOrEqual(3);
      });

      // Semantic hues are used as TEXT on page (a green "connected", an amber
      // timestamp, a red error line), so they owe the body floor.
      const semantic = sheet === "web" ? ["ok", "amber", "danger"] : ["ok", "amber"];
      for (const hue of semantic) {
        test(`${t}: ${hue} reads as text on page`, () => {
          expect(ratio(sheet, scheme, hue, "page")).toBeGreaterThanOrEqual(4.5);
        });
      }
    }

    // In the dark half white is 4.16:1 on the brand orange, under AA — which
    // is why dark signalink is page ink rather than white, and why the two
    // halves of signalink differ at all.
    test(`${sheet}/dark: white would fail on signalbtn`, () => {
      expect(contrast("#ffffff", token(sheet, "signalbtn").dark)).toBeLessThan(4.5);
    });
  }

  // The Readout marks sit on chrome, the tightest site surface.
  for (const scheme of SCHEMES) {
    test(`site/${scheme}: ok reads as text on chrome`, () => {
      expect(ratio("site", scheme, "ok", "chrome")).toBeGreaterThanOrEqual(4.5);
    });

    // The two status hues that carry words inside an app window get a text
    // tier on the window's surface; the dot/chip hues themselves are the
    // app's and are not held to it.
    test(`site/${scheme}: status ink tiers read on ab-surface`, () => {
      for (const ink of ["ab-attn-ink", "ab-run-ink"]) {
        expect(ratio("site", scheme, ink, "ab-surface")).toBeGreaterThanOrEqual(4.5);
      }
    });

    // daisyUI's `*-content` colours all point at signalink, so it has to read
    // on every semantic fill, not only the brand one.
    test(`web/${scheme}: signalink reads on every daisyUI fill`, () => {
      for (const fill of ["ok", "amber", "danger"]) {
        expect(ratio("web", scheme, "signalink", fill)).toBeGreaterThanOrEqual(4.5);
      }
    });
  }

  test("daisyUI puts signalink on the primary fill, not its default white", () => {
    expect(css.web).toContain("--color-primary: var(--color-signalbtn)");
    expect(css.web).toContain("--color-primary-content: var(--color-signalink)");
  });

  // The override block used to be keyed on `[data-theme="dark"]`, which is
  // only present when a reader pinned a scheme: under the system default it
  // never matched and daisyUI's own indigo showed through. Anchored to the
  // line start so the `html[data-theme="dark"]` scheme pin stays allowed.
  test("the daisyUI override is not keyed on the override attribute", () => {
    expect(css.web).not.toMatch(/^\[data-theme="dark"\]\s*\{/m);
  });

  // The accent alone. Surfaces diverged on purpose (#149): the site is warm so
  // its zinc app windows read as objects on a bench, while this service has no
  // windows and stays zinc. The signal ramp is the contract a reader carries
  // across the sign-in crossing, so only it is held byte-identical, in both
  // halves. The site's third tint and second deep have no surface here.
  test("both sheets ship the same accent ramp", () => {
    for (const name of ["signal", "signal2", "signalbtn", "signaldeep"]) {
      for (const scheme of SCHEMES) {
        expect(`${name}/${scheme}=${token("web", name)[scheme]}`).toBe(
          `${name}/${scheme}=${token("site", name)[scheme]}`,
        );
      }
    }
  });
});
