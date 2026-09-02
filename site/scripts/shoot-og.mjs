// Plain .mjs on plain node: Playwright's chromium.launch() hangs under Bun on
// Windows, and .ts under node needs 22.6+ type stripping — this needs neither.
// Run it against `astro preview`; the dev server's HMR socket never lets
// "networkidle" settle.
import { chromium } from "@playwright/test";

const url = process.env.OG_URL ?? "http://localhost:4321/og-card";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 } });
await page.goto(url, { waitUntil: "networkidle" });
// Settle the self-hosted webfonts so the shot never captures fallback metrics.
await page.evaluate(() => document.fonts.ready);
// animations: "disabled" or the shot is not reproducible -- the readout's
// "watching" dot pulses forever, so two runs of an unchanged card differ by a few
// bytes and every recut lands as a noisy binary diff. It also fast-forwards the
// ProofCard's finite reveals to their end state, which is the state worth
// shipping: the card should show the run resolved, not caught mid-populate.
await page
  .locator("#og")
  .screenshot({ path: "public/og/control-plane.png", animations: "disabled" });
await browser.close();
console.log("wrote public/og/control-plane.png");
