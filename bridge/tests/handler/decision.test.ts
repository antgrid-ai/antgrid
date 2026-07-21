import { test, expect } from "bun:test";
import { buildJudgeCommand, parseDecisionFromOutput, buildJudgePrompt } from "../../src/handler/decision";

test("buildJudgeCommand maps the three supported tools", () => {
  expect(buildJudgeCommand("claude-code", "haiku", "PROMPT")).toEqual(["claude", "-p", "--model", "haiku", "PROMPT"]);
  expect(buildJudgeCommand("codex", undefined, "PROMPT")).toEqual(["codex", "exec", "PROMPT"]);
  expect(buildJudgeCommand("opencode", "grok", "PROMPT")).toEqual(["opencode", "run", "--model", "grok", "PROMPT"]);
});

test("buildJudgeCommand returns null for unsupported tools", () => {
  expect(buildJudgeCommand("cursor-agent", undefined, "P")).toBeNull();
});

test("parseDecisionFromOutput extracts the JSON object amid noise", () => {
  const out = "thinking...\n{\"decision\":\"handle\",\"confidence\":0.9,\"reason\":\"clear\",\"reply\":\"use bun\"}\nbye";
  const d = parseDecisionFromOutput(out);
  expect(d).not.toBeNull();
  expect(d!.decision).toBe("handle");
  expect(d!.reply).toBe("use bun");
});

test("parseDecisionFromOutput returns null on no/invalid JSON", () => {
  expect(parseDecisionFromOutput("no json here")).toBeNull();
  expect(parseDecisionFromOutput("{\"decision\":\"banana\"}")).toBeNull();
});

test("buildJudgePrompt embeds guidance and context", () => {
  const p = buildJudgePrompt("ESCALATE WHEN UNSURE", "AGENT ASKED X");
  expect(p).toContain("ESCALATE WHEN UNSURE");
  expect(p).toContain("AGENT ASKED X");
  expect(p).toContain("\"decision\"");
});
