import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const FRAMEWORK_DEFAULT_PORTS: Array<[RegExp, number]> = [
  [/^next$/,   3000],
  [/^vite$/,   5173],
  [/^nuxt/,    3000],
  [/^remix/,   3000],
  [/^astro$/,  4321],
  [/^django$/, 8000],
  [/^flask$/,  5000],
];

export function inferFrameworkPort(deps: Record<string, string>): number | null {
  for (const name of Object.keys(deps)) {
    for (const [re, port] of FRAMEWORK_DEFAULT_PORTS) {
      if (re.test(name)) return port;
    }
  }
  return null;
}

export function envPort(cwd: string): number | null {
  for (const f of [".env", ".env.example"]) {
    const p = join(cwd, f);
    if (!existsSync(p)) continue;
    const content = readFileSync(p, "utf8");
    const m = content.match(/^\s*PORT\s*=\s*(\d+)\s*$/m);
    if (m) return Number(m[1]);
  }
  return null;
}

export const NON_PREVIEW_PORTS: number[] = [
  5432, 3306, 27017,
  6379,
  9229, 5005,
  9092,
];
