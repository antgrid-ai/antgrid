import { createAgentRuntime } from "antgrid-agents/runtime";
import { builtinRegistry } from "antgrid-agents/builtins";
import { logger } from "./logger";
import { resolveAbDir } from "./antgrid-dir";
import { resolveHookCommand, resolveMcpCommand } from "./hook-command";
import { killChildTree, stripInheritedCertOverrides } from "./terminal-session";

export const agentHostServices = {
  logger,
  stateDirectory: resolveAbDir,
  hookCommand: resolveHookCommand,
  mcpCommand: resolveMcpCommand,
  killChildTree: (child: Parameters<typeof killChildTree>[0]) => killChildTree(child),
  stripInheritedCertOverrides: (env: Record<string, string>) => stripInheritedCertOverrides(env),
};

export const agentRuntime = createAgentRuntime({ registry: builtinRegistry, host: agentHostServices });
