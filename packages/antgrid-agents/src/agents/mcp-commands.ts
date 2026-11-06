import { MEMORY_MCP_SERVER } from "../memory-guidance";
import type { BridgeCommand } from "../hook-command";
import type { McpInjectCtx } from "./types";

export function mcpCommands(ctx: McpInjectCtx): [string, BridgeCommand][] {
  return [
    ["antgrid", ctx.mcpCommand],
    ...(ctx.memoryMcpCommand ? [[MEMORY_MCP_SERVER, ctx.memoryMcpCommand] as [string, BridgeCommand]] : []),
  ];
}
