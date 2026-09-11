import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: true,
  webServer: {
    command: "bun run build && bun run preview --port 4321",
    url: "http://localhost:4321/",
    // `astro preview` auto-detaches into a background process when it detects an
    // agent environment, which leaves Playwright's webServer child exiting
    // immediately. Presence of the variable — any value — is what disables that
    // detection, and it is the PREVIEW one: this command is `astro preview`, and
    // ASTRO_DEV_BACKGROUND is read only by `astro dev`.
    env: { ASTRO_PREVIEW_BACKGROUND: "false" },
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
  use: { baseURL: "http://localhost:4321" },
  projects: [
    { name: "desktop", use: { ...devices["Desktop Chrome"] } },
    { name: "mobile", use: { ...devices["Pixel 7"] } },
  ],
});
