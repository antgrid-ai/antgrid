import { chromium } from "@playwright/test";

const url = process.env.OG_URL ?? "http://localhost:4321/og-card";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 } });
await page.goto(url, { waitUntil: "networkidle" });
await page.locator("#og").screenshot({ path: "public/og/while-you-slept.png" });
await browser.close();
console.log("wrote public/og/while-you-slept.png");
