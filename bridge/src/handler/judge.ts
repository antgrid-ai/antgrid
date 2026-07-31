// bridge/src/handler/judge.ts
import { agentSpec } from "../agents/registry";
import {
  buildDecidePrompt, buildRetryPrompt, parseDecisionFromOutput,
  type HandlerDecision,
} from "./decision";
import { buildPlanPrompt, parseBriefFromOutput, type Brief } from "./brief";

// One spawn of the agent's own CLI (reusing its auth). Spawn failure → null.
// A timeout still returns whatever stdout was captured before the kill — the
// CLI may have written a complete answer and merely lingered on exit, so the
// caller parses it before deciding; `timedOut` tells the caller to skip the
// retry leg (retry exists for malformed output, not for a hung judge).
async function spawnJudge(
  cmd: string[], cwd: string, timeoutMs: number, spawn: typeof Bun.spawn,
): Promise<{ stdout: string; timedOut: boolean } | null> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const proc = spawn(cmd, { cwd, stdout: "pipe", stderr: "ignore" });
    let timedOut = false;
    timer = setTimeout(() => {
      timedOut = true;
      try { proc.kill(); } catch { /* already gone */ }
    }, timeoutMs);
    const out = await new Response(proc.stdout).text();
    await proc.exited;
    return { stdout: out, timedOut };
  } catch {
    return null;
  } finally {
    // Must be finally, not a tail call: killing the proc mid-read rejects the
    // stdout read, and an un-cleared timer then stays armed for the full budget
    // holding the dead proc alive — once per judge call, on every failure.
    clearTimeout(timer);
  }
}

// Eval-only judge override (Task 16's e2e harness): the spawned agent process can't
// have fakes injected in-process, so swap the CLI for a scripted bun script. Gated
// on ANTGRID_EVAL_TEST like the /test/open-pairing-window hook — inert in production.
function resolveCmd(cmd: string[], prompt: string): string[] {
  const script = process.env.ANTGRID_EVAL_TEST === "1" ? process.env.ANTGRID_TEST_JUDGE_SCRIPT : undefined;
  return script ? ["bun", script, prompt] : cmd;
}

// Shared retry-once shape: build prompt → spawn → parse; on parse failure re-spawn
// with the validation error appended; second failure fails closed (null). Timeout
// and spawn failure fail closed IMMEDIATELY — no retry.
//
// timeoutMs is a TOTAL budget across both attempts, not per-spawn: the retry gets
// only the time the first attempt left unspent. This keeps worst-case wall time at
// ~timeoutMs so callers can bound the whole call — the app's plan backstop, for
// one, is set just above the bridge's plan timeout on the assumption the bridge
// always resolves first; a per-spawn budget would let a slow-but-malformed first
// attempt push the real total to ~2×timeoutMs and lose that race.
async function runWithRetry<T>(opts: {
  tool: string; model?: string; cwd: string; timeoutMs: number;
  spawn?: typeof Bun.spawn; transcriptPath?: string;
  makePrompt: (transcriptPath?: string) => string;
  parse: (stdout: string) => { value: T | null; error?: string };
}): Promise<T | null> {
  const spawn = opts.spawn ?? Bun.spawn;
  // Tier first: transcript-tier judges have no Read tool, so a transcript-path
  // hint would be an instruction they cannot follow. No judge on the spec means
  // no verified headless judge for this tool — Handler stays escalate-only.
  const judge = agentSpec(opts.tool)?.judge;
  if (!judge) return null;
  const path = judge.tier === "readonly" ? opts.transcriptPath : undefined;

  const prompt = opts.makePrompt(path);
  const started = Date.now();
  const out1 = await spawnJudge(resolveCmd(judge.cmd(prompt, opts.model), prompt), opts.cwd, opts.timeoutMs, spawn);
  if (out1 === null) return null;
  const r1 = opts.parse(out1.stdout);
  if (r1.value) return r1.value;
  if (out1.timedOut) return null; // hung judge with unusable output: no retry

  // Budget spent by the first attempt is gone; the retry runs only within what
  // remains. If none is left, fail closed rather than start a full second timeout.
  const remaining = opts.timeoutMs - (Date.now() - started);
  if (remaining <= 0) return null;
  const retryPrompt = buildRetryPrompt(prompt, r1.error ?? "invalid output");
  const out2 = await spawnJudge(resolveCmd(judge.cmd(retryPrompt, opts.model), retryPrompt), opts.cwd, remaining, spawn);
  if (out2 === null) return null;
  return opts.parse(out2.stdout).value;
}

export async function runDecision(opts: {
  tool: string; model?: string; brief: Brief; ledgerText: string; context: string;
  transcriptPath?: string; cwd: string; timeoutMs?: number; spawn?: typeof Bun.spawn;
}): Promise<HandlerDecision | null> {
  return runWithRetry<HandlerDecision>({
    tool: opts.tool, model: opts.model, cwd: opts.cwd,
    timeoutMs: opts.timeoutMs ?? 45_000, spawn: opts.spawn, transcriptPath: opts.transcriptPath,
    makePrompt: (path) => buildDecidePrompt({
      brief: opts.brief, ledgerText: opts.ledgerText, context: opts.context, transcriptPath: path,
    }),
    parse: (stdout) => {
      const r = parseDecisionFromOutput(stdout);
      return { value: r.decision, error: r.error };
    },
  });
}

/**
 * Budget for a plan call. Measured, not guessed: a real `claude -p` plan over a
 * short context takes ~25s and codex ~17s, and a full PLAN_MAX_CHARS transcript
 * is slower still — the old 25s default put Claude on a coin flip.
 *
 * Keep in lockstep with `_kPlanTimeout` in the app's handler_briefing_sheet.dart,
 * which must stay ABOVE this so the bridge's own fallback result always wins the
 * race and the sheet never gives up first.
 */
export const PLAN_TIMEOUT_MS = 45_000;

export async function runPlan(opts: {
  tool: string; model?: string; context: string; transcriptPath?: string;
  cwd: string; timeoutMs?: number; spawn?: typeof Bun.spawn;
}): Promise<Brief | null> {
  return runWithRetry<Brief>({
    tool: opts.tool, model: opts.model, cwd: opts.cwd,
    timeoutMs: opts.timeoutMs ?? PLAN_TIMEOUT_MS, spawn: opts.spawn, transcriptPath: opts.transcriptPath,
    makePrompt: (path) => buildPlanPrompt(opts.context, path),
    parse: (stdout) => {
      const brief = parseBriefFromOutput(stdout);
      return { value: brief, error: brief ? undefined : "output did not match the brief schema" };
    },
  });
}
