/**
 * Registers the Dart MCP server in a checkout's `.mcp.json`.
 *
 * Shared by dev-setup.ts (main checkout) and worktree.ts (new worktrees) so the
 * merge rule only has to be right once.
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const DART_ENTRY = {
  type: "stdio",
  command: "dart",
  args: ["mcp-server"],
  env: {},
} as const;

/**
 * Idempotent. Merges into `.mcp.json` rather than rewriting it: this file is
 * also owned by `bridge/plugin/setup.ts`, which adds/removes its own `antgrid`
 * key, and it is gitignored, so a clone never carries one.
 *
 * Why register it at all: the MCP server keeps ONE warm analysis server, so
 * agents get near-instant `analyze_files` instead of spawning `flutter analyze`
 * per check — and two concurrent `flutter analyze` runs deadlock silently on
 * the Flutter startup lock (see the gotcha in CLAUDE.md).
 */
export function ensureDartMcp(projectDir: string): void {
  const path = resolve(projectDir, ".mcp.json");

  let data: { mcpServers?: Record<string, unknown> } = {};
  if (existsSync(path)) {
    try {
      data = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      // A hand-broken .mcp.json is not worth failing setup over, but silently
      // overwriting someone's file would be worse — leave it for them to fix.
      console.warn("  ! .mcp.json is not valid JSON — leaving it alone.");
      return;
    }
  }

  if (!data.mcpServers) data.mcpServers = {};
  if (data.mcpServers.dart) {
    console.log("  .mcp.json: dart MCP server already registered");
    return;
  }

  data.mcpServers.dart = DART_ENTRY;
  writeFileSync(path, `${JSON.stringify(data, null, 2)}\n`);
  console.log("  .mcp.json: registered dart MCP server");
}
