import { logger, resolveAbDir, resolveHookCommand, agentHost } from "./host";
import type { HookCommand, BridgeCommand } from "./hook-command";
import { agentSpec } from "./agents/registry";
import { NO_INJECTION, NO_OBSERVATION } from "./agents/launch-inject";
import type { AgentSpec, LaunchAugmentation } from "./agents/types";

const log = logger.child({ component: "agent-launch" });
export type { LaunchAugmentation };
export interface AugmentOptions {
  mode?: "terminal" | "chat";
  abDir?: string;
  cursorDir?: string;
  kimiHome?: string;
  vibeHome?: string;
  geminiConfigDir?: string;
  hookCommand?: HookCommand;
  mcpCommand?: BridgeCommand;
  memoryMcpCommand?: BridgeCommand;
}
export function injectsHookAliveProbe(tool: string): boolean {
  return agentSpec(tool)?.hooks?.observation.hookAlive === true;
}

export function augmentAgentLaunch(
  tool: string,
  options: AugmentOptions = {},
  get: (tool: string) => AgentSpec | undefined = agentSpec,
): LaunchAugmentation {
  const spec = get(tool);
  if (!spec?.hooks && !spec?.mcp) return NO_INJECTION;
  const abDir = options.abDir ?? resolveAbDir();
  let mcp = NO_INJECTION;
  if (spec.mcp) {
    try {
      const mcpCommand = options.mcpCommand ?? agentHost().mcpCommand?.();
      const memoryMcpCommand = options.memoryMcpCommand
        ?? (options.mcpCommand ? undefined : agentHost().memoryMcpCommand?.());
      if (mcpCommand) {
        mcp = spec.mcp.inject({ abDir, mcpCommand, memoryMcpCommand });
        // Guidance is offered only for a server the agent was actually handed:
        // a profile that fails soft (unmergeable config, unwritable file)
        // returns NO_INJECTION and must not leave the agent told about tools
        // it does not have.
        if (mcp !== NO_INJECTION) {
          mcp = memoryMcpCommand ? { ...mcp, env: { ...mcp.env, ANTGRID_MEMORY_MCP: "1" } } : { ...mcp, memoryWithheld: true };
        }
      }
    } catch (err) {
      log.warn("agent MCP augmentation failed for %s: %s", tool, err);
    }
  }
  // MCP runs first so a hook profile can tell whether Memory was registered.
  let hooks = NO_INJECTION;
  if (spec.hooks) {
    try {
      const memoryRegistered = mcp.env.ANTGRID_MEMORY_MCP === "1";
      const result = spec.hooks.inject({ ...options, abDir, hookCommand: options.hookCommand ?? resolveHookCommand(), memoryRegistered });
      hooks = { ...result, observation: result.observation ?? (result.notificationsInjected === false ? NO_OBSERVATION : spec.hooks.observation) };
    } catch (err) {
      log.warn("agent hook augmentation failed for %s: %s", tool, err);
    }
  }
  return {
    ...hooks, args: [...hooks.args, ...mcp.args], env: { ...hooks.env, ...mcp.env },
    ...(mcp.memoryWithheld ? { memoryWithheld: true as const } : {}),
  };
}
