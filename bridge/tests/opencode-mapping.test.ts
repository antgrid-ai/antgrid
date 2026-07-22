import { describe, it, expect } from "bun:test";
import { mapPart, mapPlanEntries, mapTokens, mapOpencodeError, toolKind } from "../src/opencode/opencode-mapping";

describe("opencode-mapping", () => {
  it("maps a text part to a message item with role", () => {
    const item = mapPart({ id: "p1", type: "text", text: "hello", messageID: "m1" }, "assistant");
    expect(item).toEqual({
      itemId: "p1",
      kind: "message",
      role: "assistant",
      text: "hello",
      revertTarget: { messageId: "m1", partId: "p1" },
    });
  });

  it("maps a reasoning part", () => {
    const item = mapPart({ id: "p2", type: "reasoning", text: "thinking" });
    expect(item?.kind).toBe("reasoning");
    expect(item?.text).toBe("thinking");
  });

  it("maps a completed shell tool to a tool_call with terminal content", () => {
    const item = mapPart({ id: "t1", type: "tool", tool: "bash", state: { status: "completed", title: "ls", output: "a\nb\n", input: { command: "ls" } } });
    expect(item?.kind).toBe("tool_call");
    expect(item?.toolKind).toBe("shell");
    expect(item?.status).toBe("completed");
    expect(item?.content?.[0]).toEqual({ type: "terminal", data: "a\nb\n" });
  });

  it("maps an errored tool to status error with an AgentError", () => {
    const item = mapPart({ id: "t2", type: "tool", tool: "edit", state: { status: "error", error: { name: "ProviderAuthError", data: { message: "401" } } } });
    expect(item?.status).toBe("error");
    expect(item?.error?.category).toBe("auth");
    expect(item?.toolKind).toBe("edit");
  });

  it("maps a patch part to an edit tool_call with diff content per file", () => {
    const item = mapPart({ id: "pp", type: "patch", files: ["a.ts", "b.ts"] });
    expect(item?.toolKind).toBe("edit");
    expect(item?.content?.map((c) => (c as { path?: string }).path)).toEqual(["a.ts", "b.ts"]);
    expect(item?.content?.[0].type).toBe("diff");
  });

  it("maps a compaction part", () => {
    expect(mapPart({ id: "c1", type: "compaction", auto: true })?.kind).toBe("compaction");
  });

  it("ignores file/agent/subtask/step parts", () => {
    for (const type of ["file", "agent", "subtask", "step-start", "step-finish", "snapshot", "retry"]) {
      expect(mapPart({ id: "x", type })).toBeNull();
    }
  });

  it("derives toolKind from the tool name", () => {
    expect(toolKind("bash")).toBe("shell");
    expect(toolKind("write")).toBe("edit");
    expect(toolKind("read")).toBe("read");
    expect(toolKind("webfetch")).toBe("fetch");
    expect(toolKind("grep")).toBe("search");
    expect(toolKind("task")).toBe("task");
    expect(toolKind("github_create_issue")).toBe("mcp");
    expect(toolKind("frobnicate")).toBe("other");
  });

  it("maps todos to plan entries with status normalization", () => {
    const entries = mapPlanEntries([
      { content: "scout", status: "completed" },
      { content: "build", status: "in_progress" },
      { content: "ship", status: "pending" },
    ]);
    expect(entries).toEqual([
      { text: "scout", status: "completed" },
      { text: "build", status: "running" },
      { text: "ship", status: "pending" },
    ]);
  });

  it("maps message tokens to AgentUsage shape (cache.read -> cacheReadTokens)", () => {
    const u = mapTokens({ total: 100, input: 60, output: 40, reasoning: 5, cache: { read: 20, write: 1 } });
    expect(u).toEqual({ totalTokens: 100, inputTokens: 60, outputTokens: 40, reasoningTokens: 5, cacheReadTokens: 20 });
  });

  // opencode's real AssistantMessage.tokens (packages/sdk/js/src/gen/types.gen.ts)
  // never carries a `total` field — only input/output/reasoning/cache.{read,write}.
  // opencode's own overflow detection (session/overflow.ts) derives total the same
  // way: `tokens.total || input + output + cache.read + cache.write`.
  it("derives totalTokens from the leaf counters when total is absent (real opencode shape)", () => {
    const u = mapTokens({ input: 60, output: 40, reasoning: 5, cache: { read: 20, write: 1 } });
    expect(u.totalTokens).toBe(60 + 40 + 20 + 1);
  });

  it("maps a named opencode error to a category", () => {
    expect(mapOpencodeError({ name: "MessageOutputLengthError", data: { message: "too long" } }).category).toBe("context_overflow");
    expect(mapOpencodeError("boom").category).toBe("unknown");
  });
});
