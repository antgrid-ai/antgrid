import { describe, it, expect } from "bun:test";
import { codexResumeReplay } from "../src/codex/codex-resume-replay";

// Minimal thread shape mirroring ThreadResumeResponse.thread. Each turn has an
// id and an items array; item shape matches what mapThreadItem consumes (see
// codex-mapping.ts) — an assistant message here.
const thread = {
  id: "th-1",
  turns: [
    {
      id: "turn-a",
      items: [{ id: "i1", type: "agentMessage", text: "hello from the past" }],
    },
  ],
};

describe("codexResumeReplay", () => {
  it("emits turn-start, item-added, turn-end per historical turn", () => {
    const msgs = codexResumeReplay("sess-1", thread);
    expect(msgs.map((m) => m.type)).toEqual([
      "agent:turn-start",
      "agent:item-added",
      "agent:turn-end",
    ]);
    expect((msgs[0] as any).sessionId).toBe("sess-1");
    expect((msgs[0] as any).turnId).toBe("turn-a");
    expect((msgs[1] as any).item.itemId).toBe("i1");
    expect((msgs[2] as any).stopReason).toBe("end_turn");
  });

  it("returns [] for a thread with no turns", () => {
    expect(codexResumeReplay("s", { id: "t", turns: [] })).toEqual([]);
    expect(codexResumeReplay("s", { id: "t" })).toEqual([]);
  });

  it("stamps envelope timestamps from turn boundaries (seconds -> ms)", () => {
    const msgs = codexResumeReplay("s1", {
      turns: [{
        id: "t1",
        startedAt: 1700000000, // unix SECONDS
        completedAt: 1700000123,
        items: [
          { type: "userMessage", id: "u1", content: [{ type: "text", text: "q" }] },
          { type: "agentMessage", id: "a1", text: "answer" },
        ],
      }],
    });
    const [start, userItem, asstItem, end] = msgs;
    expect(start.timestamp).toBe(1700000000000);
    expect(userItem.timestamp).toBe(1700000000000); // user = turn start
    expect(asstItem.timestamp).toBe(1700000123000); // assistant = turn complete
    expect(end.timestamp).toBe(1700000123000);
  });

  it("falls back to a real send time when the turn has no timestamps", () => {
    const before = Date.now();
    const msgs = codexResumeReplay("s1", {
      turns: [{ id: "t1", items: [{ id: "i1", type: "agentMessage", text: "x" }] }],
    });
    // No source time -> createMessage's Date.now(), never 0/undefined.
    expect(msgs[1].timestamp).toBeGreaterThanOrEqual(before);
  });

  it("replays userMessage history items", () => {
    const msgs = codexResumeReplay("s1", {
      turns: [{
        id: "t1",
        items: [{ type: "userMessage", id: "u1", content: [{ type: "text", text: "hello" }] }],
      }],
    });
    const added = msgs.find((m) => m.type === "agent:item-added");
    expect(added?.type).toBe("agent:item-added");
    if (added?.type === "agent:item-added") {
      expect(added.item.kind).toBe("message");
      expect(added.item.role).toBe("user");
      expect(added.item.text).toBe("hello");
    }
  });
});
