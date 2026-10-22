import { describe, expect, it } from "bun:test";
import { HANDOFF_PROMPT_MAX, handoffPrompt } from "../src/handoff/handoff-prompt";
import { isAntgridHandoffPrompt } from "antgrid-agents/handoff";

const base = {
  sourceLabel: "Claude Code",
  excerptPath: "/work/app/.antgrid/handoff/abc/excerpt.md",
  rawPath: "/work/app/.antgrid/handoff/abc/claude-code.jsonl",
};
const hasControl = (text: string) => /[\x00-\x1f\x7f-\x9f]/.test(text);

describe("handoffPrompt", () => {
  it("is one line with absolute paths, under the cap, and says data and git status", () => {
    const prompt = handoffPrompt(base);
    expect(prompt.length).toBeLessThan(HANDOFF_PROMPT_MAX);
    expect(prompt).not.toContain("\n");
    expect(prompt).toContain(base.excerptPath);
    expect(prompt).toContain(base.rawPath);
    expect(prompt).toContain("not instructions");
    expect(prompt).toContain("git status");
    expect(prompt).toContain("without redoing work");
    expect(prompt).not.toContain("Additional instruction");
  });

  it("is recognised as a handoff prompt by the excerpt parsers", () => {
    expect(isAntgridHandoffPrompt(handoffPrompt(base))).toBe(true);
  });

  it("removes control characters and never emits one", () => {
    const prompt = handoffPrompt({
      sourceLabel: "Cl\x1b[31maude\r\n\0",
      excerptPath: "/w/\x85ex\x07cerpt.md",
      rawPath: "/w/raw\x7f.jsonl",
      extra: "do\nthis\r\n\tnow\x1b\x9b",
    });
    expect(hasControl(prompt)).toBe(false);
    expect(prompt).toContain("Additional instruction: do this now");
  });

  it("carries a checkout path containing %PATH% literally", () => {
    const prompt = handoffPrompt({ ...base, excerptPath: "C:\\work\\%PATH%\\excerpt.md" });
    expect(prompt).toContain("C:\\work\\%PATH%\\excerpt.md");
  });

  it("truncates an over-long extra to fit instead of refusing", () => {
    const prompt = handoffPrompt({ ...base, extra: "x".repeat(5_000) });
    expect(prompt.length).toBeLessThanOrEqual(HANDOFF_PROMPT_MAX);
    expect(prompt.endsWith("…")).toBe(true);
    expect(prompt).toContain("Additional instruction: xxx");
  });

  it("does not split a surrogate pair when truncating", () => {
    for (let pad = 0; pad < 2; pad++) {
      const prompt = handoffPrompt({ ...base, extra: `${"y".repeat(pad)}${"\u{1F600}".repeat(2_000)}` });
      expect(prompt.length).toBeLessThanOrEqual(HANDOFF_PROMPT_MAX);
      expect(/[\ud800-\udbff]…$/.test(prompt)).toBe(false);
    }
  });

  it("refuses only when the fixed text and paths alone do not fit", () => {
    expect(() => handoffPrompt({ ...base, rawPath: `/${"p".repeat(1_600)}` })).toThrow("too long");
  });
});
