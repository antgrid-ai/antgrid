import { describe, test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// The theme-color metas in Seo.astro are literals: the browser paints them
// before any CSS lands, so they cannot read the token. This is what keeps them
// equal to the two halves of --color-page.
const SRC = resolve(import.meta.dir, "../../src");
const css = readFileSync(resolve(SRC, "styles/global.css"), "utf8");
const seo = readFileSync(resolve(SRC, "components/Seo.astro"), "utf8");

const pair = css.match(/--color-page:\s*light-dark\(\s*(#[0-9a-f]{6})\s*,\s*(#[0-9a-f]{6})\s*\)\s*;/);

function meta(scheme: "light" | "dark"): string {
  const m = seo.match(
    new RegExp(
      `<meta name="theme-color" media="\\(prefers-color-scheme: ${scheme}\\)" content="(#[0-9a-f]{6})" data-scheme="${scheme}" />`,
    ),
  );
  if (!m) throw new Error(`no ${scheme} theme-color meta in Seo.astro`);
  return m[1];
}

describe("theme-color", () => {
  test("--color-page is a light-dark pair", () => {
    expect(pair).not.toBeNull();
  });

  test("the light meta is the light half of --color-page", () => {
    expect(meta("light")).toBe(pair![1]);
  });

  test("the dark meta is the dark half of --color-page", () => {
    expect(meta("dark")).toBe(pair![2]);
  });

  // Chrome takes the first meta whose media matches; the override script
  // flips `media` rather than reordering, so the order is load-bearing.
  test("the light meta comes first", () => {
    expect(seo.indexOf('data-scheme="light"')).toBeLessThan(seo.indexOf('data-scheme="dark"'));
  });
});
