// tool/color_parity/gen_corpus.ts — run from repo root: bun tool/color_parity/gen_corpus.ts
import { writeFileSync } from 'node:fs';
const ESC = '\x1b';
const lines: string[] = [];
// 16 standard + bright foregrounds
for (let i = 30; i <= 37; i++) lines.push(`${ESC}[${i}mFG${i}${ESC}[0m`);
for (let i = 90; i <= 97; i++) lines.push(`${ESC}[${i}mFG${i}${ESC}[0m`);
// 16 backgrounds
for (let i = 40; i <= 47; i++) lines.push(`${ESC}[${i}m BG${i} ${ESC}[0m`);
// 256-color cube + grayscale samples
for (const n of [16, 52, 88, 124, 196, 231, 232, 244, 255]) {
  lines.push(`${ESC}[38;5;${n}m256:${n}${ESC}[0m`);
}
// truecolor
lines.push(`${ESC}[38;2;0;255;255mTRUECYAN${ESC}[0m`);
lines.push(`${ESC}[38;2;255;128;0mTRUEORANGE${ESC}[0m`);
// attributes: bold, faint, inverse, italic, underline
lines.push(`${ESC}[1mBOLD${ESC}[0m ${ESC}[2mFAINT${ESC}[0m ${ESC}[7mINVERSE${ESC}[0m`);
// faint over default fg (the historically buggy case)
lines.push(`${ESC}[2mDIMDEFAULT${ESC}[0m`);
// complex scripts (grapheme handling)
lines.push('Devanagari: नमस्ते  Arabic: السلام عليكم  Emoji ZWJ: 👨‍👩‍👧');
// XTPUSHSGR / XTPOPSGR probe (CSI # { ... CSI # })
lines.push(`${ESC}[31m${ESC}[#{${ESC}[32mGREEN?${ESC}[#}AFTERPOP${ESC}[0m`);
writeFileSync('tool/color_parity/color_torture.bin', lines.join('\r\n') + '\r\n');
console.log('wrote', lines.length, 'lines');
