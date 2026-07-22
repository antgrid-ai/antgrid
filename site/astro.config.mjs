import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";
import icon from "astro-icon";
import sitemap from "@astrojs/sitemap";

// PUBLIC_SITE_URL kept in lockstep with Seo's PUBLIC_SITE_URL so canonical and sitemap never diverge.
export default defineConfig({
  site: process.env.PUBLIC_SITE_URL ?? "https://antgrid.ai",
  vite: { plugins: [tailwindcss()] },
  integrations: [icon(), sitemap({ filter: (page) => !page.includes("/og-card") })],
});
