import { mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { logger } from "../logger";
import { stripInheritedCertOverrides } from "../terminal-session";
import { detectInstalledTools } from "../tool-detector";
import { AGENTS, agentSpec } from "./registry";
import { pickHeadlessFrom, type HeadlessCommand, type HeadlessNeed, type HeadlessReach } from "./types";

const log = logger.child({ component: "headless" });

/** The tightest entry this agent declares that still satisfies `need`. */
export function pickHeadless(
  tool: string, need: HeadlessNeed,
): { reach: HeadlessReach; command: HeadlessCommand } | null {
  return pickHeadlessFrom(agentSpec(tool)?.headless, need);
}

/**
 * Which CLI actually runs a `need: "none"` call for a session of `tool`.
 *
 * The session's own agent when it declares a usable entry, else the first
 * INSTALLED agent that does. Borrowing is sound only for this need: the whole
 * job is inlined into the prompt and the spawn gets no repo access, no tools and
 * no transcript path, so nothing about it is specific to the agent whose work is
 * being done. It exists so a one-shot call does not depend on whether a
 * particular vendor's argv has been verified yet.
 *
 * Registry order decides the borrow, so it is stable across runs rather than
 * dependent on PATH order. Null = nothing on this machine can serve it —
 * including for a `tool` that is not a registry key at all, where borrowing
 * would be doing work on behalf of an agent we know nothing about.
 *
 * A `need: "repo"` call is NEVER borrowed. That need is the Handler's judge, and
 * `judgeCapable` gates the whole feature per tool: silently running another
 * vendor's agent there would arm a supervisor the user never chose, over a
 * working tree, on an account they did not pick.
 */
export function resolveHeadless(tool: string, need: HeadlessNeed, installedTools?: string[]):
  { tool: string; reach: HeadlessReach; command: HeadlessCommand } | null {
  const own = pickHeadless(tool, need);
  if (own) return { tool, ...own };
  if (need !== "none" || !agentSpec(tool)) return null;
  const installed = new Set(installedTools ?? detectInstalledTools().map((t) => t.tool));
  for (const key of Object.keys(AGENTS)) {
    if (!installed.has(key)) continue;
    const borrowed = pickHeadless(key, need);
    if (borrowed) return { tool: key, ...borrowed };
  }
  return null;
}

/**
 * The working directory for a `need: "none"` spawn: an empty, throwaway one.
 *
 * These CLIs write a session unconditionally — none of the shipped argvs is
 * `sealed`, and most have no ephemeral switch — but every resume surface worth
 * worrying about is scoped to the working directory (kimi's --continue says so
 * outright; agy's was measured). Running here rather than in the user's checkout
 * means a naming spawn can never surface in the picker they actually use.
 *
 * It is not a sandbox and must not be read as one: the agent keeps whatever
 * tools its argv allows. What changes is that there is nothing here to act on,
 * which is exactly right for a call whose whole input is already in the prompt.
 * Two things fall out for free — the agent finds no repo to read, and no
 * project-tier Antgrid hook config either, closing the one gap headlessEnv
 * cannot reach by unsetting ANTGRID_TERMINAL_ID.
 *
 * Never the checkout: a naming run has no use for the tree, and pointing it
 * there is what put these sessions in the user's own --continue.
 */
export function headlessScratchCwd(): string {
  const dir = join(tmpdir(), "antgrid-headless", "cwd");
  try { mkdirSync(dir, { recursive: true }); } catch { /* falls back below */ }
  return dir;
}

export interface HeadlessResult {
  stdout: string;
  /** Exit code, or null when the process was killed at the timeout. */
  code: number | null;
  timedOut: boolean;
}

/**
 * One spawn of an agent CLI, no retry.
 *
 * Returns whatever was captured even on a non-zero exit or a timeout, and the
 * caller decides: a judge parses partial output because a CLI may write a whole
 * answer and merely linger on exit, while a caller that would accept any short
 * line has to reject a failed run (a refusal like "Invalid API key · Please run
 * /login" is six words and parses as a perfectly good title). Null = the spawn
 * itself failed.
 */
export async function runHeadless(
  cmd: string[],
  opts: {
    cwd: string;
    timeoutMs: number;
    spawn?: typeof Bun.spawn;
    env?: Record<string, string>;
  },
): Promise<HeadlessResult | null> {
  const spawn = opts.spawn ?? Bun.spawn;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const proc = spawn(cmd, {
      cwd: opts.cwd, stdout: "pipe", stderr: "ignore", env: headlessEnv(opts.env),
    });
    let timedOut = false;
    timer = setTimeout(() => {
      timedOut = true;
      try { proc.kill(); } catch { /* already gone */ }
    }, opts.timeoutMs);
    const stdout = await new Response(proc.stdout).text();
    const code = await proc.exited;
    return { stdout, code: timedOut ? null : code, timedOut };
  } catch {
    return null;
  } finally {
    // Must be `finally`, not a tail call: killing the process mid-read rejects
    // the stdout read, and an un-cleared timer then stays armed for the full
    // budget holding the dead process alive.
    clearTimeout(timer);
  }
}

/**
 * The environment a headless spawn runs under.
 *
 * Bun.spawn's `env` REPLACES rather than merges, so this starts from the
 * bridge's own environment — the agent's auth lives there and PATH with it —
 * and edits two things out:
 *
 *   - the inherited TLS/proxy overrides every other agent spawn in the tree
 *     strips, because one inherited from the bridge's launcher breaks the
 *     agent's outbound TLS (see agents/claude-code/spawn.ts).
 *   - ANTGRID_TERMINAL_ID, stripped rather than merely left unset. agy and
 *     opencode install their Antgrid hooks GLOBALLY, so this spawn fires them
 *     too; both no-op without that variable, which is the only thing keeping a
 *     one-shot call from posting /session-title and /notify for a conversation
 *     that does not exist (bridge/plugin/antigravity/post-title.js). It does
 *     NOT silence the project-tier hooks `antgrid plugin install` writes —
 *     those resolve the port from `$ANTGRID_DIR/api.port` when the env is
 *     absent, so a call made inside a project that has them still fires one
 *     (bridge/plugin/hooks/on-stop).
 */
function headlessEnv(overrides?: Record<string, string>): Record<string, string> {
  const { ANTGRID_TERMINAL_ID: _drop, ...inherited } = process.env;
  const env = stripInheritedCertOverrides({ ...inherited } as Record<string, string>);
  return overrides ? { ...env, ...overrides } : env;
}

/** Logs a borrow once per call site that takes one, so a machine naming
 *  everything with one vendor's CLI is visible in the log rather than only in
 *  that vendor's bill. */
export function logBorrow(need: HeadlessNeed, requested: string, actual: string): void {
  if (requested === actual) return;
  log.info("running a %s call for %s with %s (no verified headless argv for %s)",
    need, requested, actual, requested);
}
