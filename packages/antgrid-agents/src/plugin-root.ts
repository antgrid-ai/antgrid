import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { atomicWriteFile } from "./atomic-file";
// Bun embeds text imports in compiled executables; TypeScript resolves the source module instead.
// @ts-expect-error Bun's text loader returns source text.
import opencode from "../assets/opencode/plugin.ts" with { type: "text" };
// @ts-expect-error Bun's text loader returns source text.
import antigravity from "../assets/antigravity/post-title.js" with { type: "text" };

// @ts-expect-error Bun embeds shell source as text.
import onStop from "../assets/hooks/on-stop" with { type: "text" };
// @ts-expect-error Bun embeds shell source as text.
import onNotification from "../assets/hooks/on-notification" with { type: "text" };
// @ts-expect-error Bun embeds shell source as text.
import resolvePort from "../assets/hooks/_resolve-api-port.sh" with { type: "text" };

const assets: Record<string, string> = {
  "hooks/on-stop": onStop,
  "hooks/on-notification": onNotification,
  "hooks/_resolve-api-port.sh": resolvePort,
  "opencode/plugin.ts": opencode,
  "antigravity/post-title.js": antigravity,
  "package.json": '{"type":"module"}\n',
};
const digest = createHash("sha256").update(JSON.stringify(assets)).digest("hex");

/** Content-addressed files remain usable by external runtimes across bridge updates. */
export function materializeAgentAssets(directory: string): string {
  const root = join(directory, "agent-assets", digest);
  for (const [name, content] of Object.entries(assets)) {
    const path = join(root, name);
    if (!existsSync(path) || readFileSync(path, "utf8") !== content) {
      atomicWriteFile(path, content, { dirMode: 0o700, fileMode: 0o600 });
    }
  }
  return root;
}

export function bundledPluginPath(directory: string, ...segments: string[]): string {
  const name = segments.join("/");
  if (!Object.hasOwn(assets, name)) throw new Error(`Unknown bundled agent asset: ${name}`);
  return join(materializeAgentAssets(directory), name);
}
