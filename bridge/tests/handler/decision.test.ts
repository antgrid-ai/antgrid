import { describe, it, expect } from "bun:test";
import {
  HandlerDecisionSchema,
  buildJudgeCommand,
  buildDecidePrompt,
  buildRetryPrompt,
  parseDecisionFromOutput,
} from "../../src/handler/decision";

const BRIEF = {
  taskSummary: "Migrating auth", willHandle: ["routine prompts"],
  wakeFor: ["schema changes"], doneWhen: "tests pass", thenItems: ["/compact"],
};

describe("decision schema v2", () => {
  it("accepts satisfiedItems and doneWhenMet", () => {
    const r = HandlerDecisionSchema.safeParse({
      decision: "continue", confidence: 0.9, reason: "progressing",
      satisfiedItems: [{ item: "/compact", evidence: "ran at turn 3" }],
      doneWhenMet: true,
    });
    expect(r.success).toBe(true);
  });
});

describe("buildJudgeCommand tiers", () => {
  it("claude-code is readonly with allowed tools pinned", () => {
    const r = buildJudgeCommand("claude-code", undefined, "P")!;
    expect(r.tier).toBe("readonly");
    expect(r.cmd).toContain("--allowedTools");
  });
  // --allowedTools is variadic: a prompt after it is eaten as another tool name
  // and claude exits 1, failing every judge call closed. Position, not presence,
  // is what makes the argv work.
  it("claude-code puts the prompt ahead of the variadic --allowedTools", () => {
    const r = buildJudgeCommand("claude-code", undefined, "P")!;
    expect(r.cmd.indexOf("P")).toBeGreaterThan(-1);
    expect(r.cmd.indexOf("P")).toBeLessThan(r.cmd.indexOf("--allowedTools"));
  });
  it("codex is readonly via sandbox", () => {
    const r = buildJudgeCommand("codex", undefined, "P")!;
    expect(r.tier).toBe("readonly");
    expect(r.cmd).toContain("read-only");
  });
  // A project need not be a git repo; without this codex refuses to run at all.
  it("codex skips the git-repo check without weakening the sandbox", () => {
    const r = buildJudgeCommand("codex", undefined, "P")!;
    expect(r.cmd).toContain("--skip-git-repo-check");
    expect(r.cmd).toContain("--sandbox");
    expect(r.cmd).toContain("read-only");
  });
  it("opencode is transcript tier; unknown is null", () => {
    expect(buildJudgeCommand("opencode", undefined, "P")!.tier).toBe("transcript");
    expect(buildJudgeCommand("gemini", undefined, "P")).toBeNull();
  });
});

describe("buildDecidePrompt", () => {
  it("embeds brief sections, ledger, and standing rules", () => {
    const p = buildDecidePrompt({ brief: BRIEF, ledgerText: "- [remaining] /compact", context: "CTX" });
    expect(p).toContain("Migrating auth");
    expect(p).toContain("schema changes");
    expect(p).toContain("- [remaining] /compact");
    expect(p).toContain("satisfiedItems");
    expect(p).not.toContain("Fuller transcript");
  });
  it("adds transcript pull-through when a path is given", () => {
    const p = buildDecidePrompt({ brief: BRIEF, ledgerText: "", context: "CTX", transcriptPath: "/t.jsonl" });
    expect(p).toContain("/t.jsonl");
  });
});

describe("parseDecisionFromOutput", () => {
  it("returns the decision on valid output", () => {
    const out = JSON.stringify({ decision: "continue", confidence: 0.9, reason: "ok" });
    expect(parseDecisionFromOutput(out).decision?.decision).toBe("continue");
  });
  it("returns an error string on schema mismatch for the retry prompt", () => {
    const r = parseDecisionFromOutput('{"decision":"maybe"}');
    expect(r.decision).toBeNull();
    expect(r.error).toBeTruthy();
    expect(buildRetryPrompt("ORIG", r.error!)).toContain("ORIG");
  });
});
