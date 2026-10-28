import type { BridgeCommand } from "../hook-command";
import type { McpInjectCtx } from "./types";

export function mcpCommands(ctx: McpInjectCtx): [string, BridgeCommand][] {
  return [
    ["antgrid", ctx.mcpCommand],
    ...(ctx.memoryMcpCommand ? [["antgrid-memory", ctx.memoryMcpCommand] as [string, BridgeCommand]] : []),
  ];
}
