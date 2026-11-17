import { redirectLogsToStderr } from "../logger";

export async function runMemoryMcpCli(): Promise<void> {
  redirectLogsToStderr();
  const { runMemoryMcpStdioServer } = await import("../memory-mcp/server");
  await runMemoryMcpStdioServer();
}
