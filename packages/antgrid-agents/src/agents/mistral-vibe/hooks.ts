import { homedir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import { hookShellCommand } from "../../hook-command";
import { logger } from "../../host";
import { compact, parseOrEmpty, titlePost, type HookInvocation, type HookPost } from "../hook-posts";
import { NO_INJECTION } from "../launch-inject";
import { runningUnderTest } from "../test-runner";
import { installManagedTomlHook } from "../toml-hooks";
import type { HookInjectCtx, HookPostCtx, LaunchAugmentation } from "../types";

const begin = "# BEGIN ANTGRID VIBE IDENTITY";
const end = "# END ANTGRID VIBE IDENTITY";
// Vibe drops a second hook that reuses a name, so ours is fixed and distinctive.
const HOOK_NAME = "antgrid-identity";

// Ours by what it runs, for the same reasons as Kimi's: a relocated bridge
// leaves a command naming the old binary that Vibe would keep running.
function isManaged(hook: unknown): boolean {
  const { type, command } = (hook ?? {}) as { type?: unknown; command?: unknown };
  return type === "post_agent" && typeof command === "string"
    && /(["'])mistral-vibe\1\s+(["'])post-agent\2\s*$/.test(command);
}

export function inject({ vibeHome, hookCommand }: HookInjectCtx): LaunchAugmentation {
  // The user-level file is the only one Vibe reads outside a trusted project,
  // so test launches must never install their test-runner command into it.
  if (vibeHome === undefined && runningUnderTest()) return NO_INJECTION;
  const path = join(vibeHome ?? process.env.VIBE_HOME ?? join(homedir(), ".vibe"), "hooks.toml");
  try {
    // Vibe runs the command through create_subprocess_shell (cmd.exe on Windows,
    // sh elsewhere), and every vibe on the machine runs it, so outside an
    // Antgrid terminal the shell skips starting the bridge binary at all.
    const run = hookShellCommand(hookCommand, "mistral-vibe", "post-agent", { callOperator: false });
    const command = process.platform === "win32"
      ? `if defined ANTGRID_TERMINAL_ID ${run}`
      : `test -z "$ANTGRID_TERMINAL_ID" || ${run}`;
    installManagedTomlHook({ path, begin, end, isManaged, agent: "Vibe", fields: { name: HOOK_NAME, type: "post_agent", command, timeout: 5 } });
    return { args: [], env: {}, observation };
  } catch (error) {
    logger.warn("Could not install Vibe session identity hook: %s", error);
    return NO_INJECTION;
  }
}

export const events = ["post-agent"] as const;
export const turnBoundaryEvents = { start: [], end: [] } as const;
export const posts = ["/session-title"] as const;
export const observation = { notifications: false, titles: true, handler: false, turnStart: false, turnEnd: false, hookAlive: false } as const;
const Payload = z.object({ session_id: z.string().nullish(), transcript_path: z.string().nullish() });
// A subagent's loop runs its own post_agent hooks with its log at
// <parent session>/agents/<child>/messages.jsonl; recording that identity would
// replace the parent's. Only that position counts, since a home or save dir can
// have an agents directory higher up.
const SUBAGENT_LOG = /[\\/]agents[\\/][^\\/]+[\\/][^\\/]+$/;

export async function toPosts(invocation: HookInvocation, { port, terminalId, readStdin }: HookPostCtx): Promise<HookPost[]> {
  if (invocation.event !== "post-agent" || !terminalId) return [];
  const payload = parseOrEmpty(Payload, await readStdin());
  if (!payload || (payload.transcript_path && SUBAGENT_LOG.test(payload.transcript_path))) return [];
  return compact([titlePost(port, terminalId, payload.session_id, "mistral-vibe", payload.transcript_path ? { transcriptPath: payload.transcript_path } : {})]);
}
