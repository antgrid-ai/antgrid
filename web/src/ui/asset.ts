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
  devices: "src/ui/entries/devices.ts",
  waitlist: "src/ui/entries/waitlist.ts",
} as const;

// Fonts reach the manifest as dependencies of styles.css, not as inputs, so
// their keys are whatever path the installer laid the package down at —
// `../node_modules/.bun/@fontsource-variable+inter@5.3.0/...` under Bun, a flat
// path under npm. Both carry the version, so an exact key would break on every
// font-package bump. Match the basename instead, which is stable.
const FONT_ENTRIES = {
  fontDisplay: "archivo-latin-wght-normal.woff2",
  fontSans: "inter-latin-wght-normal.woff2",
} as const;

export type AssetName = keyof typeof ENTRIES | keyof typeof FONT_ENTRIES;

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
  const file =
    name in FONT_ENTRIES
      ? findByBasename(FONT_ENTRIES[name as keyof typeof FONT_ENTRIES])
      : manifest[ENTRIES[name as keyof typeof ENTRIES]]?.file;
  if (!file) {
    throw new Error(
      `Missing asset '${name}' in ${MANIFEST_PATH}. Run \`bun run build:assets\`.`
    );
  }
  return `${BUILD_URL_PREFIX}/${file}`;
}

function findByBasename(basename: string): string | undefined {
  for (const key of Object.keys(manifest)) {
    if (key.endsWith(`/${basename}`)) return manifest[key]?.file;
  }
  return undefined;
}
