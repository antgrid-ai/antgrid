import { describe, it, expect } from "bun:test";
import { mapToolKind, mapAssistantContent, mapUsage, mapResultError, addUsage } from "../src/agents/claude-code/mapping";

describe("mapToolKind", () => {
  it("maps known Claude Code tools to toolKinds", () => {
    expect(mapToolKind("Bash")).toBe("shell");
    expect(mapToolKind("Edit")).toBe("edit");
    expect(mapToolKind("Write")).toBe("edit");
    expect(mapToolKind("MultiEdit")).toBe("edit");
    expect(mapToolKind("Read")).toBe("read");
    expect(mapToolKind("Grep")).toBe("search");
    expect(mapToolKind("Glob")).toBe("search");
    expect(mapToolKind("mcp__foo__bar")).toBe("mcp");
    expect(mapToolKind("SomethingNew")).toBe("other");
  });
});

describe("mapAssistantContent", () => {
  it("splits text, thinking, and tool_use blocks", () => {
    const r = mapAssistantContent([
      { type: "text", text: "hello " },
      { type: "text", text: "world" },
      { type: "thinking", thinking: "hmm" },
      { type: "tool_use", id: "t1", name: "Bash", input: { command: "ls" } },
    ]);
    expect(r.text).toBe("hello world");
    expect(r.thinking).toBe("hmm");
    expect(r.toolUses).toEqual([{ id: "t1", name: "Bash", input: { command: "ls" } }]);
  });
});

describe("mapUsage", () => {
  it("renames SDK usage fields to AgentUsage fields", () => {
    const u = mapUsage({
      input_tokens: 10, output_tokens: 5,
      cache_read_input_tokens: 2, cache_creation_input_tokens: 3,
    });
    expect(u).toEqual({
      inputTokens: 10, outputTokens: 5, cacheReadTokens: 2, cacheWriteTokens: 3,
      totalTokens: 15,
    });
  });
});

describe("mapResultError", () => {
  // SDKResultError carries `errors: string[]`, not `result` (that field only
  // exists on SDKResultSuccess) — joining errors is the actual failure reason.
  it("joins non-empty errors into the message", () => {
    const e = mapResultError({ type: "result", subtype: "error_max_turns", is_error: true, errors: ["boom"] });
    expect(e.category).toBe("unknown");
    expect(e.retryable).toBe(false);
    expect(e.message).toContain("boom");
  });

  it("falls back to the generic subtype message when errors is empty/missing", () => {
    const withEmpty = mapResultError({ type: "result", subtype: "error_max_turns", is_error: true, errors: [] });
    expect(withEmpty.message).toBe("turn failed (error_max_turns)");
    const withMissing = mapResultError({ type: "result", subtype: "error_during_execution", is_error: true });
    expect(withMissing.message).toBe("turn failed (error_during_execution)");
  });
});

describe("addUsage", () => {
  it("adds each field explicitly onto the running total", () => {
    const total = { inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 4, totalTokens: 3 };
    addUsage(total, { inputTokens: 10, outputTokens: 20, cacheReadTokens: 30, cacheWriteTokens: 40, totalTokens: 30 });
    expect(total).toEqual({ inputTokens: 11, outputTokens: 22, cacheReadTokens: 33, cacheWriteTokens: 44, totalTokens: 33 });
  });
});
