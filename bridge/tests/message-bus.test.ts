import { describe, expect, test, it, mock } from "bun:test";
import { MessageBus, type TransportSubscriber } from "../src/message-bus";
import { createMessage } from "../src/protocol";

function makeSub(): TransportSubscriber & { sent: { msg: any; channel: string }[] } {
  const sent: any[] = [];
  return {
    sent,
    deliver(msg, channel) { sent.push({ msg, channel }); },
  };
}

describe("MessageBus", () => {
  test("publish fans out to all subscribers", () => {
    const bus = new MessageBus();
    const a = makeSub();
    const b = makeSub();
    bus.subscribe(a); bus.subscribe(b);

    const m = createMessage("terminal:output", { terminalId: "s", data: "x" });
    bus.publish(m, "control");

    expect(a.sent).toEqual([{ msg: m, channel: "control" }]);
    expect(b.sent).toEqual([{ msg: m, channel: "control" }]);
  });

  test("unsubscribe stops delivery", () => {
    const bus = new MessageBus();
    const a = makeSub();
    const off = bus.subscribe(a);
    off();
    bus.publish(createMessage("terminal:output", { terminalId: "s", data: "x" }), "control");
    expect(a.sent).toEqual([]);
  });

  test("inbound dispatches to handler", () => {
    const bus = new MessageBus();
    const handler = mock(() => {});
    bus.setInboundHandler(handler);
    const m = createMessage("terminal:input", { terminalId: "s", data: "x" });
    bus.dispatchInbound(m, "control");
    // source defaults to "relay" (fail-closed) when a caller omits it.
    expect(handler).toHaveBeenCalledWith(m, "control", "relay");
  });

  test("inbound forwards an explicit loopback source", () => {
    const bus = new MessageBus();
    const handler = mock(() => {});
    bus.setInboundHandler(handler);
    const m = createMessage("terminal:input", { terminalId: "s", data: "x" });
    bus.dispatchInbound(m, "control", "loopback");
    expect(handler).toHaveBeenCalledWith(m, "control", "loopback");
  });

  test("publish is safe with zero subscribers", () => {
    const bus = new MessageBus();
    expect(() => bus.publish(createMessage("terminal:output", { terminalId: "s", data: "x" }), "control")).not.toThrow();
  });

  describe("cache-on-publish (no auto-replay)", () => {
    // The bus caches the latest frame for each type in `REPLAY_TYPES` but
    // does NOT replay them to new subscribers. Transports fetch state via
    // bus.getSnapshot() on (re)connect instead.
    const status = createMessage("agent:status", {
      terminals: [],
      agent: { version: "test" },
    });
    const gitMsg = createMessage("git:status", { projectId: "p1", files: [] });
    const stream = createMessage("terminal:output", { terminalId: "s", data: "x" });

    test("does NOT auto-replay cached frames to a fresh subscriber", () => {
      const bus = new MessageBus();
      bus.publish(status, "control"); // no subscribers — must still cache
      const a = makeSub();
      bus.subscribe(a);
      expect(a.sent).toHaveLength(0); // no auto-replay
      expect(bus.getSnapshot(["*"]).map((m) => m.type)).toContain("agent:status");
    });

    test("does NOT replay non-state-typed frames", () => {
      const bus = new MessageBus();
      bus.publish(stream, "control");
      const a = makeSub();
      bus.subscribe(a);
      expect(a.sent).toEqual([]);
    });

    test("keeps only the latest per type in cache", () => {
      const bus = new MessageBus();
      const oldGit = createMessage("git:status", { projectId: "p1", files: [{ path: "a.ts", status: "M" as const }] });
      bus.publish(oldGit, "control");
      bus.publish(gitMsg, "control"); // overwrites — same type
      const a = makeSub();
      bus.subscribe(a);
      expect(a.sent).toHaveLength(0); // no auto-replay
      // cache holds only the latest
      expect(bus.getSnapshot(["git:status"])).toEqual([gitMsg]);
    });

    test("dedups identical re-publishes to existing subscribers", () => {
      const bus = new MessageBus();
      const a = makeSub();
      bus.subscribe(a);
      bus.publish(gitMsg, "control");
      bus.publish(gitMsg, "control"); // identical — no-op
      bus.publish({ ...gitMsg }, "control"); // structurally identical — no-op
      expect(a.sent).toHaveLength(1);
    });

    test("re-publishes when a tracked field changes", () => {
      const bus = new MessageBus();
      const a = makeSub();
      bus.subscribe(a);
      const gitV1 = createMessage("git:status", { projectId: "p1", files: [] });
      const gitV2 = createMessage("git:status", { projectId: "p1", files: [{ path: "a.ts", status: "M" as const }] });
      bus.publish(gitV1, "control");
      bus.publish(gitV2, "control");
      expect(a.sent).toHaveLength(2);
    });

    test("cache preserves insertion order across types", () => {
      const bus = new MessageBus();
      bus.publish(status, "control");
      bus.publish(gitMsg, "control");
      // No auto-replay — subscriber gets nothing
      const a = makeSub();
      bus.subscribe(a);
      expect(a.sent).toHaveLength(0);
      // But snapshot returns both in insertion order
      expect(bus.getSnapshot(["*"]).map((m) => m.type)).toEqual([
        "agent:status",
        "git:status",
      ]);
    });

  });
});

describe("MessageBus.getSnapshot", () => {
  test("returns cached state frames for requested types", () => {
    const bus = new MessageBus();
    const tree = createMessage("tree:full", {
      projectId: "p1",
      root: { name: "root", path: "/", type: "directory" as const, children: [] },
    });
    const git = createMessage("git:status", { projectId: "p1", files: [] });
    bus.publish(tree, "control");
    bus.publish(git, "control");

    const snap = bus.getSnapshot(["tree:full", "git:status"]);
    expect(snap.map((m) => m.type).sort()).toEqual(["git:status", "tree:full"]);
  });

  test("returns all cached state frames when called with ['*']", () => {
    const bus = new MessageBus();
    const tree = createMessage("tree:full", {
      projectId: "p1",
      root: { name: "root", path: "/", type: "directory" as const, children: [] },
    });
    bus.publish(tree, "control");
    expect(bus.getSnapshot(["*"]).map((m) => m.type)).toEqual(["tree:full"]);
  });

  test("returns empty array for an unknown type with no cached frame", () => {
    const bus = new MessageBus();
    expect(bus.getSnapshot(["tree:full"])).toEqual([]);
  });
});

describe("session-scoped replay (agent:capabilities)", () => {
  const caps = (sessionId: string, currentModelId?: string) =>
    createMessage("agent:capabilities", { sessionId, ...(currentModelId ? { currentModelId } : {}) });

  it("caches one frame per session, latest wins within a session", () => {
    const bus = new MessageBus();
    bus.publish(caps("s1", "m1"), "control");
    bus.publish(caps("s2", "m2"), "control");
    bus.publish(caps("s1", "m3"), "control");
    const frames = bus.getSnapshot(["agent:capabilities"]) as any[];
    expect(frames).toHaveLength(2);
    const s1 = frames.find((f) => f.sessionId === "s1");
    expect(s1?.currentModelId).toBe("m3");
  });

  it("includes session frames in the '*' snapshot", () => {
    const bus = new MessageBus();
    bus.publish(caps("s1"), "control");
    expect(bus.getSnapshot(["*"]).some((f) => f.type === "agent:capabilities")).toBe(true);
  });

  it("dedups an identical re-publish per session", () => {
    const bus = new MessageBus();
    const delivered: unknown[] = [];
    bus.subscribe({ deliver: (m) => delivered.push(m) });
    bus.publish(caps("s1", "m1"), "control");
    bus.publish(caps("s1", "m1"), "control");
    expect(delivered).toHaveLength(1);
  });

  it("dropSessionReplay evicts one session's entry and leaves the rest", () => {
    const bus = new MessageBus();
    bus.publish(caps("s1", "m1"), "control");
    bus.publish(caps("s2", "m2"), "control");
    bus.dropSessionReplay("s1");
    const frames = bus.getSnapshot(["agent:capabilities"]) as any[];
    expect(frames).toHaveLength(1);
    expect(frames[0].sessionId).toBe("s2");
    // Type-scoped entries are untouched.
    bus.publish(
      createMessage("agent:status", { terminals: [], agent: { version: "test" } }),
      "control",
    );
    bus.dropSessionReplay("s2");
    expect(bus.getSnapshot(["*"]).map((m) => m.type)).toEqual(["agent:status"]);
  });
});
