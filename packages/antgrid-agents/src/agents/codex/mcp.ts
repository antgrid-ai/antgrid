import { toPosixPath } from "./hooks";
import type { LaunchAugmentation, McpInjectCtx } from "../types";

// Codex does NOT pass its own environment down to an MCP server — a probe
// spawned from `codex exec` saw 21 keys and none of ours — so the identity the
// server needs is forwarded by name rather than inherited. Values stay live and
// per-PTY, which is what keeps this override identical for every terminal.
const MCP_ENV_VARS = ["ANTGRID_API_PORT", "ANTGRID_TERMINAL_ID"] as const;

/**
 * `-c mcp_servers.antgrid.*`, which MERGES with the user's own servers rather
 * than replacing them. Values are rendered exactly the way the notify argv is:
 * forward slashes so the TOML parser never sees an escape, then `JSON.stringify`
 * — a valid TOML basic string for the command and a valid TOML array for the
 * rest. (`tomlBasicString` is for the hooks path, which hand-escapes a command
 * already rendered as a shell line.)
 */
export function inject({ mcpCommand }: McpInjectCtx): LaunchAugmentation {
  const command = JSON.stringify(toPosixPath(mcpCommand.binary));
  const args = JSON.stringify(mcpCommand.preargs.map(toPosixPath));
  return {
    args: [
      "-c", `mcp_servers.antgrid.command=${command}`,
      "-c", `mcp_servers.antgrid.args=${args}`,
      "-c", `mcp_servers.antgrid.env_vars=${JSON.stringify(MCP_ENV_VARS)}`,
    ],
    env: {},
  };
}
