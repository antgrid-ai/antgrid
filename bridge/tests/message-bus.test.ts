import { describe, expect, test, it, mock } from "bun:test";
import { MessageBus, type TransportSubscriber } from "../src/message-bus";
import { createMessage, parseMessage, parseMessageFast, CHECKOUT_VARIABLE_MESSAGE_TYPES } from "../src/protocol";

function makeSub(): TransportSubscriber & { sent: { msg: any; channel: string }[] } {
  const sent: any[] = [];
  return {
    sent,
    deliver(msg, channel) { sent.push({ msg, channel }); },
  };
}

describe("MessageBus", () => {
  test("bell events reach both app wires without exposing or replaying raw output", () => {
    const bus = new MessageBus();
    const relay = makeSub();
    const loopback = makeSub();
    bus.subscribe({ ...relay, audience: "relay" });
    bus.subscribe({ ...loopback, audience: "loopback" });
    bus.publish(createMessage("terminal:output", { terminalId: "t", data: "\x07" }), "control");
    const bell = createMessage("terminal:bell", {
      terminalId: "t", runId: crypto.randomUUID(), checkoutId: "wt1",
    });
    bus.publish(bell, "control");
    expect(relay.sent).toEqual([{ msg: bell, channel: "control" }]);
    expect(loopback.sent).toEqual(relay.sent);
    expect(bus.getSnapshot(["terminal:bell"])).toEqual([]);
    expect(parseMessage(JSON.stringify(bell))).toEqual(bell);
    expect(parseMessageFast(JSON.stringify(bell))).toEqual(bell);
    expect(CHECKOUT_VARIABLE_MESSAGE_TYPES.has("terminal:bell")).toBe(true);
  });
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

  test("republish delivers an unchanged snapshot the dedup would swallow", () => {
    const bus = new MessageBus();
    const a = makeSub();
    bus.subscribe(a);
    const payload = {
      projectId: "p", terminals: [], services: [], checkoutId: "wt1",
      agent: { version: "1.0.0" },
    };

    bus.publish(createMessage("agent:status", payload), "control");
    // Identical payload: the ordinary dedup drops it before any subscriber.
    bus.publish(createMessage("agent:status", payload), "control");
    expect(a.sent).toHaveLength(1);

    // The re-sync paths must still reach the wire — this is what an app whose
    // per-checkout view was built after the replay depends on.
    bus.republish(createMessage("agent:status", payload), "control");
    expect(a.sent).toHaveLength(2);
    expect((a.sent[1]!.msg as any).checkoutId).toBe("wt1");

    const cached = bus.getSnapshot(["agent:status"]);
    expect(cached).toHaveLength(1);
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
    expect(handler).toHaveBeenCalledWith(m, "control", "relay", undefined);
  });

  test("inbound forwards an explicit loopback source", () => {
    const bus = new MessageBus();
    const handler = mock(() => {});
    bus.setInboundHandler(handler);
    const m = createMessage("terminal:input", { terminalId: "s", data: "x" });
    bus.dispatchInbound(m, "control", "loopback");
    expect(handler).toHaveBeenCalledWith(m, "control", "loopback", undefined);
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
      const oldGit = createMessage("git:status", { projectId: "p1", files: [{ path: "a.ts", status: "M" as const, staged: true }] });
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
      const gitV2 = createMessage("git:status", { projectId: "p1", files: [{ path: "a.ts", status: "M" as const, staged: true }] });
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
    const status = createMessage("agent:status", { terminals: [], agent: { version: "test" } });
    const git = createMessage("git:status", { projectId: "p1", files: [] });
    bus.publish(status, "control");
    bus.publish(git, "control");

    const snap = bus.getSnapshot(["agent:status", "git:status"]);
    expect(snap.map((m) => m.type).sort()).toEqual(["agent:status", "git:status"]);
  });

  test("returns all cached state frames when called with ['*']", () => {
    const bus = new MessageBus();
    const git = createMessage("git:status", { projectId: "p1", files: [] });
    bus.publish(git, "control");
    expect(bus.getSnapshot(["*"]).map((m) => m.type)).toEqual(["git:status"]);
  });

  test("returns empty array when nothing has been cached for the type yet", () => {
    const bus = new MessageBus();
    expect(bus.getSnapshot(["git:status"])).toEqual([]);
  });

  test("exclude drops a type from both the ['*'] and the named answer", () => {
    const bus = new MessageBus();
    const status = createMessage("agent:status", { terminals: [], agent: { version: "test" } });
    const git = createMessage("git:status", { projectId: "p1", files: [] });
    bus.publish(status, "control");
    bus.publish(git, "control");

    expect(bus.getSnapshot(["*"], ["agent:status"]).map((m) => m.type)).toEqual(["git:status"]);
    expect(bus.getSnapshot(["agent:status", "git:status"], ["agent:status"]).map((m) => m.type)).toEqual(["git:status"]);
    expect(bus.getSnapshot(["agent:status"], ["agent:status"])).toEqual([]);
  });
});

describe("session-scoped replay (agent:capabilities)", () => {
  const caps = (sessionId: string, currentModelId?: string) =>
    createMessage("agent:capabilities", { sessionId, ...(currentModelId ? { currentModelId } : {}) });

  // A shell backgrounded before the app attached is otherwise invisible until
  // it settles — and an app that never saw it can never offer a stop for it.
  it("replays the latest background-task list per session", () => {
    const bus = new MessageBus();
    const tasks = (sessionId: string, taskId: string) => createMessage("agent:background-tasks", {
      sessionId,
      tasks: [{ taskId, kind: "shell", title: "bun dev", status: "running" }],
    });
    bus.publish(tasks("s1", "task-1"), "control");
    bus.publish(tasks("s2", "task-9"), "control");
    bus.publish(tasks("s1", "task-2"), "control");
    const frames = bus.getSnapshot(["agent:background-tasks"]) as any[];
    expect(frames).toHaveLength(2);
    expect(frames.find((f) => f.sessionId === "s1")?.tasks[0].taskId).toBe("task-2");
    bus.dropSessionReplay("s1");
    expect(bus.getSnapshot(["agent:background-tasks"])).toHaveLength(1);
  });

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

  const gitStatus = (checkoutId: string, label: string) => ({
    ...createMessage("git:status", {
      projectId: "p",
      files: [{ path: label, status: "M" as const, staged: false }],
    }),
    checkoutId,
  });

  it("keeps one replayed snapshot per checkout", () => {
    // An isolated session's worktree publishes its own git:status. Keyed by
    // type alone it evicted main's, and the app — which filters replayed
    // frames by checkoutId — was left with nothing to draw main's status from.
    const bus = new MessageBus();
    bus.publish(gitStatus("main", "primary"), "control");
    bus.publish(gitStatus("wt-1", "isolated"), "control");
    const frames = bus.getSnapshot(["git:status"]) as any[];
    expect(frames.map((f) => f.checkoutId).sort()).toEqual(["main", "wt-1"]);
    expect(frames.find((f) => f.checkoutId === "main").files[0].path).toBe("primary");
  });

  it("dropCheckoutReplay evicts one checkout's entries and leaves the rest", () => {
    const bus = new MessageBus();
    bus.publish(gitStatus("main", "primary"), "control");
    bus.publish(gitStatus("wt-1", "isolated"), "control");
    bus.dropCheckoutReplay("wt-1");
    const frames = bus.getSnapshot(["git:status"]) as any[];
    expect(frames).toHaveLength(1);
    expect(frames[0].checkoutId).toBe("main");
  });
});
