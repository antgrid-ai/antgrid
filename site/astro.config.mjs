import { defineConfig, fontProviders } from "astro/config";
import tailwindcss from "@tailwindcss/vite";
import icon from "astro-icon";
import sitemap from "@astrojs/sitemap";

// The local provider pointed at the installed @fontsource-variable packages,
// not fontProviders.fontsource(): the hosted provider fetches at build time, so
// a cold CI build would need network and the exact bytes could move under us
// between releases. Reading the npm packages keeps the fonts lockfile-pinned and
// the build offline, while still getting what the API is actually here for —
// metric-matched fallbacks and preload generated from each font's own metrics
// instead of the numbers we used to measure by hand.
//
// Only the latin subset is registered. The other subsets these packages ship
// (cyrillic, greek, vietnamese, latin-ext) were never referenced by any page and
// only widened the emitted CSS.

// font-display stays at the default "swap". "block" was tried and reverted: it
// hides the text rather than substituting it, and because this page's above-fold
// content is almost entirely type, nothing contentful paints until the woff2
// lands — measured first paint moved to 318ms on fast 4G and 1328ms on slow 4G,
// turning a font problem into an FCP regression and a visibly empty page.
//
// The stand-in is chosen below instead. Two things about how Astro picks it, both
// load-bearing and neither obvious (`core/optimize-fallbacks.js`):
//
//  1. Only the LAST entry is read, and only if it is a CSS generic. It is expanded
//     through a fixed table of the seven system faces Astro carries metrics for;
//     every earlier entry is ignored for matching. So a list ending in "sans-serif"
//     metric-matches Arial no matter what precedes it.
//  2. The generated faces are PREPENDED to the list. They therefore win over the
//     real families named after them — which is why naming Consolas did nothing
//     while a "fallback: Courier New" face sat in front of it.
const variant = (pkg, file, weight) => ({
  weight,
  style: "normal",
  src: [`./node_modules/@fontsource-variable/${pkg}/files/${file}`],
});

const fonts = [
  // "system-ui", not "sans-serif": it expands to five faces rather than one, so each
  // platform metric-matches its own UI font (Segoe UI here, BlinkMacSystemFont on
  // macOS, Roboto on Android) instead of every platform getting Arial. Those are
  // near-neighbours of Inter and Archivo, so the substitution reads as a weight
  // shift rather than a different typeface.
  {
    provider: fontProviders.local(),
    name: "Inter Variable",
    cssVariable: "--font-inter",
    fallbacks: ["Segoe UI", "Helvetica Neue", "Arial", "system-ui"],
    options: { variants: [variant("inter", "inter-latin-wght-normal.woff2", "100 900")] },
  },
  {
    provider: fontProviders.local(),
    name: "Archivo Variable",
    cssVariable: "--font-archivo",
    fallbacks: ["Segoe UI", "Helvetica Neue", "Arial", "system-ui"],
    options: { variants: [variant("archivo", "archivo-latin-wght-normal.woff2", "100 900")] },
  },
  // Deliberately NOT terminated with a generic, which suppresses metric matching
  // entirely for this family. Both mono generics map to Courier New alone, and a
  // thin typewriter face standing in for JetBrains Mono was the harshest swap on
  // the page. Trading it for an unmatched Consolas/SF Mono — right texture, width
  // off by a hair — is the better deal at the sizes mono appears here (eyebrow,
  // beta pill, ProofCard labels); measured CLS across the swap is 0.003.
  {
    provider: fontProviders.local(),
    name: "JetBrains Mono Variable",
    cssVariable: "--font-jetbrains",
    fallbacks: ["ui-monospace", "SFMono-Regular", "Menlo", "Consolas", "Liberation Mono", "DejaVu Sans Mono"],
    options: { variants: [variant("jetbrains-mono", "jetbrains-mono-latin-wght-normal.woff2", "100 800")] },
  },
];

// PUBLIC_SITE_URL kept in lockstep with Seo's PUBLIC_SITE_URL so canonical and sitemap never diverge.
export default defineConfig({
  site: process.env.PUBLIC_SITE_URL ?? "https://antgrid.ai",
  // There is no ClientRouter here, so every navigation is a full document load.
  // `hover` buys the one that matters back: the download CTAs are deliberate,
  // aimed clicks, and the page is fetched while the pointer is still travelling.
  // prefetchAll rather than per-link opt-in because the site is nine pages —
  // tagging them individually is a list that goes stale, not a saving.
  prefetch: { prefetchAll: true, defaultStrategy: "hover" },
  // Still behind the experimental flag as of Astro 5.18 — the docs describe it
  // unflagged, but `fonts` at the top level throws ExperimentalFontsNotEnabled.
  // Move it up a level when it stabilises; the shape of `fonts` itself is what
  // the docs document, so only the nesting should need to change.
  experimental: { fonts },
  vite: { plugins: [tailwindcss()] },
  integrations: [
    // simple-icons is named explicitly because astro-icon otherwise assigns an
    // installed collection `["*"]` and inlines the whole pack into the build's
    // virtual module — 3,700 icons and ~4.7MB of source, to draw five brand
    // marks in Compat.astro. (Claude Code and Mistral AI moved to src/icons/
    // with a tightened viewBox — the simple-icons originals letterbox short of
    // the full 24x24, so they render smaller than their siblings.) Collections
    // left unnamed (tabler) keep `*`.
    icon({
      include: {
        "simple-icons": [
          "openai",
          "opencode",
          "cursor",
          "githubcopilot",
          "kimi",
        ],
      },
    }),
    // og-card carries robots=noindex — it is the screenshot source for the
    // social card — and a sitemap that submits a noindex URL is a conflict
    // Search Console reports rather than ignores. /download is deliberately NOT
    // excluded: it is the site's only addressable download URL and the one page
    // a "antgrid download" search should be able to land on.
    sitemap({ filter: (page) => !page.includes("/og-card") }),
  ],
});
