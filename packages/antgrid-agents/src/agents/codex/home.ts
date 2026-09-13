import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { AgentUpdateState } from "../types";

// `~/.codex` and the state files codex keeps in it. Codex is the one agent that
// writes its own updater state to disk, so this is the only `readState` in the
// registry — everything the update path does with it is agent-agnostic and
// lives in src/update/.

// Resolve `~/.codex` (or $CODEX_HOME) — where codex keeps version.json and
// sessions/. Blank or whitespace-padded CODEX_HOME (a trailing \r from an .env
// file is enough) would build paths that never exist, so it falls back instead.
export function codexHomeDir(env: Record<string, string | undefined> = process.env): string {
  const home = env.CODEX_HOME?.trim();
  return home ? home : join(homedir(), ".codex");
}

// Read codex's updater state file. Fail-soft: missing/garbage -> null.
export function readCodexVersionJson(codexHome: string): AgentUpdateState | null {
  try {
    const j = JSON.parse(readFileSync(join(codexHome, "version.json"), "utf8")) as Record<string, unknown>;
    return {
      latest_version: typeof j.latest_version === "string" ? j.latest_version : undefined,
      dismissed_version: typeof j.dismissed_version === "string" ? j.dismissed_version : null,
    };
  } catch {
    return null;
  }
}
