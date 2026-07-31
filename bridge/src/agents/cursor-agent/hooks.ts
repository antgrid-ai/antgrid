import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import { atomicWriteFile } from "../../discovery";
import type { HookCommand } from "../../hook-command";
import { logger } from "../../logger";
import { compact, parseOrEmpty, titlePost, type HookInvocation, type HookPost } from "../hook-posts";
import type { HookInjectCtx, HookPostCtx, LaunchAugmentation } from "../types";
import {
  managedCursorCommands,
  replaceManagedCursorHookEntries,
} from "./global-hooks";

const log = logger.child({ component: "agent-launch" });

// Memoized once per process: cursor-agent builds predating --trust hard-exit
// on the unknown option (commander), which would kill every spawn on that
// machine. An inconclusive probe (binary not on PATH, empty/failed --help)
// counts as support: current builds have the flag, and a missing binary fails
// the spawn regardless of argv.
let cursorTrustSupported: boolean | null = null;
function cursorSupportsTrust(): boolean {
  if (cursorTrustSupported !== null) return cursorTrustSupported;
  try {
    const bin = Bun.which("cursor-agent");
    if (bin) {
      const res = spawnSync(bin, ["--help"], { timeout: 3000, encoding: "utf8" });
      const help = `${res.stdout ?? ""}\n${res.stderr ?? ""}`;
      if (help.trim().length > 0) {
        cursorTrustSupported = help.includes("--trust");
        return cursorTrustSupported;
      }
    }
  } catch (err) {
    log.warn("cursor-agent --trust probe failed, assuming support: %s", err);
  }
  cursorTrustSupported = true;
  return cursorTrustSupported;
}

// The user-tier file (~/.cursor/hooks.json) is cursor-agent's only workable
// injection point: hook tiers MERGE (enterprise→team→project→user, nothing
// overrides), and --plugin-dir cannot carry hooks — plugin hooks are
// discovery-only in current builds (PluginHooksService has no callers; verified
// against build 2026.07.16 — the flag delivers skills/commands/MCP only).
// Machine-global is safe because unrelated cursor-agent runs fast-exit: the
// hook posts nothing without ANTGRID_API_PORT in its environment, which only
// bridge-spawned PTYs carry (see hook-runner.ts resolvePort), so a run outside
// the bridge costs one short-lived process and no stdin wait.
function ensureGlobalCursorHooks(
  command: HookCommand,
  cursorDir?: string,
): boolean {
  if (cursorDir === undefined) {
    // Structural guard, not a convention: under `bun test` Bun.main is the
    // TEST FILE, so a default-resolved hook command is junk — refuse to write
    // it into the developer's real ~/.cursor. Tests exercising the write path
    // inject an isolated cursorDir, which skips this guard.
    if (/\.(test|spec)\.[cm]?[jt]sx?$/.test(Bun.main)) return false;
    cursorDir = join(homedir(), ".cursor");
  }
  const hooksPath = join(cursorDir, "hooks.json");
  const commands = managedCursorCommands(command);
  try {
    let data: any = {};
    if (existsSync(hooksPath)) {
      const content = readFileSync(hooksPath, "utf8").trim();
      if (content) {
        const parsed = JSON.parse(content);
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
          data = parsed;
        }
      }
    }
    const replaced = replaceManagedCursorHookEntries(data, commands);
    if (replaced === null) return true;
    atomicWriteFile(hooksPath, `${JSON.stringify(replaced, null, 2)}\n`);
    return true;
  } catch (err) {
    log.warn("failed to write global cursor hooks.json (%s): %s", hooksPath, err);
    return false;
  }
}

export function inject({ cursorDir, hookCommand }: HookInjectCtx): LaunchAugmentation {
  const notificationsInjected = ensureGlobalCursorHooks(hookCommand, cursorDir);
  // --trust: cursor-agent gates hooks (and project config) behind
  // workspace trust — an untrusted dir prompts in the TUI and exits 1
  // headless, before any hook runs. Opening a project in the bridge IS
  // the user's trust decision, so pre-trust rather than re-asking.
  return {
    args: cursorSupportsTrust() ? ["--trust"] : [],
    env: {},
    notificationsInjected,
  };
}

const SessionPayloadSchema = z.object({
  session_id: z.string().nullish(),
  transcript_path: z.string().nullish(),
});

const CursorStopPayloadSchema = z.object({ status: z.string().nullish() });

export const events = ["session-start", "stop"] as const;

export async function toPosts(
  invocation: HookInvocation,
  { port, terminalId, readStdin }: HookPostCtx,
): Promise<HookPost[]> {
  const posts: Array<HookPost | null> = [];
  const raw = await readStdin();
  if (invocation.event === "session-start") {
    const input = parseOrEmpty(SessionPayloadSchema, raw);
    if (!input) return [];
    posts.push(titlePost(port, terminalId, input.session_id, "cursor"));
  } else {
    const input = parseOrEmpty(CursorStopPayloadSchema, raw);
    if (input?.status === "completed" && terminalId) {
      posts.push({ port, path: "/notify", body: { type: "task_complete", terminalId } });
    }
  }

  return compact(posts);
}
