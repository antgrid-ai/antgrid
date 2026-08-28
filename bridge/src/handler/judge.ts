// bridge/src/handler/judge.ts
import { agentSpec } from "../agents/registry";
import { runHeadless } from "../agents/headless";
import { pickHeadlessFrom } from "../agents/types";
import {
  buildDecidePrompt, buildRetryPrompt, parseDecisionFromOutput,
  type HandlerDecision,
} from "./decision";
import { buildExtractPrompt, parseItemsFromOutput, type ExtractedItem } from "./extract";

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
// ~timeoutMs, which is what lets a caller racing this against its own deadline
// bound it; a per-spawn budget would let a slow-but-malformed first attempt push
// the real total to ~2×timeoutMs and lose that race.
async function runWithRetry<T>(opts: {
  tool: string; model?: string; cwd: string; timeoutMs: number;
  spawn?: typeof Bun.spawn; transcriptPath?: string;
  makePrompt: (transcriptPath?: string) => string;
  parse: (stdout: string) => { value: T | null; error?: string };
}): Promise<T | null> {
  const spawn = opts.spawn ?? Bun.spawn;
  // Reach first: a transcript-reach judge has no Read tool, so a transcript-path
  // hint would be an instruction it cannot follow. No "repo" entry on the spec
  // means no verified headless judge for this tool — Handler stays
  // escalate-only, and a sealed entry is never promoted into one just because
  // the agent can answer a question (see AgentSpec.headless).
  const judge = pickHeadlessFrom(agentSpec(opts.tool)?.headless, "repo");
  if (!judge || judge.reach === "sealed") return null;
  const path = judge.reach === "readonly" ? opts.transcriptPath : undefined;
  // Output is parsed whatever the exit code says: a judge answers in JSON, so a
  // failed run cannot masquerade as a verdict the way a one-line refusal can
  // masquerade as a title (see runHeadless).
  const run = (p: string, timeoutMs: number) => runHeadless(
    resolveCmd(judge.command.cmd(p, opts.model), p),
    { cwd: opts.cwd, timeoutMs, spawn, env: judge.command.env },
  );

  const prompt = opts.makePrompt(path);
  const started = Date.now();
  const out1 = await run(prompt, opts.timeoutMs);
  if (out1 === null) return null;
  const r1 = opts.parse(out1.stdout);
  if (r1.value) return r1.value;
  if (out1.timedOut) return null; // hung judge with unusable output: no retry

  // Budget spent by the first attempt is gone; the retry runs only within what
  // remains. If none is left, fail closed rather than start a full second timeout.
  const remaining = opts.timeoutMs - (Date.now() - started);
  if (remaining <= 0) return null;
  const retryPrompt = buildRetryPrompt(prompt, r1.error ?? "invalid output");
  const out2 = await run(retryPrompt, remaining);
  if (out2 === null) return null;
  return opts.parse(out2.stdout).value;
}

export async function runDecision(opts: {
  tool: string; model?: string; goal: string; backlogText: string; context: string;
  transcriptPath?: string; cwd: string; timeoutMs?: number; spawn?: typeof Bun.spawn;
  floorWarnings?: string[];
}): Promise<HandlerDecision | null> {
  return runWithRetry<HandlerDecision>({
    tool: opts.tool, model: opts.model, cwd: opts.cwd,
    timeoutMs: opts.timeoutMs ?? 45_000, spawn: opts.spawn, transcriptPath: opts.transcriptPath,
    makePrompt: (path) => buildDecidePrompt({
      goal: opts.goal, backlogText: opts.backlogText, context: opts.context, transcriptPath: path,
      floorWarnings: opts.floorWarnings,
    }),
    parse: (stdout) => {
      const r = parseDecisionFromOutput(stdout);
      return { value: r.decision, error: r.error };
    },
  });
}

// Deliberately no transcriptPath and no context parameter: extraction reads the
// user's instruction and nothing else (spec §3.1), so there is no context tier to
// assemble. The budget is well under decide's 45s because this prompt
// carries no transcript excerpt and the arm it feeds is non-blocking (§3.2) — a
// slower one only widens the window in which the backlog is still empty.
export async function runExtraction(opts: {
  tool: string; model?: string; text: string; cwd: string;
  timeoutMs?: number; spawn?: typeof Bun.spawn;
}): Promise<ExtractedItem[] | null> {
  return runWithRetry<ExtractedItem[]>({
    tool: opts.tool, model: opts.model, cwd: opts.cwd,
    timeoutMs: opts.timeoutMs ?? 20_000, spawn: opts.spawn,
    makePrompt: () => buildExtractPrompt(opts.text),
    parse: (stdout) => {
      const r = parseItemsFromOutput(stdout);
      return { value: r.items, error: r.error };
    },
  });
}
