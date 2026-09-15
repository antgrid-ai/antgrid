import { logger, resolveAbDir, resolveHookCommand, agentHost } from "./host";
import type { HookCommand, BridgeCommand } from "./hook-command";
import { agentSpec } from "./agents/registry";
import { NO_INJECTION, NO_OBSERVATION } from "./agents/launch-inject";
import type { AgentSpec, LaunchAugmentation } from "./agents/types";

const log = logger.child({ component: "agent-launch" });
export type { LaunchAugmentation };
export interface AugmentOptions {
  abDir?: string;
  cursorDir?: string;
  geminiConfigDir?: string;
  hookCommand?: HookCommand;
  mcpCommand?: BridgeCommand;
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
  let hooks = NO_INJECTION;
  if (spec.hooks) {
    try {
      const result = spec.hooks.inject({ ...options, abDir, hookCommand: options.hookCommand ?? resolveHookCommand() });
      hooks = { ...result, observation: result.observation ?? (result.notificationsInjected === false ? NO_OBSERVATION : spec.hooks.observation) };
    } catch (err) {
      log.warn("agent hook augmentation failed for %s: %s", tool, err);
    }
  }
  let mcp = NO_INJECTION;
  if (spec.mcp) {
    try {
      const mcpCommand = options.mcpCommand ?? agentHost().mcpCommand?.();
      if (mcpCommand) mcp = spec.mcp.inject({ abDir, mcpCommand });
    } catch (err) {
      log.warn("agent MCP augmentation failed for %s: %s", tool, err);
    }
  }
  return { ...hooks, args: [...hooks.args, ...mcp.args], env: { ...hooks.env, ...mcp.env } };
}
