import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { logger } from "../logger";
import { killChildTree, stripInheritedCertOverrides } from "../terminal-session";
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
  // Best effort: a spawn whose cwd does not exist fails, and that failure is
  // already the same null every other headless failure returns. Throwing here
  // would instead reject the caller's promise on a path that has nothing to do
  // with the model call.
  try { mkdirSync(dir, { recursive: true }); } catch { /* the spawn reports it */ }
  return dir;
}

/** How long a killed tree gets to release the stdout pipe before the reads are
 *  abandoned and the timeout is reported on its own. */
const ABANDON_GRACE_MS = 2_000;

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
    /** Env vars to point at a directory created for this spawn and deleted
     *  after it — see HeadlessCommand.scratchEnv. */
    scratchEnv?: string[];
  },
): Promise<HeadlessResult | null> {
  const spawn = opts.spawn ?? Bun.spawn;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let abandonTimer: ReturnType<typeof setTimeout> | undefined;
  const scratch = makeScratchHome(opts.scratchEnv);
  try {
    const proc = spawn(cmd, {
      cwd: opts.cwd, stdout: "pipe", stderr: "ignore",
      env: headlessEnv({ ...opts.env, ...scratch?.env }),
    });
    let timedOut = false;
    // Resolves only if the timeout fires AND the tree kill fails to end the
    // reads below. Nothing here is racing the happy path: on it, this promise
    // is simply never settled and both awaits win outright.
    const abandoned = new Promise<null>((resolve) => {
      timer = setTimeout(() => {
        timedOut = true;
        // The TREE, not the handle. Every one of these argvs is reached through
        // a launcher script, so the handle is a `cmd.exe`/`sh` wrapper and the
        // real agent is its child holding the inherited stdout pipe: killing
        // the wrapper alone leaves that pipe open, `proc.stdout` never reaches
        // EOF, and this call never settles. The judge awaits it with no outer
        // deadline of its own, so that hang wedges a supervised session in
        // "handling" for the life of the process.
        void killChildTree(proc);
        // POSIX cannot reach past the direct child (Bun.spawn starts no process
        // group), so the kill above is a best effort there and this is the
        // backstop that makes the budget an actual bound.
        abandonTimer = setTimeout(() => resolve(null), ABANDON_GRACE_MS);
      }, opts.timeoutMs);
    });
    const stdout = await Promise.race([
      new Response(proc.stdout).text(), abandoned.then(() => ""),
    ]);
    const code = await Promise.race([proc.exited, abandoned]);
    return { stdout, code: timedOut ? null : code, timedOut };
  } catch {
    return null;
  } finally {
    // Must be `finally`, not a tail call: killing the process mid-read rejects
    // the stdout read, and an un-cleared timer then stays armed for the full
    // budget holding the dead process alive.
    clearTimeout(timer);
    clearTimeout(abandonTimer);
    scratch?.dispose();
  }
}

/**
 * A private directory for one spawn's redirected state, or null when the
 * command asked for none.
 *
 * Deleted on the way out, which is the whole point: these vars exist because
 * the CLI has no ephemeral switch, and a fixed path would accumulate a session
 * per call in a temp dir the OS does not reclaim on Windows.
 */
function makeScratchHome(vars?: string[]):
  { env: Record<string, string>; dispose: () => void } | null {
  if (!vars?.length) return null;
  let dir: string;
  try {
    dir = mkdtempSync(join(tmpdir(), "antgrid-headless-"));
  } catch (err) {
    // Falling through to the inherited value would run the spawn against the
    // user's REAL agent home and write a session into their history, which is
    // the one outcome these entries exist to prevent.
    log.warn("no scratch home for a headless spawn: %s", err);
    return null;
  }
  return {
    env: Object.fromEntries(vars.map((name) => [name, dir])),
    dispose: () => {
      // A spawn that outlived its kill still holds its store open, and Windows
      // refuses to unlink an open file. One leaked directory on the timeout
      // path beats throwing from a `finally` that owes the caller a result.
      try { rmSync(dir, { recursive: true, force: true }); } catch { /* leaked */ }
    },
  };
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
