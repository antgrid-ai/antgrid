import { describe, test, expect, it } from "bun:test";
import { createMessage, parseMessage, HandlerConfigureWire } from "../../src/protocol";

describe("handler wire v2", () => {
  const brief = { taskSummary: "t", willHandle: ["a"], wakeFor: ["b"], thenItems: [] as string[] };

  test("parses planRequest/planResult", () => {
    expect(parseMessage(JSON.stringify(createMessage("handler:planRequest", { projectId: "p", terminalId: "t1" })))).toBeTruthy();
    expect(parseMessage(JSON.stringify(createMessage("handler:planResult", { projectId: "p", terminalId: "t1", fallback: true })))).toBeTruthy();
  });

  test("configure requires a brief when armed", () => {
    const armedNoBrief = createMessage("handler:configure", { projectId: "p", terminalId: "t1", armed: true, notifyOnly: false } as never);
    expect(parseMessage(JSON.stringify(armedNoBrief))).toBeNull();
    const ok = createMessage("handler:configure", { projectId: "p", terminalId: "t1", armed: true, notifyOnly: false, brief });
    expect(parseMessage(JSON.stringify(ok))).toBeTruthy();
  });

  test("configure and status carry the judge override fields", () => {
    const cfg = createMessage("handler:configure", {
      projectId: "p", terminalId: "t1", armed: true, notifyOnly: false, brief,
      judgeTool: "codex", judgeModel: "",
    });
    expect(parseMessage(JSON.stringify(cfg))).toBeTruthy();
    const status = createMessage("handler:status", {
      projectId: "p", defaultTool: "claude-code", defaultNotifyOnly: false,
      sessions: [{
        terminalId: "t1", notifyOnly: false, state: "watching", pendingEscalations: 0,
        armedAt: 1, doneWhenMet: false, brief, ledger: [],
        escalations: [], judgeTool: "codex", judgeModel: "m",
      }],
    });
    const parsed = parseMessage(JSON.stringify(status)) as any;
    expect(parsed).toBeTruthy();
    expect(parsed.sessions[0].judgeTool).toBe("codex");
    expect(parsed.sessions[0].judgeModel).toBe("m");
  });

  test("status carries per-session snapshots with open escalations", () => {
    const msg = createMessage("handler:status", {
      projectId: "p", defaultNotifyOnly: false, sessions: [{
        terminalId: "t1", notifyOnly: false, state: "watching", pendingEscalations: 1,
        armedAt: 1, doneWhenMet: false, brief, ledger: [],
        escalations: [{
          escalationId: "e1", question: "q", reasoning: "r", draftReply: "",
          urgency: "normal", at: 2,
        }],
      }],
    });
    expect(parseMessage(JSON.stringify(msg))).toBeTruthy();
  });

  test("activity accepts the new kinds; escalation accepts floorRule", () => {
    const act = createMessage("handler:activity", {
      projectId: "p", recordId: "r", at: 1, terminalId: "t1",
      decision: "wrapped_up", reason: "done",
    });
    expect(parseMessage(JSON.stringify(act))).toBeTruthy();
    const esc = createMessage("handler:escalation", {
      projectId: "p", escalationId: "e", terminalId: "t1", question: "q",
      reasoning: "r", draftReply: "", urgency: "normal", floorRule: "force-push", at: 1,
    });
    expect(parseMessage(JSON.stringify(esc))).toBeTruthy();
  });

  test("escalation accepts optional kind; unknown values rejected", () => {
    const base = {
      projectId: "p", escalationId: "e1", terminalId: "t1", question: "q",
      reasoning: "r", draftReply: "", urgency: "normal", at: 1,
    } as const;
    expect(parseMessage(JSON.stringify(createMessage("handler:escalation", base)))).toBeTruthy();
    expect(parseMessage(JSON.stringify(createMessage("handler:escalation", {
      ...base, kind: "resolve_in_session",
    })))).toBeTruthy();
    expect(parseMessage(JSON.stringify({
      ...createMessage("handler:escalation", base), kind: "bogus",
    }))).toBeNull();
  });

  test("status snapshot escalations carry kind through the replay", () => {
    const msg = createMessage("handler:status", {
      projectId: "p", defaultNotifyOnly: false, sessions: [{
        terminalId: "t1", notifyOnly: true, state: "needs_you", pendingEscalations: 1,
        armedAt: 1, doneWhenMet: false, brief, ledger: [],
        escalations: [{
          escalationId: "e1", question: "q", reasoning: "r", draftReply: "",
          urgency: "high", at: 2, kind: "resolve_in_session",
        }],
      }],
    });
    expect(parseMessage(JSON.stringify(msg))).toBeTruthy();
  });

  test("status carries a parked session with its park fields", () => {
    const msg = createMessage("handler:status", {
      projectId: "p", defaultNotifyOnly: false, sessions: [{
        terminalId: "t1", notifyOnly: false, state: "parked", pendingEscalations: 0,
        armedAt: 1, doneWhenMet: false, brief, ledger: [], escalations: [],
        parkKind: "limit", parkedUntil: 1770000000000,
      }],
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.sessions[0].state).toBe("parked");
    expect(parsed.sessions[0].parkKind).toBe("limit");
    expect(parsed.sessions[0].parkedUntil).toBe(1770000000000);
  });

  test("status carries per-session observability, and survives its absence", () => {
    const session = {
      terminalId: "t1", notifyOnly: false, state: "watching" as const, pendingEscalations: 0,
      armedAt: 1, doneWhenMet: false, brief, ledger: [], escalations: [],
    };
    for (const observability of ["full", "escalate_only", "unsupported"] as const) {
      const msg = createMessage("handler:status", {
        projectId: "p", defaultNotifyOnly: false,
        sessions: [{ ...session, observability }],
      });
      const parsed = parseMessage(JSON.stringify(msg)) as any;
      expect(parsed.sessions[0].observability).toBe(observability);
    }
    // Absent is what an older bridge sends; it must parse rather than read as a
    // capability verdict.
    const bare = parseMessage(JSON.stringify(createMessage("handler:status", {
      projectId: "p", defaultNotifyOnly: false, sessions: [session],
    }))) as any;
    expect(bare).toBeTruthy();
    expect(bare.sessions[0].observability).toBeUndefined();
    // A value outside the enum is a bug on the sender, not a field to widen.
    expect(parseMessage(JSON.stringify(createMessage("handler:status", {
      projectId: "p", defaultNotifyOnly: false,
      sessions: [{ ...session, observability: "partly" }],
    } as never)))).toBeNull();
  });

  test("observability is appended last, so no existing key moved", () => {
    // The app reads by key, but the snapshot's byte layout is what an older app
    // was tested against — a new field ahead of the others would reorder it.
    const msg = createMessage("handler:status", {
      projectId: "p", defaultNotifyOnly: false, sessions: [{
        terminalId: "t1", notifyOnly: false, state: "watching", pendingEscalations: 0,
        armedAt: 1, doneWhenMet: false, brief, ledger: [], escalations: [],
        judgeTool: "codex", observability: "full",
      }],
    });
    const keys = Object.keys((parseMessage(JSON.stringify(msg)) as any).sessions[0]);
    expect(keys.at(-1)).toBe("observability");
  });

  test("activity accepts the lifecycle kinds", () => {
    for (const decision of ["parked", "resumed"] as const) {
      const act = createMessage("handler:activity", {
        projectId: "p", recordId: "r", at: 1, terminalId: "t1", decision, reason: "usage limit",
      });
      expect(parseMessage(JSON.stringify(act))).toBeTruthy();
    }
  });

  test("handler:planRequest accepts optional judge overrides", () => {
    const msg = createMessage("handler:planRequest", {
      projectId: "p", terminalId: "t", judgeTool: "codex", judgeModel: "gpt-5.3-codex",
    });
    const parsed = parseMessage(JSON.stringify(msg));
    expect(parsed?.type).toBe("handler:planRequest");
    expect((parsed as any).judgeTool).toBe("codex");
  });

  test("handler:planResult echoes the stored judge", () => {
    const msg = createMessage("handler:planResult", {
      projectId: "p", terminalId: "t", fallback: false,
      judgeTool: "opencode", judgeModel: "m",
    });
    const parsed = parseMessage(JSON.stringify(msg));
    expect((parsed as any).judgeTool).toBe("opencode");
  });

  test("handler:status carries judge per session, not at top level", () => {
    const msg = createMessage("handler:status", {
      projectId: "p", defaultTool: "claude-code", defaultNotifyOnly: false,
      sessions: [{
        terminalId: "t", notifyOnly: false, state: "watching", pendingEscalations: 0,
        armedAt: 1, doneWhenMet: false,
        brief: { taskSummary: "x", willHandle: [], wakeFor: [], thenItems: [] },
        ledger: [], escalations: [], judgeTool: "codex", judgeModel: "gpt-5.3-codex",
      }],
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.sessions[0].judgeTool).toBe("codex");
    expect(parsed.tool).toBeUndefined();
    expect(parsed.model).toBeUndefined();
  });
});

// parseMessageFast validates ONLY the message type, so agent-core re-parses the
// configure payload with HandlerConfigureWire before arming. notifyOnly is as
// safety-relevant as the brief: absent, it reads as falsy and would arm an
// auto-injecting session for a user who asked for notify-only.
describe("HandlerConfigureWire (hot-path re-validation)", () => {
  const brief = { taskSummary: "s", willHandle: [], wakeFor: [], thenItems: [] };

  it("accepts a well-formed arm payload", () => {
    const r = HandlerConfigureWire.safeParse({ terminalId: "t1", armed: true, notifyOnly: true, brief });
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.notifyOnly).toBe(true);
  });

  it("rejects a missing notifyOnly instead of letting it read as false", () => {
    expect(HandlerConfigureWire.safeParse({ terminalId: "t1", armed: true, brief }).success).toBe(false);
  });

  it("rejects a non-boolean notifyOnly", () => {
    expect(
      HandlerConfigureWire.safeParse({ terminalId: "t1", armed: true, notifyOnly: "false", brief }).success,
    ).toBe(false);
  });

  it("rejects a non-string terminalId and a non-boolean armed", () => {
    expect(HandlerConfigureWire.safeParse({ terminalId: 7, armed: false, notifyOnly: false }).success).toBe(false);
    expect(HandlerConfigureWire.safeParse({ terminalId: "t1", armed: "yes", notifyOnly: false }).success).toBe(false);
  });

  it("still enforces armed-requires-a-brief", () => {
    expect(HandlerConfigureWire.safeParse({ terminalId: "t1", armed: true, notifyOnly: false }).success).toBe(false);
    expect(HandlerConfigureWire.safeParse({ terminalId: "t1", armed: false, notifyOnly: false }).success).toBe(true);
  });
});
