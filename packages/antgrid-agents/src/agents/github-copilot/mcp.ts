import { join } from "node:path";
import { atomicWriteFile } from "../../atomic-file";
import { logger } from "../../host";
import { toPosixPath } from "../codex/hooks";
import { hasFiles, NO_INJECTION } from "../launch-inject";
import type { LaunchAugmentation, McpInjectCtx } from "../types";

const log = logger.child({ component: "agent-launch" });

/**
 * `--additional-mcp-config @<file>`, which augments `~/.copilot/mcp-config.json`
 * and the workspace `.mcp.json` for this session only. A file rather than the
 * inline-JSON form so no quote in the entry ever has to survive the shell line
 * the session's argv is rendered into; forward slashes because that is the form
 * measured.
 *
 * Measured against copilot 1.0.93: the server is spawned at startup, before the
 * folder-trust prompt, with copilot's whole environment. That is the MCP host,
 * not the plugin host that runs our hooks, so the env loss noted there does not
 * apply. `tools: ["*"]` because copilot exposes none of a server's tools
 * without an allowlist.
 *
 * Deliberately NOT under `<abDir>/plugin/copilot`: the hooks already pass that
 * tree via `--plugin-dir`, and a `.mcp.json` inside it would register the
 * server a second time.
 */
export function inject({ abDir, mcpCommand }: McpInjectCtx): LaunchAugmentation {
  const configPath = join(abDir, "mcp", "copilot.json");
  const config = {
    mcpServers: {
      antgrid: { type: "local", command: mcpCommand.binary, args: [...mcpCommand.preargs], tools: ["*"] },
    },
  };
  try {
    atomicWriteFile(configPath, `${JSON.stringify(config, null, 2)}\n`);
  } catch (err) {
    log.warn("failed to materialize Copilot MCP config: %s", err);
  }
  if (!hasFiles([configPath])) return NO_INJECTION;
  return { args: ["--additional-mcp-config", `@${toPosixPath(configPath)}`], env: {} };
}
