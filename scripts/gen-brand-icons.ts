/**
 * Regenerates every brand icon slot that the OS or a browser paints onto a
 * background we do not control: browser tab strips, the Windows taskbar, and
 * Store tiles.
 *
 * Those slots must be TILED. The tileless adaptive monogram stays the brand
 * primary, but it only survives where the canvas is known: a raster cannot
 * carry `prefers-color-scheme` at all, and even the adaptive SVG favicon is
 * matched against the page/OS scheme, which is independent of the tab-strip
 * colour a Chromium user can theme on its own. Either way round the letter
 * disappears — dark ink on a dark tab strip, white ink on a light taskbar.
 * Keep the tile and both failures are unreachable.
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

const ROOT = join(import.meta.dir, "..");

const INK = "#FAFAFA";
const ACCENT = "#818CF8";
const TILE = "#18181B";

/** The wordmark 'a' at wght 600 — the full-detail tier, best at 24px and up. */
const GLYPH_600 =
  "M36.50 0L25.13 0.31L24.53-9.50L24.09-13.19L24.09-20.50Q24.09-23.41 21.81-24.77Q19.53-26.12 15-26.25L6.75-26.47L7.38-33.44L14.38-33.34Q23.06-33.22 27.28-29.80Q31.50-26.37 31.50-19.81L31.50-6.94L36.50-6.25L36.50 0M13.72 0.63Q8.47 0.63 5.58-1.94Q2.69-4.50 2.69-9.19Q2.69-14.62 6.56-17.53Q10.44-20.44 17.53-20.44Q20.34-20.44 22.47-20.12Q24.59-19.81 26.53-19.16L25.16-13.41Q23.13-13.87 21.38-13.95Q19.63-14.03 17.72-14.03Q10.34-14.03 10.34-9.69Q10.34-7.78 11.64-6.78Q12.94-5.78 15.41-5.78Q18.28-5.78 20.22-6.83Q22.16-7.87 23.13-9.48Q24.09-11.09 24.09-12.81L24.09-15.50L25.59-7L22.94-7L24.03-8Q23.97-5.12 22.70-3.20Q21.44-1.28 19.16-0.33Q16.88 0.63 13.72 0.63";

/** The same 'a' re-instanced at wght 700 — thicker strokes survive 16px. */
const GLYPH_700 =
  "M36.72 0L24.84 0.31L24.13-9.50L24-13.81L24-20.28Q24-22.94 21.73-24.17Q19.47-25.41 15-25.53L6.53-25.75L7.16-33.44L14.38-33.34Q23.38-33.22 27.75-29.80Q32.13-26.37 32.13-19.81L32.13-7.56L36.72-6.87L36.72 0M13.63 0.63Q8.34 0.63 5.41-1.97Q2.47-4.56 2.47-9.34Q2.47-14.91 6.31-17.87Q10.16-20.84 17.22-20.84Q19.94-20.84 21.92-20.56Q23.91-20.28 25.94-19.69L24.56-13.09Q22.56-13.56 20.97-13.64Q19.38-13.72 17.63-13.72Q11.06-13.72 11.06-9.97Q11.06-8.28 12.25-7.39Q13.44-6.50 15.72-6.50Q18.47-6.50 20.31-7.53Q22.16-8.56 23.08-10.16Q24-11.75 24-13.44L24-15.50L25.19-7L22.53-7L23.63-8Q23.53-5.12 22.31-3.20Q21.09-1.28 18.89-0.33Q16.69 0.63 13.63 0.63";

/**
 * Antenna metrics per tier, in glyph units. The vertical stems are drawn apart
 * from the 45° elbow runs: the left one is a flat-bottomed rect (a round cap
 * there bulged over the 'a' top bar) and the right one is a fill+stroke patch
 * whose bottom edge follows the letter's sloping shoulder.
 */
type Tier = {
  glyph: string;
  stroke: number;
  dotR: number;
  left: string;
  right: string;
  rect: { x: number; y: number; w: number; h: number };
  patch: string;
  patchStroke: number;
  dots: [number, number][];
  /** [minX, maxX, minY, maxY] of the inked artwork, stroke caps and dots included. */
  bbox: [number, number, number, number];
};

const TIER_FULL: Tier = {
  glyph: GLYPH_600,
  stroke: 5,
  dotR: 5,
  left: "M11 -46.5 L0.5 -57",
  right: "M26.5 -46.5 L37 -57",
  rect: { x: 8.5, y: -46.5, w: 5, h: 10.5 },
  patch:
    "m28.4724 -46.134-.0508 12.8918c0 0-.5354-.4773-.831-.6786-.3484-.2373-.7183-.4465-1.1032-.6184-.6407-.2862-1.2214-.4396-1.9922-.6805l.0154-10.9178z",
  patchStroke: 1.0096,
  dots: [
    [-3, -60.5],
    [40.5, -60.5],
  ],
  bbox: [-8, 45.5, -65.5, 0.63],
};

const TIER_SOLID: Tier = {
  glyph: GLYPH_700,
  stroke: 8,
  dotR: 8,
  left: "M11 -45 L2 -54",
  right: "M26.5 -45 L35 -54",
  rect: { x: 7, y: -45, w: 8, h: 9 },
  patch:
    "m29.6657 -44.7-.0813 11.4578c0 0-.8566-.4773-1.3296-.6786-.5575-.2373-1.1493-.4465-1.7651-.6184-1.0252-.2862-1.9543-.4396-3.1875-.6805l.0246-9.4841z",
  patchStroke: 1.69,
  dots: [
    [-1.5, -57.5],
    [38.5, -57.5],
  ],
  bbox: [-9.5, 46.5, -65.5, 0.63],
};

/**
 * Fits a tier's artwork to `fill` of the 512 canvas and centres it. Solving for
 * the transform rather than hard-coding one keeps the two tiers optically
 * matched when either tier's metrics move.
 */
function fit(tier: Tier, fill: number) {
  const [x0, x1, y0, y1] = tier.bbox;
  const scale = (512 * fill) / (y1 - y0);
  const w = (x1 - x0) * scale;
  const h = (y1 - y0) * scale;
  return {
    scale,
    tx: (512 - w) / 2 - x0 * scale,
    ty: (512 - h) / 2 - y0 * scale,
  };
}

function markSvg(tier: Tier, opts: { rx: number; fill: number; size?: number }): string {
  const { scale, tx, ty } = fit(tier, opts.fill);
  const n = (v: number) => Number(v.toFixed(4));
  const size = opts.size ?? 512;
  const { rect } = tier;
  const dots = tier.dots
    .map(([cx, cy]) => `    <circle cx="${cx}" cy="${cy}" r="${tier.dotR}" fill="${ACCENT}"/>`)
    .join("\n");
  return `<svg width="${size}" height="${size}" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Antgrid">
  <rect width="512" height="512" rx="${opts.rx}" fill="${TILE}"/>
  <g transform="translate(${n(tx)},${n(ty)}) scale(${n(scale)})">
    <path d="${tier.glyph}" fill="${INK}"/>
    <g fill="none" stroke="${ACCENT}" stroke-width="${tier.stroke}" stroke-linecap="round" stroke-linejoin="round">
      <path d="${tier.left}"/>
      <path d="${tier.right}"/>
    </g>
    <rect x="${rect.x}" y="${rect.y}" width="${rect.w}" height="${rect.h}" fill="${ACCENT}"/>
    <path d="${tier.patch}" fill="${ACCENT}" stroke="${ACCENT}" stroke-width="${tier.patchStroke}"/>
${dots}
  </g>
</svg>
`;
}

/** Below ~24px the full-detail antennae collapse into a blob; swap tiers there. */
const tierFor = (px: number) => (px <= 24 ? TIER_SOLID : TIER_FULL);
/**
 * A tab strip or taskbar gives the tile no breathing room of its own, so the
 * small sizes run a tighter margin than a launcher tile wants.
 */
const fillFor = (px: number) => (px <= 24 ? 0.78 : px <= 48 ? 0.72 : 0.646);

const render = (px: number, rx: number) =>
  sharp(Buffer.from(markSvg(tierFor(px), { rx, fill: fillFor(px), size: px })))
    .png({ compressionLevel: 9 })
    .toBuffer();

/**
 * Packs an ICO. Sizes up to 48 go in as 32-bit BGRA DIBs (the encoding Explorer
 * has always taken) and 256 as PNG, which is the only way it fits.
 */
async function ico(sizes: number[], rx: number): Promise<Buffer> {
  const images = await Promise.all(
    sizes.map(async (px) => {
      if (px >= 256) return { px, data: await render(px, rx) };
      const raw = await sharp(
        Buffer.from(markSvg(tierFor(px), { rx, fill: fillFor(px), size: px })),
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
      const input = await sharp(await render(px, 112))
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

  // Browser tabs. The SVG is what Chromium and Firefox actually fetch; the ICO
  // and the PNGs are the fallback for everything that will not take an SVG.
  const faviconSvg = markSvg(TIER_FULL, { rx: 112, fill: 0.646 });
  const faviconSolidSvg = markSvg(TIER_SOLID, { rx: 112, fill: 0.78 });
  const favIco = await ico([16, 32, 48], 112);
  for (const pub of ["site/public", "web/public"]) {
    put(`${pub}/logo/antgrid-favicon.svg`, faviconSvg);
    put(`${pub}/logo/antgrid-favicon-solid.svg`, faviconSolidSvg);
    for (const px of [16, 32, 48]) put(`${pub}/logo/favicon-${px}.png`, await render(px, 112));
  }
  put("site/public/favicon.ico", favIco);
  put("web/public/logo/favicon.ico", favIco);

  // Windows taskbar, title bar and Alt-Tab, via Runner.rc's IDI_APP_ICON.
  put("app/windows/runner/resources/app_icon.ico", await ico([16, 24, 32, 48, 256], 112));

  // Microsoft Store tiles. Full-bleed (rx=0): the Store and the Start menu
  // apply their own corner treatment, and rounding twice leaves a dark fringe.
  put("app/assets/icon/antgrid-store-logo.png", await render(1024, 0));
}
