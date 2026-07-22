// tool/color_parity/dump_ghostty_web.ts — run from repo root: bun tool/color_parity/dump_ghostty_web.ts
//
// Dumps per-cell resolved colors from the ghostty-web reference engine for the
// shared color-parity corpus, writing tool/color_parity/expected_cells.json.
// Consumed by packages/ghostty_vte_flutter/test/color_parity_test.dart, which
// proves OUR Flutter terminal resolves identical per-cell colors.
//
// ONE-TIME SETUP (the reference engine is gitignored, not committed):
//   cd tool/color_parity
//   npm pack ghostty-web@0.4.0            # downloads ghostty-web-0.4.0.tgz
//   mkdir -p _ghostty_web_ref && tar -xzf ghostty-web-0.4.0.tgz -C _ghostty_web_ref
//   # -> _ghostty_web_ref/package/dist/{ghostty-web.js, ghostty-vt.wasm}
// The 0.4.0 npm bundle ships a self-consistent lib + prebuilt wasm; building
// from the source checkout requires Zig 0.15.2 (see scripts/build-wasm.sh there).
//
// Palette: Windows-Terminal "Campbell" (shared with the Flutter side via
// campbellAnsi/campbellForeground in package:ghostty_vte_flutter).

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Ghostty } from './_ghostty_web_ref/package/dist/ghostty-web.js';

// Campbell ANSI 0..15 as 0xRRGGBB ints (no alpha), in palette order.
const CAMPBELL_PALETTE = [
  0x0c0c0c, 0xc50f1f, 0x13a10e, 0xc19c00, 0x0037da, 0x881798, 0x3a96dd, 0xcccccc,
  0x767676, 0xe74856, 0x16c60c, 0xf9f1a5, 0x3b78ff, 0xb4009e, 0x61d6d6, 0xf2f2f2,
];
const FG_COLOR = 0xcccccc;
const BG_COLOR = 0x09090b; // matches the app's default terminal background
const CURSOR_COLOR = 0xcccccc;

const wasmPath = fileURLToPath(
  new URL('./_ghostty_web_ref/package/dist/ghostty-vt.wasm', import.meta.url),
);
const corpusPath = fileURLToPath(new URL('./color_torture.bin', import.meta.url));
const outPath = fileURLToPath(new URL('./expected_cells.json', import.meta.url));

const ghostty = await Ghostty.load(wasmPath);
const term = ghostty.createTerminal(120, 40, {
  scrollbackLimit: 0,
  fgColor: FG_COLOR,
  bgColor: BG_COLOR,
  cursorColor: CURSOR_COLOR,
  palette: CAMPBELL_PALETTE,
});

const data = readFileSync(corpusPath);
term.write(new Uint8Array(data));

interface OutCell {
  y: number;
  x: number;
  ch: string;
  fg: [number, number, number];
  bg: [number, number, number];
  flags: number;
  width: number;
}

const out: OutCell[] = [];
for (let y = 0; y < term.rows; y++) {
  const cells = term.getLine(y);
  if (!cells) continue;
  for (let x = 0; x < cells.length; x++) {
    const cell = cells[x];
    if (!cell || cell.codepoint === 0) continue; // skip blanks
    out.push({
      y,
      x,
      ch: String.fromCodePoint(cell.codepoint),
      fg: [cell.fg_r, cell.fg_g, cell.fg_b],
      bg: [cell.bg_r, cell.bg_g, cell.bg_b],
      flags: cell.flags,
      width: cell.width,
    });
  }
}

// CRITICAL GUARD: the corpus emits "FG30".."FG37" on rows 0..7; row 1 is the
// \e[31m run "FG31", whose first glyph 'F' must resolve to Campbell red
// [0xC5,0x0F,0x1F], NOT VS Code red [0xcd,0x31,0x31]. If this fails, the palette
// config was not applied and the dump is untrustworthy.
const redCell = out.find((c) => c.y === 1 && c.x === 0);
if (!redCell || redCell.ch !== 'F') {
  throw new Error(
    `Campbell-red guard: expected 'F' at (y=1,x=0) of the \\e[31m line, got ${JSON.stringify(redCell)}`,
  );
}
const [r, g, b] = redCell.fg;
const isCampbellRed = r === 0xc5 && g === 0x0f && b === 0x1f;
console.log(
  `Campbell-red guard: first 'F' fg = [${r},${g},${b}] (#${r.toString(16).padStart(2, '0')}${g
    .toString(16)
    .padStart(2, '0')}${b.toString(16).padStart(2, '0')}) -> ${
    isCampbellRed ? 'PASS (Campbell red)' : 'FAIL'
  }`,
);
if (!isCampbellRed) {
  throw new Error(
    `Campbell-red guard FAILED: expected [197,15,31], got [${r},${g},${b}]. ` +
      'The createTerminal palette config was not applied; refusing to write a misleading expected_cells.json.',
  );
}

writeFileSync(outPath, JSON.stringify(out, null, 2));
console.log(`wrote ${out.length} cells to ${outPath}`);
