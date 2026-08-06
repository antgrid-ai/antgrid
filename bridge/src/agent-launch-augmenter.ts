import { logger } from "./logger";
const log = logger.child({ component: "agent-launch" });
import { resolveAbDir } from "./antgrid-dir";
import { resolveHookCommand, type HookCommand } from "./hook-command";
import { agentSpec } from "./agents/registry";
import { NO_INJECTION } from "./agents/launch-inject";
import type { LaunchAugmentation } from "./agents/types";

export type { LaunchAugmentation };

/**
 * Whether this agent's injected integration pings /hook-alive at session start,
 * so a terminal that never sees the ping can report the integration as dead.
 */
export function injectsHookAliveProbe(tool: string): boolean {
  return agentSpec(tool)?.hooks?.posts.includes("/hook-alive") === true;
}

/**
 * Per-spawn integration for one agent launch: the argv/env that install its
 * callback channel, plus whatever config or plugin file that channel needs on
 * disk first. Additive only — see each agent's `inject` in agents/<key>/hooks.ts.
 *
 * Fail-open at two levels, and both matter: an agent with no hook profile
 * injects nothing, and an injection that throws degrades to nothing. A session
 * that launches without notifications is recoverable by the OSC scanner; a
 * session that fails to launch is not.
 */
export function augmentAgentLaunch(
  tool: string,
  abDir: string = resolveAbDir(),
  cursorDir?: string,
  hookCommand: HookCommand = resolveHookCommand(),
  geminiConfigDir?: string,
): LaunchAugmentation {
  const inject = agentSpec(tool)?.hooks?.inject;
  if (!inject) return NO_INJECTION;
  try {
    return inject({ abDir, cursorDir, geminiConfigDir, hookCommand });
  } catch (err) {
    log.warn("agent launch augmentation failed for %s: %s", tool, err);
    return NO_INJECTION;
  }
}
