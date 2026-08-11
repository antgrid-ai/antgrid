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
      },
      output: {
        entryFileNames: "[name].[hash].js",
        chunkFileNames: "[name].[hash].js",
        assetFileNames: "[name].[hash][extname]",
      },
    },
  },
});
