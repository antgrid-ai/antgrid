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

const begin = "# BEGIN ANTGRID KIMI IDENTITY";
const end = "# END ANTGRID KIMI IDENTITY";

// Ours by what it runs rather than by the markers around it: Kimi's own config
// writer drops comments, and a relocated bridge leaves a command naming the
// old binary, which Kimi would otherwise keep running beside the new one.
function isManaged(hook: unknown): boolean {
  const { event, command } = (hook ?? {}) as { event?: unknown; command?: unknown };
  return event === "SessionStart" && typeof command === "string"
    && /(["'])kimi\1\s+(["'])session-start\2\s*$/.test(command);
}

export function inject({ kimiHome, hookCommand }: HookInjectCtx): LaunchAugmentation {
  // Kimi exposes only user-level hooks.
  if (kimiHome === undefined && runningUnderTest()) return NO_INJECTION;
  const path = join(kimiHome ?? process.env.KIMI_CODE_HOME ?? join(homedir(), ".kimi-code"), "config.toml");
  try {
    // Kimi's hook runner uses Node shell:true (cmd.exe on Windows), not
    // PowerShell. Every kimi on the machine runs this hook and waits for it, so
    // outside an Antgrid terminal, where its post would be dropped anyway, the
    // shell skips starting the bridge binary at all.
    const run = hookShellCommand(hookCommand, "kimi", "session-start", { callOperator: false });
    const command = process.platform === "win32"
      ? `if defined ANTGRID_TERMINAL_ID ${run}`
      : `test -z "$ANTGRID_TERMINAL_ID" || ${run}`;
    installManagedTomlHook({ path, begin, end, isManaged, agent: "Kimi", fields: { event: "SessionStart", command, timeout: 5 } });
    return { args: [], env: {}, observation };
  } catch (error) {
    logger.warn("Could not install Kimi session identity hook: %s", error);
    return NO_INJECTION;
  }
}

export const events = ["session-start"] as const;
export const turnBoundaryEvents = { start: [], end: [] } as const;
export const posts = ["/session-title"] as const;
export const observation = { notifications: false, titles: true, handler: false, turnStart: false, turnEnd: false, hookAlive: false } as const;
const Payload = z.object({ session_id: z.string().nullish(), session_title: z.string().nullish() });

export async function toPosts(invocation: HookInvocation, { port, terminalId, readStdin }: HookPostCtx): Promise<HookPost[]> {
  if (invocation.event !== "session-start" || !terminalId) return [];
  const payload = parseOrEmpty(Payload, await readStdin());
  return payload ? compact([titlePost(port, terminalId, payload.session_id, "kimi", payload.session_title ? { title: payload.session_title } : {})]) : [];
}
