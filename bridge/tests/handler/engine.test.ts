// bridge/tests/handler/engine.test.ts
import { describe, it, test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { HandlerEngine } from "../../src/handler/engine";
import { RunawayGuard } from "../../src/handler/runaway-guard";
import { LIMIT_FALLBACK_MS, LIMIT_PARK_CEILING, MIN_PARK_MS } from "../../src/handler/lifecycle";
import type { AbMessage } from "../../src/protocol";
import type { HandlerDecision } from "../../src/handler/decision";
import type { HandlerSessionRecord } from "../../src/handler/brief";

const BRIEF = {
  taskSummary: "Migrating auth", willHandle: ["routine prompts"],
  wakeFor: ["schema changes"], doneWhen: "tests pass", thenItems: ["/compact"],
};

interface FakeTimer { ms: number; fn: () => void; cancelled: boolean; fired: boolean }

function makeEngine(overrides: Record<string, unknown> = {}) {
  const sent: AbMessage[] = [];
  const injected: Array<[string, string]> = [];
  const saved: unknown[] = [];
  const activity: unknown[] = [];
  const pushes: string[] = [];
  const timers: FakeTimer[] = [];
  const clock = { t: 1000 };
  const engine = new HandlerEngine({
    projectId: "proj", projectPath: () => "/proj", tool: () => "claude-code", abDir: "/tmp/unused",
    adapter: {
      injectReply: (id: string, t: string) => injected.push([id, t]),
      recentOutput: () => "pty-tail",
      transcriptPath: () => "/t.jsonl",
      outputKind: () => "pty",
      supportsSlashCommands: () => true,
    },
    sendAb: (m: AbMessage) => sent.push(m),
    sendPush: (m: string) => pushes.push(m),
    loadConfigFn: () => ({ version: 2, defaultNotifyOnly: false }),
    appendActivityFn: (r: unknown) => activity.push(r),
    loadSessionFn: () => null,
    saveSessionFn: (r: unknown) => saved.push(r),
    now: () => clock.t,
    schedule: (ms: number, fn: () => void) => {
      const t: FakeTimer = { ms, fn: () => { t.fired = true; fn(); }, cancelled: false, fired: false };
      timers.push(t);
      return () => { t.cancelled = true; };
    },
    ...overrides,
  } as never);
  // Timers still waiting to fire — a re-arm cancels its predecessor, so this is
  // how "exactly one timer armed" is asserted.
  const armed = () => timers.filter((t) => !t.cancelled && !t.fired);
  return { engine, sent, injected, saved, activity, pushes, timers, armed, clock };
}

interface SessionSnapshot {
  state: string; parkKind?: string; parkedUntil?: number; pendingEscalations: number;
  observability?: string;
}
function statusOf(sent: AbMessage[]): SessionSnapshot {
  const status = sent.filter((m) => m.type === "handler:status").at(-1) as never as {
    sessions: SessionSnapshot[];
  };
  return status.sessions[0];
}
function records(activity: unknown[], kind: string): unknown[] {
  return activity.filter((a) => (a as { decision: string }).decision === kind);
}

describe("arm/disarm", () => {
  it("arm persists the record, logs brief_armed, and emits a session snapshot", () => {
    const { engine, sent, saved, activity } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    expect((saved[0] as { armed: boolean }).armed).toBe(true);
    expect((activity[0] as { decision: string }).decision).toBe("brief_armed");
    const status = sent.find((m) => m.type === "handler:status") as never as {
      sessions: Array<{ terminalId: string; state: string }>;
    };
    expect(status.sessions).toHaveLength(1);
    expect(status.sessions[0].terminalId).toBe("t1");
    expect(status.sessions[0].state).toBe("watching");
  });
  it("re-arming an armed session logs brief_edited and keeps the ledger", () => {
    const { engine, activity } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    engine.arm({ terminalId: "t1", brief: { ...BRIEF, taskSummary: "edited" }, notifyOnly: true });
    expect((activity[1] as { decision: string }).decision).toBe("brief_edited");
  });
  it("disarm saves armed:false and removes the session from status", () => {
    const { engine, sent, saved } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    engine.disarm("t1");
    expect((saved.at(-1) as { armed: boolean }).armed).toBe(false);
    const status = sent.at(-1) as never as { sessions: unknown[] };
    expect(status.sessions).toHaveLength(0);
  });
});

const continueDecision = decide({});

test("arm persists the judge choice on the session record and snapshot", () => {
  const saved: HandlerSessionRecord[] = [];
  const sent: AbMessage[] = [];
  const { engine } = makeEngine({ saveSessionFn: (r: HandlerSessionRecord) => saved.push(r), sendAb: (m: AbMessage) => sent.push(m) });
  engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false, judgeTool: "codex", judgeModel: "gpt-5.3-codex" });
  expect(saved.at(-1)?.judgeTool).toBe("codex");
  expect(saved.at(-1)?.judgeModel).toBe("gpt-5.3-codex");
  const status = sent.filter((m) => m.type === "handler:status").at(-1) as never as {
    sessions: Array<{ judgeTool?: string }>; tool?: string;
  };
  expect(status.sessions[0].judgeTool).toBe("codex");
  expect(status.tool).toBeUndefined();
});

test("arm ignores an unknown judge tool but applies the model", () => {
  const saved: HandlerSessionRecord[] = [];
  const { engine } = makeEngine({ saveSessionFn: (r: HandlerSessionRecord) => saved.push(r) });
  engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false, judgeTool: "codex" });
  engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false, judgeTool: "not-a-cli", judgeModel: "m2" });
  expect(saved.at(-1)?.judgeTool).toBe("codex"); // ignored, not cleared
  expect(saved.at(-1)?.judgeModel).toBe("m2");
});

test("arm with empty strings clears back to defaults", () => {
  const saved: HandlerSessionRecord[] = [];
  const { engine } = makeEngine({ saveSessionFn: (r: HandlerSessionRecord) => saved.push(r) });
  engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false, judgeTool: "codex", judgeModel: "m" });
  engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false, judgeTool: "", judgeModel: "" });
  expect(saved.at(-1)?.judgeTool).toBeUndefined();
  expect(saved.at(-1)?.judgeModel).toBeUndefined();
});

test("decision runs on the session judge, falling back to the session's own tool", async () => {
  const calls: { tool: string; model?: string }[] = [];
  const { engine } = makeEngine({
    tool: () => "claude-code",
    runDecisionFn: async (o: { tool: string; model?: string }) => { calls.push({ tool: o.tool, model: o.model }); return continueDecision; },
  });
  engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false, judgeTool: "codex", judgeModel: "m" });
  await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
  expect(calls[0]).toEqual({ tool: "codex", model: "m" });

  engine.arm({ terminalId: "t2", brief: BRIEF, notifyOnly: false });
  await engine.handleEvent({ terminalId: "t2", event: "turn_end" });
  expect(calls[1]).toEqual({ tool: "claude-code", model: undefined });
});

test("plan honours a one-shot judge override, else the stored record, and echoes the STORED judge", async () => {
  const planCalls: { tool: string; model?: string }[] = [];
  const sent: AbMessage[] = [];
  const { engine } = makeEngine({
    tool: () => "claude-code",
    sendAb: (m: AbMessage) => sent.push(m),
    loadSessionFn: (tid: string) => tid === "t1"
      ? { version: 1, terminalId: "t1", armed: false, brief: BRIEF, notifyOnly: false,
          armedAt: 1, doneWhenMet: false, ledger: [], escalations: [],
          judgeTool: "opencode", judgeModel: "stored-m" }
      : null,
    runPlanFn: async (o: { tool: string; model?: string }) => { planCalls.push({ tool: o.tool, model: o.model }); return BRIEF; },
  });
  // Override wins for the call itself…
  await engine.plan("t1", { judgeTool: "codex", judgeModel: "override-m" });
  expect(planCalls[0]).toEqual({ tool: "codex", model: "override-m" });
  // …but the echo is the STORED judge (what a fresh sheet should seed from).
  const result = sent.filter((m) => m.type === "handler:planResult").at(-1) as never as {
    judgeTool?: string; judgeModel?: string;
  };
  expect(result.judgeTool).toBe("opencode");
  expect(result.judgeModel).toBe("stored-m");
  // No override → stored record drives the call.
  await engine.plan("t1");
  expect(planCalls[1]).toEqual({ tool: "opencode", model: "stored-m" });
});

test("plan({judgeTool: ''}) forces the session's own tool even over a stored judge", async () => {
  const planCalls: { tool: string; model?: string }[] = [];
  const { engine } = makeEngine({
    tool: () => "claude-code",
    loadSessionFn: (tid: string) => tid === "t1"
      ? { version: 1, terminalId: "t1", armed: false, brief: BRIEF, notifyOnly: false,
          armedAt: 1, doneWhenMet: false, ledger: [], escalations: [],
          judgeTool: "opencode", judgeModel: "stored-m" }
      : null,
    runPlanFn: async (o: { tool: string; model?: string }) => { planCalls.push({ tool: o.tool, model: o.model }); return BRIEF; },
  });
  await engine.plan("t1", { judgeTool: "" });
  // '' is a one-shot "force default" — deps.tool(terminalId), not the stored
  // "opencode" record, and the model falls through with it (no override given).
  expect(planCalls[0]).toEqual({ tool: "claude-code", model: "stored-m" });
});

test("bridge-restart re-arm keeps the persisted judge when the arm carries none", () => {
  const saved: HandlerSessionRecord[] = [];
  const { engine } = makeEngine({
    saveSessionFn: (r: HandlerSessionRecord) => saved.push(r),
    loadSessionFn: () => ({ version: 1, terminalId: "t1", armed: true, brief: BRIEF,
      notifyOnly: false, armedAt: 1, doneWhenMet: false, ledger: [], escalations: [],
      judgeTool: "codex", judgeModel: "m" }),
  });
  engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
  expect(saved.at(-1)?.judgeTool).toBe("codex");
});

describe("plan", () => {
  it("emits planResult with the brief on success", async () => {
    const { engine, sent } = makeEngine({ runPlanFn: async () => BRIEF });
    await engine.plan("t1");
    const r = sent.find((m) => m.type === "handler:planResult") as never as {
      fallback: boolean; brief?: { taskSummary: string };
    };
    expect(r.fallback).toBe(false);
    expect(r.brief?.taskSummary).toBe("Migrating auth");
  });
  it("emits fallback:true with previousBrief when the judge fails", async () => {
    const { engine, sent } = makeEngine({
      runPlanFn: async () => null,
      loadSessionFn: () => ({
        version: 1, terminalId: "t1", armed: false, brief: BRIEF,
        notifyOnly: false, armedAt: 1, doneWhenMet: false, ledger: [],
      }),
    });
    await engine.plan("t1");
    const r = sent.find((m) => m.type === "handler:planResult") as never as {
      fallback: boolean; previousBrief?: { taskSummary: string };
    };
    expect(r.fallback).toBe(true);
    expect(r.previousBrief?.taskSummary).toBe("Migrating auth");
  });
});

describe("escalation accounting", () => {
  it("reply on an unarmed terminal is a safe no-op", () => {
    const { engine } = makeEngine();
    expect(() => engine.onUserReply("t-unknown", "x\r")).not.toThrow();
  });

  it("a submitted line clears ALL pending escalations; bare keystrokes clear none", async () => {
    const { engine, sent } = makeEngine({ runDecisionFn: async () => decide({ decision: "escalate" }) });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    const pending = () => (sent.at(-1) as never as {
      sessions: Array<{ pendingEscalations: number; state: string }>;
    }).sessions[0];
    expect(pending().pendingEscalations).toBe(2);
    engine.onUserReply("t1", "l");
    engine.onUserReply("t1", "s");
    expect(pending().pendingEscalations).toBe(2); // typing alone never swallows a question
    engine.onUserReply("t1", "\r");
    expect(pending().pendingEscalations).toBe(0);
    expect(pending().state).toBe("watching");
  });

  it("status snapshots replay full escalation payloads (reconnect can rebuild rows)", async () => {
    const { engine, sent } = makeEngine({ runDecisionFn: async () => decide({ decision: "escalate" }) });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    const esc = sent.find((m) => m.type === "handler:escalation") as never as { escalationId: string };
    const status = sent.at(-1) as never as {
      sessions: Array<{ escalations: Array<{ escalationId: string; question: string }> }>;
    };
    expect(status.sessions[0].escalations).toHaveLength(1);
    expect(status.sessions[0].escalations[0].escalationId).toBe(esc.escalationId);
    expect(status.sessions[0].escalations[0].question).toBeTruthy();
  });
});

function decide(d: Partial<HandlerDecision>): HandlerDecision {
  return { decision: "continue", confidence: 0.9, reason: "r", ...d } as HandlerDecision;
}

describe("handleEvent decision loop", () => {
  it("ignores events for unarmed sessions (no judge call)", async () => {
    let judged = 0;
    const { engine } = makeEngine({ runDecisionFn: async () => { judged++; return decide({}); } });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect(judged).toBe(0);
  });

  it("notifyOnly escalates without spending a judge call", async () => {
    let judged = 0;
    const { engine, sent } = makeEngine({ runDecisionFn: async () => { judged++; return decide({}); } });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: true });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    expect(judged).toBe(0);
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(true);
  });

  it("handle injects the reply through the adapter and records activity", async () => {
    const { engine, injected, activity } = makeEngine({
      runDecisionFn: async () => decide({ decision: "handle", reply: "yes" }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    expect(injected).toEqual([["t1", "yes"]]);
    expect(activity.some((a) => (a as { decision: string }).decision === "handle")).toBe(true);
  });

  it("floor-blocked reply escalates with floorRule", async () => {
    const { engine, sent, injected } = makeEngine({
      runDecisionFn: async () => decide({ decision: "handle", reply: "rm -rf /" }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    expect(injected).toHaveLength(0);
    const esc = sent.find((m) => m.type === "handler:escalation") as never as { floorRule?: string };
    expect(esc.floorRule).toBeTruthy();
  });

  it("records satisfiedItems into the ledger and resets the runaway counter", async () => {
    const { engine, sent, activity } = makeEngine({
      runDecisionFn: async () => decide({
        decision: "continue",
        satisfiedItems: [{ item: "/compact", evidence: "compact ran" }],
      }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect(activity.some((a) => (a as { decision: string }).decision === "item_satisfied")).toBe(true);
    const status = sent.at(-1) as never as { sessions: Array<{ ledger: unknown[] }> };
    expect(status.sessions[0].ledger).toHaveLength(1);
  });

  it("does not double-record an already satisfied item", async () => {
    const { engine, activity } = makeEngine({
      runDecisionFn: async () => decide({
        satisfiedItems: [{ item: "/compact", evidence: "compact ran" }],
      }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    const satisfied = activity.filter((a) => (a as { decision: string }).decision === "item_satisfied");
    expect(satisfied).toHaveLength(1);
  });

  it("wraps up when doneWhenMet and all thenItems satisfied: push + wrapped_up + disarm", async () => {
    const pushes: string[] = [];
    const { engine, sent, activity } = makeEngine({
      sendPush: (m: string) => pushes.push(m),
      runDecisionFn: async () => decide({
        doneWhenMet: true,
        satisfiedItems: [{ item: "/compact", evidence: "ran" }],
      }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect(activity.some((a) => (a as { decision: string }).decision === "wrapped_up")).toBe(true);
    expect(pushes).toHaveLength(1);
    expect(pushes[0]).toContain("/compact"); // ledger items named in the push
    const status = sent.at(-1) as never as { sessions: unknown[] };
    expect(status.sessions).toHaveLength(0); // disarmed
  });

  it("a final handle reply is injected BEFORE wrap-up disarms", async () => {
    const pushes: string[] = [];
    const { engine, injected, activity } = makeEngine({
      sendPush: (m: string) => pushes.push(m),
      runDecisionFn: async () => decide({
        decision: "handle", reply: "yes, finish",
        doneWhenMet: true,
        satisfiedItems: [{ item: "/compact", evidence: "ran" }],
      }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect(injected).toEqual([["t1", "yes, finish"]]); // reply not dropped
    expect(activity.some((a) => (a as { decision: string }).decision === "wrapped_up")).toBe(true);
  });

  it("an escalation never wraps up, even with doneWhenMet", async () => {
    const { engine, sent, activity } = makeEngine({
      runDecisionFn: async () => decide({
        decision: "escalate",
        doneWhenMet: true,
        satisfiedItems: [{ item: "/compact", evidence: "ran" }],
      }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect(activity.some((a) => (a as { decision: string }).decision === "wrapped_up")).toBe(false);
    const status = sent.at(-1) as never as { sessions: Array<{ state: string }> };
    expect(status.sessions[0].state).toBe("needs_you"); // still armed, pending
  });

  it("never auto-disarms a brief with neither doneWhen nor thenItems", async () => {
    const bare = { ...BRIEF, doneWhen: undefined, thenItems: [] as string[] };
    const { engine, sent } = makeEngine({
      runDecisionFn: async () => decide({ doneWhenMet: true }),
    });
    engine.arm({ terminalId: "t1", brief: bare, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    const status = sent.at(-1) as never as { sessions: unknown[] };
    expect(status.sessions).toHaveLength(1);
  });

  it("judge unavailable parks instead of escalating on the first failure", async () => {
    const { engine, sent } = makeEngine({ runDecisionFn: async () => null });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(false);
    expect(statusOf(sent).state).toBe("parked");
  });

  it("does not inject when the session is disarmed while the judge is still deciding", async () => {
    const { engine, sent, injected } = makeEngine({
      runDecisionFn: async () => {
        // Simulate a concurrent disarm (e.g. app-driven handler:configure or
        // onTerminalExit) landing while the judge call is still in flight.
        engine.disarm("t1");
        return decide({ decision: "handle", reply: "yes" });
      },
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    expect(injected).toHaveLength(0);
    const status = sent.at(-1) as never as { sessions: unknown[] };
    expect(status.sessions).toHaveLength(0);
  });

  it("coalesces events queued behind a slow judge call — only the newest runs", async () => {
    let judged = 0;
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const { engine } = makeEngine({
      runDecisionFn: async () => { judged++; await gate; return decide({}); },
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    // Four events land back-to-back; by the time the chain drains each thunk,
    // only the last is still the terminal's newest — one judge call total.
    const all = [
      engine.handleEvent({ terminalId: "t1", event: "turn_end" }),
      engine.handleEvent({ terminalId: "t1", event: "turn_end" }),
      engine.handleEvent({ terminalId: "t1", event: "turn_end" }),
      engine.handleEvent({ terminalId: "t1", event: "awaiting_input" }),
    ];
    release();
    await Promise.all(all);
    expect(judged).toBe(1);
  });

  it("notify-only re-escalates only after the pending question is answered", async () => {
    const { engine, sent } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: true });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    expect(sent.filter((m) => m.type === "handler:escalation")).toHaveLength(1);
    engine.onUserReply("t1", "done\r");
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    expect(sent.filter((m) => m.type === "handler:escalation")).toHaveLength(2);
  });

  it("notify-only escalation body carries a PTY output snippet", async () => {
    const { engine, sent } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: true });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    const esc = sent.find((m) => m.type === "handler:escalation") as never as { question: string };
    expect(esc.question).toContain("pty-tail"); // adapter.recentOutput in makeEngine
  });
});

describe("chat blocking prompts and slash guard", () => {
  it("permission_request force-escalates with kind resolve_in_session, no judge call", async () => {
    let judged = 0;
    const { engine, sent } = makeEngine({ runDecisionFn: async () => { judged++; return decide({}); } });
    engine.arm({ terminalId: "c1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "c1", event: "permission_request", detail: "Bash: rm -rf build" });
    expect(judged).toBe(0);
    const esc = sent.find((m) => m.type === "handler:escalation") as never as {
      kind?: string; question: string; urgency: string;
    };
    expect(esc.kind).toBe("resolve_in_session");
    expect(esc.question).toContain("rm -rf build");
    expect(esc.urgency).toBe("high");
    // kind must survive the snapshot too — the app rebuilds its escalation
    // list wholesale from handler:status, so a kind that only rides the
    // one-shot message would be erased milliseconds later.
    const status = sent.filter((m) => m.type === "handler:status").at(-1) as never as {
      sessions: Array<{ escalations: Array<{ kind?: string }> }>;
    };
    expect(status.sessions[0].escalations[0].kind).toBe("resolve_in_session");
  });

  it("question force-escalates with kind resolve_in_session even in notify-only", async () => {
    const { engine, sent } = makeEngine();
    engine.arm({ terminalId: "c1", brief: BRIEF, notifyOnly: true });
    await engine.handleEvent({ terminalId: "c1", event: "question", detail: "Pick a migration strategy" });
    const esc = sent.find((m) => m.type === "handler:escalation") as never as { kind?: string };
    expect(esc.kind).toBe("resolve_in_session");
  });

  it("turn_end escalations carry no kind (free-text reply default)", async () => {
    const { engine, sent } = makeEngine();
    engine.arm({ terminalId: "c1", brief: BRIEF, notifyOnly: true });
    await engine.handleEvent({ terminalId: "c1", event: "turn_end" });
    const esc = sent.find((m) => m.type === "handler:escalation") as never as { kind?: string };
    expect(esc.kind).toBeUndefined();
  });

  it("slash_command handle escalates instead of injecting when the adapter refuses", async () => {
    const injected: Array<[string, string]> = [];
    const { engine, sent } = makeEngine({
      adapter: {
        injectReply: (id: string, t: string) => injected.push([id, t]),
        recentOutput: () => "",
        transcriptPath: () => undefined,
        outputKind: () => "pty",
        supportsSlashCommands: () => false,
      },
      runDecisionFn: async () =>
        decide({ decision: "handle", action: { kind: "slash_command", value: "/compact" } }),
    });
    engine.arm({ terminalId: "c1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "c1", event: "turn_end" });
    expect(injected).toHaveLength(0);
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(true);
  });

  it("slash_command handle injects via adapter when slash commands are supported", async () => {
    const { engine, sent, injected } = makeEngine({
      // Default projectPath "/proj" (not "/") — this is the real production shape,
      // and relies on classifyDestructive's pathCheckText scoping (destructive-floor.ts)
      // to not misread the "/compact" action value as an out-of-project path.
      // makeEngine()'s default adapter already has supportsSlashCommands: () => true.
      runDecisionFn: async () =>
        decide({ decision: "handle", action: { kind: "slash_command", value: "/compact" } }),
    });
    engine.arm({ terminalId: "c1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "c1", event: "turn_end" });
    expect(injected).toEqual([["c1", "/compact"]]);
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(false);
  });

  it("slash_command handle escalates instead of injecting when the value is not a simple verb", async () => {
    // action.value is judge-generated free text with no allowlist (decision.ts) — a
    // hallucinating judge could shape it like a path. This must escalate rather than
    // reach classifyDestructive, whose path check is scoped away from action values.
    const injected: Array<[string, string]> = [];
    const { engine, sent } = makeEngine({
      adapter: {
        injectReply: (id: string, t: string) => injected.push([id, t]),
        recentOutput: () => "",
        transcriptPath: () => undefined,
        outputKind: () => "pty",
        supportsSlashCommands: () => true,
      },
      runDecisionFn: async () =>
        decide({ decision: "handle", action: { kind: "slash_command", value: "/etc/hosts" } }),
    });
    engine.arm({ terminalId: "c1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "c1", event: "turn_end" });
    expect(injected).toHaveLength(0);
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(true);
  });

  it("judges an isolated session in its own checkout, and floors paths by that checkout", async () => {
    // An isolated session's agent runs inside a managed worktree. If the judge
    // and the destructive floor stayed on the main checkout, the floor would
    // wave through writes to main and block the session's own files.
    const ISO = "/worktrees/iso";
    const cwds: Array<string | undefined> = [];
    const injected: Array<[string, string]> = [];
    const { engine, sent } = makeEngine({
      projectPath: (terminalId?: string) => (terminalId === "iso" ? ISO : "/proj"),
      adapter: {
        injectReply: (id: string, t: string) => injected.push([id, t]),
        recentOutput: () => "pty-tail",
        transcriptPath: () => undefined,
        outputKind: () => "pty",
        supportsSlashCommands: () => true,
      },
      runDecisionFn: async (args: { cwd?: string }) => {
        cwds.push(args.cwd);
        return decide({ decision: "handle", reply: `edit ${ISO}/src/main.ts` });
      },
    });
    engine.arm({ terminalId: "iso", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "iso", event: "turn_end" });

    expect(cwds).toEqual([ISO]);
    expect(injected).toEqual([["iso", `edit ${ISO}/src/main.ts`]]);
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(false);
  });

  it("floors a main-checkout path for an isolated session as outside its project", async () => {
    const injected: Array<[string, string]> = [];
    const { engine, sent } = makeEngine({
      projectPath: (terminalId?: string) => (terminalId === "iso" ? "/worktrees/iso" : "/proj"),
      adapter: {
        injectReply: (id: string, t: string) => injected.push([id, t]),
        recentOutput: () => "pty-tail",
        transcriptPath: () => undefined,
        outputKind: () => "pty",
        supportsSlashCommands: () => true,
      },
      runDecisionFn: async () => decide({ decision: "handle", reply: "rm /proj/src/main.ts" }),
    });
    engine.arm({ terminalId: "iso", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "iso", event: "turn_end" });

    expect(injected).toHaveLength(0);
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(true);
  });

  it("onPromptRetracted clears pending escalations without a user answer", async () => {
    const { engine, sent } = makeEngine();
    engine.arm({ terminalId: "c1", brief: BRIEF, notifyOnly: true });
    await engine.handleEvent({ terminalId: "c1", event: "permission_request", detail: "x" });
    engine.onPromptRetracted("c1");
    const status = sent.filter((m) => m.type === "handler:status").at(-1) as never as {
      sessions: Array<{ pendingEscalations: number; state: string }>;
    };
    expect(status.sessions[0].pendingEscalations).toBe(0);
    expect(status.sessions[0].state).toBe("watching");
  });

  it("onPromptRetracted drops a permission_request still queued behind an in-flight earlier event (no resurrected escalation)", async () => {
    // Reproduces the race: a slow non-blocking event (A) is still being judged
    // when a permission_request (X) arrives for the same terminal — X queues
    // behind A in the per-terminal chain and has NOT run yet, so s.escalations
    // is still empty when the retraction lands (the exact precondition the old
    // code's `s.escalations.length === 0` guard bailed out on, leaving `latest`
    // pointing at X so X ran anyway once dequeued).
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    let aStarted = false;
    const { engine, sent } = makeEngine({
      adapter: {
        injectReply: () => {},
        recentOutput: async () => { aStarted = true; await gate; return "pty-tail"; },
        transcriptPath: () => undefined,
        outputKind: () => "pty",
        supportsSlashCommands: () => true,
      },
      runDecisionFn: async () => decide({}),
    });
    engine.arm({ terminalId: "c1", brief: BRIEF, notifyOnly: false });

    // A: turn_end. Wait (bounded — no real timers, so this can't hang) for its
    // dispatch to pass its own coalescing check and reach the gated
    // recentOutput await, i.e. genuinely in flight rather than merely queued.
    const a = engine.handleEvent({ terminalId: "c1", event: "turn_end" });
    for (let i = 0; i < 10 && !aStarted; i++) await Promise.resolve();
    expect(aStarted).toBe(true);

    // X: permission_request, queued behind A — not dequeued yet.
    const x = engine.handleEvent({ terminalId: "c1", event: "permission_request", detail: "rm -rf build" });

    // Retraction lands while X is still queued.
    engine.onPromptRetracted("c1");

    release();
    await Promise.all([a, x]);

    expect(sent.some((m) => m.type === "handler:escalation")).toBe(false);
    const status = sent.filter((m) => m.type === "handler:status").at(-1) as never as {
      sessions: Array<{ pendingEscalations: number }>;
    };
    expect(status.sessions[0].pendingEscalations).toBe(0);
  });

  // A chat session sends agent:turn-end and then retracts every pending prompt
  // synchronously in the SAME stack (ChatSession.closeTurn -> endTurn ->
  // retractAllPending), and both frames reach the engine through agent-core's
  // sendMessage tap. So the retraction lands after handleEvent has recorded the
  // turn_end in `latest` but before the chain's microtask dequeues it. A blanket
  // latest.delete() there failed the coalescing identity check and swallowed the
  // turn end outright — the armed session stayed "watching" a dead agent, which is
  // precisely what counting stopReason "error" as a turn boundary exists to prevent.
  it("a retraction in the same tick does not swallow the turn_end that preceded it", async () => {
    const { engine, sent } = makeEngine();
    engine.arm({ terminalId: "c1", brief: BRIEF, notifyOnly: true });

    const turn = engine.handleEvent({ terminalId: "c1", event: "turn_end" });
    engine.onPromptRetracted("c1"); // the turn boundary's retraction, same stack
    await turn;

    expect(sent.filter((m) => m.type === "handler:escalation")).toHaveLength(1);
    const status = sent.filter((m) => m.type === "handler:status").at(-1) as never as {
      sessions: Array<{ state: string }>;
    };
    expect(status.sessions[0].state).toBe("needs_you");
  });

  it("a retraction in the same tick still lets the turn_end reach the judge", async () => {
    let judged = 0;
    const { engine } = makeEngine({
      runDecisionFn: async () => { judged++; return decide({}); },
    });
    engine.arm({ terminalId: "c1", brief: BRIEF, notifyOnly: false });

    const turn = engine.handleEvent({ terminalId: "c1", event: "turn_end" });
    engine.onPromptRetracted("c1");
    await turn;

    expect(judged).toBe(1);
  });
});

// Codex hooks never post a transcript path, so the engine must resolve the
// rollout itself via CODEX_HOME and hand the judge the resolved path.
test("codex plan context comes from the rollout and its path reaches the judge", async () => {
  const thread = "019f0000-0000-7000-8000-000000000001";
  const home = mkdtempSync(join(tmpdir(), "ab-eng-cx-"));
  const dir = join(home, "sessions", "2026", "07", "28");
  mkdirSync(dir, { recursive: true });
  const rollout = join(dir, `rollout-x-${thread}.jsonl`);
  writeFileSync(rollout, JSON.stringify(
    { type: "event_msg", payload: { type: "agent_message", message: "migrated the schema" } }), "utf8");

  const prevHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = home;
  try {
    const planCalls: Array<{ context: string; transcriptPath?: string }> = [];
    const { engine } = makeEngine({
      tool: () => "codex",
      agentSessionId: () => thread,
      adapter: {
        injectReply: () => {}, recentOutput: () => "pty-tail",
        transcriptPath: () => undefined, outputKind: () => "pty" as const,
        supportsSlashCommands: () => true,
      },
      runPlanFn: async (o: { context: string; transcriptPath?: string }) => {
        planCalls.push({ context: o.context, transcriptPath: o.transcriptPath });
        return BRIEF;
      },
    });
    await engine.plan("t1");
    expect(planCalls[0].context).toContain("migrated the schema");
    expect(planCalls[0].transcriptPath).toBe(rollout);
  } finally {
    if (prevHome === undefined) delete process.env.CODEX_HOME; else process.env.CODEX_HOME = prevHome;
  }
});

test("decide context for codex also resolves the rollout path for the judge", async () => {
  const thread = "019f0000-0000-7000-8000-000000000002";
  const home = mkdtempSync(join(tmpdir(), "ab-eng-cx-"));
  const dir = join(home, "sessions", "2026", "07", "28");
  mkdirSync(dir, { recursive: true });
  const rollout = join(dir, `rollout-x-${thread}.jsonl`);
  writeFileSync(rollout, JSON.stringify(
    { type: "event_msg", payload: { type: "user_message", message: "run the tests" } }), "utf8");

  const prevHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = home;
  try {
    const decideCalls: Array<{ context: string; transcriptPath?: string }> = [];
    const { engine } = makeEngine({
      tool: () => "codex",
      agentSessionId: () => thread,
      adapter: {
        injectReply: () => {}, recentOutput: () => "pty-tail",
        transcriptPath: () => undefined, outputKind: () => "pty" as const,
        supportsSlashCommands: () => true,
      },
      runDecisionFn: async (o: { context: string; transcriptPath?: string }) => {
        decideCalls.push({ context: o.context, transcriptPath: o.transcriptPath });
        return decide({});
      },
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect(decideCalls[0].context).toContain("run the tests");
    expect(decideCalls[0].transcriptPath).toBe(rollout);
  } finally {
    if (prevHome === undefined) delete process.env.CODEX_HOME; else process.env.CODEX_HOME = prevHome;
  }
});

test("opencode decide context reads the db but hands the judge no path", async () => {
  const dbPath = join(mkdtempSync(join(tmpdir(), "ab-eng-oc-")), "opencode.db");
  const db = new Database(dbPath);
  db.exec(`
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
    CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
  `);
  db.query("INSERT INTO message VALUES (?, ?, ?, ?, ?)").run("msg_1", "ses_1", 1, 1, JSON.stringify({ role: "user" }));
  db.query("INSERT INTO part VALUES (?, ?, ?, ?, ?, ?)").run("prt_1", "msg_1", "ses_1", 1, 1, JSON.stringify({ type: "text", text: "ship it" }));
  db.close();

  const prevDb = process.env.OPENCODE_DB;
  process.env.OPENCODE_DB = dbPath; // absolute → used as-is by resolveOpencodeDbPath
  try {
    const decideCalls: Array<{ context: string; transcriptPath?: string }> = [];
    const { engine } = makeEngine({
      tool: () => "opencode",
      agentSessionId: () => "ses_1",
      adapter: {
        injectReply: () => {}, recentOutput: () => "pty-tail",
        transcriptPath: () => undefined, outputKind: () => "pty" as const,
        supportsSlashCommands: () => true,
      },
      runDecisionFn: async (o: { context: string; transcriptPath?: string }) => {
        decideCalls.push({ context: o.context, transcriptPath: o.transcriptPath });
        return decide({});
      },
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect(decideCalls[0].context).toContain("ship it");
    expect(decideCalls[0].transcriptPath).toBeUndefined();
  } finally {
    if (prevDb === undefined) delete process.env.OPENCODE_DB; else process.env.OPENCODE_DB = prevDb;
  }
});

// Lets a re-enqueued event (the timer's re-judge) drain without real timers.
async function drain(): Promise<void> {
  for (let i = 0; i < 30; i++) await Promise.resolve();
}

function parkedRecord(over: Partial<HandlerSessionRecord> = {}): HandlerSessionRecord {
  return {
    version: 1, terminalId: "t1", armed: true, brief: BRIEF, notifyOnly: false,
    armedAt: 1, doneWhenMet: false, ledger: [], escalations: [], ...over,
  } as HandlerSessionRecord;
}

describe("lifecycle park / resume", () => {
  it("limit_hit parks until the detector's reset time with exactly one timer armed", async () => {
    const { engine, sent, activity, armed, clock } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({
      terminalId: "t1", event: "limit_hit", resetsAt: clock.t + 60_000, errorClass: "rate_limit",
    });
    const s = statusOf(sent);
    expect(s.state).toBe("parked");
    expect(s.parkKind).toBe("limit");
    expect(s.parkedUntil).toBe(clock.t + 60_000);
    expect(armed()).toHaveLength(1);
    expect(armed()[0].ms).toBe(60_000);
    expect(records(activity, "parked")).toHaveLength(1);
  });

  it("a limit_hit without a reset time falls back to 30 minutes", async () => {
    const { engine, sent, armed, clock } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    expect(statusOf(sent).parkedUntil).toBe(clock.t + LIMIT_FALLBACK_MS);
    expect(armed()[0].ms).toBe(LIMIT_FALLBACK_MS);
  });

  it("floors a reset time already in the past so the park cannot wake on arrival", async () => {
    const { engine, sent, injected, armed, clock, timers } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    // A stale limit snapshot: the window it describes closed a minute ago.
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit", resetsAt: clock.t - 60_000 });
    // The invariant is that a park cannot expire on arrival — without the floor
    // this arms a 0ms timer that nudges straight back into the failure.
    expect(statusOf(sent).parkedUntil).toBeGreaterThan(clock.t);
    expect(statusOf(sent).parkedUntil).toBe(clock.t + MIN_PARK_MS);
    expect(armed()[0].ms).toBeGreaterThan(0);
    expect(armed()[0].ms).toBe(MIN_PARK_MS);
    expect(injected).toEqual([]);
    expect(timers).toHaveLength(1);
  });

  it("the park timer nudges exactly once and records resumed", async () => {
    const { engine, sent, injected, activity, timers } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    timers.at(-1)!.fn();
    expect(injected).toEqual([["t1", "continue"]]);
    expect(records(activity, "resumed")).toHaveLength(1);
    expect(statusOf(sent).state).toBe("watching");
    expect(statusOf(sent).parkKind).toBeUndefined();
  });

  it("the first park of an episode pushes once; a re-park refreshes the deadline silently", async () => {
    const { engine, sent, activity, pushes, armed, clock } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit", resetsAt: clock.t + 60_000 });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit", resetsAt: clock.t + 90_000 });
    expect(statusOf(sent).parkedUntil).toBe(clock.t + 90_000);
    expect(armed()).toHaveLength(1);
    expect(armed()[0].ms).toBe(90_000);
    expect(records(activity, "parked")).toHaveLength(1);
    expect(pushes).toHaveLength(1);
    expect(pushes[0]).toContain("resuming automatically");
  });

  it("a selfResuming park never arms a timer and unparks on the next normal event", async () => {
    let judged = 0;
    const { engine, sent, injected, armed, clock } = makeEngine({
      runDecisionFn: async () => { judged++; return decide({}); },
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({
      terminalId: "t1", event: "limit_hit", selfResuming: true, resetsAt: clock.t + 60_000,
    });
    expect(statusOf(sent).state).toBe("parked");
    expect(armed()).toHaveLength(0);
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect(judged).toBe(1);
    expect(injected).toHaveLength(0);
    expect(statusOf(sent).state).toBe("watching");
  });

  it("limit_cleared unparks and records resumed; on an unparked session it is dropped", async () => {
    const { engine, sent, activity, timers } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "limit_cleared" });
    expect(records(activity, "resumed")).toHaveLength(0);
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    await engine.handleEvent({ terminalId: "t1", event: "limit_cleared" });
    expect(timers.at(-1)!.cancelled).toBe(true);
    expect(records(activity, "resumed")).toHaveLength(1);
    expect(statusOf(sent).state).toBe("watching");
    expect(statusOf(sent).parkKind).toBeUndefined();
  });

  it("turn_end mid-park is dropped without a judge call", async () => {
    let judged = 0;
    const { engine, sent } = makeEngine({ runDecisionFn: async () => { judged++; return decide({}); } });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect(judged).toBe(0);
    expect(statusOf(sent).state).toBe("parked");
  });

  it("a blocking prompt mid-park unparks, cancels the timer, and escalates with no judge call", async () => {
    let judged = 0;
    const { engine, sent, timers } = makeEngine({ runDecisionFn: async () => { judged++; return decide({}); } });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    await engine.handleEvent({ terminalId: "t1", event: "permission_request", detail: "Bash: rm -rf build" });
    expect(judged).toBe(0);
    expect(timers.at(-1)!.cancelled).toBe(true);
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(true);
    expect(statusOf(sent).state).toBe("needs_you");
    expect(statusOf(sent).parkKind).toBeUndefined();
  });

  it("a submitted line unparks a session with zero pending escalations", async () => {
    const { engine, sent, timers } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    engine.onUserReply("t1", "k");
    expect(statusOf(sent).state).toBe("parked"); // a bare keystroke is not a resume
    engine.onUserReply("t1", "go on\r");
    expect(timers.at(-1)!.cancelled).toBe(true);
    expect(statusOf(sent).state).toBe("watching");
    expect(statusOf(sent).parkKind).toBeUndefined();
  });

  it("a prompt retraction unparks a session with zero pending escalations", async () => {
    const { engine, sent, timers } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    engine.onPromptRetracted("t1");
    expect(timers.at(-1)!.cancelled).toBe(true);
    expect(statusOf(sent).state).toBe("watching");
  });

  it("disarm and terminal exit cancel the park timer", async () => {
    const a = makeEngine();
    a.engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await a.engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    a.engine.disarm("t1");
    expect(a.timers.at(-1)!.cancelled).toBe(true);

    const b = makeEngine();
    b.engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await b.engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    b.engine.onTerminalExit("t1");
    expect(b.timers.at(-1)!.cancelled).toBe(true);
  });

  it("a lifecycle event queued behind a judge call is never coalesced away", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    let judged = 0;
    const { engine, sent, activity } = makeEngine({
      runDecisionFn: async () => { judged++; await gate; return decide({}); },
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    const first = engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    await drain(); // the first event is now inside the judge call
    // A later turn_end makes itself the newest event. A limit_hit riding the
    // same map would be superseded by it and silently dropped.
    const limit = engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    const third = engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    release();
    await Promise.all([first, limit, third]);
    expect(records(activity, "parked")).toHaveLength(1);
    expect(statusOf(sent).state).toBe("parked");
    // …and the limit_hit did not supersede the pause events either: the first
    // was judged, the third dropped only because the session was by then parked.
    expect(judged).toBe(1);
  });

  it("a resume with a question still outstanding stays needs_you and never nudges", async () => {
    const { engine, sent, injected, activity, timers } = makeEngine({
      runDecisionFn: async () => decide({ decision: "escalate" }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect(statusOf(sent).state).toBe("needs_you");
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    expect(statusOf(sent).state).toBe("parked");

    timers.at(-1)!.fn();
    // injectReply submits a line, so nudging here would answer the human's
    // pending question with "continue".
    expect(injected).toHaveLength(0);
    expect(records(activity, "resumed")).toHaveLength(1);
    expect(statusOf(sent).state).toBe("needs_you");
    expect(statusOf(sent).pendingEscalations).toBe(1);
    expect(statusOf(sent).parkKind).toBeUndefined();
  });

  it("a limit that outlasts repeated waits escalates instead of parking again", async () => {
    const { engine, sent, injected, activity, pushes, timers, armed } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    for (let i = 0; i < LIMIT_PARK_CEILING - 1; i++) {
      await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
      timers.at(-1)!.fn();
    }
    expect(injected).toHaveLength(LIMIT_PARK_CEILING - 1);
    // The wait keeps ending with the same limit still in force, so waiting is
    // not the answer: without a ceiling this cycles forever, re-pushing and
    // re-nudging every window and never telling anyone the agent is stuck.
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    expect(statusOf(sent).state).toBe("needs_you");
    expect(statusOf(sent).parkKind).toBeUndefined();
    expect(armed()).toHaveLength(0);
    expect(injected).toHaveLength(LIMIT_PARK_CEILING - 1);
    expect(records(activity, "parked")).toHaveLength(LIMIT_PARK_CEILING - 1);

    // …and one unanswered escalation is enough for every further limit.
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    expect(sent.filter((m) => m.type === "handler:escalation")).toHaveLength(1);
    expect(pushes).toHaveLength(LIMIT_PARK_CEILING - 1);
  });

  it("a judged turn between limit parks clears the limit ceiling", async () => {
    const { engine, sent, timers } = makeEngine({ runDecisionFn: async () => decide({}) });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    for (let i = 0; i < LIMIT_PARK_CEILING + 2; i++) {
      await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
      timers.at(-1)!.fn();
      await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    }
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(false);
  });

  it("a notify-only park ends in a notification, never a nudge", async () => {
    const { engine, sent, injected, timers } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: true });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    expect(statusOf(sent).state).toBe("parked");
    timers.at(-1)!.fn();
    // "tell me, never act" — the wake must not type into the user's terminal.
    expect(injected).toEqual([]);
    expect(statusOf(sent).state).toBe("needs_you");
    expect(sent.filter((m) => m.type === "handler:escalation")).toHaveLength(1);
  });

  it("a cancel ends a selfResuming park, whose only wake path it also ended", async () => {
    const { engine, sent, activity, clock } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({
      terminalId: "t1", event: "limit_hit", selfResuming: true, resetsAt: clock.t + 60_000,
    });
    expect(statusOf(sent).state).toBe("parked");
    engine.onTurnCancelled("t1");
    expect(statusOf(sent).state).toBe("watching");
    expect(statusOf(sent).parkKind).toBeUndefined();
    expect(records(activity, "resumed")).toHaveLength(1);
  });

  it("a cancel is not an answer: pending escalations survive it", async () => {
    const { engine, sent } = makeEngine({ runDecisionFn: async () => decide({ decision: "escalate" }) });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    engine.onTurnCancelled("t1");
    expect(statusOf(sent).state).toBe("needs_you");
    expect(statusOf(sent).pendingEscalations).toBe(1);
  });

  it("a park timer that throws never escapes to the event loop", async () => {
    // The wake path writes to disk (activity log, session record); a failed
    // write there would otherwise become an uncaughtException and shut the whole
    // bridge — every project, every PTY — down.
    const { engine, timers } = makeEngine({
      appendActivityFn: (r: { decision: string }) => {
        if (r.decision === "resumed") throw new Error("ENOSPC");
      },
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    expect(() => timers.at(-1)!.fn()).not.toThrow();
  });

  it("limit_cleared re-judges a pause the judge still owed a verdict on", async () => {
    const calls: Array<string | undefined> = [];
    let sawSecond!: () => void;
    const second = new Promise<void>((r) => { sawSecond = r; });
    const { engine, injected } = makeEngine({
      runDecisionFn: async (o: { transcriptPath?: string }) => {
        calls.push(o.transcriptPath);
        if (calls.length === 2) sawSecond();
        return null;
      },
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end", transcriptPath: "/orig.jsonl" });
    expect(calls).toHaveLength(1);
    // The provider coming back does not answer the pause nobody assessed.
    await engine.handleEvent({ terminalId: "t1", event: "limit_cleared" });
    await second;
    expect(calls[1]).toBe("/orig.jsonl");
    expect(injected).toHaveLength(0);
  });

  it("limit_cleared with a question outstanding leaves the session needs_you", async () => {
    const { engine, sent } = makeEngine({ runDecisionFn: async () => decide({ decision: "escalate" }) });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    await engine.handleEvent({ terminalId: "t1", event: "limit_cleared" });
    expect(statusOf(sent).state).toBe("needs_you");
    expect(statusOf(sent).pendingEscalations).toBe(1);
  });
});

describe("lifecycle transient ceiling", () => {
  it("backs off 30s then 2m and escalates on the third consecutive failure", async () => {
    const { engine, sent, timers, armed } = makeEngine({ runDecisionFn: async () => decide({}) });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });

    await engine.handleEvent({ terminalId: "t1", event: "turn_failed", errorClass: "overloaded" });
    expect(statusOf(sent).parkKind).toBe("outage");
    expect(armed()[0].ms).toBe(30_000);
    timers.at(-1)!.fn();

    await engine.handleEvent({ terminalId: "t1", event: "turn_failed", errorClass: "overloaded" });
    expect(armed()[0].ms).toBe(120_000);
    timers.at(-1)!.fn();

    await engine.handleEvent({ terminalId: "t1", event: "turn_failed", errorClass: "overloaded" });
    const esc = sent.filter((m) => m.type === "handler:escalation") as never as Array<{ reasoning: string }>;
    expect(esc).toHaveLength(1);
    expect(esc[0].reasoning).toBe("repeated transient failures");
    expect(statusOf(sent).state).toBe("needs_you");
    expect(armed()).toHaveLength(0);
  });

  it("past the ceiling, further failures do not re-escalate until a human replies", async () => {
    const { engine, sent, pushes, timers } = makeEngine({ runDecisionFn: async () => decide({}) });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    for (let i = 0; i < 3; i++) {
      await engine.handleEvent({ terminalId: "t1", event: "turn_failed" });
      if (timers.at(-1)!.fired === false && !timers.at(-1)!.cancelled) timers.at(-1)!.fn();
    }
    const escalations = () => sent.filter((m) => m.type === "handler:escalation").length;
    expect(escalations()).toBe(1);
    const pushedOnce = pushes.length;

    // The counter only a judged turn clears is now pinned at the ceiling, so
    // without a dedup every later failure appends an identical row and pushes.
    await engine.handleEvent({ terminalId: "t1", event: "turn_failed" });
    await engine.handleEvent({ terminalId: "t1", event: "turn_failed" });
    expect(escalations()).toBe(1);
    expect(pushes).toHaveLength(pushedOnce);

    // A human line answers it and restarts the series at the first backoff.
    engine.onUserReply("t1", "try again\r");
    await engine.handleEvent({ terminalId: "t1", event: "turn_failed" });
    expect(escalations()).toBe(1);
    expect(statusOf(sent).parkKind).toBe("outage");
    expect(timers.at(-1)!.ms).toBe(30_000);
  });

  it("a judged turn between failures resets the counter", async () => {
    const { engine, timers, armed } = makeEngine({ runDecisionFn: async () => decide({}) });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_failed" });
    timers.at(-1)!.fn();
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    await engine.handleEvent({ terminalId: "t1", event: "turn_failed" });
    expect(armed()[0].ms).toBe(30_000);
  });

  it("limit parks never contribute to the transient ceiling", async () => {
    const { engine, sent, timers, armed } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    timers.at(-1)!.fn();
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    timers.at(-1)!.fn();
    await engine.handleEvent({ terminalId: "t1", event: "turn_failed" });
    expect(armed()[0].ms).toBe(30_000);
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(false);
  });

  it("turn_failed mid-park is dropped: no counter change, no overwritten limit park", async () => {
    const { engine, sent, activity, timers, armed, clock } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit", resetsAt: clock.t + 60_000 });
    await engine.handleEvent({ terminalId: "t1", event: "turn_failed" });
    expect(statusOf(sent).parkKind).toBe("limit");
    expect(statusOf(sent).parkedUntil).toBe(clock.t + 60_000);
    expect(records(activity, "parked")).toHaveLength(1);
    expect(armed()).toHaveLength(1);
    // The dropped failure must not shorten the NEXT backoff either.
    timers.at(-1)!.fn();
    await engine.handleEvent({ terminalId: "t1", event: "turn_failed" });
    expect(armed()[0].ms).toBe(30_000);
  });

  it("a judge failure parks with the original event and re-judges it on resume", async () => {
    const calls: Array<string | undefined> = [];
    let sawSecond!: () => void;
    const second = new Promise<void>((r) => { sawSecond = r; });
    const { engine, sent, injected, timers } = makeEngine({
      runDecisionFn: async (o: { transcriptPath?: string }) => {
        calls.push(o.transcriptPath);
        if (calls.length === 2) sawSecond();
        return null;
      },
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end", transcriptPath: "/orig.jsonl" });
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(false);
    expect(statusOf(sent).parkKind).toBe("outage");
    expect(timers.at(-1)!.ms).toBe(30_000);

    timers.at(-1)!.fn();
    await second;
    await drain();
    expect(calls[1]).toBe("/orig.jsonl");
    expect(injected).toHaveLength(0);
  });

  it("a judge that throws parks instead of rejecting", async () => {
    const { engine, sent } = makeEngine({
      runDecisionFn: async () => { throw new Error("judge spawn failed"); },
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect(statusOf(sent).state).toBe("parked");
    expect(statusOf(sent).parkKind).toBe("outage");
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(false);
  });
});

describe("lifecycle guard invariant", () => {
  it("a park/resume cycle never resets the consecutive counter", async () => {
    let reply = "first";
    const { engine, sent, injected, timers } = makeEngine({
      guard: new RunawayGuard(1, 4),
      runDecisionFn: async () => decide({ decision: "handle", reply }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    timers.at(-1)!.fn();
    reply = "second";
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    // "second" is still capped: the park neither reset nor advanced the counter.
    expect(injected.map((i) => i[1])).toEqual(["first", "continue"]);
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(true);
  });

  it("resume nudges never enter the circular-exchange window", async () => {
    let reply = "first";
    const { engine, sent, injected, timers } = makeEngine({
      guard: new RunawayGuard(5, 4),
      runDecisionFn: async () => decide({ decision: "handle", reply }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    timers.at(-1)!.fn();
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    timers.at(-1)!.fn();
    reply = "continue";
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect(injected.map((i) => i[1])).toEqual(["first", "continue", "continue", "continue"]);
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(false);
  });

  it("park and resume call no guard mutator at all", async () => {
    // Reply text alone cannot prove this: a nudge fed through recordAutoReply
    // hashes as "continue", a judged one as the probe "continue\n", so the two
    // never collide and a behavioral assertion slips past the bug. Watch the
    // mutators themselves instead.
    const guard = new RunawayGuard(5, 4);
    const calls: string[] = [];
    for (const m of ["reset", "recordAutoReply", "recordProgress"] as const) {
      const orig = guard[m].bind(guard) as (...a: never[]) => unknown;
      (guard as unknown as Record<string, unknown>)[m] =
        (...a: never[]) => { calls.push(m); return orig(...a); };
    }
    const { engine, timers } = makeEngine({
      guard, runDecisionFn: async () => decide({ decision: "handle", reply: "go" }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    const beforePark = [...calls];
    expect(beforePark).toEqual(["recordAutoReply"]);

    await engine.handleEvent({ terminalId: "t1", event: "limit_hit" });
    timers.at(-1)!.fn();
    await engine.handleEvent({ terminalId: "t1", event: "turn_failed" });
    timers.at(-1)!.fn();
    expect(calls).toEqual(beforePark);
  });
});

describe("lifecycle persistence", () => {
  it("persists the park fields on the session record", async () => {
    const { engine, saved, clock } = makeEngine();
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "limit_hit", resetsAt: clock.t + 60_000 });
    const rec = saved.at(-1) as { parkKind?: string; parkedUntil?: number; transientFailures?: number };
    expect(rec.parkKind).toBe("limit");
    expect(rec.parkedUntil).toBe(clock.t + 60_000);
    expect(rec.transientFailures).toBe(0);
  });

  it("rehydrates a future park and re-arms the remainder", () => {
    const { engine, sent, armed, clock } = makeEngine({
      loadSessionFn: () => parkedRecord({ parkKind: "limit", parkedUntil: 1000 + 90_000, transientFailures: 2 }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    expect(statusOf(sent).state).toBe("parked");
    expect(statusOf(sent).parkedUntil).toBe(clock.t + 90_000);
    expect(armed()).toHaveLength(1);
    expect(armed()[0].ms).toBe(90_000);
  });

  it("persists that a park still owes a judge a verdict", async () => {
    const { engine, saved } = makeEngine({ runDecisionFn: async () => null });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "turn_end" });
    expect((saved.at(-1) as { parkAwaitingJudge?: boolean }).parkAwaitingJudge).toBe(true);
  });

  it("resumes a rehydrated judge-failure park WITHOUT nudging", () => {
    const { engine, sent, injected, activity } = makeEngine({
      loadSessionFn: () => parkedRecord({
        parkKind: "outage", parkedUntil: 900, parkAwaitingJudge: true,
      }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    // The stashed event did not survive the restart, so "continue" here would
    // let the agent proceed from a pause no judge ever saw.
    expect(injected).toEqual([]);
    expect(records(activity, "resumed")).toHaveLength(1);
    expect(statusOf(sent).state).toBe("watching");
  });

  it("rehydrates a park whose deadline has passed by resuming WITHOUT nudging", () => {
    const { engine, sent, injected, activity, armed } = makeEngine({
      loadSessionFn: () => parkedRecord({ parkKind: "outage", parkedUntil: 900 }),
    });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    // The wake lands in a runtime this process never armed — a restart may have
    // respawned the PTY empty — so "continue" would run as a shell command the
    // instant the user re-arms.
    expect(injected).toEqual([]);
    expect(armed()).toHaveLength(0);
    expect(records(activity, "resumed")).toHaveLength(1);
    expect(statusOf(sent).state).toBe("watching");
  });
});

describe("observabilityFor", () => {
  it("reports unsupported for a slot the engine cannot see, whatever its judge", () => {
    const { engine } = makeEngine({ observable: () => false });
    expect(engine.observabilityFor("t1")).toBe("unsupported");
  });

  it("reports escalate_only when the slot is visible but its judge cannot run headless", () => {
    const { engine } = makeEngine({ observable: () => true, tool: () => "cursor-agent" });
    expect(engine.observabilityFor("t1")).toBe("escalate_only");
  });

  it("reports full when the slot is visible and its judge is headless-capable", () => {
    const { engine } = makeEngine({ observable: () => true });
    expect(engine.observabilityFor("t1")).toBe("full");
  });

  it("prefers the session's stored judge over the observed session's own tool", () => {
    const { engine } = makeEngine({
      observable: () => true,
      tool: () => "cursor-agent",
      loadSessionFn: () => ({ terminalId: "t1", armed: false, judgeTool: "claude-code" }),
    });
    expect(engine.observabilityFor("t1")).toBe("full");
  });

  it("assumes observable when no caller supplied the thunk", () => {
    const { engine } = makeEngine();
    expect(engine.observabilityFor("t1")).toBe("full");
  });

  it("stamps every session snapshot with it, so an unwatchable arm is not silent", () => {
    const { engine, sent } = makeEngine({ observable: () => false });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    expect(statusOf(sent).observability).toBe("unsupported");
  });

  it("re-derives it on each emit rather than freezing it at arm time", () => {
    // A slot's mode (and so its integration) can flip under a live arm; a value
    // captured at arm time would keep reporting the mode it was armed in.
    let visible = false;
    const { engine, sent } = makeEngine({ observable: () => visible });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    expect(statusOf(sent).observability).toBe("unsupported");
    visible = true;
    engine.emitStatus();
    expect(statusOf(sent).observability).toBe("full");
  });

  it("separates escalate_only from unsupported on the snapshot", () => {
    const { engine, sent } = makeEngine({ observable: () => true, tool: () => "cursor-agent" });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    expect(statusOf(sent).observability).toBe("escalate_only");
  });
});
