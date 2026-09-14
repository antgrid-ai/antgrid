import { logger } from "./logger";
const log = logger.child({ component: "agent-launch" });
import { resolveAbDir } from "./antgrid-dir";
import {
  resolveHookCommand,
  resolveMcpCommand,
  type ResolveBridgeCommandOptions,
} from "./hook-command";
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
 * Per-spawn inputs. `abDir` is an option rather than a resolved default at the
 * call site because SessionManager launches against its own storeDir.
 *
 * `self` is deliberately ONE decision covering every way the bridge re-enters
 * itself: the hook command and the MCP command are both derived from it, so a
 * spawn cannot carry a compiled hook alongside a dev-mode MCP server.
 */
export interface AugmentOptions {
  abDir?: string;
  /** Overrides the machine-global `~/.cursor` that only cursor-agent writes into. */
  cursorDir?: string;
  /** Overrides the machine-global `~/.gemini/config` that only antigravity
   *  writes into. Test seam, same role as `cursorDir`. */
  geminiConfigDir?: string;
  self?: ResolveBridgeCommandOptions;
}

function injectOrNothing(
  tool: string,
  kind: string,
  run: () => LaunchAugmentation | undefined,
): LaunchAugmentation {
  try {
    return run() ?? NO_INJECTION;
  } catch (err) {
    log.warn("agent %s augmentation failed for %s: %s", kind, tool, err);
    return NO_INJECTION;
  }
}

/**
 * Per-spawn integration for one agent launch: the argv/env that install its
 * callback channel and its Antgrid MCP server, plus whatever config or plugin
 * file either needs on disk first. Additive only — see each agent's `inject` in
 * agents/<key>/hooks.ts and agents/<key>/mcp.ts.
 *
 * Fail-open at two levels, and both matter: an agent with no profile injects
 * nothing, and an injection that throws degrades to nothing. A session that
 * launches without notifications is recoverable by the OSC scanner and one
 * without tools is recoverable by hand; a session that fails to launch is not.
 *
 * The two profiles are composed independently so an MCP failure can never cost
 * the hook injection. `notificationsInjected` stays the hook profile's answer
 * alone — MCP has no bearing on whether the OSC scanner is still needed.
 */
export function augmentAgentLaunch(
  tool: string,
  { abDir = resolveAbDir(), cursorDir, geminiConfigDir, self }: AugmentOptions = {},
): LaunchAugmentation {
  const spec = agentSpec(tool);
  if (!spec?.hooks && !spec?.mcp) return NO_INJECTION;
  const hookAug = injectOrNothing(tool, "hook", () =>
    spec.hooks?.inject({
      abDir,
      cursorDir,
      geminiConfigDir,
      hookCommand: resolveHookCommand(self),
    }),
  );
  // Last, so claude's argv reads `--plugin-dir <dir> --mcp-config=<file>`.
  const mcpAug = injectOrNothing(tool, "mcp", () =>
    spec.mcp?.inject({ abDir, mcpCommand: resolveMcpCommand(self) }),
  );
  const merged: LaunchAugmentation = {
    args: [...hookAug.args, ...mcpAug.args],
    env: { ...hookAug.env, ...mcpAug.env },
  };
  if (hookAug.notificationsInjected !== undefined) {
    merged.notificationsInjected = hookAug.notificationsInjected;
  }
  return merged;
}
