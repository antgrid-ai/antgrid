import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/blog",
  fullyParallel: true,
  webServer: {
    command: "bun run build --config astro.blog-test.config.mjs && bun run preview --config astro.blog-test.config.mjs --port 4322",
    url: "http://localhost:4322/blog",
    env: { ASTRO_PREVIEW_BACKGROUND: "false" },
    reuseExistingServer: false,
    timeout: 120_000,
  },
  use: { baseURL: "http://localhost:4322" },
  projects: [
    { name: "desktop", use: { ...devices["Desktop Chrome"] } },
    { name: "tablet", use: { viewport: { width: 768, height: 1024 } } },
    { name: "mobile", use: { ...devices["Pixel 7"] } },
  ],
});
