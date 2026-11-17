import { createAgentRuntime } from "antgrid-agents/runtime";
import { builtinRegistry } from "antgrid-agents/builtins";
import { logger } from "./logger";
import { resolveAbDir } from "./antgrid-dir";
import { resolveHookCommand, resolveMcpCommand, resolveMemoryMcpCommand, type ResolveBridgeCommandOptions } from "./hook-command";
import { killChildTree, stripInheritedCertOverrides } from "./terminal-session";

let memoryLaunchGate: () => boolean = () => false;

/** The host that owns the memory store installs this. Until one does, launches get no memory server. */
export function setMemoryLaunchGate(gate: () => boolean): () => void {
  memoryLaunchGate = gate;
  return () => { if (memoryLaunchGate === gate) memoryLaunchGate = () => false; };
}
/** The same gate a launch reads, so a caller asking whether a restart would add Memory agrees with the launch that follows. */
export const memoryLaunchEnabled = (): boolean => memoryLaunchGate();
export const memoryMcpCommandForLaunch = (self?: ResolveBridgeCommandOptions) =>
  memoryLaunchGate() ? resolveMemoryMcpCommand(self) : undefined;

export const agentHostServices = {
  logger,
  stateDirectory: resolveAbDir,
  hookCommand: resolveHookCommand,
  mcpCommand: resolveMcpCommand,
  memoryMcpCommand: () => memoryMcpCommandForLaunch(),
  killChildTree: (child: Parameters<typeof killChildTree>[0]) => killChildTree(child),
  stripInheritedCertOverrides: (env: Record<string, string>) => stripInheritedCertOverrides(env),
};

export const agentRuntime = createAgentRuntime({ registry: builtinRegistry, host: agentHostServices });
