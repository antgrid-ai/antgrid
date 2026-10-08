import { join } from "node:path";
import { atomicWriteFile } from "../../atomic-file";
import type { BridgeCommand } from "../../hook-command";
import { logger } from "../../host";
import { hasFiles, NO_INJECTION } from "../launch-inject";
import type { LaunchAugmentation, McpInjectCtx } from "../types";
import { cursorSupportsFlag } from "./help";

const log = logger.child({ component: "agent-launch" });

// Cursor strips the environment of an MCP child (measured: the server saw
// roughly 15-18 keys, none of ours) but expands `${env:VAR}` in the entry's
// `env` against its own, so the identity stays symbolic and one plugin serves
// every terminal on the machine.
const MCP_ENV = {
  ANTGRID_API_PORT: "${env:ANTGRID_API_PORT}",
  ANTGRID_TERMINAL_ID: "${env:ANTGRID_TERMINAL_ID}",
} as const;

function materializeCursorMcpPlugin(abDir: string, command: BridgeCommand): string | null {
  const pluginDir = join(abDir, "plugin", "cursor");
  const manifestPath = join(pluginDir, ".cursor-plugin", "plugin.json");
  const mcpPath = join(pluginDir, ".mcp.json");
  try {
    atomicWriteFile(
      manifestPath,
      `${JSON.stringify({ name: "antgrid-mcp", version: "1.0.0", description: "Antgrid session tools" }, null, 2)}\n`,
    );
    atomicWriteFile(
      mcpPath,
      `${JSON.stringify(
        { mcpServers: { antgrid: { command: command.binary, args: [...command.preargs], env: MCP_ENV } } },
        null,
        2,
      )}\n`,
    );
  } catch (err) {
    log.warn("failed to materialize Cursor MCP plugin: %s", err);
  }
  return hasFiles([manifestPath, mcpPath]) ? pluginDir : null;
}

/**
 * `--plugin-dir <dir>` with a plugin that carries only `.mcp.json` (the leading
 * dot is required; `mcp.json` is not loaded) and a `.cursor-plugin/plugin.json`
 * manifest. Cursor has no per-launch MCP flag, and `cursor-agent mcp list` does
 * not show plugin servers. Measured against 2026.10.01: the server starts after
 * workspace trust (the hook profile already passes `--trust`) with no approval
 * prompt, and is spawned twice per launch, which is accepted.
 *
 * The flag is only passed when `--help` lists it, since older builds exit on an
 * unknown option.
 */
export function inject({ abDir, mcpCommand }: McpInjectCtx): LaunchAugmentation {
  if (!cursorSupportsFlag("--plugin-dir")) return NO_INJECTION;
  const pluginDir = materializeCursorMcpPlugin(abDir, mcpCommand);
  return pluginDir ? { args: ["--plugin-dir", pluginDir], env: {} } : NO_INJECTION;
}
