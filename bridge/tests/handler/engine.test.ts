// bridge/tests/handler/engine.test.ts
import { describe, it, test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { HandlerEngine } from "../../src/handler/engine";
import type { AbMessage } from "../../src/protocol";
import type { HandlerDecision } from "../../src/handler/decision";
import type { HandlerSessionRecord } from "../../src/handler/brief";

const BRIEF = {
  taskSummary: "Migrating auth", willHandle: ["routine prompts"],
  wakeFor: ["schema changes"], doneWhen: "tests pass", thenItems: ["/compact"],
};

function makeEngine(overrides: Record<string, unknown> = {}) {
  const sent: AbMessage[] = [];
  const injected: Array<[string, string]> = [];
  const saved: unknown[] = [];
  const activity: unknown[] = [];
  const engine = new HandlerEngine({
    projectId: "proj", projectPath: "/proj", tool: () => "claude-code", abDir: "/tmp/unused",
    adapter: {
      injectReply: (id: string, t: string) => injected.push([id, t]),
      recentOutput: () => "pty-tail",
      transcriptPath: () => "/t.jsonl",
      outputKind: () => "pty",
      supportsSlashCommands: () => true,
    },
    sendAb: (m: AbMessage) => sent.push(m),
    loadConfigFn: () => ({ version: 2, defaultNotifyOnly: false }),
    appendActivityFn: (r: unknown) => activity.push(r),
    loadSessionFn: () => null,
    saveSessionFn: (r: unknown) => saved.push(r),
    now: () => 1000,
    ...overrides,
  } as never);
  return { engine, sent, injected, saved, activity };
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
    const { engine, sent } = makeEngine({ runDecisionFn: async () => null });
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
    const { engine, sent } = makeEngine({ runDecisionFn: async () => null });
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

  it("judge unavailable escalates (fail closed)", async () => {
    const { engine, sent } = makeEngine({ runDecisionFn: async () => null });
    engine.arm({ terminalId: "t1", brief: BRIEF, notifyOnly: false });
    await engine.handleEvent({ terminalId: "t1", event: "awaiting_input" });
    expect(sent.some((m) => m.type === "handler:escalation")).toBe(true);
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

  // Drivers send agent:turn-end and then call retractAllPending() synchronously in
  // the SAME stack (claude-driver's endActiveTurnOnFailure and onResult, codex's
  // turn-complete handler), and both frames reach the engine through agent-core's
  // sendMessage tap. So the retraction lands after handleEvent has recorded the
  // turn_end in `latest` but before the chain's microtask dequeues it. A blanket
  // latest.delete() there failed the coalescing identity check and swallowed the
  // turn end outright — the armed session stayed "watching" a dead agent, which is
  // precisely what counting stopReason "error" as a turn boundary exists to prevent.
  it("a retraction in the same tick does not swallow the turn_end that preceded it", async () => {
    const { engine, sent } = makeEngine();
    engine.arm({ terminalId: "c1", brief: BRIEF, notifyOnly: true });

    const turn = engine.handleEvent({ terminalId: "c1", event: "turn_end" });
    engine.onPromptRetracted("c1"); // retractAllPending(), same stack
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
