import { describe, it, expect } from "bun:test";
import { initialPromptArgv } from "../src/initial-prompt";

describe("initialPromptArgv", () => {
  it("positional prompt guarded by `--` for claude-code / codex / cursor-agent", () => {
    // `--` ends option parsing so the prompt is taken positionally. VERIFIED
    // against all three CLIs (commander / clap / commander).
    expect(initialPromptArgv("claude-code", "fix the bug")).toEqual(["--", "fix the bug"]);
    expect(initialPromptArgv("codex", "fix the bug")).toEqual(["--", "fix the bug"]);
    expect(initialPromptArgv("cursor-agent", "fix the bug")).toEqual(["--", "fix the bug"]);
  });

  it("a dash-leading prompt survives as the positional prompt, not a flag", () => {
    // The whole point of the `--` separator: "--fix …" / "-p …" must reach the
    // agent as prompt text, never be consumed as a CLI option.
    expect(initialPromptArgv("claude-code", "--fix the enum")).toEqual(["--", "--fix the enum"]);
    expect(initialPromptArgv("codex", "-p is broken")).toEqual(["--", "-p is broken"]);
    expect(initialPromptArgv("cursor-agent", "--fix the enum")).toEqual(["--", "--fix the enum"]);
  });

  it("--prompt flag for opencode (no `--` — value is flag-consumed)", () => {
    expect(initialPromptArgv("opencode", "fix the bug")).toEqual(["--prompt", "fix the bug"]);
    // A leading-dash prompt is safe as the flag's value; no separator needed.
    expect(initialPromptArgv("opencode", "--fix the enum")).toEqual(["--prompt", "--fix the enum"]);
  });

  it("--prompt-interactive flag for antigravity (Go flag consumes next token)", () => {
    expect(initialPromptArgv("antigravity", "fix the bug")).toEqual(["--prompt-interactive", "fix the bug"]);
    // agy's Go stdlib flag parser takes the next token as the value verbatim, so
    // a leading-dash prompt survives without a `--` separator.
    expect(initialPromptArgv("antigravity", "--fix the enum")).toEqual(["--prompt-interactive", "--fix the enum"]);
  });

  it("empty for unverified tools (github-copilot, unknown)", () => {
    expect(initialPromptArgv("github-copilot", "fix the bug")).toEqual([]);
    expect(initialPromptArgv("some-future-agent", "fix the bug")).toEqual([]);
  });

  it("empty for blank/whitespace prompts", () => {
    expect(initialPromptArgv("claude-code", "")).toEqual([]);
    expect(initialPromptArgv("claude-code", "   ")).toEqual([]);
  });

  it("prompt is one element — newlines and quotes survive verbatim", () => {
    const p = 'line one\nline "two"';
    expect(initialPromptArgv("claude-code", p)).toEqual(["--", p]);
  });
});
