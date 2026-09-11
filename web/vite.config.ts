import { defineConfig } from "vite";
import tailwindcss from "@tailwindcss/vite";
import { resolve } from "node:path";

// Assets only — Hono SSR runs under Bun and serves the build output.
// `outDir` is `public/build/` (not `public/`) because Vite refuses to
// build when `outDir` overlaps `publicDir`; `publicDir: false` disables
// the copy-through behavior we don't need.
export default defineConfig({
  plugins: [tailwindcss()],
  publicDir: false,
  // Only affects URLs Vite writes INTO the bundles — the `url()` a stylesheet
  // uses to reach a font it pulled in. Those resolve against the site root, not
  // the stylesheet, so without this a font emitted to `public/build/` is asked
  // for at `/`. `asset()` builds its own hrefs off the manifest and is unaffected.
  base: "/build/",
  build: {
    outDir: "public/build",
    emptyOutDir: true,
    manifest: true,
    rollupOptions: {
      input: {
        styles: resolve(import.meta.dirname, "src/ui/styles.css"),
        htmx: resolve(import.meta.dirname, "src/ui/entries/htmx.ts"),
        checkout: resolve(import.meta.dirname, "src/ui/entries/checkout.ts"),
        dashboard: resolve(import.meta.dirname, "src/ui/entries/dashboard.ts"),
        devices: resolve(import.meta.dirname, "src/ui/entries/devices.ts"),
        waitlist: resolve(import.meta.dirname, "src/ui/entries/waitlist.ts"),
      },
      output: {
        entryFileNames: "[name].[hash].js",
        chunkFileNames: "[name].[hash].js",
        assetFileNames: "[name].[hash][extname]",
      },
    },
  },
});
