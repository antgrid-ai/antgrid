import { describe, it, expect } from "bun:test";
import { StructuredAgentManager, type StructuredDriver } from "../src/structured/structured-manager";
import { createMessage, type AbMessage } from "../src/protocol";
import { isChatCapableTool } from "../src/structured/chat-capable";

function makeFakeDriver(overrides: Partial<StructuredDriver> & { onStart?: () => Promise<string>; onDispose?: () => void } = {}): StructuredDriver {
  return {
    start: overrides.start ?? (overrides.onStart ? overrides.onStart : async () => ""),
    prompt: overrides.prompt ?? (async () => {}),
    cancel: overrides.cancel ?? (async () => false),
    compact: overrides.compact ?? (async () => {}),
    revert: overrides.revert ?? (async () => {}),
    resolvePermission: overrides.resolvePermission ?? (() => {}),
    resolveQuestion: overrides.resolveQuestion ?? (() => {}),
    setConfig: overrides.setConfig ?? (() => {}),
    dispose: overrides.dispose ?? (overrides.onDispose ? overrides.onDispose : () => {}),
    ...(overrides.getTranscriptSnapshot ? { getTranscriptSnapshot: overrides.getTranscriptSnapshot } : {}),
  };
}

function makeManager() {
  const created: any[] = [];
  const calls: Array<{ id: string; method: string; arg?: any }> = [];
  const sent: AbMessage[] = [];
  const factory = (sessionId: string, _tool: string, _send: (m: AbMessage) => void, _resumeId?: string) => {
    const driver = {
      sessionId,
      start: async () => { calls.push({ id: sessionId, method: "start" }); return sessionId; },
      prompt: async (t: string, commandId?: string) => {
        calls.push({ id: sessionId, method: "prompt", arg: commandId === undefined ? t : { text: t, commandId } });
      },
      cancel: async (turnId?: string) => { calls.push({ id: sessionId, method: "cancel", arg: turnId }); return false; },
      compact: async () => { calls.push({ id: sessionId, method: "compact" }); },
      revert: async (target: any) => { calls.push({ id: sessionId, method: "revert", arg: target }); },
      resolvePermission: (pid: string, oid: string) => { calls.push({ id: sessionId, method: "resolve", arg: { pid, oid } }); },
      resolveQuestion: () => {},
      setConfig: (key: string, value: unknown) => {
        calls.push({ id: sessionId, method: "setConfig", arg: { key, value } });
      },
      dispose: () => { calls.push({ id: sessionId, method: "dispose" }); },
    };
    created.push(driver);
    return driver as any;
  };
  const mgr = new StructuredAgentManager({ driverFactory: factory, sendMessage: (m) => sent.push(m), onAgentSession: () => {} });
  return { mgr, created, calls, sent };
}

describe("StructuredAgentManager", () => {
  it("starts a driver via startChat and forwards a prompt", async () => {
    const { mgr, created, calls } = makeManager();
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.handleAgentMessage(createMessage("agent:prompt", { sessionId: "s1", requestId: "r", text: "hi" }));
    expect(created.length).toBe(1);
    expect(calls).toContainEqual({ id: "s1", method: "start" });
    expect(calls).toContainEqual({ id: "s1", method: "prompt", arg: "hi" });
  });

  it("reuses the same driver for a second prompt in the same session", async () => {
    const { mgr, created } = makeManager();
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.handleAgentMessage(createMessage("agent:prompt", { sessionId: "s1", requestId: "r1", text: "a" }));
    await mgr.handleAgentMessage(createMessage("agent:prompt", { sessionId: "s1", requestId: "r2", text: "b" }));
    expect(created.length).toBe(1);
  });

  it("routes cancel/session-action/permission-resolve to the existing driver", async () => {
    const { mgr, calls } = makeManager();
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.handleAgentMessage(createMessage("agent:prompt", { sessionId: "s1", requestId: "r", text: "hi" }));
    await mgr.handleAgentMessage(createMessage("agent:cancel", { sessionId: "s1" }));
    await mgr.handleAgentMessage(createMessage("agent:session-action", { sessionId: "s1", action: "compact" }));
    await mgr.handleAgentMessage(createMessage("agent:session-action", { sessionId: "s1", action: "revert", turnId: "t1", messageId: "m1" }));
    await mgr.handleAgentMessage(createMessage("agent:permission-resolve", { sessionId: "s1", permissionId: "p1", optionId: "ok" }));
    expect(calls).toContainEqual({ id: "s1", method: "cancel" });
    expect(calls).toContainEqual({ id: "s1", method: "compact" });
    expect(calls).toContainEqual({ id: "s1", method: "revert", arg: { turnId: "t1", itemId: undefined, messageId: "m1", partId: undefined } });
    expect(calls).toContainEqual({ id: "s1", method: "resolve", arg: { pid: "p1", oid: "ok" } });
  });

  it("ignores control verbs for an unknown session (no driver yet)", async () => {
    const { mgr, calls } = makeManager();
    await mgr.handleAgentMessage(createMessage("agent:cancel", { sessionId: "ghost" }));
    expect(calls).toEqual([]);
  });

  it("disposeAll tears down every driver", async () => {
    const { mgr, calls } = makeManager();
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.startChat({ sessionId: "s2", tool: "codex" });
    await mgr.handleAgentMessage(createMessage("agent:prompt", { sessionId: "s1", requestId: "r", text: "a" }));
    await mgr.handleAgentMessage(createMessage("agent:prompt", { sessionId: "s2", requestId: "r", text: "b" }));
    mgr.disposeAll();
    expect(calls.filter((c) => c.method === "dispose").length).toBe(2);
  });

  it("disposeAll disposes a driver whose start() is still in flight (no orphan)", async () => {
    let disposed = false;
    let releaseStart!: () => void;
    const startGate = new Promise<void>((r) => { releaseStart = r; });
    const factory = (sessionId: string) => ({
      start: async () => { await startGate; return sessionId; },
      prompt: async () => {}, cancel: async () => false, compact: async () => {},
      revert: async () => {}, resolvePermission: () => {}, resolveQuestion: () => {},
      setConfig: () => {}, dispose: () => { disposed = true; },
    });
    const mgr = new StructuredAgentManager({
      driverFactory: factory as any,
      sendMessage: () => {},
      onAgentSession: () => {},
    });
    // Start is mid-spawn (gated): the driver isn't in `drivers` yet.
    const startP = mgr.startChat({ sessionId: "s1", tool: "codex" });
    const disposeP = mgr.disposeAll();
    // Let the gated start resolve; disposeAll must have joined it and disposed
    // the driver it produced rather than leaving the process orphaned.
    releaseStart();
    await Promise.all([startP, disposeP]);
    expect(disposed).toBe(true);
  });

  it("does not cache a driver whose start() failed; a retry spawns a fresh one", async () => {
    const created: any[] = [];
    let failNext = true;
    const factory = (sessionId: string, _tool: string, _send: (m: AbMessage) => void, _resumeId?: string) => {
      const driver = {
        started: false,
        start: async () => {
          if (failNext) { failNext = false; throw new Error("spawn failed"); }
          driver.started = true;
          return sessionId;
        },
        prompt: async () => {},
        cancel: async () => false, compact: async () => {},
        resolvePermission: () => {}, resolveQuestion: () => {}, dispose: () => {},
      };
      created.push(driver);
      return driver as any;
    };
    const errors: AbMessage[] = [];
    const mgr = new StructuredAgentManager({
      driverFactory: factory,
      sendMessage: (m) => { if (m.type === "agent:error") errors.push(m); },
      onAgentSession: () => {},
    });

    // First startChat: start() throws -> rejects, driver NOT cached.
    await expect(mgr.startChat({ sessionId: "s1", tool: "codex" })).rejects.toThrow("spawn failed");
    expect(created.length).toBe(1);

    // Retry: a brand-new driver is spawned (the dead one was not reused) and starts.
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    expect(created.length).toBe(2);
    expect(created[1].started).toBe(true);
  });

  it("routes agent:question-resolve to the existing driver", async () => {
    const calls: string[] = [];
    const factory = (_sessionId: string, _tool: string, _send: (m: AbMessage) => void, _resumeId?: string) => ({
      start: async () => "",
      prompt: async () => {},
      cancel: async () => false, compact: async () => {},
      resolvePermission: () => {},
      resolveQuestion: (id: string, ans: string | string[]) => {
        calls.push(`q:${id}:${Array.isArray(ans) ? ans.join(",") : ans}`);
      },
      dispose: () => {},
    } as any);
    const mgr = new StructuredAgentManager({ driverFactory: factory, sendMessage: () => {}, onAgentSession: () => {} });
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.handleAgentMessage(createMessage("agent:prompt", { sessionId: "s1", requestId: "r1", text: "hi" }));
    await mgr.handleAgentMessage(createMessage("agent:question-resolve", { sessionId: "s1", questionId: "q9", answer: "yes" }));
    expect(calls).toContain("q:q9:yes");
  });

  it("emits agent:error when a driver call rejects", async () => {
    const factory = (sessionId: string, _tool: string, _send: (m: AbMessage) => void, _resumeId?: string) => ({
      start: async () => sessionId,
      prompt: async () => { throw new Error("turn boom"); },
      cancel: async () => false, compact: async () => {},
      resolvePermission: () => {}, resolveQuestion: () => {}, dispose: () => {},
    } as any);
    const errors: any[] = [];
    const mgr = new StructuredAgentManager({
      driverFactory: factory,
      sendMessage: (m) => { if (m.type === "agent:error") errors.push(m); },
      onAgentSession: () => {},
    });
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.handleAgentMessage(createMessage("agent:prompt", { sessionId: "s1", requestId: "r", text: "hi" }));
    expect(errors.length).toBe(1);
    expect(errors[0].sessionId).toBe("s1");
    expect(errors[0].error.message).toContain("turn boom");
  });

  it("startChat starts a driver and reports the agent session id", async () => {
    const started: string[] = [];
    const captured: Array<[string, string]> = [];
    const mgr = new StructuredAgentManager({
      sendMessage: () => {},
      onAgentSession: (sid, aid) => captured.push([sid, aid]),
      driverFactory: (sessionId, tool, send, resumeId) => makeFakeDriver({
        onStart: async () => { started.push(`${sessionId}:${tool}:${resumeId ?? ""}`); return "agent-id-1"; },
      }),
    });
    await mgr.startChat({ sessionId: "s1", tool: "codex", resumeId: "prev" });
    expect(started).toEqual(["s1:codex:prev"]);
    expect(captured).toEqual([["s1", "agent-id-1"]]);
    // Idempotent.
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    expect(started.length).toBe(1);
  });

  it("startChat rejects a non-chat-capable tool", async () => {
    const mgr = new StructuredAgentManager({
      sendMessage: () => {}, onAgentSession: () => {},
      driverFactory: () => makeFakeDriver({}),
    });
    await expect(mgr.startChat({ sessionId: "s1", tool: "cursor-agent" })).rejects.toThrow(/chat/i);
  });

  it("treats claude-code as chat-capable", () => {
    expect(isChatCapableTool("claude-code")).toBe(true);
  });

  it("prompt without a started chat session emits agent:error", async () => {
    const sent: any[] = [];
    const mgr = new StructuredAgentManager({
      sendMessage: (m) => sent.push(m), onAgentSession: () => {},
      driverFactory: () => makeFakeDriver({}),
    });
    await mgr.handleAgentMessage({ type: "agent:prompt", sessionId: "sX", text: "hi" } as any);
    expect(sent.some((m) => m.type === "agent:error")).toBe(true);
  });

  it("stopChat disposes the driver", async () => {
    let disposed = 0;
    const mgr = new StructuredAgentManager({
      sendMessage: () => {}, onAgentSession: () => {},
      driverFactory: () => makeFakeDriver({ onDispose: () => { disposed++; } }),
    });
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    mgr.stopChat("s1");
    expect(disposed).toBe(1);
  });

  it("routes agent:set-config to the session's driver", async () => {
    const { mgr, calls } = makeManager();
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.handleAgentMessage(createMessage("agent:set-config", { sessionId: "s1", key: "model", value: "gpt-5.2" }) as any);
    expect(calls).toContainEqual({ id: "s1", method: "setConfig", arg: { key: "model", value: "gpt-5.2" } });
  });

  it("persists a config change via onSetConfig when the app sets it", async () => {
    const persisted: Array<{ id: string; key: string; value: string }> = [];
    const mgr = new StructuredAgentManager({
      driverFactory: (sessionId) => makeFakeDriver({ start: async () => sessionId }),
      sendMessage: () => {},
      onAgentSession: () => {},
      onSetConfig: (id, key, value) => persisted.push({ id, key, value }),
    });
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    // handleAgentMessage is the manager's inbound dispatch (the switch holding
    // `case "agent:set-config"` at structured-manager.ts:186); it is async.
    await mgr.handleAgentMessage(createMessage("agent:set-config", {
      sessionId: "s1", key: "model", value: "gpt-5.2",
    }) as AbMessage);
    expect(persisted).toEqual([{ id: "s1", key: "model", value: "gpt-5.2" }]);
  });

  it("passes commandId through agent:prompt", async () => {
    const { mgr, calls } = makeManager();
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.handleAgentMessage(createMessage("agent:prompt", { sessionId: "s1", requestId: "r1", text: "", commandId: "builtin:compact" }) as any);
    expect(calls).toContainEqual({ id: "s1", method: "prompt", arg: { text: "", commandId: "builtin:compact" } });
  });

  it("publishes a clearing agent:capabilities frame on stopChat", async () => {
    const { mgr, sent } = makeManager();
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.stopChat("s1");
    const clear = sent.find((m) => m.type === "agent:capabilities" && (m as any).sessionId === "s1");
    expect(clear).toBeDefined();
    expect((clear as any).models).toBeUndefined();
  });

  it("drops the session's replay entry on stopChat, after the clearing frame", async () => {
    const events: string[] = [];
    const mgr = new StructuredAgentManager({
      sendMessage: (m) => { if (m.type === "agent:capabilities") events.push("clear"); },
      onAgentSession: () => {},
      dropSessionReplay: (sessionId) => events.push(`drop:${sessionId}`),
      driverFactory: () => makeFakeDriver(),
    });
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.stopChat("s1");
    // Twice: once before dispose so a reconnect during a slow teardown replays
    // nothing stale, and once after, because dispose itself emits session-scoped
    // frames (a driver clearing its background-task list) that would otherwise
    // re-cache a tombstone for a session that no longer exists.
    expect(events).toEqual(["clear", "drop:s1", "drop:s1"]);
  });

  it("getTranscriptSnapshot delegates to the driver when running", async () => {
    const frames = [createMessage("agent:turn-start", { sessionId: "s1", turnId: "t1" })];
    const mgr = new StructuredAgentManager({
      driverFactory: () => makeFakeDriver({ getTranscriptSnapshot: async () => frames }),
      sendMessage: () => {},
      onAgentSession: () => {},
    });
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    expect(await mgr.getTranscriptSnapshot("s1")).toBe(frames);
  });

  it("getTranscriptSnapshot returns [] for a session with no driver", async () => {
    const mgr = new StructuredAgentManager({
      driverFactory: () => makeFakeDriver(),
      sendMessage: () => {},
      onAgentSession: () => {},
    });
    expect(await mgr.getTranscriptSnapshot("ghost")).toEqual([]);
  });

  it("getTranscriptSnapshot returns [] when the running driver doesn't implement it", async () => {
    const mgr = new StructuredAgentManager({
      driverFactory: () => makeFakeDriver(),
      sendMessage: () => {},
      onAgentSession: () => {},
    });
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    expect(await mgr.getTranscriptSnapshot("s1")).toEqual([]);
  });

  it("replays persisted config through setConfig after start()", async () => {
    const calls: Array<{ method: string; arg?: any }> = [];
    const mgr = new StructuredAgentManager({
      driverFactory: () => makeFakeDriver({
        start: async () => { calls.push({ method: "start" }); return "s1"; },
        setConfig: (key, value) => calls.push({ method: "setConfig", arg: { key, value } }),
      }),
      sendMessage: () => {},
      onAgentSession: () => {},
    });
    await mgr.startChat({
      sessionId: "s1", tool: "codex",
      config: { model: "gpt-5.2", effort: "high" },
    });
    // start() must precede any replayed setConfig.
    expect(calls[0]).toEqual({ method: "start" });
    expect(calls.slice(1)).toEqual(
      expect.arrayContaining([
        { method: "setConfig", arg: { key: "model", value: "gpt-5.2" } },
        { method: "setConfig", arg: { key: "effort", value: "high" } },
      ]),
    );
    expect(calls.length).toBe(3);
  });

  it("replays model before effort even when the persisted key order is effort-first", async () => {
    // Regression: an effort pick validates against the CURRENT model, so if the
    // user set effort before ever touching model, the persisted object's key
    // order is [effort, model] and a naive Object.entries replay would apply
    // effort against the default model (and drop it). Replay must sequence model
    // ahead of effort regardless of stored order.
    const order: string[] = [];
    const mgr = new StructuredAgentManager({
      driverFactory: () => makeFakeDriver({
        start: async () => "s1",
        setConfig: (key) => order.push(key),
      }),
      sendMessage: () => {},
      onAgentSession: () => {},
    });
    await mgr.startChat({
      sessionId: "s1", tool: "codex",
      config: { effort: "high", mode: "plan", model: "gpt-5.2" }, // effort-first
    });
    expect(order).toEqual(["model", "mode", "effort"]);
  });

  it("tears the driver down if a replayed setConfig throws after a successful start", async () => {
    // start() succeeded (subprocess live), so a setConfig that throws during
    // replay must not leave the driver started-but-unregistered — trackTeardown
    // (which calls dispose) must run, mirroring the start()-failure path.
    let disposed = false;
    const mgr = new StructuredAgentManager({
      driverFactory: () => makeFakeDriver({
        start: async () => "s1",
        setConfig: () => { throw new Error("boom"); },
        onDispose: () => { disposed = true; },
      }),
      sendMessage: () => {},
      onAgentSession: () => {},
    });
    await expect(
      mgr.startChat({ sessionId: "s1", tool: "codex", config: { model: "gpt-5.2" } }),
    ).rejects.toThrow("boom");
    expect(disposed).toBe(true);
  });

  it("startChat with no config replays nothing", async () => {
    const calls: string[] = [];
    const mgr = new StructuredAgentManager({
      driverFactory: () => makeFakeDriver({
        start: async () => { calls.push("start"); return "s1"; },
        setConfig: () => calls.push("setConfig"),
      }),
      sendMessage: () => {}, onAgentSession: () => {},
    });
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    expect(calls).toEqual(["start"]);
  });
});

describe("StructuredAgentManager cancel reconciliation", () => {
  it("answers agent:cancel with turn-end when the driver has no live turn, so a client showing a phantom turn can close it", async () => {
    const { mgr, sent } = makeManager();
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    // The fake driver reports "nothing was cancelled" — the real drivers do the
    // same once a turn has finished. Without an answer the app's turn (whose
    // turn-end the relay dropped) would render as running forever.
    await mgr.handleAgentMessage(
      createMessage("agent:cancel", { sessionId: "s1", turnId: "resumed" }),
    );
    const ends = sent.filter((m) => m.type === "agent:turn-end");
    expect(ends.length).toBe(1);
    expect(ends[0]).toMatchObject({ sessionId: "s1", turnId: "resumed", stopReason: "cancelled" });
  });

  // The client's turnId is what lets a driver tell "stop the turn I'm showing"
  // from "stop whatever is live". Drop it here and every driver's staleness
  // guard silently never fires, taking the reconciliation below with it.
  it("forwards the client's turnId to the driver", async () => {
    const { mgr, calls } = makeManager();
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.handleAgentMessage(
      createMessage("agent:cancel", { sessionId: "s1", turnId: "t-42" }),
    );
    expect(calls).toContainEqual({ id: "s1", method: "cancel", arg: "t-42" });
  });

  it("does not synthesize a turn-end when the driver actually cancelled a live turn (the driver emits its own)", async () => {
    const { mgr, sent, created } = makeManager();
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    created[0].cancel = async () => true;
    await mgr.handleAgentMessage(
      createMessage("agent:cancel", { sessionId: "s1", turnId: "t1" }),
    );
    expect(sent.filter((m) => m.type === "agent:turn-end").length).toBe(0);
  });

  it("still answers with turn-end when cancel() itself rejects, and surfaces the error too", async () => {
    const { mgr, sent, created } = makeManager();
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    // A dead agent process whose driver is still registered: turn/interrupt
    // rejects. This is precisely when the client is most likely stuck on a turn
    // whose end never arrives, so the reconciliation must not be skipped.
    created[0].cancel = async () => { throw new Error("rpc dead"); };
    await mgr.handleAgentMessage(
      createMessage("agent:cancel", { sessionId: "s1", turnId: "t1" }),
    );
    expect(sent.filter((m) => m.type === "agent:turn-end")).toMatchObject([
      { sessionId: "s1", turnId: "t1", stopReason: "cancelled" },
    ]);
    // The rejection still reaches the user rather than being swallowed.
    expect(sent.filter((m) => m.type === "agent:error").length).toBe(1);
  });
});
