import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { atomicWriteFile } from "../../discovery";
import { logger } from "../../logger";
import type { HookPost } from "../hook-posts";
import type { HookInjectCtx, LaunchAugmentation } from "../types";
import {
  antigravityHookCommand,
  antigravityScriptPath,
  mergeAntigravityHookEntries,
} from "./global-hooks";

const log = logger.child({ component: "agent-launch" });

/**
 * Appends `x509usefallbackroots=1` to an inherited GODEBUG value (or sets it
 * fresh) without clobbering the user's own GODEBUG settings — GODEBUG entries
 * are comma-separated. This is Go's own documented escape hatch for "the
 * platform cert store can't be read/is incomplete for this process": it makes
 * crypto/x509 fall back to Go's bundled Mozilla root CA list instead of
 * depending on a successful Windows CryptoAPI system-store lookup. Targeted at
 * `agy`, a Go binary: confirmed A/B that its OAuth/eligibility HTTPS calls fail
 * `tls: ... certificate signed by unknown authority` against every
 * googleapis.com host when spawned through antgrid's terminal chain, while the
 * identical binary run outside that chain (same user/machine/token) succeeds —
 * narrowing it to the system-store lookup itself failing for this spawn
 * context, for a reason that isn't SSL_CERT_* / proxy env vars, ConPTY
 * direct-vs-cmd.exe-mediated parentage, or a hosts-file override (all ruled
 * out). No-op for a non-Go binary that doesn't read GODEBUG.
 */
function withFallbackRoots(existing: string | undefined): string {
  const flag = "x509usefallbackroots=1";
  if (!existing) return flag;
  const entries = existing.split(",").map((e) => e.trim()).filter(Boolean);
  return entries.some((e) => e.startsWith("x509usefallbackroots="))
    ? existing
    : `${existing},${flag}`;
}

/**
 * Idempotently merges our PreInvocation (conversation id + transcript path, for
 * title/resume) and Stop (title refresh + task-complete notify) hooks into the
 * GLOBAL `~/.gemini/config/hooks.json`. PreInvocation fires on every turn
 * (including the first), forwarding the conversation id + transcript path as
 * soon as they exist — more robust than a SessionStart-style one-shot hook for a
 * `--conversation <id>`-resumed session, which may not re-fire a "session start"
 * event.
 *
 * agy has no per-spawn hook flag (no `--plugin-dir` like claude-code/copilot, no
 * `-c` like codex) — confirmed against a real install: its `plugin` subcommand
 * installs into its own store, but the simpler and more directly verified path
 * is the one cursor-agent uses, merging into the tool's own GLOBAL hooks.json.
 * The global file is used so we never write into the opened project's own repo.
 * Safe for the user's own (non-bridge) agy runs because the hook script
 * self-gates on ANTGRID_TERMINAL_ID/ANTGRID_API_PORT, which only a
 * bridge-spawned PTY sets. Additive: any other hook groups already in the file
 * are preserved. No-ops / never throws so a read-only home doesn't block the
 * launch. `geminiConfigDir` is injectable for tests; production always resolves
 * to `~/.gemini/config`.
 *
 * Returns whether the hooks are (now, or already) present, mirroring
 * ensureGlobalCursorHooks's contract — false means the write failed, so the
 * caller must not suppress the OSC fallback for this spawn.
 */
export function ensureAntigravityHook(
  geminiConfigDir: string = join(homedir(), ".gemini", "config"),
): boolean {
  const hooksPath = join(geminiConfigDir, "hooks.json");
  try {
    const scriptPath = antigravityScriptPath();
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
    const merged = mergeAntigravityHookEntries(data, [
      { event: "PreInvocation", command: antigravityHookCommand(scriptPath, "PreInvocation") },
      { event: "Stop", command: antigravityHookCommand(scriptPath, "Stop") },
    ]);
    if (merged === null) return true; // both hooks already present
    atomicWriteFile(hooksPath, `${JSON.stringify(merged, null, 2)}\n`);
    return true;
  } catch (err) {
    log.warn("failed to write global antigravity hooks.json (%s): %s", hooksPath, err);
    return false;
  }
}

export function inject({ geminiConfigDir }: HookInjectCtx): LaunchAugmentation {
  const notificationsInjected = ensureAntigravityHook(geminiConfigDir);
  return {
    args: [],
    env: { GODEBUG: withFallbackRoots(process.env.GODEBUG) },
    notificationsInjected,
  };
}

// Empty on purpose: the injected hook runs under bare `node` and POSTs to the
// loopback API itself (see plugin/antigravity/post-title.js), so agy never
// shells out to `bridge hook` and has no event for the runner to allowlist.
export const events = [] as const;

// Empty for the same reason `events` is: agy's Stop hook posts its turn-end
// straight to the loopback API, so nothing passes through `bridge hook` that
// could close an inferred turn. Keystroke turn-start inference stays off.
export const turnBoundaryEvents = {
  start: [],
  end: [],
} as const;

// Posted by bridge/plugin/antigravity/post-title.js under bare `node`, not by
// `toPosts` — which is why this list is not derivable from `events`. No
// /handler-event: the script posts none, so an armed Handler cannot observe an
// antigravity TERMINAL session (handlerObservable answers false).
export const posts = ["/session-title", "/notify"] as const;

// Unreachable while `events` is empty — hook-runner drops every invocation at
// the allowlist check before dispatch. Present so the profile stays one shape
// across agents.
export async function toPosts(): Promise<HookPost[]> {
  return [];
}
