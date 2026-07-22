import { describe, it, expect } from "bun:test";
import { isChatCapableTool } from "../src/structured/chat-capable";

describe("isChatCapableTool", () => {
  it("is true for codex, opencode, and claude-code", () => {
    expect(isChatCapableTool("codex")).toBe(true);
    expect(isChatCapableTool("opencode")).toBe(true);
    expect(isChatCapableTool("claude-code")).toBe(true);
  });
  it("is false for other/absent tools", () => {
    for (const t of ["github-copilot", "cursor-agent", undefined, ""]) {
      expect(isChatCapableTool(t as string | undefined)).toBe(false);
    }
  });
});
