// bridge/tests/handler/structured-adapter.test.ts
import { describe, it, expect } from "bun:test";
import { renderSnapshotText, createStructuredAdapter } from "../../src/handler/structured-adapter";
import type { AbMessage } from "../../src/protocol";

const item = (type: string, itemId: string, itm: Record<string, unknown>) =>
  ({ type, sessionId: "s1", turnId: "t", itemId, item: { itemId, ...itm } }) as unknown as AbMessage;

describe("renderSnapshotText", () => {
  it("renders message/reasoning roles and reduces tool calls to titles", () => {
    const text = renderSnapshotText([
      item("agent:item-added", "u1", { kind: "message", role: "user", text: "run the tests" }),
      item("agent:item-added", "tool1", { kind: "tool_call", title: "Bash", status: "running" }),
      item("agent:item-added", "a1", { kind: "message", role: "assistant", text: "3 passed" }),
    ]);
    expect(text).toBe("user: run the tests\n[tool: Bash]\nassistant: 3 passed");
  });

  it("dedups item-updated over item-added by itemId (last write wins, order kept)", () => {
    const text = renderSnapshotText([
      item("agent:item-added", "a1", { kind: "message", role: "assistant", text: "partial" }),
      item("agent:item-updated", "a1", { kind: "message", role: "assistant", text: "final" }),
    ]);
    expect(text).toBe("assistant: final");
  });

  it("keeps an updated item at its original position, not the update's position", () => {
    const text = renderSnapshotText([
      item("agent:item-added", "a1", { kind: "message", role: "assistant", text: "first" }),
      item("agent:item-added", "b2", { kind: "message", role: "user", text: "second" }),
      item("agent:item-updated", "a1", { kind: "message", role: "assistant", text: "first-updated" }),
    ]);
    expect(text).toBe("assistant: first-updated\nuser: second");
  });

  it("unwraps agent:transcript-replay nested frames", () => {
    const replay = {
      type: "agent:transcript-replay", sessionId: "s1",
      frames: [item("agent:item-added", "a1", { kind: "message", role: "assistant", text: "hi" })],
    } as unknown as AbMessage;
    expect(renderSnapshotText([replay])).toBe("assistant: hi");
  });

  it("caps output at maxChars keeping the tail", () => {
    const text = renderSnapshotText(
      [item("agent:item-added", "a1", { kind: "message", role: "assistant", text: "x".repeat(100) })],
      10,
    );
    expect(text).toHaveLength(10);
  });
});

describe("createStructuredAdapter", () => {
  it("injectReply forwards to prompt; slash commands unsupported", () => {
    const prompts: Array<[string, string]> = [];
    const a = createStructuredAdapter({
      prompt: (id, text) => prompts.push([id, text]),
      getTranscriptPath: () => "/x.jsonl",
      getSnapshot: async () => [],
    });
    a.injectReply("s1", "continue");
    expect(prompts).toEqual([["s1", "continue"]]);
    expect(a.supportsSlashCommands("s1")).toBe(false);
    expect(a.transcriptPath("s1")).toBe("/x.jsonl");
  });

  it("recentOutput renders the snapshot and fails closed to empty on error", async () => {
    const ok = createStructuredAdapter({
      prompt: () => {},
      getTranscriptPath: () => undefined,
      getSnapshot: async () => [item("agent:item-added", "a1", { kind: "message", role: "assistant", text: "hi" })],
    });
    expect(await ok.recentOutput("s1")).toBe("assistant: hi");
    const bad = createStructuredAdapter({
      prompt: () => {},
      getTranscriptPath: () => undefined,
      getSnapshot: async () => { throw new Error("driver gone"); },
    });
    expect(await bad.recentOutput("s1")).toBe("");
  });
});
