// bridge/tests/modelwatch-taps.test.ts
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { createHash } from "node:crypto";

import { runHeadless } from "../src/agents/headless";
import { generateTitleFromContext, type TitleGeneration } from "../src/agents/title-generate";
import type { TitleOutcome } from "../src/agents/title-attempts";
import { runDecision, runExtraction } from "../src/handler/judge";
import {
  armContextCapture, armPromptCapture, modelwatch, __resetModelwatchForTest,
  type ModelCallContext, type ModelCallEvent,
} from "../src/modelwatch";

// The suite shares one module cache across spec files, so an arm left standing
// by any file — this one included — would decide whether the next file's calls
// carry prompt text, and the whole suite would pass or fail on file order. The
// `afterEach` is what makes that true of the LAST test here: `beforeEach` only
// protects this file from its predecessors, and the arms below outlive it by ten
// seconds of wall clock, which is long enough to reach the handler and title
// suites that spawn judges of their own.
beforeEach(() => { __resetModelwatchForTest(); });
afterEach(() => { __resetModelwatchForTest(); });

const GOOD_DECISION = JSON.stringify({ decision: "continue", confidence: 0.9, reason: "ok" });
const GOOD_EXTRACTION = JSON.stringify({ items: [{ ref: "r1", text: "run the tests" }] });

/**
 * Stands in for Bun.spawn: replays one scripted answer per attempt, and can
 * make an attempt take real time.
 *
 * The delay is not decoration. A judge's two attempts share ONE budget, so the
 * retry leg only differs from the first attempt when the first spent something
 * — a spawn that answers instantly hands the retry the whole budget back and
 * the record it produces cannot tell a starved retry from a fresh call.
 */
function scriptedSpawn(steps: Array<{ stdout: string; delayMs?: number; exitCode?: number }>) {
  const calls: string[][] = [];
  const spawn = ((cmd: string[]) => {
    const step = steps[Math.min(calls.length, steps.length - 1)]!;
    calls.push(cmd);
    const delay = step.delayMs ?? 0;
    return {
      stdout: new ReadableStream<Uint8Array>({
        start(c) {
          setTimeout(() => {
            c.enqueue(new TextEncoder().encode(step.stdout));
            c.close();
          }, delay);
        },
      }),
      exited: new Promise<number>((r) => setTimeout(() => r(step.exitCode ?? 0), delay)),
      kill() { /* nothing to kill */ },
    };
  }) as unknown as typeof Bun.spawn;
  return { spawn, calls };
}

const events = () => modelwatch.snapshot();
const phases = () => events().map((e) => `${e.phase}:${e.attempt}`);
const ends = () => events().filter((e) => e.phase === "end");
const outcomes = () => events().filter((e) => e.phase === "outcome");
const sha256 = (text: string) => createHash("sha256").update(text).digest("hex");
/** Everything the ring holds, as one string — what a leak test searches. */
const ringText = () => JSON.stringify(events());

function ctx(over: Partial<ModelCallContext> = {}): ModelCallContext {
  return {
    callId: "call-1", purpose: "title", attempt: 1,
    requestedTool: "kimi", actualTool: "claude-code", reach: "sealed",
    ...over,
  };
}

describe("a judge retry, recorded per attempt", () => {
  /**
   * The measurement the whole recorder was built to make.
   *
   * `runWithRetry` splits one budget across both attempts, so a first attempt
   * that is merely slow can leave the second structurally dead — and nothing
   * on the machine says so today, because a retry is invisible upstream: both
   * attempts collapse into one verdict or one null. Two `end` records under one
   * callId, the second bounded by what the first left, is what turns that from
   * a suspicion into a number.
   */
  it("emits two end records under one callId, the second bounded by what the first left", async () => {
    const BUDGET_MS = 2_000;
    const BURNED_MS = 900;
    const { spawn, calls } = scriptedSpawn([
      { stdout: "not a decision at all", delayMs: BURNED_MS },
      { stdout: GOOD_DECISION, delayMs: 5 },
    ]);

    const decision = await runDecision({
      tool: "claude-code", goal: "migrate the auth module", backlogText: "",
      context: "C", cwd: ".", timeoutMs: BUDGET_MS, spawn,
    });

    expect(decision?.decision).toBe("continue");
    expect(calls).toHaveLength(2);
    expect(phases()).toEqual([
      "start:1", "end:1", "outcome:1", "start:2", "end:2", "outcome:2",
    ]);
    expect(new Set(events().map((e) => e.callId)).size).toBe(1);

    const [first, second] = ends();
    expect(first!.budgetMs).toBe(BUDGET_MS);
    // The first attempt really did burn the budget — without this the retry
    // could be shrinking for no reason and the assertion below proves nothing.
    expect(first!.wallMs).toBeGreaterThanOrEqual(BURNED_MS - 20);
    expect(second!.budgetMs).toBeLessThanOrEqual(BUDGET_MS - BURNED_MS);
    expect(second!.budgetMs).toBeGreaterThan(0);

    // The join that makes the shrink attributable: what attempt 1 reported
    // leaving is exactly what attempt 2 was held to.
    const rejected = outcomes().find((e) => e.attempt === 1)!;
    expect(rejected.outcome).toBe("unparsed");
    expect(rejected.remainingMs).toBe(second!.budgetMs);
    expect(outcomes().find((e) => e.attempt === 2)!.outcome).toBe("retried-parsed");
  });

  // A retry that carries its own id is indistinguishable in the record from two
  // unrelated calls that happened to land together, so the id is the feature.
  it("keeps the retry's attribution identical to the first attempt's", async () => {
    const { spawn } = scriptedSpawn([{ stdout: "garbage" }, { stdout: "still garbage" }]);
    await runDecision({
      tool: "claude-code", goal: "g", backlogText: "", context: "C", cwd: ".", spawn,
    });

    const attribution = events().map((e) => [
      e.callId, e.purpose, e.requestedTool, e.actualTool, e.reach,
    ].join("|"));
    expect(new Set(attribution).size).toBe(1);
    // A `need: "repo"` call is never borrowed, so these two are equal by
    // construction — an inequality here would mean a judge ran on an account
    // the user did not choose for this session.
    expect(events()[0]!.requestedTool).toBe(events()[0]!.actualTool);
  });

  // The one leg with no spawn behind it, and the only record with no start or
  // end to join to: naming a tier would name one that never ran.
  it("records a lone outcome for a tool no judge serves", async () => {
    const decision = await runDecision({
      tool: "kimi", goal: "g", backlogText: "", context: "C", cwd: ".",
    });

    expect(decision).toBeNull();
    expect(events()).toHaveLength(1);
    expect(events()[0]).toMatchObject({
      phase: "outcome", attempt: 1, purpose: "decision",
      outcome: "no-judge", reach: "unavailable",
    });
  });

  // Nothing inside runWithRetry can tell its two callers apart — they differ
  // only in the prompt they build and the shape they parse — so the purpose is
  // the caller's word and a wrong one files a call under the wrong work.
  it("files an extraction under its own purpose", async () => {
    const { spawn } = scriptedSpawn([{ stdout: GOOD_EXTRACTION }]);
    const extracted = await runExtraction({
      tool: "claude-code", text: "run the tests", cwd: ".", spawn,
    });

    expect(extracted?.items).toHaveLength(1);
    expect(events().map((e) => e.purpose)).toEqual(["extraction", "extraction", "extraction"]);
  });
});

describe("a naming call, recorded against the session it names", () => {
  it("records a start and an end under the callId it hands back", async () => {
    const { spawn } = scriptedSpawn([{ stdout: "Add retry to uploader\n" }]);
    const result = await generateTitleFromContext("please add a retry", {
      tool: "claude-code", terminalId: "t-42", spawn, installedTools: ["claude-code"],
    });

    expect(result.ok).toBe(true);
    expect(phases()).toEqual(["start:1", "end:1"]);
    // The ref is the whole reason generateTitleFromContext returns a record
    // rather than a bare title: the caller's verdict arrives tens of seconds
    // later and has nothing else to file itself against.
    expect(new Set(events().map((e) => e.callId))).toEqual(new Set([result.callId]));
    expect(events()[0]).toMatchObject({
      purpose: "title", attempt: 1, terminalId: "t-42",
      requestedTool: "claude-code", actualTool: "claude-code",
    });
    expect(ends()[0]!.exitCode).toBe(0);
    expect(ends()[0]!.timedOut).toBe(false);
  });

  /**
   * F8, made countable. `need: "none"` takes whichever installed agent can
   * serve it and registry order puts Claude first, so on a machine with Claude
   * installed every borrowed title is billed to the Claude account — under a
   * session the user is running on something else entirely. A record that
   * carried only the session's own agent would file that bill to the vendor
   * that never ran.
   */
  it("names both the agent asked for and the one that was billed, on a borrow", async () => {
    const { spawn, calls } = scriptedSpawn([{ stdout: "Ship the parser\n" }]);
    const result = await generateTitleFromContext("do a thing", {
      tool: "kimi", spawn, installedTools: ["claude-code"],
    });

    expect(result.ok).toBe(true);
    expect(calls[0]![0]).toBe("claude");
    for (const e of events()) {
      expect(e.requestedTool).toBe("kimi");
      expect(e.actualTool).toBe("claude-code");
      expect(e.requestedTool).not.toBe(e.actualTool);
    }
    expect(result.actualTool).toBe("claude-code");
  });

  /**
   * agent-core's `maybeGenerateTitle` records the verdict in its own `finally`,
   * built from the ref the generation handed back. That closure takes no spawn
   * seam, so driving it from a test would put a real CLI spawn — a real billed
   * model call — in the suite. What is exercised here instead is the contract
   * it rests on: EVERY arm of TitleGeneration, and so every TitleOutcome,
   * carries a ref that files against the spawn's own records.
   */
  function recordOutcome(tool: string, result: TitleGeneration, outcome: TitleOutcome): void {
    modelwatch.record({
      callId: result.callId, phase: "outcome", purpose: "title", attempt: 1,
      requestedTool: tool, actualTool: result.actualTool, reach: result.reach,
      terminalId: "t-42", outcome,
    });
  }

  it("gives a named title a verdict joined to the spawn that produced it", async () => {
    const { spawn } = scriptedSpawn([{ stdout: "Add retry to uploader\n" }]);
    const result = await generateTitleFromContext("please add a retry", {
      tool: "claude-code", terminalId: "t-42", spawn, installedTools: ["claude-code"],
    });
    recordOutcome("claude-code", result, "named");

    expect(phases()).toEqual(["start:1", "end:1", "outcome:1"]);
    expect(new Set(events().map((e) => e.callId)).size).toBe(1);
    expect(outcomes()[0]!.outcome).toBe("named");
  });

  it("gives a spawn that answered nothing usable the same join", async () => {
    // A refusal printed to stdout on a non-zero exit — six words that clear
    // every one of parseTitleFromOutput's checks and would otherwise name the
    // session for good.
    const { spawn } = scriptedSpawn([{ stdout: "Invalid API key\n", exitCode: 1 }]);
    const result = await generateTitleFromContext("please add a retry", {
      tool: "claude-code", terminalId: "t-42", spawn, installedTools: ["claude-code"],
    });
    expect(result).toMatchObject({ ok: false, reason: "failed" });
    recordOutcome("claude-code", result, "failed");

    expect(phases()).toEqual(["start:1", "end:1", "outcome:1"]);
    expect(ends()[0]!.exitCode).toBe(1);
    expect(outcomes()[0]!.callId).toBe(events()[0]!.callId);
  });

  /**
   * The verdict nothing else on the machine counts: the spawn ran, was paid
   * for, produced a perfectly good title, and the caller threw it away because
   * the user renamed the session or started a new conversation while the model
   * was running. Upstream it is indistinguishable from a call that never
   * happened — `settle` records nothing for it — so this record is the only
   * place the waste is visible.
   */
  it("records an abandoned title against the call that was paid for anyway", async () => {
    const { spawn } = scriptedSpawn([{ stdout: "Add retry to uploader\n" }]);
    const result = await generateTitleFromContext("please add a retry", {
      tool: "claude-code", terminalId: "t-42", spawn, installedTools: ["claude-code"],
    });
    expect(result.ok).toBe(true);
    recordOutcome("claude-code", result, "abandoned");

    expect(phases()).toEqual(["start:1", "end:1", "outcome:1"]);
    expect(outcomes()[0]!.outcome).toBe("abandoned");
    // A spawn ran and exited cleanly, which is what makes this outcome worth a
    // record rather than a silence.
    expect(ends()[0]!.exitCode).toBe(0);
  });

  it("still hands back a ref when nothing on the machine could serve the call", async () => {
    const { spawn, calls } = scriptedSpawn([{ stdout: "unused" }]);
    const result = await generateTitleFromContext("do a thing", {
      tool: "kimi", terminalId: "t-42", spawn, installedTools: [],
    });

    expect(result).toMatchObject({ ok: false, reason: "unavailable", reach: "none" });
    expect(calls).toHaveLength(0);
    recordOutcome("kimi", result, "unavailable");
    // No spawn to join to, and a callId all the same — an outcome with no
    // matching start is how a reader tells "nothing could run" apart from
    // "something ran and failed".
    expect(events()).toHaveLength(1);
    expect(events()[0]).toMatchObject({ phase: "outcome", outcome: "unavailable" });
  });
});

describe("a caller that names no call", () => {
  // The parameter is additive or it is a second thing every existing call site
  // has to get right. Every other spawn in the tree passes none.
  it("records nothing, and gets the answer it always got", async () => {
    const bare = await runHeadless(["agent", "--print", "hello?"], {
      cwd: ".", timeoutMs: 1_000, spawn: scriptedSpawn([{ stdout: "hi\n" }]).spawn,
    });

    expect(bare).toEqual({ stdout: "hi\n", code: 0, timedOut: false });
    expect(modelwatch.recorded).toBe(0);

    const watched = await runHeadless(["agent", "--print", "hello?"], {
      cwd: ".", timeoutMs: 1_000, spawn: scriptedSpawn([{ stdout: "hi\n" }]).spawn, call: ctx(),
    });
    expect(watched).toEqual(bare);
    expect(modelwatch.recorded).toBe(2);
  });
});

describe("a spawn that never ran", () => {
  /**
   * Upstream this null is the same value an unparseable answer returns, so a
   * machine where the CLI is not on PATH looks exactly like one whose judge
   * talks nonsense. The code is what separates them — and it is recorded
   * instead of the message because a runtime's spawn-failure text is free to
   * quote the command it could not run, and that command's tail is the prompt.
   */
  it("is named by its code, never by the message that quotes the argv", async () => {
    const SECRET = "SENTINEL-ARGV-9f3a21";
    const spawn = (() => {
      const err = new Error(`spawn ENOENT: agent --print ${SECRET}`) as Error & { code?: string };
      err.code = "ENOENT";
      throw err;
    }) as unknown as typeof Bun.spawn;

    const result = await runHeadless(["agent", "--print", SECRET], {
      cwd: ".", timeoutMs: 1_000, spawn, call: ctx(),
    });

    expect(result).toBeNull();
    expect(phases()).toEqual(["start:1", "end:1"]);
    expect(ends()[0]).toMatchObject({
      exitCode: null, timedOut: false, stdoutChars: 0,
      outcome: "spawn-failed", outcomeDetail: "ENOENT",
    });
    expect(ringText()).not.toContain(SECRET);
  });
});

describe("what the ring holds with nothing armed", () => {
  /**
   * Every string a recorded event may hold, and how long it may be.
   *
   * An allowlist rather than a check on the two fields we happen to remember:
   * the default is that nothing the user typed, nothing the agent read back at
   * them and nothing the model answered reaches the ring, and a field added to
   * ModelCallEvent without thought is not in this table — so it fails here
   * rather than shipping capture nobody asked for. The lengths are the second
   * half of the same rule: a known field widened into carrying text is the
   * other way this default is lost.
   */
  const ALLOWED_STRINGS: Record<string, number> = {
    callId: 64, phase: 16, purpose: 16,
    requestedTool: 64, actualTool: 64, reach: 32,
    requestedModel: 64, actualModel: 64,
    terminalId: 128, conversationId: 128, projectId: 128,
    outcome: 32,
    // The parser's own diagnostic about a shape it rejected — a Zod issue list,
    // which the parsers cap at 500 before it ever reaches here.
    outcomeDetail: 512,
    // The vendor tag on `usage.money`, which is a unit and never an amount.
    unit: 32,
  };

  function walkStrings(value: unknown, path: string, fail: (why: string) => void): void {
    if (typeof value === "string") {
      const field = path.slice(path.lastIndexOf(".") + 1);
      const max = ALLOWED_STRINGS[field];
      if (max === undefined) fail(`${path} holds text and is not a known metadata field`);
      else if (value.length > max) fail(`${path} holds ${value.length} chars, past the ${max} a ${field} may carry`);
      return;
    }
    if (Array.isArray(value)) {
      value.forEach((item, i) => walkStrings(item, `${path}[${i}]`, fail));
      return;
    }
    if (value && typeof value === "object") {
      for (const [k, v] of Object.entries(value)) walkStrings(v, `${path}.${k}`, fail);
    }
  }

  const NEEDLES = {
    transcript: "SENTINEL-TRANSCRIPT-4c81ea",
    goal: "SENTINEL-GOAL-7b32dd",
    backlog: "SENTINEL-BACKLOG-19af60",
    answer: "SENTINEL-ANSWER-e502cb",
    argv: "SENTINEL-ARGV-a7710f",
  };

  /** Every tap, driven once, each carrying a sentinel a leak would surface. */
  async function driveEveryTap(): Promise<void> {
    await generateTitleFromContext(NEEDLES.transcript, {
      tool: "claude-code", terminalId: "t-42", installedTools: ["claude-code"],
      spawn: scriptedSpawn([{ stdout: `${NEEDLES.answer}\n` }]).spawn,
    });
    await runDecision({
      tool: "claude-code", goal: NEEDLES.goal, backlogText: NEEDLES.backlog,
      context: NEEDLES.transcript, cwd: ".",
      spawn: scriptedSpawn([{ stdout: NEEDLES.answer }]).spawn,
    });
    await runExtraction({
      tool: "claude-code", text: NEEDLES.goal, cwd: ".",
      spawn: scriptedSpawn([{ stdout: GOOD_EXTRACTION }]).spawn,
    });
    await runDecision({ tool: "kimi", goal: NEEDLES.goal, backlogText: "", context: "C", cwd: "." });
    await runHeadless(["agent", "--print", NEEDLES.argv], {
      cwd: ".", timeoutMs: 1_000, call: ctx(),
      spawn: (() => { throw Object.assign(new Error(NEEDLES.argv), { code: "ENOENT" }); }) as unknown as typeof Bun.spawn,
    });
  }

  it("holds metadata and nothing else, on every field of every event", async () => {
    await driveEveryTap();

    // Guards the assertions below against a refactor that quietly stops
    // recording: an empty ring satisfies every rule in this test.
    expect(events().length).toBeGreaterThan(10);

    const problems: string[] = [];
    for (const event of events()) walkStrings(event, `#${event.seq}`, (why) => problems.push(why));
    expect(problems).toEqual([]);
  });

  it("carries no prompt, no transcript, no answer and no argv element", async () => {
    await driveEveryTap();

    for (const [part, needle] of Object.entries(NEEDLES)) {
      expect(`${part}: ${ringText().includes(needle)}`).toBe(`${part}: false`);
    }
    for (const event of events() as ModelCallEvent[]) {
      expect(event.prompt).toBeUndefined();
      expect(event.stdout).toBeUndefined();
    }
    // The counts stay, which is the point of a default that redacts rather than
    // one that records nothing: a call is still measurable while unreadable.
    expect(events().find((e) => e.phase === "start")!.promptChars).toBeGreaterThan(0);
    expect(events().find((e) => e.phase === "end")!.stdoutChars).toBeGreaterThan(0);
  });
});

describe("what each arm admits, through the taps", () => {
  const TRANSCRIPT = "user: please add a retry\nassistant: on it";
  const ANSWER = "Add retry to uploader\n";

  async function nameASession() {
    return generateTitleFromContext(TRANSCRIPT, {
      tool: "claude-code", terminalId: "t-42", installedTools: ["claude-code"],
      spawn: scriptedSpawn([{ stdout: ANSWER }]).spawn,
    });
  }

  it("gives the scaffold verbatim and the session's own words as a digest", async () => {
    armPromptCapture(true, 10_000);
    await nameASession();

    const prompt = events()[0]!.prompt!;
    // Ours, so it is safe verbatim — and it is the part worth reading, since a
    // title that came back malformed is usually the scaffold's fault.
    expect(prompt.scaffold).toContain("Reply with a title for the session's overall task");
    // The excerpt is identified without being read. The digest is what answers
    // "was this the same context as the previous attempt" with nothing to leak.
    expect(prompt.context).toEqual({ sha256: sha256(TRANSCRIPT), chars: TRANSCRIPT.length });
    expect(prompt.contextText).toBeUndefined();
    expect(ringText()).not.toContain(TRANSCRIPT);
    // The answer rides the context arm, not this one: a model can quote its
    // input back, and the decide prompt REQUIRES it to.
    expect(ends()[0]!.stdout).toBeUndefined();
  });

  /**
   * The way the context arm is got around without ever being armed.
   *
   * `buildDecidePrompt` requires every transition to `done`, `skipped` or
   * `failed` to carry "a short verbatim quote copied character-for-character out
   * of the RECENT CONTEXT block", and the harness discards a paraphrase — so a
   * judge that obeys answers with the excerpt inside it. An `.env` the agent
   * cat'd reaches the ring through the model's own reply, under the arm whose
   * documented promise is a digest and never the text.
   */
  it("withholds an answer that quotes the context, under the prompt arm alone", async () => {
    const SECRET = "AWS_SECRET_ACCESS_KEY=not-a-real-key";
    armPromptCapture(true, 10_000);
    const quoted = JSON.stringify({
      decision: "continue", confidence: 0.9, reason: "ok",
      transitions: [{ id: "i1", status: "done", evidence: SECRET }],
    });
    await runDecision({
      tool: "claude-code", goal: "g", backlogText: "",
      context: `$ cat .env\n${SECRET}`, cwd: ".",
      spawn: scriptedSpawn([{ stdout: quoted }]).spawn,
    });

    expect(ends()[0]!.stdout).toBeUndefined();
    expect(ringText()).not.toContain(SECRET);
    // The call stays measurable while unreadable, which is what a redacting
    // default buys over one that records nothing.
    expect(ends()[0]!.stdoutChars).toBe(quoted.length);
  });

  // Arming the dangerous one alone must not become a way around the first
  // decision — it says nothing about the prompt arm, in either direction.
  it("admits nothing under the context arm alone", async () => {
    armContextCapture(true, 10_000);
    await nameASession();

    expect(events()[0]!.prompt).toBeUndefined();
    expect(ends()[0]!.stdout).toBeUndefined();
    expect(ringText()).not.toContain(TRANSCRIPT);
  });

  it("admits the excerpt itself only when both arms are up", async () => {
    armPromptCapture(true, 10_000);
    armContextCapture(true, 10_000);
    await nameASession();

    const prompt = events()[0]!.prompt!;
    expect(prompt.contextText).toBe(TRANSCRIPT);
    expect(prompt.context!.sha256).toBe(sha256(TRANSCRIPT));
  });

  it("holds a judge's goal but only the size of the backlog", async () => {
    const GOAL = "migrate the auth module";
    const BACKLOG = "- id=i1 [queued] SENTINEL-BACKLOG-19af60";
    armPromptCapture(true, 10_000);
    const { spawn } = scriptedSpawn([{ stdout: GOOD_DECISION }]);
    await runDecision({
      tool: "claude-code", goal: GOAL, backlogText: BACKLOG, context: "the transcript",
      cwd: ".", spawn,
    });

    const prompt = events()[0]!.prompt!;
    // Short, user-authored and the one line that says what the session is for.
    expect(prompt.goal).toBe(GOAL);
    // The user's own words to their agent: counted, never quoted.
    expect(prompt.backlogChars).toBe(BACKLOG.length);
    expect(ringText()).not.toContain(BACKLOG);
    expect(prompt.contextText).toBeUndefined();
  });

  // Both attempts of one call are captured, so a retry's record is as readable
  // as the first attempt's — and the reason for the retry is the previous
  // attempt's own outcome rather than a second copy of the prompt.
  it("captures both attempts of a retried call", async () => {
    armPromptCapture(true, 10_000);
    // Both arms, because reading the two answers back is the point here and an
    // answer is admitted by the decision that admits the context it may quote.
    armContextCapture(true, 10_000);
    const { spawn } = scriptedSpawn([{ stdout: "garbage" }, { stdout: GOOD_DECISION }]);
    await runDecision({
      tool: "claude-code", goal: "migrate the auth module", backlogText: "",
      context: "the transcript", cwd: ".", spawn,
    });

    const starts = events().filter((e) => e.phase === "start");
    expect(starts.map((e) => e.attempt)).toEqual([1, 2]);
    expect(starts[1]!.prompt?.goal).toBe(starts[0]!.prompt?.goal);
    expect(ends()[0]!.stdout).toBe("garbage");
    expect(ends()[1]!.stdout).toBe(GOOD_DECISION);
  });
});
