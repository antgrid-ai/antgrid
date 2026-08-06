import { describe, it, expect } from "bun:test";
import { opencodeResumeReplay } from "../src/agents/opencode/resume-replay";

// Message history shape mirrors client.session.messages: [{ info, parts }].
const history = [
  { info: { id: "m1", role: "user" }, parts: [{ id: "p1", type: "text", text: "hi" }] },
  { info: { id: "m2", role: "assistant" }, parts: [{ id: "p2", type: "text", text: "hello" }] },
];

describe("opencodeResumeReplay", () => {
  it("emits turn-start, an item per part, turn-end", () => {
    const msgs = opencodeResumeReplay("s1", history);
    expect(msgs[0].type).toBe("agent:turn-start");
    expect(msgs[msgs.length - 1].type).toBe("agent:turn-end");
    expect(msgs.filter((m) => m.type === "agent:item-added").length).toBe(2);
  });
  it("stamps envelope timestamps from each message's created time (ms)", () => {
    const msgs = opencodeResumeReplay("s1", [
      { info: { id: "m1", role: "user", time: { created: 1700000000000 } },
        parts: [{ id: "p1", type: "text", text: "hi" }] },
      { info: { id: "m2", role: "assistant", time: { created: 1700000050000 } },
        parts: [{ id: "p2", type: "text", text: "hello" }] },
    ]);
    const added = msgs.filter((m) => m.type === "agent:item-added");
    expect(added[0].timestamp).toBe(1700000000000); // user part
    expect(added[1].timestamp).toBe(1700000050000); // assistant part
    expect(msgs[0].timestamp).toBe(1700000000000); // turn-start = first msg
    expect(msgs[msgs.length - 1].timestamp).toBe(1700000050000); // turn-end = last
  });

  it("returns [] for empty history", () => {
    expect(opencodeResumeReplay("s", [])).toEqual([]);
  });
});

describe("opencodeResumeReplay turn segmentation", () => {
  // See claude-resume-replay.test.ts — the app's deriveRows folds a settled turn
  // to its prompt + trailing answer, so one turn per prompt is what keeps each
  // exchange's answer visible on resume.
  it("opens one turn per user message", () => {
    const out = opencodeResumeReplay("s1", [
      { info: { id: "m1", role: "user" }, parts: [{ id: "p1", type: "text", text: "first" }] },
      { info: { id: "m2", role: "assistant" }, parts: [{ id: "p2", type: "text", text: "answer one" }] },
      { info: { id: "m3", role: "user" }, parts: [{ id: "p3", type: "text", text: "second" }] },
      { info: { id: "m4", role: "assistant" }, parts: [{ id: "p4", type: "text", text: "answer two" }] },
    ]);
    const starts = out.filter((m) => m.type === "agent:turn-start");
    expect(starts.length).toBe(2);
    expect(out.filter((m) => m.type === "agent:turn-end").length).toBe(2);
    const ids = starts.map((m: any) => m.turnId);
    expect(new Set(ids).size).toBe(2);
    const firstTurn = out.filter((m: any) => m.turnId === ids[0]);
    expect(firstTurn.some((m: any) => m.item?.text === "answer one")).toBe(true);
    expect(firstTurn.some((m: any) => m.item?.text === "answer two")).toBe(false);
  });

  it("stamps each turn's start/end from its own messages", () => {
    const out = opencodeResumeReplay("s1", [
      { info: { id: "m1", role: "user", time: { created: 1000 } }, parts: [{ id: "p1", type: "text", text: "a" }] },
      { info: { id: "m2", role: "assistant", time: { created: 2000 } }, parts: [{ id: "p2", type: "text", text: "x" }] },
      { info: { id: "m3", role: "user", time: { created: 9000 } }, parts: [{ id: "p3", type: "text", text: "b" }] },
      { info: { id: "m4", role: "assistant", time: { created: 9500 } }, parts: [{ id: "p4", type: "text", text: "y" }] },
    ]);
    const starts = out.filter((m) => m.type === "agent:turn-start");
    const ends = out.filter((m) => m.type === "agent:turn-end");
    expect(starts[0]?.timestamp).toBe(1000);
    expect(ends[0]?.timestamp).toBe(2000);
    expect(starts[1]?.timestamp).toBe(9000);
    expect(ends[1]?.timestamp).toBe(9500);
  });

  it("emits no empty turn for a user message whose parts all map to nothing", () => {
    const out = opencodeResumeReplay("s1", [
      { info: { id: "m1", role: "user" }, parts: [] },
      { info: { id: "m2", role: "user" }, parts: [{ id: "p2", type: "text", text: "real" }] },
    ]);
    expect(out.filter((m) => m.type === "agent:turn-start").length).toBe(1);
  });
});

describe("opencodeResumeReplay usage backfill", () => {
  const tokens = { input: 100, output: 50, reasoning: 0, cache: { read: 10, write: 0 } };
  const assistantMsg = {
    info: { id: "m1", role: "assistant", tokens, providerID: "anthropic", modelID: "claude-sonnet-5", time: { created: 1720000000000 } },
    parts: [{ id: "p1", type: "text", text: "hello", messageID: "m1" }],
  };

  it("emits an itemId-anchored usage frame per assistant message, with resolved contextWindow", () => {
    const out = opencodeResumeReplay("s1", [assistantMsg], (p, m) => (p === "anthropic" && m === "claude-sonnet-5" ? 200000 : undefined));
    const frames = out.filter((f: any) => f.type === "agent:usage") as any[];
    expect(frames.length).toBe(1);
    expect(frames[0].itemId).toBe("p1");
    expect(frames[0].last.totalTokens).toBe(160); // input+output+cache.read+cache.write
    expect(frames[0].contextWindow).toBe(200000);
    expect(frames[0].total).toEqual({});
  });

  it("omits contextWindow when the lookup misses, and skips messages without tokens or text", () => {
    const noTokens = { info: { id: "m2", role: "assistant", time: { created: 1 } }, parts: [{ id: "p2", type: "text", text: "x", messageID: "m2" }] };
    const noText = { info: { id: "m3", role: "assistant", tokens, time: { created: 2 } }, parts: [{ id: "p3", type: "tool", tool: "read", state: { status: "completed" }, messageID: "m3" }] };
    const out = opencodeResumeReplay("s1", [assistantMsg, noTokens, noText], () => undefined);
    const frames = out.filter((f: any) => f.type === "agent:usage") as any[];
    expect(frames.length).toBe(1);
    expect(frames[0].contextWindow).toBeUndefined();
  });
});
