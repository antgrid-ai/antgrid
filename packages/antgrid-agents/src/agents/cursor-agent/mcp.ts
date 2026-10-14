import { join } from "node:path";
import { materializeJson, NO_INJECTION } from "../launch-inject";
import type { LaunchAugmentation, McpInjectCtx } from "../types";
import { cursorSupportsFlag } from "./help";

// Cursor strips the environment of an MCP child (measured: the server saw
// roughly 15-18 keys, none of ours) but expands `${env:VAR}` in the entry's
// `env` against its own, so the identity stays symbolic and one plugin serves
// every terminal on the machine.
const MCP_ENV = {
  ANTGRID_API_PORT: "${env:ANTGRID_API_PORT}",
  ANTGRID_TERMINAL_ID: "${env:ANTGRID_TERMINAL_ID}",
  ANTGRID_RUN_ID: "${env:ANTGRID_RUN_ID}",
} as const;

/**
 * `--plugin-dir <dir>` with a plugin that carries only `.mcp.json` (the leading
 * dot is required; `mcp.json` is not loaded) and a `.cursor-plugin/plugin.json`
 * manifest. Cursor has no per-launch MCP flag, and `cursor-agent mcp list` does
 * not show plugin servers. Measured against 2026.10.01: the server starts after
 * workspace trust (the hook profile already passes `--trust`) with no approval
 * prompt, and is spawned twice per launch, which is accepted.
 */
export function inject({ abDir, mcpCommand }: McpInjectCtx): LaunchAugmentation {
  if (!cursorSupportsFlag("--plugin-dir")) return NO_INJECTION;
  const pluginDir = join(abDir, "plugin", "cursor");
  const written = materializeJson("Cursor MCP plugin", {
    [join(pluginDir, ".cursor-plugin", "plugin.json")]: {
      name: "antgrid-mcp",
      version: "1.0.0",
      description: "Antgrid session tools",
    },
    [join(pluginDir, ".mcp.json")]: {
      mcpServers: { antgrid: { command: mcpCommand.binary, args: [...mcpCommand.preargs], env: MCP_ENV } },
    },
  });
  return written ? { args: ["--plugin-dir", pluginDir], env: {} } : NO_INJECTION;
}
