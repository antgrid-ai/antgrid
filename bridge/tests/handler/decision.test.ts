import { describe, it, expect } from "bun:test";
import {
  HandlerDecisionSchema,
  pickJudge,
  buildDecidePrompt,
  buildRetryPrompt,
  parseDecisionFromOutput,
} from "../../src/handler/decision";

const GOAL = "Migrating auth";
const BACKLOG_TEXT = "- id=i1 [queued] run the tests\n- id=i2 [done] update the docs";

describe("decision schema", () => {
  it("accepts a decision reporting transitions", () => {
    const r = HandlerDecisionSchema.safeParse({
      decision: "continue", confidence: 0.9, reason: "progressing",
      transitions: [
        { id: "i1", status: "done", evidence: "3 passed", outcome: "suite green" },
        { id: "i2", status: "active" },
      ],
    });
    expect(r.success).toBe(true);
  });

  it("accepts a decision with no transitions at all", () => {
    const r = HandlerDecisionSchema.safeParse({
      decision: "escalate", confidence: 0.2, reason: "needs the user",
    });
    expect(r.success).toBe(true);
  });

  // A status outside the state machine's vocabulary would be stored verbatim and
  // then match nothing, leaving the item undrivable — so it is refused here, one
  // layer before applyTransitions re-checks the same schema.
  it("rejects a transition carrying an unknown status", () => {
    const r = HandlerDecisionSchema.safeParse({
      decision: "continue", confidence: 0.9, reason: "ok",
      transitions: [{ id: "i1", status: "in_progress" }],
    });
    expect(r.success).toBe(false);
  });

  it("rejects a transition with no id", () => {
    const r = HandlerDecisionSchema.safeParse({
      decision: "continue", confidence: 0.9, reason: "ok",
      transitions: [{ status: "done", evidence: "q" }],
    });
    expect(r.success).toBe(false);
  });
});

describe("pickJudge tiers", () => {
  it("claude-code is readonly with allowed tools pinned", () => {
    const r = pickJudge("claude-code")!;
    expect(r.tier).toBe("readonly");
    expect(r.command.cmd("P")).toContain("--allowedTools");
  });
  // --allowedTools is variadic: a prompt after it is eaten as another tool name
  // and claude exits 1, failing every judge call closed. Position, not presence,
  // is what makes the argv work.
  it("claude-code puts the prompt ahead of the variadic --allowedTools", () => {
    const cmd = pickJudge("claude-code")!.command.cmd("P");
    expect(cmd.indexOf("P")).toBeGreaterThan(-1);
    expect(cmd.indexOf("P")).toBeLessThan(cmd.indexOf("--allowedTools"));
  });
  it("codex is readonly via sandbox", () => {
    const r = pickJudge("codex")!;
    expect(r.tier).toBe("readonly");
    expect(r.command.cmd("P")).toContain("read-only");
  });
  // A project need not be a git repo; without this codex refuses to run at all.
  it("codex skips the git-repo check without weakening the sandbox", () => {
    const r = pickJudge("codex")!;
    expect(r.command.cmd("P")).toContain("--skip-git-repo-check");
    expect(r.command.cmd("P")).toContain("--sandbox");
    expect(r.command.cmd("P")).toContain("read-only");
  });
  // A judge pass is machine bookkeeping, and one runs per agent pause — left
  // persisted they bury the user's own sessions in /resume and `codex exec
  // resume`. Both flags are load-bearing rather than cosmetic, so pin them:
  // dropping one is invisible until someone goes looking for their own work.
  it("claude-code and codex write no session of their own", () => {
    expect(pickJudge("claude-code")!.command.cmd("P")).toContain("--no-session-persistence");
    expect(pickJudge("codex")!.command.cmd("P")).toContain("--ephemeral");
  });

  // opencode has no such flag, so its session store is redirected instead. The
  // DATA dir must NOT move with it: auth.json lives there, so an XDG_DATA_HOME
  // override would hide the session by taking the judge's credentials with it.
  it("opencode redirects its session store without moving its auth", () => {
    const r = pickJudge("opencode")!;
    expect(r.command.env).toEqual({ OPENCODE_DB: ":memory:" });
    expect(Object.keys(r.command.env!)).not.toContain("XDG_DATA_HOME");
  });

  // Only opencode needs one: claude and codex say it in the argv, and an env
  // override there would be a second, quieter place to look for the same rule.
  it("the flag-based judges carry no env override", () => {
    expect(pickJudge("claude-code")!.command.env).toBeUndefined();
    expect(pickJudge("codex")!.command.env).toBeUndefined();
  });

  it("opencode is transcript tier; unknown is null", () => {
    expect(pickJudge("opencode")!.tier).toBe("transcript");
    expect(pickJudge("gemini")).toBeNull();
  });
});

describe("buildDecidePrompt", () => {
  it("embeds the goal, the backlog and the standing rules", () => {
    const p = buildDecidePrompt({ goal: GOAL, backlogText: BACKLOG_TEXT, context: "CTX" });
    expect(p).toContain(GOAL);
    expect(p).toContain(BACKLOG_TEXT);
    expect(p).toContain("CTX");
    expect(p).toContain("transitions");
    expect(p).not.toContain("Fuller transcript");
  });

  // The prompt is belt-and-braces over applyTransitions, but it is the only thing
  // making well-formed output likely: an evaluator that never hears the rules
  // answers in prose and its progress is dropped with nothing explaining why.
  it("states the id bound and the evidence requirement", () => {
    const p = buildDecidePrompt({ goal: GOAL, backlogText: BACKLOG_TEXT, context: "CTX" });
    expect(p).toContain("ONLY the ids listed above");
    expect(p).toContain("evidence");
    for (const status of ["queued", "active", "done", "blocked", "skipped", "failed"]) {
      expect(p).toContain(status);
    }
  });

  it("stands in for an empty goal and an empty backlog rather than rendering nothing", () => {
    const p = buildDecidePrompt({ goal: "", backlogText: "", context: "CTX" });
    expect(p).toContain("(none stated)");
    expect(p).toContain("(no items)");
  });

  it("adds transcript pull-through when a path is given", () => {
    const p = buildDecidePrompt({ goal: GOAL, backlogText: "", context: "CTX", transcriptPath: "/t.jsonl" });
    expect(p).toContain("/t.jsonl");
  });
});

describe("parseDecisionFromOutput", () => {
  it("returns the decision on valid output", () => {
    const out = JSON.stringify({ decision: "continue", confidence: 0.9, reason: "ok" });
    expect(parseDecisionFromOutput(out).decision?.decision).toBe("continue");
  });

  it("carries transitions through from noisy stdout", () => {
    const out = `thinking...\n${JSON.stringify({
      decision: "handle", confidence: 0.8, reason: "answering the prompt",
      reply: "y",
      transitions: [{ id: "i1", status: "done", evidence: "3 passed", outcome: "suite green" }],
    })}\ntrailing prose`;
    const t = parseDecisionFromOutput(out).decision?.transitions;
    expect(t).toEqual([{ id: "i1", status: "done", evidence: "3 passed", outcome: "suite green" }]);
  });

  // A malformed transition sinks the whole decision rather than being dropped from
  // it: the evaluator's verdict and its progress report are one answer, and half
  // of one is not a safer thing to act on.
  it("fails the parse when a transition is malformed", () => {
    const out = JSON.stringify({
      decision: "continue", confidence: 0.9, reason: "ok",
      transitions: [{ id: "i1", status: "nonsense" }],
    });
    const r = parseDecisionFromOutput(out);
    expect(r.decision).toBeNull();
    expect(r.error).toBeTruthy();
  });

  it("returns an error string on schema mismatch for the retry prompt", () => {
    const r = parseDecisionFromOutput('{"decision":"maybe"}');
    expect(r.decision).toBeNull();
    expect(r.error).toBeTruthy();
    expect(buildRetryPrompt("ORIG", r.error!)).toContain("ORIG");
  });
});
