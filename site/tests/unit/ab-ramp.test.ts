import { describe, test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// The site's hand-built app windows are painted in the desktop app's palette,
// dark half from `_zincFallback`, light half from the `_light` preset. Nothing
// else spans the two trees, and a drifted value is silent: it shows up as a
// window that looks almost right. So the Dart literals are parsed here and
// compared with the `--color-ab-*` tokens in global.css.
const ROOT = resolve(import.meta.dir, "../../..");
const css = readFileSync(resolve(ROOT, "site/src/styles/global.css"), "utf8");
const presets = readFileSync(resolve(ROOT, "app/lib/design/theme_presets.dart"), "utf8");
const abColors = readFileSync(resolve(ROOT, "app/lib/design/ab_colors.dart"), "utf8");

/** The `name: Color(0xFFrrggbb)` fields of one `AbColors(...)` literal. */
function palette(source: string, constName: string): Record<string, string> {
  const start = source.indexOf(`const ${constName} = AbColors(`);
  if (start < 0) throw new Error(`${constName} not found`);
  const body = source.slice(start, source.indexOf(");", start));
  const out: Record<string, string> = {};
  for (const m of body.matchAll(/(\w+): Color\(0xFF([0-9A-Fa-f]{6})\)/g)) {
    out[m[1]] = `#${m[2].toLowerCase()}`;
  }
  return out;
}

const light = palette(presets, "_light");
const dark = palette(abColors, "_zincFallback");

// Site token → app field. The `-ink` text tiers are the site's own and are
// held to contrast instead (web/tests/ui/accent-contrast.test.ts).
const MAP: Record<string, string> = {
  deepest: "bgDeepest",
  deep: "bgDeep",
  surface: "bgSurface",
  raised: "bgRaised",
  elevated: "bgElevated",
  selected: "bgSelected",
  "line-soft": "borderSubtle",
  line: "borderDefault",
  "line-strong": "borderStrong",
  text: "textPrimary",
  text2: "textSecondary",
  ok: "success",
  run: "statusRunning",
  think: "statusThinking",
  attn: "statusAttention",
};

// The ramp entries that deliberately DIVERGE from the app, and the app value
// each one replaces. The app tunes these for a dense native window the reader
// is working in; the site paints them at 9.5-13px on a page that is scanned
// once, where the app value runs 2.1-4.4:1. They are held to a contrast floor
// here instead of to the Dart literal, so a drift is still caught -- what is
// no longer asserted is only the equality the site cannot afford.
const LIFTED: Record<string, string> = {
  mute: "textMuted",
  dim: "textDisabled",
  err: "error",
};

function token(name: string): string {
  const m = css.match(new RegExp(`--color-ab-${name}:\\s*([^;]+);`));
  if (!m) throw new Error(`--color-ab-${name} missing`);
  return m[1].replace(/\s+/g, "").toLowerCase();
}

describe("ab-* ramp mirrors the app palette", () => {
  for (const [name, field] of Object.entries(MAP)) {
    test(`ab-${name} is the app's ${field} in both schemes`, () => {
      const l = light[field];
      const d = dark[field];
      expect(l).toBeDefined();
      expect(d).toBeDefined();
      const want = l === d ? l : `light-dark(${l},${d})`;
      expect(token(name)).toBe(want);
    });
  }

  test("every ab-* token is mapped, apart from the site's own ink tiers", () => {
    const names = [...css.matchAll(/--color-ab-([\w-]+):/g)]
      .map((m) => m[1])
      .filter((n) => !n.endsWith("-ink"));
    expect(names.sort()).toEqual([...Object.keys(MAP), ...Object.keys(LIFTED)].sort());
  });
});

describe("ab-* tiers lifted off the app palette", () => {
  for (const [name, field] of Object.entries(LIFTED)) {
    // Equality is what the mirrored set asserts; here the point is the
    // opposite -- if one of these ever matches the app again it has silently
    // dropped back below the floor the site needs.
    test(`ab-${name} no longer equals the app's ${field}`, () => {
      const l = light[field];
      const d = dark[field];
      expect(l).toBeDefined();
      expect(d).toBeDefined();
      expect(token(name)).not.toBe(l === d ? l : `light-dark(${l},${d})`);
    });

    test(`ab-${name} is a light-dark pair`, () => {
      expect(token(name)).toMatch(/^light-dark\(#[0-9a-f]{6},#[0-9a-f]{6}\)$/);
    });
  }
});
