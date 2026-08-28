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
  it("a plain reply forwards to prompt with no commandId", () => {
    const prompts: Array<[string, string, string | undefined]> = [];
    const a = createStructuredAdapter({
      prompt: (id, text, commandId) => prompts.push([id, text, commandId]),
      getTranscriptPath: () => "/x.jsonl",
      getSnapshot: async () => [],
      commandCatalog: () => undefined,
    });
    a.injectReply("s1", "continue");
    expect(prompts).toEqual([["s1", "continue", undefined]]);
    expect(a.transcriptPath("s1")).toBe("/x.jsonl");
  });

  it("a resolved command sends the argument tail under its command id", () => {
    const prompts: Array<[string, string, string | undefined]> = [];
    const a = createStructuredAdapter({
      prompt: (id, text, commandId) => prompts.push([id, text, commandId]),
      getTranscriptPath: () => undefined,
      getSnapshot: async () => [],
      commandCatalog: () => undefined,
    });
    a.injectReply("s1", "/code-review --fix", { id: "cmd:code-review", args: "--fix" });
    expect(prompts).toEqual([["s1", "--fix", "cmd:code-review"]]);
  });

  it("a bare verb sends empty text alongside its command id", () => {
    const prompts: Array<[string, string, string | undefined]> = [];
    const a = createStructuredAdapter({
      prompt: (id, text, commandId) => prompts.push([id, text, commandId]),
      getTranscriptPath: () => undefined,
      getSnapshot: async () => [],
      commandCatalog: () => undefined,
    });
    a.injectReply("s1", "/compact", { id: "builtin:compact", args: "" });
    expect(prompts).toEqual([["s1", "", "builtin:compact"]]);
  });

  it("an unresolved slash command degrades to an ordinary plain prompt", () => {
    const prompts: Array<[string, string, string | undefined]> = [];
    const a = createStructuredAdapter({
      prompt: (id, text, commandId) => prompts.push([id, text, commandId]),
      getTranscriptPath: () => undefined,
      getSnapshot: async () => [],
      commandCatalog: () => undefined,
    });
    // Never a made-up commandId: every backend would drop the verb and send the
    // bare args, so the whole line goes as text and the agent rejects it visibly.
    a.injectReply("s1", "/invented arg");
    expect(prompts).toEqual([["s1", "/invented arg", undefined]]);
  });

  it("commandCatalog is read from the dep, and undefined stays undefined", () => {
    const withCatalog = createStructuredAdapter({
      prompt: () => {},
      getTranscriptPath: () => undefined,
      getSnapshot: async () => [],
      commandCatalog: () => [{ id: "cmd:x", name: "x" }],
    });
    expect(withCatalog.commandCatalog("s1")).toEqual([{ id: "cmd:x", name: "x" }]);
    const without = createStructuredAdapter({
      prompt: () => {},
      getTranscriptPath: () => undefined,
      getSnapshot: async () => [],
      commandCatalog: () => undefined,
    });
    expect(without.commandCatalog("s1")).toBeUndefined();
  });

  it("injection never resolves a permission or a question", () => {
    const touched: string[] = [];
    const base = {
      prompt: () => {},
      getTranscriptPath: () => undefined,
      getSnapshot: async () => [] as AbMessage[],
      commandCatalog: () => undefined,
      // Off the deps contract on purpose: approving a pending tool call is a
      // human-only act, so the seam must not reach for either.
      resolvePermission: () => { throw new Error("resolvePermission from the inject seam"); },
      resolveQuestion: () => { throw new Error("resolveQuestion from the inject seam"); },
    };
    const deps = new Proxy(base, {
      get(target, prop, recv) { touched.push(String(prop)); return Reflect.get(target, prop, recv); },
    });
    createStructuredAdapter(deps).injectReply("s1", "continue");
    expect(touched).toEqual(["prompt"]);
  });

  it("recentOutput renders the snapshot and fails closed to empty on error", async () => {
    const ok = createStructuredAdapter({
      prompt: () => {},
      getTranscriptPath: () => undefined,
      getSnapshot: async () => [item("agent:item-added", "a1", { kind: "message", role: "assistant", text: "hi" })],
      commandCatalog: () => undefined,
    });
    expect(await ok.recentOutput("s1")).toBe("assistant: hi");
    const bad = createStructuredAdapter({
      prompt: () => {},
      getTranscriptPath: () => undefined,
      getSnapshot: async () => { throw new Error("driver gone"); },
      commandCatalog: () => undefined,
    });
    expect(await bad.recentOutput("s1")).toBe("");
  });
});
