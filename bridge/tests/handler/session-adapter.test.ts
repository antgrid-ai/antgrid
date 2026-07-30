import { describe, it, expect } from "bun:test";
import { createPtyAdapter, createDispatchAdapter } from "../../src/handler/session-adapter";
import type { SessionAdapter } from "../../src/handler/session-adapter";

describe("createPtyAdapter", () => {
  it("appends CR on inject and passes through reads", () => {
    const writes: Array<[string, string]> = [];
    const a = createPtyAdapter({
      write: (id, data) => writes.push([id, data]),
      getRecentOutput: () => "scrollback",
      getTranscriptPath: (id) => (id === "t1" ? "/p.jsonl" : undefined),
    });
    a.injectReply("t1", "yes");
    expect(writes).toEqual([["t1", "yes\r"]]);
    expect(a.recentOutput("t1")).toBe("scrollback");
    expect(a.transcriptPath("t1")).toBe("/p.jsonl");
    expect(a.transcriptPath("t2")).toBeUndefined();
  });
});

describe("createDispatchAdapter", () => {
  const calls: string[] = [];
  const fake = (name: string): SessionAdapter => ({
    injectReply: (id) => { calls.push(`${name}:inject:${id}`); },
    recentOutput: (id) => `${name}:recent:${id}`,
    outputKind: () => (name === "pty" ? "pty" : "rendered"),
    transcriptPath: (id) => `${name}:path:${id}`,
    supportsSlashCommands: () => name === "pty",
  });

  it("routes every method by isChat and delegates supportsSlashCommands", async () => {
    calls.length = 0;
    const a = createDispatchAdapter({
      isChat: (id) => id.startsWith("chat"),
      pty: fake("pty"),
      chat: fake("chat"),
    });
    a.injectReply("chat-1", "x");
    a.injectReply("term-1", "x");
    expect(calls).toEqual(["chat:inject:chat-1", "pty:inject:term-1"]);
    expect(await a.recentOutput("chat-1")).toBe("chat:recent:chat-1");
    expect(a.transcriptPath("term-1")).toBe("pty:path:term-1");
    expect(a.supportsSlashCommands("term-1")).toBe(true);
    expect(a.supportsSlashCommands("chat-1")).toBe(false);
  });
});
