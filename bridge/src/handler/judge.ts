// bridge/src/handler/judge.ts
import { runHeadless } from "../agents/headless";
import type { CapCommand } from "../structured/chat-session";
import {
  buildDecidePrompt, buildRetryPrompt, buildShapeRetryPrompt, parseDecisionFromOutput, pickJudge,
  type HandlerDecision,
} from "./decision";
import type { InstructionItem } from "./backlog";
import { buildExtractPrompt, parseExtractionOutput, type ExtractionResult } from "./extract";

// Eval-only judge override (Task 16's e2e harness): the spawned agent process can't
// have fakes injected in-process, so swap the CLI for a scripted bun script. Gated
// on ANTGRID_EVAL_TEST like the /test/open-pairing-window hook — inert in production.
function resolveCmd(cmd: string[], prompt: string): string[] {
  const script = process.env.ANTGRID_EVAL_TEST === "1" ? process.env.ANTGRID_TEST_JUDGE_SCRIPT : undefined;
  return script ? ["bun", script, prompt] : cmd;
}

// Shared retry-once shape: build prompt → spawn → parse. A parse failure OR a
// caller `retryIf` rejection each earn exactly one re-spawn; the second answer is
// final. Timeout and spawn failure earn none.
//
// Null means ONE thing — no attempt produced a value — because that is what a
// caller reads as a judge outage: HandlerEngine parks the session and re-runs the
// event on it. So a value that PARSED and was then rejected always beats null on
// the way out, on every leg (timeout, spent budget, failed retry spawn); parking
// on it would swallow a decision the caller's own gate would have escalated with
// its text attached. Null is left for a tool with no repo-reach judge, a failed
// spawn, and output that never parsed at all.
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
  // Re-ask once when the parsed value is well-formed JSON but breaks a caller
  // rule the prompt states (a non-null string is that rejection's reason).
  // Deliberately a CALLER hook rather than a rule of this module: the caller's
  // safety verdicts live above this function and must stay unreachable from
  // the retry — a retry loop around a safety verdict is a bypass.
  retryIf?: (value: T) => string | null;
}): Promise<T | null> {
  const spawn = opts.spawn ?? Bun.spawn;
  // Reach first: a transcript-reach judge has no Read tool, so a transcript-path
  // hint would be an instruction it cannot follow. No "repo" entry on the spec
  // means no verified headless judge for this tool — Handler stays
  // escalate-only, and a sealed entry is never promoted into one just because
  // the agent can answer a question (see AgentSpec.headless).
  const judge = pickJudge(opts.tool);
  if (!judge) return null;
  const path = judge.tier === "readonly" ? opts.transcriptPath : undefined;
  // Output is parsed whatever the exit code says: a judge answers in JSON, so a
  // failed run cannot masquerade as a verdict the way a one-line refusal can
  // masquerade as a title (see runHeadless).
  const run = (p: string, timeoutMs: number) => runHeadless(
    resolveCmd(judge.command.cmd(p, opts.model), p),
    {
      cwd: opts.cwd, timeoutMs, spawn,
      env: judge.command.env, scratchEnv: judge.command.scratchEnv,
    },
  );

  const prompt = opts.makePrompt(path);
  const started = Date.now();
  const out1 = await run(prompt, opts.timeoutMs);
  if (out1 === null) return null;
  const r1 = opts.parse(out1.stdout);
  const shapeError = r1.value ? opts.retryIf?.(r1.value) ?? null : null;
  if (r1.value && !shapeError) return r1.value;
  // A shape-rejected value always beats null on the way out: null means "the
  // judge could not run" to every caller, and a caller that parks on an outage
  // would silently swallow a decision its own guards would have escalated with
  // the text attached. Null still comes back where it always did — a first
  // attempt whose output would not parse at all.
  if (out1.timedOut) return r1.value; // hung judge with unusable output: no retry

  // Budget spent by the first attempt is gone; the retry runs only within what
  // remains. If none is left, fail closed rather than start a full second timeout.
  const remaining = opts.timeoutMs - (Date.now() - started);
  if (remaining <= 0) return r1.value;
  const retryPrompt = shapeError
    ? buildShapeRetryPrompt(prompt, shapeError)
    : buildRetryPrompt(prompt, r1.error ?? "invalid output");
  const out2 = await run(retryPrompt, remaining);
  if (out2 === null) return r1.value;
  // Exactly one retry: the second answer is final even if it breaks the same
  // rule, and the caller's own gate escalates it from there.
  return opts.parse(out2.stdout).value ?? r1.value;
}

export async function runDecision(opts: {
  // `tool` is the JUDGE's CLI (a per-session pick may name a different agent
  // from the one being watched); `agentTool` is the agent under supervision,
  // and only the prompt reads it.
  tool: string; model?: string; goal: string; backlogText: string; context: string;
  transcriptPath?: string; cwd: string; timeoutMs?: number; spawn?: typeof Bun.spawn;
  floorWarnings?: string[];
  evidenceRejections?: string[];
  agentTool?: string;
  commands?: CapCommand[];
  retryIfShape?: (decision: HandlerDecision) => string | null;
}): Promise<HandlerDecision | null> {
  return runWithRetry<HandlerDecision>({
    tool: opts.tool, model: opts.model, cwd: opts.cwd,
    timeoutMs: opts.timeoutMs ?? 45_000, spawn: opts.spawn, transcriptPath: opts.transcriptPath,
    retryIf: opts.retryIfShape,
    makePrompt: (path) => buildDecidePrompt({
      goal: opts.goal, backlogText: opts.backlogText, context: opts.context, transcriptPath: path,
      floorWarnings: opts.floorWarnings, evidenceRejections: opts.evidenceRejections,
      agentTool: opts.agentTool, commands: opts.commands,
    }),
    parse: (stdout) => {
      const r = parseDecisionFromOutput(stdout);
      return { value: r.decision, error: r.error };
    },
  });
}

// Deliberately no transcriptPath and no context parameter: extraction reads the
// user's instruction and the list it is already keeping for them, and nothing else
// (spec §3.1) — no transcript, no working tree — so there is no context tier to
// assemble. `backlog` is what lets one sentence take back an earlier one; it is
// rendered under the extractor's own bound (renderAmendable), never whole. The
// budget is well under decide's 45s because this prompt carries no transcript
// excerpt and the arm it feeds is non-blocking (§3.2) — a slower one only widens
// the window in which the backlog is still empty.
export async function runExtraction(opts: {
  tool: string; model?: string; text: string; cwd: string;
  backlog?: InstructionItem[];
  timeoutMs?: number; spawn?: typeof Bun.spawn;
}): Promise<ExtractionResult | null> {
  return runWithRetry<ExtractionResult>({
    tool: opts.tool, model: opts.model, cwd: opts.cwd,
    timeoutMs: opts.timeoutMs ?? 20_000, spawn: opts.spawn,
    makePrompt: () => buildExtractPrompt(opts.text, opts.backlog ?? []),
    parse: (stdout) => {
      const r = parseExtractionOutput(stdout);
      return { value: r.items === null ? null : { items: r.items, amend: r.amend }, error: r.error };
    },
  });
}
