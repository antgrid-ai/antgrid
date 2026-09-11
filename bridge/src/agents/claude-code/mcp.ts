import { join } from "node:path";
import { atomicWriteFile } from "../../discovery";
import type { BridgeCommand } from "../../hook-command";
import { logger } from "../../logger";
import { hasFiles, NO_INJECTION } from "../launch-inject";
import type { LaunchAugmentation, McpInjectCtx } from "../types";

const log = logger.child({ component: "agent-launch" });

// Claude expands `${VAR}` in an MCP entry's `env` against its OWN environment
// at spawn time, so the port and terminal id stay symbolic here and one file
// serves every terminal on the machine. An unset variable can arrive as the
// literal `${…}`, which the server's numeric guard already reads as absent.
const MCP_ENV = {
  ANTGRID_API_PORT: "${ANTGRID_API_PORT}",
  ANTGRID_TERMINAL_ID: "${ANTGRID_TERMINAL_ID}",
} as const;

// Deliberately NOT under `<abDir>/plugin/claude`: `--plugin-dir` also loads a
// `.mcp.json` sitting in the plugin tree, and the server would then register
// twice — once as `antgrid`, once as `plugin:antgrid-session-namer:antgrid`.
function materializeClaudeMcpConfig(
  abDir: string,
  command: BridgeCommand,
): string | null {
  const configPath = join(abDir, "mcp", "claude.json");
  const config = {
    mcpServers: {
      // The same server key `plugin/setup.ts` writes, so the two entries a user
      // with both can end up holding are argv-identical rather than rival.
      antgrid: {
        type: "stdio",
        command: command.binary,
        args: [...command.preargs],
        env: MCP_ENV,
      },
    },
  };
  try {
    atomicWriteFile(configPath, `${JSON.stringify(config, null, 2)}\n`);
  } catch (err) {
    log.warn("failed to materialize Claude MCP config: %s", err);
  }
  return hasFiles([configPath]) ? configPath : null;
}

// `--mcp-config` and never `--strict-mcp-config`: the strict form would drop
// every server the user configured for themselves.
//
// ONE token, `--mcp-config=<path>`, because the flag is VARIADIC: measured
// against the installed CLI, `--mcp-config cfg.json mcp list` reads `mcp` and
// `list` as two more config paths and dies, while `--mcp-config=cfg.json mcp
// list` loads the file and leaves the rest alone. A session's own args are
// folded in right after this pair (session-manager's shell line), so the
// separated form would hand the user's first word to us as a config path.
export function inject({ abDir, mcpCommand }: McpInjectCtx): LaunchAugmentation {
  const configPath = materializeClaudeMcpConfig(abDir, mcpCommand);
  return configPath ? { args: [`--mcp-config=${configPath}`], env: {} } : NO_INJECTION;
}
