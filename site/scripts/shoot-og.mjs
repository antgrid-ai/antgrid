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
await page.locator("#og").screenshot({ path: "public/og/prove-its-done.png" });
await browser.close();
console.log("wrote public/og/prove-its-done.png");
