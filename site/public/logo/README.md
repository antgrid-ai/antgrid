# Antgrid logo assets

The mark is **Converge**: four chevrons — one per agent — closing in on a
single accent target, the one under command. It sits on a 48-unit box and
reduces by dropping agents, never by shrinking them; the four need ~40px to
stay apart, so below that only two chevrons survive, and 16px gets its own
heavier cut.

Which rendering a slot gets turns on one question: do we know the background
it will land on?

- **Tileless** — transparent, chevrons in ink, target always Signal. The brand
  primary, for canvases we control: in-page lockups, in-app chrome, marketing
  on a known ground. The sites' copy inherits `currentColor`; the app's is
  baked, and ships as an ink/paper pair (see Files).
- **Tiled** — the same mark on the rounded Ink tile. Every slot the OS or a
  browser paints for us: browser tabs, the Windows taskbar, launcher icons,
  store art.

## Colors

| Token | Value | Role |
|---|---|---|
| Ink | `#101418` | Chevrons on light grounds; the tile |
| Paper | `#F2EFE9` | Chevrons on dark grounds |
| Signal | `#D2542A` | The target dot — never flips, on any ground |

Signal on Ink is 4.44:1 and on Paper 3.63:1. Both clear the 3:1 WCAG floor
for non-text graphical objects, which is the one that applies; neither clears
the 4.5:1 text floor, so **never set type in Signal at body size**.

**Never put a tileless mark in a slot the OS or a browser draws.** A raster
cannot adapt at all, and even an adaptive SVG favicon is matched against the
page/OS scheme — which is independent of the tab-strip colour a Chromium user
can theme on its own. Both directions have already shipped broken: dark ink
swallowed by a dark tab strip, white ink swallowed by a light taskbar. The
tile is what puts both out of reach.

## Files

| File | Use |
|------|-----|
| `antgrid-wordmark.svg` | "antgrid" alone, Archivo wght 700 outlined to paths. Inherits `currentColor`. |
| `antgrid-lockup.svg` | The primary lockup: mark, gap, wordmark. Inherits `currentColor`. |
| `antgrid-mark.svg` | Tiled mark on the rounded Ink tile. Opaque contexts only (store, marketing on unknown canvases). |
| `antgrid-mark-transparent.svg` | Tileless mark that follows the reader's scheme via `prefers-color-scheme`. Fetched as an image, never inlined — see the `<style>` note below. |
| `antgrid-mark-full.svg` | The four-agent mark inheriting `currentColor`, for inlining into markup we control — both site headers carry it, at 36px. |
| `antgrid-mark-small.svg` | Its two-chevron reduction, also `currentColor`. For chrome with no room for four agents. |
| `antgrid-favicon.svg` | Favicon: full-detail **tiled** mark, what browsers actually fetch. Best at 24px and up. |
| `antgrid-favicon-solid.svg` | 16px-optimized tiled mark: the two-chevron favicon tier, heavier stroke and a larger target. |
| `favicon-16/32/48.png` | Raster favicon fallbacks, tiled (16 = solid tier, 32/48 = full detail). |
| `apple-touch-icon-180.png` | iOS home screen icon — tiled (full-bleed; iOS applies its own mask and forces opacity). |
| `antgrid-icon-512.png` | Large raster app icon — tiled (full-bleed). |

`favicon.ico` (16 solid, 32/48 full detail; tiled) lives at
`site/public/favicon.ico`.

## HTML
```html
<link rel="icon" href="/logo/antgrid-favicon.svg" type="image/svg+xml">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/logo/apple-touch-icon-180.png">
```

The app's copies live at `app/assets/logo/` and are the same geometry with
literal colours — flutter_svg cannot resolve `currentColor`. Each cut ships
twice, `-light` being the Ink twin for a light palette:
`antgrid-wordmark{,-light}.svg`, `antgrid-lockup{,-light}.svg`,
`antgrid-mark-transparent{,-light}.svg`, `antgrid-mark-small{,-light}.svg`.
`AbBrandMark` picks the pair on `bgDeepest` luminance and the tier on the
rendered height, so no caller has to know either rule. `AbThemePreset.light`
ships, so paper-on-paper was a real defect, not a hypothetical one.

**Only `antgrid-mark-transparent.svg` may carry a `<style>` block.** The
wordmark and lockup are *inlined* into markup here, where a generic `.ink`
selector would leak into the host document's global scope — those use
`currentColor` instead. The transparent mark is only ever fetched as an
image, so its scoped `<style>` is safe. Note its media query keys off the
**reader's** OS scheme, not the page's: both sites force `color-scheme: dark`,
so an on-page copy would flip the wrong way for a light-OS visitor. That is
why nothing here inlines it — it is a download/external-use asset.

## Geometry (source of truth for regeneration)

The mark is four round-capped stroked chevrons on a 48-unit box, plus a
filled target circle at its centre `(24, 24)`. Three tiers, each solved to a
target fill of the canvas rather than hard-coded — the script computes the
transform from the artwork bbox, so the tiers stay optically matched when any
one tier's metrics move.

| Tier | Used at | Stroke | Target r | Chevrons |
|---|---|---|---|---|
| Full | ≥ 36px inlined, ≥ 40px raster | 3.2 | 4 | 4 — `M18 5 L24 11.5 L30 5` and its three rotations |
| Two | below that, to 17px | 4.6 | 5.4 | 2 — `M16 5 L24 13 L32 5`, `M16 43 L24 35 L32 43` |
| Favicon | ≤ 16px | 5.8 | 6 | 2 — `M15 5 L24 14 L33 5`, `M15 43 L24 34 L33 43` |

Tile corner radius is 21.875% of the box (rx=0 full-bleed for launcher-source
rasters). Canvas fill runs tighter at small sizes, where a tab strip or
taskbar gives the tile no breathing room of its own: 0.78 at ≤24px, 0.72 at
≤48px, 0.646 above.

Lockup proportions are the kit's hero: mark height 4/3 of the type size, gap
0.304 of the mark, mark centred on the wordmark's ink box.

## Generation

`npm run gen:icons` (`scripts/gen-brand-icons.ts`) rewrites **every** file
listed above, in both sites, plus the app's logo assets, Windows runner ico,
Store logo and splash art. Nothing here is hand-maintained — edit the script,
not the SVGs. `npm run gen:icons -- --preview` instead writes contact sheets
over a light and a dark chrome to `.icon-preview/`, which is the only check
that actually answers "can you see it".

The wordmark is the one exception to "no committed artwork": it was outlined
once from Archivo wght 700 with opentype.js and lives as path data in
`scripts/brand-wordmark-paths.ts`, so the build needs no font file. Recut it
only to change the type — per-character `charToGlyph` at 100em units,
baseline `y=0`, letter-spacing -.042em.
