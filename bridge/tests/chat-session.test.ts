import { describe, it, expect } from "bun:test";
import {
  ChatSession,
  type ChatSessionOpts,
  type ChatSessionProfile,
  type SelectionSnapshot,
} from "../src/structured/chat-session";
import type { ConfigPick } from "../src/structured/set-config";
import { StructuredAgentManager } from "../src/structured/structured-manager";
import { createMessage, type AbMessage } from "../src/protocol";
import { ClaudeDriver } from "../src/agents/claude-code/chat-backend";
import { CodexDriver, type CodexEndpoint } from "../src/agents/codex/chat-backend";
import { OpencodeDriver, type OpencodeClientLike, type OpencodeEvent } from "../src/agents/opencode/chat-backend";
import type { ClaudeQueryLike, PromptStreamController } from "../src/agents/claude-code/spawn";

// A backend that does nothing but record what the shared session asked of it.
// The point of these tests is the machinery ABOVE this line: everything the
// three real backends used to carry a private copy of.
class TestSession extends ChatSession {
  protected readonly profile: ChatSessionProfile;
  readonly calls: string[] = [];
  snapshot: AbMessage[] | (() => never) = [];
  liveModel?: string;
  rejectSelection = false;
  readonly applied: ConfigPick[] = [];
  readonly reverts: Array<() => void> = [];

  constructor(opts: ChatSessionOpts & { profile?: Partial<ChatSessionProfile> }) {
    super(opts);
    this.profile = {
      turnSource: "session",
      mergeItems: true,
      snapshotDuringTurn: true,
      interruptScope: "turn",
      ...opts.profile,
    };
  }

  protected async startBackend(resumeId?: string): Promise<string> {
    this.calls.push(`start:${resumeId ?? ""}`);
    return "native-id";
  }
  protected async sendPrompt(text: string, commandId?: string): Promise<void> {
    this.calls.push(`prompt:${text}:${commandId ?? ""}`);
  }
  protected async interrupt(turnId: string): Promise<void> {
    this.calls.push(`interrupt:${turnId}`);
  }
  protected async transcriptSnapshot(): Promise<AbMessage[]> {
    if (typeof this.snapshot === "function") return this.snapshot();
    return this.snapshot;
  }
  protected disposeBackend(): void {
    this.calls.push("dispose");
  }
  async compact(): Promise<void> {
    this.calls.push("compact");
  }
  async revert(): Promise<void> {
    this.calls.push("revert");
  }
  protected liveModelId(): string | undefined {
    return this.liveModel;
  }
  protected validateSelection(pick: ConfigPick): boolean {
    return !this.rejectSelection || pick.key !== "model";
  }
  protected applySelection(pick: ConfigPick, prev: SelectionSnapshot): void {
    this.applied.push(pick);
    this.reverts.push(() => {
      if (pick.key === "model") { this.selModel = prev.model; this.modelExplicit = prev.modelExplicit; }
      if (pick.key === "mode") this.selMode = prev.mode;
      if (pick.key === "effort") { this.selEffort = prev.effort; this.effortExplicit = prev.effortExplicit; }
    });
  }

  // --- reach-throughs so a test can drive the shared machinery directly ---
  seedCatalog(): void {
    this.capModels = [
      { id: "m1", name: "M1", efforts: ["low", "high"] },
      { id: "m2", name: "M2" },
    ];
    this.capModes = [{ id: "safe", name: "Safe" }];
    this.capCommands = [{ id: "builtin:compact", name: "compact" }];
    this.capabilitiesReady();
  }
  open(turnId?: string | null): void { this.openTurn(turnId); }
  close(o: Parameters<ChatSession["closeTurn"]>[0]): void { this.closeTurn(o); }
  item(itemId: string, fields: Record<string, unknown>, turnId = ""): void {
    this.emitItem(itemId, fields, { turnId });
  }
  plan(turnId: string, entries: Array<{ text: string; status: string }>): void {
    this.emitPlan(turnId, entries);
  }
  permission(title: string, answer: (o: string | null) => void, permissionId?: string): string {
    return this.askPermission({
      ...(permissionId ? { permissionId } : {}),
      title,
      options: [{ optionId: "ok", label: "Allow", kind: "allow_once" }],
    }, answer);
  }
  question(
    answer: (v: string | string[] | null) => void,
    o?: { labels?: readonly string[]; single?: boolean },
  ): string {
    return this.askQuestion({ kind: "single_select", prompt: "?" }, answer, o);
  }
  guard(call: Promise<unknown>, axis: string, id: string, revert: () => void): void {
    this.guardPick(call, axis, id, revert);
  }
}

function make(profile?: Partial<ChatSessionProfile>) {
  const sent: AbMessage[] = [];
  const s = new TestSession({ sessionId: "s1", sendMessage: (m) => sent.push(m), ...(profile ? { profile } : {}) });
  return { s, sent, types: () => sent.map((m) => m.type) };
}

const flush = () => new Promise((r) => setTimeout(r, 0));

describe("ChatSession turn lifecycle", () => {
  it("start() advertises an empty not-ready catalog before the backend boots", async () => {
    const { s, sent } = make();
    const id = await s.start("resume-1");
    expect(id).toBe("native-id");
    const first = sent[0];
    expect(first?.type).toBe("agent:capabilities");
    if (first?.type === "agent:capabilities") {
      expect(first.ready).toBe(false);
      expect(first.models).toEqual([]);
    }
    // The frame must precede the backend's own boot, not follow it.
    expect(s.calls).toEqual(["start:resume-1"]);
  });

  it("prompt() mints turn-<n> for a session-sourced turn and routes builtin:compact past it", async () => {
    const { s, sent } = make();
    await s.start();
    await s.prompt("hi");
    await s.prompt("", "builtin:compact");
    const starts = sent.filter((m) => m.type === "agent:turn-start");
    expect(starts).toHaveLength(1);
    expect(starts[0]?.type === "agent:turn-start" ? starts[0].turnId : "").toBe("turn-0");
    expect(s.calls).toEqual(["start:", "prompt:hi:", "compact"]);
  });

  it("a backend-sourced turn carries the provider's id, and a nameless one still opens", async () => {
    const { s, sent } = make({ turnSource: "backend" });
    await s.start();
    await s.prompt("hi");
    expect(sent.some((m) => m.type === "agent:turn-start")).toBe(false);
    s.open("t-9");
    s.open(null);
    const ids = sent.filter((m) => m.type === "agent:turn-start").map((m) => (m as any).turnId);
    expect(ids).toEqual(["t-9", ""]);
  });

  it("turn-end carries the stopReason and omits `error` unless one is given", async () => {
    const { s, sent } = make();
    await s.start();
    await s.prompt("hi");
    s.close({ stopReason: "end_turn" });
    const end = sent.findLast((m) => m.type === "agent:turn-end");
    expect(end?.type === "agent:turn-end" ? end.stopReason : "").toBe("end_turn");
    expect(Object.keys(end as object)).not.toContain("error");
  });

  it("cancel() refuses a stale turnId, refuses when idle, and clears the intent at the next boundary", async () => {
    const { s } = make();
    await s.start();
    expect(await s.cancel()).toBe(false); // nothing running
    await s.prompt("hi");
    expect(await s.cancel("turn-0-stale")).toBe(false);
    expect(s.calls).not.toContain("interrupt:turn-0");
    expect(await s.cancel("turn-0")).toBe(true);
    expect(s.calls).toContain("interrupt:turn-0");
    s.close({ stopReason: "cancelled" });
    // A second turn must not inherit the first turn's cancel intent.
    await s.prompt("again");
    expect(await s.cancel("turn-0")).toBe(false);
  });

  it("a turn-scoped cancel whose turn-end lands during the interrupt still yields exactly one turn-end", async () => {
    // The backend can close the turn while interrupt() is still in flight.
    // Answering from activeTurnId then reports "nothing cancelled", and the
    // manager emits its own turn-end for a turn the backend already ended.
    class RacingSession extends TestSession {
      protected async interrupt(turnId: string): Promise<void> {
        await super.interrupt(turnId);
        this.close({ stopReason: "cancelled" });
      }
    }
    const sent: AbMessage[] = [];
    const session = new RacingSession({ sessionId: "s1", sendMessage: (m) => sent.push(m) });
    const mgr = new StructuredAgentManager({
      driverFactory: () => session,
      sendMessage: (m) => sent.push(m),
      onAgentSession: () => {},
    });
    await mgr.startChat({ sessionId: "s1", tool: "codex" });
    await mgr.handleAgentMessage(createMessage("agent:prompt", { sessionId: "s1", requestId: "r", text: "hi" }));
    await mgr.handleAgentMessage(createMessage("agent:cancel", { sessionId: "s1", turnId: "turn-0" }));
    expect(sent.filter((m) => m.type === "agent:turn-end").length).toBe(1);
  });

  it("a session-scoped interrupt still fires with no open turn, and reports that none was running", async () => {
    // opencode's shape: abort takes a session, so an unaimed cancel is the only
    // thing that stops work the turn bookkeeping lost track of.
    const { s } = make({ interruptScope: "session" });
    await s.start();
    expect(await s.cancel()).toBe(false);
    expect(s.calls).toContain("interrupt:");
    await s.prompt("hi");
    expect(await s.cancel()).toBe(true);
  });
});

describe("ChatSession items", () => {
  it("first sighting is item-added, later ones item-updated, and a merging session keeps prior fields", async () => {
    const { s, sent } = make();
    await s.start();
    await s.prompt("hi");
    s.item("tool:1", { kind: "tool_call", toolKind: "shell", title: "Bash", status: "running" }, "turn-0");
    s.item("tool:1", { status: "completed" }, "turn-0");
    const added = sent.find((m) => m.type === "agent:item-added");
    const updated = sent.find((m) => m.type === "agent:item-updated");
    expect((added as any).item.status).toBe("running");
    expect((updated as any).item).toEqual({
      kind: "tool_call", toolKind: "shell", title: "Bash", status: "completed", itemId: "tool:1",
    });
  });

  it("a non-merging session emits the mapper's item verbatim", async () => {
    const { s, sent } = make({ mergeItems: false });
    await s.start();
    s.item("p1", { itemId: "p1", kind: "message", role: "assistant", text: "hi" }, "t");
    expect((sent.find((m) => m.type === "agent:item-added") as any).item)
      .toEqual({ itemId: "p1", kind: "message", role: "assistant", text: "hi" });
  });

  it("an item id reused after a turn boundary is a first sighting again", async () => {
    const { s, sent } = make();
    await s.start();
    await s.prompt("a");
    s.item("p1", { kind: "message", text: "x" }, "turn-0");
    s.close({ stopReason: "end_turn" });
    await s.prompt("b");
    s.item("p1", { kind: "message", text: "y" }, "turn-1");
    expect(sent.filter((m) => m.type === "agent:item-added" && m.itemId === "p1")).toHaveLength(2);
    // The merge cache is dropped with it, so the second card is not a blend.
    expect((sent.findLast((m) => m.type === "agent:item-added") as any).item)
      .toEqual({ kind: "message", text: "y", itemId: "p1" });
  });

  it("the synthetic plan item is always an update, keyed by turn", async () => {
    const { s, sent } = make();
    await s.start();
    s.plan("t1", [{ text: "scout", status: "running" }]);
    s.plan("t1", [{ text: "scout", status: "completed" }]);
    const plans = sent.filter((m) => m.type === "agent:item-updated" && m.itemId === "plan:t1");
    expect(plans).toHaveLength(2);
    expect(sent.some((m) => m.type === "agent:item-added")).toBe(false);
  });
});

describe("ChatSession prompt retraction", () => {
  it("retracts pending permissions before questions at a turn boundary and answers each with null", async () => {
    const { s, sent } = make();
    await s.start();
    await s.prompt("hi");
    const answers: Array<string | string[] | null> = [];
    s.permission("Run?", (o) => answers.push(o));
    s.question((v) => answers.push(v));
    s.close({ stopReason: "error" });
    const retracted = sent.filter((m) => m.type === "agent:request-retracted");
    expect(retracted).toHaveLength(2);
    expect((retracted[0] as any).permissionId).toBe("perm-0");
    expect((retracted[1] as any).questionId).toBe("q-0");
    expect(answers).toEqual([null, null]);
    // The retraction frames follow the turn-end, never precede it.
    expect(sent.findIndex((m) => m.type === "agent:turn-end"))
      .toBeLessThan(sent.findIndex((m) => m.type === "agent:request-retracted"));
  });

  it("retracts on dispose and drops the pending entries, so a late answer is a no-op", async () => {
    const { s, sent } = make();
    await s.start();
    const answers: Array<string | null> = [];
    const id = s.permission("Run?", (o) => answers.push(o));
    await s.dispose();
    expect(sent.filter((m) => m.type === "agent:request-retracted")).toHaveLength(1);
    s.resolvePermission(id, "ok");
    expect(answers).toEqual([null]);
    expect(s.calls).toContain("dispose");
  });

  it("does not retract a prompt that was already answered", async () => {
    const { s, sent } = make();
    await s.start();
    await s.prompt("hi");
    const id = s.permission("Run?", () => {});
    s.resolvePermission(id, "ok");
    s.close({ stopReason: "end_turn" });
    expect(sent.some((m) => m.type === "agent:request-retracted")).toBe(false);
  });

  it("a prompt group withdraws its whole batch once, and only what is still open", async () => {
    const { s, sent } = make();
    await s.start();
    const group = (s as any).promptGroup();
    const seen: Array<string | string[] | null> = [];
    const a = (s as any).askQuestion({ kind: "text", prompt: "1" }, (v: any) => seen.push(v), { group });
    (s as any).askQuestion({ kind: "text", prompt: "2" }, (v: any) => seen.push(v), { group });
    s.resolveQuestion(a, "answered");
    group.retract();
    group.retract(); // idempotent
    expect(seen).toEqual(["answered", null]);
    expect(sent.filter((m) => m.type === "agent:request-retracted")).toHaveLength(1);
  });

  it("translates the app's synthetic option index back to the label the backend answers by", async () => {
    const { s } = make();
    await s.start();
    const got: Array<string | string[] | null> = [];
    const single = s.question((v) => got.push(v), { labels: ["Yes", "No"], single: true });
    s.resolveQuestion(single, ["1", "0"]);
    const multi = s.question((v) => got.push(v), { labels: ["a.ts", "b.ts"] });
    s.resolveQuestion(multi, ["0", "1"]);
    const passthrough = s.question((v) => got.push(v), { labels: ["Yes"] });
    s.resolveQuestion(passthrough, "Yes");
    const free = s.question((v) => got.push(v));
    s.resolveQuestion(free, "1");
    expect(got).toEqual(["No", ["a.ts", "b.ts"], "Yes", "1"]);
  });

  it("an answer for an unknown prompt is dropped unless the backend claims it", async () => {
    const { s } = make();
    await s.start();
    s.resolvePermission("nope", "ok");
    s.resolveQuestion("nope", "x");
    expect(s.calls).toEqual(["start:"]);
  });
});

describe("ChatSession capabilities and config", () => {
  it("queues picks until discovery lands, then applies them in arrival order", async () => {
    const { s, sent } = make();
    await s.start();
    s.setConfig("model", "m1");
    s.setConfig("effort", "high");
    s.setConfig("mode", 42); // non-string picks never reach validation
    expect(s.applied).toEqual([]);
    s.seedCatalog();
    expect(s.applied).toEqual([
      { key: "model", id: "m1", clearEffort: false },
      { key: "effort", id: "high" },
    ]);
    const caps = sent.findLast((m) => m.type === "agent:capabilities");
    expect(caps?.type === "agent:capabilities" ? caps.ready : false).toBe(true);
    expect(caps?.type === "agent:capabilities" ? caps.currentModelId : "").toBe("m1");
    expect(caps?.type === "agent:capabilities" ? caps.currentEffortId : "").toBe("high");
  });

  it("emits no capabilities echo for an unadvertised id or a backend veto", async () => {
    const { s, sent } = make();
    await s.start();
    s.seedCatalog();
    const before = sent.filter((m) => m.type === "agent:capabilities").length;
    s.setConfig("model", "made-up");
    s.setConfig("effort", "ultra");
    s.rejectSelection = true;
    s.setConfig("model", "m1");
    expect(sent.filter((m) => m.type === "agent:capabilities").length).toBe(before);
    expect(s.applied).toEqual([]);
  });

  it("advertises the live model when the user has pinned none, and stops once they pin one", async () => {
    const { s, sent } = make();
    s.liveModel = "m2";
    await s.start();
    s.seedCatalog();
    expect((sent.findLast((m) => m.type === "agent:capabilities") as any).currentModelId).toBe("m2");
    s.setConfig("model", "m1");
    expect((sent.findLast((m) => m.type === "agent:capabilities") as any).currentModelId).toBe("m1");
  });

  it("switching to a model without the current effort clears it", async () => {
    const { s, sent } = make();
    await s.start();
    s.seedCatalog();
    s.setConfig("model", "m1");
    s.setConfig("effort", "high");
    s.setConfig("model", "m2");
    const caps = sent.findLast((m) => m.type === "agent:capabilities") as any;
    expect(caps.currentEffortId).toBeUndefined();
    expect(s.applied.at(-1)).toEqual({ key: "model", id: "m2", clearEffort: true });
  });

  it("guardPick rolls a rejected pick back, re-emits, and lets a newer pick win", async () => {
    const { s, sent } = make();
    await s.start();
    s.seedCatalog();
    s.setConfig("mode", "safe");
    const before = sent.filter((m) => m.type === "agent:capabilities").length;
    s.guard(Promise.reject(new Error("no")), "mode", "safe", s.reverts.at(-1)!);
    await flush();
    expect((sent.findLast((m) => m.type === "agent:capabilities") as any).currentModeId).toBeUndefined();
    expect(sent.filter((m) => m.type === "agent:capabilities").length).toBe(before + 1);

    // A stale rejection must not clobber the selection a later pick landed.
    s.setConfig("mode", "safe");
    let rejectFirst!: (e: unknown) => void;
    s.guard(new Promise((_r, rej) => { rejectFirst = rej; }), "mode", "safe", s.reverts.at(-1)!);
    s.guard(Promise.resolve(), "mode", "safe", () => {});
    rejectFirst(new Error("stale"));
    await flush();
    expect((sent.findLast((m) => m.type === "agent:capabilities") as any).currentModeId).toBe("safe");
  });

  it("contains a rejected pick whose rollback re-emit also fails", async () => {
    const sent: AbMessage[] = [];
    let fail = false;
    const s = new TestSession({
      sessionId: "s1",
      sendMessage: (m) => { sent.push(m); if (fail && m.type === "agent:capabilities") throw new Error("transport closed"); },
    });
    const unhandled: unknown[] = [];
    const onUnhandled = (e: unknown) => unhandled.push(e);
    process.on("unhandledRejection", onUnhandled);
    try {
      await s.start();
      fail = true;
      s.guard(Promise.reject(new Error("no")), "mode", "x", () => {});
      await flush();
      await flush();
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
    expect(unhandled).toEqual([]);
  });
});

describe("ChatSession transcript snapshot", () => {
  it("returns [] rather than a half-streamed turn when the backend can't filter one", async () => {
    const { s } = make({ snapshotDuringTurn: false });
    await s.start();
    s.snapshot = [{ type: "agent:session-reset", sessionId: "s1" } as AbMessage];
    expect(await s.getTranscriptSnapshot()).toHaveLength(1);
    await s.prompt("hi");
    expect(await s.getTranscriptSnapshot()).toEqual([]);
    s.close({ stopReason: "end_turn" });
    expect(await s.getTranscriptSnapshot()).toHaveLength(1);
  });

  it("fails soft to [] when the backend read throws", async () => {
    const { s } = make();
    await s.start();
    s.snapshot = () => { throw new Error("boom"); };
    expect(await s.getTranscriptSnapshot()).toEqual([]);
  });
});

// The one deliberate wire change of the split: the three drivers used to emit
// the `current*` keys in two different orders, and one shared emitter cannot
// preserve both. Pin the normalized order so a future backend cannot re-fork it.
describe("agent:capabilities key order is identical across backends", () => {
  function claudeSession(sent: AbMessage[]) {
    async function* chunks() { /* nothing arrives during this test */ }
    const q = Object.assign(chunks(), {
      interrupt: async () => {},
      setModel: async () => {},
      setPermissionMode: async () => {},
      applyFlagSettings: async () => {},
      supportedCommands: async () => [],
      supportedModels: async () => [],
      initializationResult: async () => ({}),
      close: () => {},
    }) as unknown as ClaudeQueryLike;
    const controller: PromptStreamController = { push: () => {}, end: () => {}, isEnded: () => false };
    return new ClaudeDriver({ sessionId: "s1", sendMessage: (m) => sent.push(m), spawn: () => ({ query: q, controller }) });
  }

  function codexSession(sent: AbMessage[]) {
    const ep: CodexEndpoint = {
      request: async () => ({}),
      notify: () => {},
      onNotification: () => {},
      onRequest: () => {},
      onClose: () => {},
      dispose: () => {},
    };
    return new CodexDriver({ sessionId: "s1", endpoint: ep, sendMessage: (m) => sent.push(m), cwd: "/x" });
  }

  function opencodeSession(sent: AbMessage[]) {
    const client = {
      createSession: async () => "root",
      messages: async () => [],
      deleteMessage: async () => {},
      prompt: async () => {},
      abort: async () => {},
      summarize: async () => {},
      replyPermission: async () => {},
      replyQuestion: async () => {},
      listCommands: async () => [],
      listAgents: async () => [],
      listProviders: async () => ({ all: [], default: {}, connected: [] }),
      command: async () => {},
      events: async function* (): AsyncGenerator<OpencodeEvent> {},
      dispose: () => {},
    } as unknown as OpencodeClientLike;
    return new OpencodeDriver({ sessionId: "s1", client, sendMessage: (m) => sent.push(m) });
  }

  it("emits the same key sequence for claude, codex and opencode", async () => {
    const shapes: string[][] = [];
    for (const build of [claudeSession, codexSession, opencodeSession]) {
      const sent: AbMessage[] = [];
      const driver = build(sent);
      await driver.start().catch(() => {});
      const caps = sent.find((m) => m.type === "agent:capabilities");
      expect(caps).toBeDefined();
      shapes.push(Object.keys(caps as object));
      await driver.dispose();
    }
    expect(shapes[1]).toEqual(shapes[0]!);
    expect(shapes[2]).toEqual(shapes[0]!);
    // `type` and `ts` are stamped by createMessage; the rest is the payload.
    expect(shapes[0]).toEqual(expect.arrayContaining(["sessionId", "ready", "commands", "modes", "models"]));
  });
});
