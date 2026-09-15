import { describe, it, expect } from "bun:test";
import { mapThreadItem, mapCodexError, mapTurnStatusToStopReason, mapPlanStepStatus, mapTokenBreakdown } from "../src/agents/codex/mapping";

describe("mapThreadItem", () => {
  it("maps agentMessage -> message item", () => {
    const item = mapThreadItem({ type: "agentMessage", id: "i1", text: "hello" });
    expect(item).toEqual({ itemId: "i1", kind: "message", role: "assistant", text: "hello" });
  });

  it("maps reasoning -> reasoning item (joins content)", () => {
    const item = mapThreadItem({ type: "reasoning", id: "i2", summary: ["s"], content: ["a", "b"] });
    expect(item?.kind).toBe("reasoning");
    expect(item?.text).toBe("ab");
  });

  it("maps commandExecution -> tool_call(shell) with terminal content + running status", () => {
    const item = mapThreadItem({
      type: "commandExecution", id: "i3", command: "ls", status: "inProgress", aggregatedOutput: "out", exitCode: null,
    });
    expect(item?.kind).toBe("tool_call");
    expect(item?.toolKind).toBe("shell");
    expect(item?.status).toBe("running");
    expect(item?.content?.[0]).toEqual({ type: "terminal", data: "out" });
  });

  it("maps fileChange -> tool_call(edit) with diff content + completed status", () => {
    const item = mapThreadItem({
      type: "fileChange", id: "i4", status: "completed",
      changes: [{ path: "a.ts", kind: { type: "update" }, diff: "@@ -1 +1 @@" }],
    });
    expect(item?.toolKind).toBe("edit");
    expect(item?.status).toBe("completed");
    expect(item?.content?.[0]).toEqual({ type: "diff", path: "a.ts", newText: "@@ -1 +1 @@" });
  });

  it("maps failed mcpToolCall -> tool_call(mcp) status error", () => {
    const item = mapThreadItem({ type: "mcpToolCall", id: "i5", server: "s", tool: "t", status: "failed" });
    expect(item?.toolKind).toBe("mcp");
    expect(item?.status).toBe("error");
  });

  it("ignores the text-blob plan item (driver folds it into the synthetic plan) and maps contextCompaction", () => {
    expect(mapThreadItem({ type: "plan", id: "i6", text: "- step" })).toBeNull();
    expect(mapThreadItem({ type: "contextCompaction", id: "i7" })?.kind).toBe("compaction");
  });

  it("maps collabAgentToolCall(spawnAgent) -> subtask running with parent ref", () => {
    const item = mapThreadItem({
      type: "collabAgentToolCall", id: "i8", tool: "spawnAgent", status: "inProgress",
      senderThreadId: "root", receiverThreadIds: ["child"],
    });
    expect(item?.kind).toBe("subtask");
    expect(item?.status).toBe("running");
    expect(item?.agent).toBe("child"); // first receiver thread id, not the sender
  });

  it("maps userMessage content parts to a user message", () => {
    const item = mapThreadItem({
      type: "userMessage", id: "u1",
      content: [
        { type: "text", text: "fix this " },
        { type: "image", url: "https://x.test/a.png" },
        { type: "localImage", path: "/tmp/b.png" },
        { type: "skill", name: "review", path: "/s" },
        { type: "mention", name: "main.rs", path: "src/main.rs" },
      ],
    });
    expect(item).toEqual({
      itemId: "u1", kind: "message", role: "user",
      text: "fix this [image] [image] @review @main.rs",
    });
  });

  it("maps webSearch, imageView and imageGeneration to tool_call items", () => {
    expect(mapThreadItem({ type: "webSearch", id: "w1", query: "bun test" })).toEqual({
      itemId: "w1", kind: "tool_call", toolKind: "search", title: "bun test",
    });
    expect(mapThreadItem({ type: "imageView", id: "v1", path: "/tmp/x.png" })).toEqual({
      itemId: "v1", kind: "tool_call", toolKind: "read", title: "/tmp/x.png",
    });
    expect(mapThreadItem({ type: "imageGeneration", id: "g1", status: "completed", revisedPrompt: "a cat" })).toEqual({
      itemId: "g1", kind: "tool_call", toolKind: "image", status: "completed", title: "a cat",
    });
  });

  it("passes unknown item kinds through generically without raw payloads", () => {
    const item = mapThreadItem({ type: "hookPrompt", id: "h1", text: "hook says hi", payload: { big: "blob" } });
    expect(item).toEqual({ itemId: "h1", kind: "hookPrompt", text: "hook says hi" });
    const noText = mapThreadItem({ type: "sleep", id: "s1", durationMs: 5 });
    expect(noText).toEqual({ itemId: "s1", kind: "sleep" });
  });

  it("still ignores plan items (driver-owned)", () => {
    expect(mapThreadItem({ type: "plan", id: "p1", text: "plan blob" })).toBeNull();
  });

  it("joins reasoning summary parts with a blank line", () => {
    const item = mapThreadItem({ type: "reasoning", id: "r1", summary: ["part one", "part two"], content: [] });
    expect(item?.text).toBe("part one\n\npart two");
  });
});

describe("mapPlanStepStatus / mapTokenBreakdown", () => {
  it("normalizes plan step status (inProgress -> running)", () => {
    expect(mapPlanStepStatus("inProgress")).toBe("running");
    expect(mapPlanStepStatus("completed")).toBe("completed");
    expect(mapPlanStepStatus(undefined)).toBe("pending");
  });

  it("maps codex token breakdown, renaming cachedInputTokens -> cacheReadTokens", () => {
    const b = mapTokenBreakdown({
      totalTokens: 100, inputTokens: 60, outputTokens: 40,
      cachedInputTokens: 25, reasoningOutputTokens: 10,
    });
    expect(b).toEqual({
      totalTokens: 100, inputTokens: 60, outputTokens: 40,
      cacheReadTokens: 25, reasoningTokens: 10,
    });
    expect(mapTokenBreakdown(undefined)).toEqual({});
  });
});

describe("mapCodexError", () => {
  it("maps serverOverloaded -> server_error retryable", () => {
    const e = mapCodexError({ type: "serverOverloaded" }, "overloaded");
    expect(e.category).toBe("server_error");
    expect(e.retryable).toBe(true);
  });
  it("maps usageLimitExceeded -> quota_exceeded and forwards httpStatusCode", () => {
    const e = mapCodexError({ type: "httpConnectionFailed", httpStatusCode: 429 }, "rl");
    expect(e.httpStatus).toBe(429);
  });
  it("maps contextWindowExceeded -> context_overflow not retryable", () => {
    const e = mapCodexError("contextWindowExceeded", "ctx");
    expect(e.category).toBe("context_overflow");
    expect(e.retryable).toBe(false);
  });
});

describe("mapTurnStatusToStopReason", () => {
  it("maps codex turn statuses", () => {
    expect(mapTurnStatusToStopReason("completed")).toBe("end_turn");
    expect(mapTurnStatusToStopReason("interrupted")).toBe("cancelled");
    expect(mapTurnStatusToStopReason("failed")).toBe("error");
  });
});
