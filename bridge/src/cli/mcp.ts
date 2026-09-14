import { redirectLogsToStderr } from "../logger";

/**
 * The child half of MCP tool support: the bridge re-invoked by the agent it
 * launched, serving the Antgrid tools over stdio for the life of that agent.
 *
 * stdout is the JSON-RPC transport and nothing else may touch it, so the
 * logger is moved to stderr BEFORE the server module loads — a log line
 * emitted at import time would corrupt the very first frame.
 */
export async function runMcpCli(): Promise<void> {
  redirectLogsToStderr();
  const { runMcpStdioServer } = await import("../mcp/server");
  await runMcpStdioServer();
}
