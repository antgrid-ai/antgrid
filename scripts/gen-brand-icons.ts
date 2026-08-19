/**
 * Regenerates every brand icon slot that the OS or a browser paints onto a
 * background we do not control: browser tab strips, the Windows taskbar, and
 * Store tiles.
 *
 * Those slots must be TILED. The tileless mark stays the brand primary, but it
 * only survives where the canvas is known: a raster cannot carry
 * `prefers-color-scheme` at all, and even the adaptive SVG favicon is matched
 * against the page/OS scheme, which is independent of the tab-strip colour a
 * Chromium user can theme on its own. Either way round the mark disappears —
 * ink chevrons on a dark tab strip, paper chevrons on a light taskbar. Keep the
 * tile and both failures are unreachable.
 *
 * Run: `npm run gen:icons` (add `--preview` to write contact sheets to
 * `.icon-preview/` instead of touching the committed assets).
 *
 * Geometry is the recipe in `site/public/logo/README.md`; this script is its
 * executable form, so move them together.
 */
import sharp from "sharp";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { WORD_PATH, WORD_BBOX } from "./brand-wordmark-paths.ts";

const ROOT = join(import.meta.dir, "..");

const INK = "#101418";
const PAPER = "#F2EFE9";
const SIGNAL = "#D2542A";

/**
 * Converge: four chevrons closing on a single target, one chevron per agent,
 * the accent marking the one under command. Drawn on a 48-unit box — tips inset
 * 5u, stroke 3.2u with round caps, target r4 dead centre. The four are one
 * chevron at 4 x 90°; no other angle is permitted.
 */
type Tier = {
  stroke: number;
  dotR: number;
  paths: string[];
  /** Extents of the path POINTS, before the stroke is widened around them. */
  ext: [number, number, number, number];
};

/** Full four-agent mark. Holds down to 40px. */
const TIER_FULL: Tier = {
  stroke: 3.2,
  dotR: 4,
  paths: [
    "M18 5 L24 11.5 L30 5",
    "M18 43 L24 36.5 L30 43",
    "M5 18 L11.5 24 L5 30",
    "M43 18 L36.5 24 L43 30",
  ],
  ext: [5, 43, 5, 43],
};

/**
 * Below 40px the side agents close into the target and the whole thing reads as
 * a blob. Drop to two agents and thicken, per the kit's reduction rule.
 */
const TIER_TWO: Tier = {
  stroke: 4.6,
  dotR: 5.4,
  paths: ["M16 5 L24 13 L32 5", "M16 43 L24 35 L32 43"],
  ext: [16, 32, 5, 43],
};

/** The 16px tier — thicker again, and a target big enough to survive one pixel. */
const TIER_FAVICON: Tier = {
  stroke: 5.8,
  dotR: 6,
  paths: ["M15 5 L24 14 L33 5", "M15 43 L24 34 L33 43"],
  ext: [15, 33, 5, 43],
};

/** Inked extents of a tier: the points, widened by the stroke, unioned with the target. */
function bboxOf(t: Tier): [number, number, number, number] {
  const h = t.stroke / 2;
  const [x0, x1, y0, y1] = t.ext;
  return [
    Math.min(x0 - h, 24 - t.dotR),
    Math.max(x1 + h, 24 + t.dotR),
    Math.min(y0 - h, 24 - t.dotR),
    Math.max(y1 + h, 24 + t.dotR),
  ];
}

/**
 * Scales a tier's artwork to `fill` of the 48-unit canvas height and centres it.
 * Solving for the transform rather than hard-coding one keeps the tiers
 * optically matched when any tier's metrics move.
 */
function fit(tier: Tier, fill: number) {
  const [x0, x1, y0, y1] = bboxOf(tier);
  const scale = (48 * fill) / (y1 - y0);
  return {
    scale,
    tx: (48 - (x1 - x0) * scale) / 2 - x0 * scale,
    ty: (48 - (y1 - y0) * scale) / 2 - y0 * scale,
  };
}

const n = (v: number) => Number(v.toFixed(4));

/** The chevrons and target, at the tier's native 48-unit coordinates. */
function glyph(tier: Tier, strokeAttr: string, dotAttr: string, indent = "  "): string {
  const paths = tier.paths.map((d) => indent + '  <path d="' + d + '"/>').join("\n");
  return (
    indent +
    '<g fill="none" ' +
    strokeAttr +
    ' stroke-width="' +
    tier.stroke +
    '" stroke-linecap="round" stroke-linejoin="round">\n' +
    paths +
    "\n" +
    indent +
    "</g>\n" +
    indent +
    '<circle cx="24" cy="24" r="' +
    tier.dotR +
    '" ' +
    dotAttr +
    "/>"
  );
}

/** A mark scaled and centred inside the 48-unit canvas at `fill` of its height. */
function fitted(tier: Tier, fill: number, strokeAttr: string, dotAttr: string): string {
  const { scale, tx, ty } = fit(tier, fill);
  return (
    "  <g transform=\"translate(" +
    n(tx) +
    "," +
    n(ty) +
    ") scale(" +
    n(scale) +
    ")\">\n" +
    glyph(tier, strokeAttr, dotAttr, "    ") +
    "\n  </g>"
  );
}

const svgOpen = (size: number) =>
  '<svg width="' +
  size +
  '" height="' +
  size +
  '" viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Antgrid">';

/** Tiled mark: ink tile, paper chevrons, accent target. `rx` is in 48-unit terms. */
function tileSvg(tier: Tier, opts: { rx: number; fill: number; size?: number }): string {
  return (
    svgOpen(opts.size ?? 512) +
    '\n  <rect width="48" height="48" rx="' +
    n(opts.rx) +
    '" fill="' +
    INK +
    '"/>\n' +
    fitted(tier, opts.fill, 'stroke="' + PAPER + '"', 'fill="' + SIGNAL + '"') +
    "\n</svg>\n"
  );
}

/** Tileless mark on a canvas we control — the caller knows the ink colour. */
function markSvg(tier: Tier, ink: string, size = 512): string {
  return (
    svgOpen(size) +
    "\n" +
    glyph(tier, 'stroke="' + ink + '"', 'fill="' + SIGNAL + '"') +
    "\n</svg>\n"
  );
}

/** Tileless mark that follows the reader's scheme. Only safe where a page owns the canvas. */
function adaptiveMarkSvg(tier: Tier, size = 512): string {
  return (
    svgOpen(size) +
    "\n  <style>.ink{stroke:" +
    INK +
    "}@media(prefers-color-scheme:dark){.ink{stroke:" +
    PAPER +
    "}}</style>\n" +
    glyph(tier, 'class="ink"', 'fill="' + SIGNAL + '"') +
    "\n</svg>\n"
  );
}

/* ---------------------------------------------------------------- wordmark */

const PAD = 6;
const [WX0, WX1, WY0, WY1] = WORD_BBOX;

const viewBox = (x0: number, y0: number, w: number, h: number) =>
  'viewBox="' + n(x0) + " " + n(y0) + " " + n(w) + " " + n(h) + '"';

/**
 * The wordmark alone, for slots that already carry the mark.
 *
 * `ink` is a literal colour for the app, which paints the file through
 * flutter_svg and cannot resolve `currentColor`. The sites inline the same file
 * into their markup, so they pass INHERIT instead: a `<style>` block would put
 * its selectors into the host document's global scope.
 */
const INHERIT = "currentColor";

function wordmarkSvg(ink: string): string {
  return (
    "<svg " +
    viewBox(WX0 - PAD, WY0 - PAD, WX1 - WX0 + PAD * 2, WY1 - WY0 + PAD * 2) +
    ' xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Antgrid">' +
    '\n  <path fill="' +
    ink +
    '" d="' +
    WORD_PATH +
    '"/>\n</svg>\n'
  );
}

/**
 * The primary lockup: mark, then wordmark. Proportions are the kit's hero —
 * mark 4/3 of the type size, gap 0.304 of the mark — and the mark centres on
 * the wordmark's ink box.
 */
const LOCK_MARK = 400 / 3;
const LOCK_GAP = LOCK_MARK * (34 / 112);
const LOCK_CY = (WY0 + WY1) / 2;

function lockupSvg(ink: string): string {
  const x0 = WX0 - LOCK_GAP - LOCK_MARK;
  const y0 = Math.min(WY0, LOCK_CY - LOCK_MARK / 2);
  const y1 = Math.max(WY1, LOCK_CY + LOCK_MARK / 2);
  const fillAttr = 'fill="' + ink + '"';
  const strokeAttr = 'stroke="' + ink + '"';
  return (
    "<svg " +
    viewBox(x0 - PAD, y0 - PAD, WX1 - x0 + PAD * 2, y1 - y0 + PAD * 2) +
    ' xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Antgrid">' +
    "\n  <g transform=\"translate(" +
    n(x0) +
    "," +
    n(LOCK_CY - LOCK_MARK / 2) +
    ") scale(" +
    n(LOCK_MARK / 48) +
    ")\">\n" +
    glyph(TIER_FULL, strokeAttr, 'fill="' + SIGNAL + '"', "    ") +
    "\n  </g>\n  <path " +
    fillAttr +
    ' d="' +
    WORD_PATH +
    '"/>\n</svg>\n'
  );
}

/* ------------------------------------------------------------------ raster */

/** Four agents need 40px; below that the two-agent tier, and 16px gets its own. */
const tierFor = (px: number) => (px <= 16 ? TIER_FAVICON : px < 40 ? TIER_TWO : TIER_FULL);
/**
 * A tab strip or taskbar gives the tile no breathing room of its own, so the
 * small sizes run a tighter margin than a launcher tile wants.
 */
const fillFor = (px: number) => (px <= 24 ? 0.78 : px <= 48 ? 0.72 : 0.646);

/** rx=112 on the old 512 grid is 21.875% — the kit's app-icon corner, in 48-unit terms. */
const TILE_RX = 48 * 0.21875;

const render = (px: number, rx: number) =>
  sharp(Buffer.from(tileSvg(tierFor(px), { rx, fill: fillFor(px), size: px })))
    .png({ compressionLevel: 9 })
    .toBuffer();

/** Rasterises an SVG into a transparent box of the given size, letterboxed. */
async function fitPng(svg: string, width: number, height: number, inset = 0): Promise<Buffer> {
  const iw = Math.round(width * (1 - inset));
  const ih = Math.round(height * (1 - inset));
  const left = Math.round((width - iw) / 2);
  const top = Math.round((height - ih) / 2);
  const inner = await sharp(Buffer.from(svg))
    .resize({
      width: iw,
      height: ih,
      fit: "contain",
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    })
    .png()
    .toBuffer();
  return sharp({
    create: { width, height, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  })
    .composite([{ input: inner, left, top }])
    .png({ compressionLevel: 9 })
    .toBuffer();
}

/**
 * Packs an ICO. Sizes up to 48 go in as 32-bit BGRA DIBs (the encoding Explorer
 * has always taken) and 256 as PNG, which is the only way it fits.
 */
async function ico(sizes: number[], rx: number): Promise<Buffer> {
  const images = await Promise.all(
    sizes.map(async (px) => {
      if (px >= 256) return { px, data: await render(px, rx) };
      const raw = await sharp(
        Buffer.from(tileSvg(tierFor(px), { rx, fill: fillFor(px), size: px })),
      )
        .ensureAlpha()
        .raw()
        .toBuffer();
      const header = Buffer.alloc(40);
      header.writeUInt32LE(40, 0);
      header.writeInt32LE(px, 4);
      header.writeInt32LE(px * 2, 8); // XOR bitmap plus the AND mask stacked below it
      header.writeUInt16LE(1, 12);
      header.writeUInt16LE(32, 14);
      header.writeUInt32LE(px * px * 4, 20);
      const xor = Buffer.alloc(px * px * 4);
      for (let y = 0; y < px; y++) {
        const src = (px - 1 - y) * px * 4; // DIB rows run bottom-up
        for (let x = 0; x < px; x++) {
          const s = src + x * 4;
          const d = (y * px + x) * 4;
          xor[d] = raw[s + 2];
          xor[d + 1] = raw[s + 1];
          xor[d + 2] = raw[s];
          xor[d + 3] = raw[s + 3];
        }
      }
      // A 32-bit DIB carries its own alpha, so the 1bpp mask stays all-opaque.
      const and = Buffer.alloc(Math.ceil(px / 32) * 4 * px);
      return { px, data: Buffer.concat([header, xor, and]) };
    }),
  );

  const head = Buffer.alloc(6);
  head.writeUInt16LE(1, 2);
  head.writeUInt16LE(images.length, 4);
  let offset = 6 + images.length * 16;
  const dir: Buffer[] = [];
  for (const { px, data } of images) {
    const e = Buffer.alloc(16);
    e[0] = px >= 256 ? 0 : px; // 0 spells 256 in an ICO directory entry
    e[1] = px >= 256 ? 0 : px;
    e.writeUInt16LE(1, 4);
    e.writeUInt16LE(32, 6);
    e.writeUInt32LE(data.length, 8);
    e.writeUInt32LE(offset, 12);
    offset += data.length;
    dir.push(e);
  }
  return Buffer.concat([head, ...dir, ...images.map((i) => i.data)]);
}

function put(rel: string, data: Buffer | string) {
  const abs = join(ROOT, rel);
  mkdirSync(dirname(abs), { recursive: true });
  writeFileSync(abs, data);
  console.log(`  ${rel}`);
}

if (process.argv.includes("--preview")) {
  // Contact sheets: every size over both a light and a dark chrome, which is
  // the only check that actually answers "can you see it".
  const sizes = [16, 24, 32, 48, 64, 128];
  const scale = 8;
  const pad = 8 * scale;
  for (const [name, bg] of [
    ["light", "#F5F5F5"],
    ["dark", "#2E2E30"],
  ] as const) {
    const width = sizes.reduce((a, s) => a + s * scale + pad, pad);
    const height = 128 * scale + pad * 2;
    let x = pad;
    const layers: sharp.OverlayOptions[] = [];
    for (const px of sizes) {
      const input = await sharp(await render(px, TILE_RX))
        .resize({ width: px * scale, kernel: "nearest" })
        .toBuffer();
      layers.push({ input, left: Math.round(x), top: Math.round((height - px * scale) / 2) });
      x += px * scale + pad;
    }
    mkdirSync(join(ROOT, ".icon-preview"), { recursive: true });
    await sharp({ create: { width, height, channels: 4, background: bg } })
      .composite(layers)
      .png()
      .toFile(join(ROOT, `.icon-preview/sheet-${name}.png`));
    console.log(`  .icon-preview/sheet-${name}.png`);
  }
} else {
  console.log("brand icons:");

  const PUBLIC = ["site/public", "web/public"];

  // Browser tabs. The SVG is what Chromium and Firefox actually fetch; the ICO
  // and the PNGs are the fallback for everything that will not take an SVG.
  const faviconSvg = tileSvg(TIER_FULL, { rx: TILE_RX, fill: 0.646 });
  const faviconSolidSvg = tileSvg(TIER_FAVICON, { rx: TILE_RX, fill: 0.78 });
  const favIco = await ico([16, 32, 48], TILE_RX);
  for (const pub of PUBLIC) {
    put(`${pub}/logo/antgrid-favicon.svg`, faviconSvg);
    put(`${pub}/logo/antgrid-favicon-solid.svg`, faviconSolidSvg);
    for (const px of [16, 32, 48]) put(`${pub}/logo/favicon-${px}.png`, await render(px, TILE_RX));
  }
  put("site/public/favicon.ico", favIco);
  put("web/public/logo/favicon.ico", favIco);

  // Windows taskbar, title bar and Alt-Tab, via Runner.rc's IDI_APP_ICON.
  put("app/windows/runner/resources/app_icon.ico", await ico([16, 24, 32, 48, 256], TILE_RX));

  // Microsoft Store tiles. Full-bleed (rx=0): the Store and the Start menu
  // apply their own corner treatment, and rounding twice leaves a dark fringe.
  put("app/assets/icon/antgrid-store-logo.png", await render(1024, 0));

  // The launcher master. flutter_launcher_icons feeds this one file to iOS,
  // macOS, web and the Android adaptive foreground, so it stays tiled.
  put("app/assets/icon/antgrid-icon-1024.png", await render(1024, TILE_RX));
  put(
    "app/assets/icon/antgrid-icon-square.svg",
    tileSvg(TIER_FULL, { rx: 0, fill: 0.646, size: 1024 }),
  );

  // Tiled and tileless marks: shipped for download, and used by the app shell.
  const tiledMark = tileSvg(TIER_FULL, { rx: TILE_RX, fill: 0.646 });
  put("app/assets/logo/antgrid-mark.svg", tiledMark);
  // The app picks between the two by palette luminance (AbBrandMark): a custom
  // background can be light, and paper-on-paper is invisible.
  put("app/assets/logo/antgrid-mark-transparent.svg", markSvg(TIER_FULL, PAPER));
  put("app/assets/logo/antgrid-mark-transparent-light.svg", markSvg(TIER_FULL, INK));
  put("app/assets/logo/antgrid-mark-small.svg", markSvg(TIER_TWO, PAPER, 48));
  put("app/assets/logo/antgrid-mark-small-light.svg", markSvg(TIER_TWO, INK, 48));
  for (const pub of PUBLIC) {
    put(`${pub}/logo/antgrid-mark.svg`, tiledMark);
    put(`${pub}/logo/antgrid-mark-transparent.svg`, adaptiveMarkSvg(TIER_FULL));
    put(`${pub}/logo/antgrid-icon-512.png`, await render(512, TILE_RX));
    put(`${pub}/logo/apple-touch-icon-180.png`, await render(180, TILE_RX));
  }

  // Wordmarks and lockups. Reverse (paper) is the app default and -light is its
  // ink twin; the sites inline theirs into markup, so those inherit the
  // surrounding text colour.
  put("app/assets/logo/antgrid-wordmark.svg", wordmarkSvg(PAPER));
  put("app/assets/logo/antgrid-wordmark-light.svg", wordmarkSvg(INK));
  put("app/assets/logo/antgrid-lockup.svg", lockupSvg(PAPER));
  put("app/assets/logo/antgrid-lockup-light.svg", lockupSvg(INK));
  for (const pub of PUBLIC) {
    put(`${pub}/logo/antgrid-wordmark.svg`, wordmarkSvg(INHERIT));
    put(`${pub}/logo/antgrid-lockup.svg`, lockupSvg(INHERIT));
  }

  // Splash art. Both land on the near-black splash colour, so both knock out.
  put("app/assets/icon/splash-mark.png", await fitPng(lockupSvg(PAPER), 880, 306));
  // Android 12 masks its splash icon to a circle: keep the mark well inside.
  put(
    "app/assets/icon/android12-splash-wordmark.png",
    await fitPng(markSvg(TIER_FULL, PAPER), 1152, 1152, 0.45),
  );

  // Linux .desktop icon, painted by whatever the desktop environment chooses.
  put("app/linux/packaging/antgrid.png", await render(256, TILE_RX));
}
