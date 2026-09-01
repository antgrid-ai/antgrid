import { describe, it, expect } from "bun:test";
import { createPtyAdapter, createDispatchAdapter } from "../../src/handler/session-adapter";
import type { SessionAdapter } from "../../src/handler/session-adapter";

describe("createPtyAdapter", () => {
  it("hands the bare line to the terminal layer and passes through reads", () => {
    const writes: Array<[string, string]> = [];
    const a = createPtyAdapter({
      submit: (id, line) => writes.push([id, line]),
      getRecentOutput: () => "scrollback",
      getTranscriptPath: (id) => (id === "t1" ? "/p.jsonl" : undefined),
    });
    a.injectReply("t1", "yes");
    // A terminal has no routing channel: the resolved command is ignored and the
    // verb rides in `text`. The submitting CR belongs to the terminal layer,
    // which adds it as a separate write, so it never appears at this seam.
    a.injectReply("t1", "/compact", { id: "builtin:compact", args: "" });
    expect(writes).toEqual([["t1", "yes"], ["t1", "/compact"]]);
    expect(a.recentOutput("t1")).toBe("scrollback");
    expect(a.transcriptPath("t1")).toBe("/p.jsonl");
    expect(a.transcriptPath("t2")).toBeUndefined();
    expect(a.commandCatalog("t1")).toBeUndefined();
  });
});

describe("createDispatchAdapter", () => {
  const calls: string[] = [];
  const fake = (name: string): SessionAdapter => ({
    injectReply: (id, _text, command) => { calls.push(`${name}:inject:${id}:${command?.id ?? "-"}`); },
    recentOutput: (id) => `${name}:recent:${id}`,
    outputKind: () => (name === "pty" ? "pty" : "rendered"),
    transcriptPath: (id) => `${name}:path:${id}`,
    commandCatalog: () => (name === "pty" ? undefined : [{ id: "cmd:x", name: "x" }]),
  });

  it("routes every method by isChat, catalog included", async () => {
    calls.length = 0;
    const a = createDispatchAdapter({
      isChat: (id) => id.startsWith("chat"),
      pty: fake("pty"),
      chat: fake("chat"),
    });
    a.injectReply("chat-1", "x", { id: "cmd:x", args: "arg" });
    a.injectReply("term-1", "x");
    expect(calls).toEqual(["chat:inject:chat-1:cmd:x", "pty:inject:term-1:-"]);
    expect(await a.recentOutput("chat-1")).toBe("chat:recent:chat-1");
    expect(a.transcriptPath("term-1")).toBe("pty:path:term-1");
    expect(a.commandCatalog("term-1")).toBeUndefined();
    expect(a.commandCatalog("chat-1")).toEqual([{ id: "cmd:x", name: "x" }]);
  });
});
