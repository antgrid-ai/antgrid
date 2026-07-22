import { readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";

// Resolve from this file so manifest lookup works regardless of process cwd.
const MANIFEST_PATH = resolve(
  import.meta.dirname,
  "../../public/build/.vite/manifest.json"
);
const BUILD_URL_PREFIX = "/build";

// Manifest keys match the `rollupOptions.input` paths in vite.config.ts.
const ENTRIES = {
  styles: "src/ui/styles.css",
  htmx: "src/ui/entries/htmx.ts",
  checkout: "src/ui/entries/checkout.ts",
  dashboard: "src/ui/entries/dashboard.ts",
} as const;

export type AssetName = keyof typeof ENTRIES;

let manifest: Record<string, { file: string }> = {};
let manifestMtime = -1;

const cacheManifest =
  process.env.NODE_ENV === "production" || process.env.NODE_ENV === "staging";

function loadManifest(): void {
  if (cacheManifest && manifestMtime !== -1) return;
  try {
    const mtime = statSync(MANIFEST_PATH).mtimeMs;
    if (mtime === manifestMtime) return;
    manifest = JSON.parse(readFileSync(MANIFEST_PATH, "utf8"));
    manifestMtime = mtime;
  } catch {
  }
}

export function asset(name: AssetName): string {
  loadManifest();
  const key = ENTRIES[name];
  const entry = manifest[key];
  if (!entry) {
    throw new Error(
      `Missing asset '${name}' (${key}) in ${MANIFEST_PATH}. Run \`bun run build:assets\`.`
    );
  }
  return `${BUILD_URL_PREFIX}/${entry.file}`;
}
