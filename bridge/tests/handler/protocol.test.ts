import { describe, test, expect, it } from "bun:test";
import {
  createMessage, parseMessage, parseMessageFast,
  HandlerConfigureWire, HandlerInstructWire, HandlerUndoWire,
  type HandlerInstructionItem,
} from "../../src/protocol";

const item = (id: string, over: Partial<HandlerInstructionItem> = {}): HandlerInstructionItem =>
  ({ id, text: `do ${id}`, status: "queued", createdAt: 1, ...over });

describe("handler wire", () => {
  const backlog = [item("i1"), item("i2", { status: "done", evidence: "3 passed", dependsOn: ["i1"] })];

  test("configure carries the goal and the backlog", () => {
    const msg = createMessage("handler:configure", {
      projectId: "p", terminalId: "t1", armed: true, notifyOnly: false,
      goal: "migrate auth", backlog,
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.goal).toBe("migrate auth");
    expect(parsed.backlog[1].evidence).toBe("3 passed");
    expect(parsed.backlog[1].dependsOn).toEqual(["i1"]);
  });

  // One tap arms with whatever the session already holds; a rule demanding a
  // filled-in field would put a form back in front of that tap.
  test("arming carries no required payload", () => {
    const msg = createMessage("handler:configure", {
      projectId: "p", terminalId: "t1", armed: true, notifyOnly: false,
    });
    expect(parseMessage(JSON.stringify(msg))).toBeTruthy();
  });

  test("configure and status carry the judge override fields", () => {
    const cfg = createMessage("handler:configure", {
      projectId: "p", terminalId: "t1", armed: true, notifyOnly: false,
      goal: "g", backlog, judgeTool: "codex", judgeModel: "",
    });
    expect(parseMessage(JSON.stringify(cfg))).toBeTruthy();
    const status = createMessage("handler:status", {
      snapshots: [],
      projectId: "p", defaultTool: "claude-code", defaultNotifyOnly: false,
      sessions: [{
        terminalId: "t1", notifyOnly: false, state: "watching", pendingEscalations: 0,
        armedAt: 1, goal: "g", backlog,
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
      snapshots: [],
      projectId: "p", defaultNotifyOnly: false, sessions: [{
        terminalId: "t1", notifyOnly: false, state: "watching", pendingEscalations: 1,
        armedAt: 1, goal: "g", backlog,
        escalations: [{
          escalationId: "e1", question: "q", reasoning: "r", draftReply: "",
          urgency: "normal", at: 2,
        }],
      }],
    });
    expect(parseMessage(JSON.stringify(msg))).toBeTruthy();
  });

  // The snapshot is the bridge's own state, which always has both — an absent
  // field there would read app-side as an empty backlog and blank the item list.
  test("status requires goal and backlog on every snapshot", () => {
    const snapshot = {
      terminalId: "t1", notifyOnly: false, state: "watching" as const, pendingEscalations: 0,
      armedAt: 1, goal: "g", backlog, escalations: [],
    };
    const send = (s: object) => parseMessage(JSON.stringify(createMessage("handler:status", {
      snapshots: [],
      projectId: "p", defaultNotifyOnly: false, sessions: [s] as never,
    })));
    const { goal: _g, ...noGoal } = snapshot;
    const { backlog: _b, ...noBacklog } = snapshot;
    expect(send(noGoal)).toBeNull();
    expect(send(noBacklog)).toBeNull();
  });

  test("activity accepts the item-outcome kinds; escalation accepts floorRule", () => {
    for (const decision of ["armed", "goal_edited", "item_done", "item_blocked",
      "item_skipped", "item_failed", "wrapped_up"] as const) {
      const act = createMessage("handler:activity", {
        projectId: "p", recordId: "r", at: 1, terminalId: "t1", decision, reason: "done",
      });
      expect(parseMessage(JSON.stringify(act))).toBeTruthy();
    }
    const esc = createMessage("handler:escalation", {
      projectId: "p", escalationId: "e", terminalId: "t1", question: "q",
      reasoning: "r", draftReply: "", urgency: "normal", floorRule: "force-push", at: 1,
    });
    expect(parseMessage(JSON.stringify(esc))).toBeTruthy();
  });

  test("activity rejects a retired decision kind", () => {
    expect(parseMessage(JSON.stringify({
      ...createMessage("handler:activity", {
        projectId: "p", recordId: "r", at: 1, terminalId: "t1",
        decision: "wrapped_up", reason: "done",
      }),
      decision: "item_satisfied",
    }))).toBeNull();
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

  test("escalation choices are optional, bounded, and control-char free", () => {
    const base = {
      projectId: "p", escalationId: "e1", terminalId: "t1", question: "q",
      reasoning: "r", draftReply: "ship it", urgency: "normal", at: 1,
    } as const;
    const choice = (over: Record<string, unknown> = {}) =>
      ({ choiceId: "approve", label: "Approve", text: "ship it", ...over });
    // Distinct id, so a case below fails on the field it names rather than on the
    // uniqueness rule.
    const other = { choiceId: "reject", label: "Reject", text: "no" };
    const send = (choices: unknown) => parseMessage(JSON.stringify({
      ...createMessage("handler:escalation", base), choices,
    }));
    // Absent = free-text reply, exactly as `kind` is absent — the pre-§4.6 shape.
    expect(parseMessage(JSON.stringify(createMessage("handler:escalation", base)))).toBeTruthy();
    expect(send([choice(), other])).toBeTruthy();
    // One chip is a card with no alternative; four is past what a lock-screen
    // notification can offer.
    expect(send([])).toBeNull();
    expect(send([choice()])).toBeNull();
    expect(send([choice({ choiceId: "a" }), choice({ choiceId: "b" }),
      choice({ choiceId: "c" }), choice({ choiceId: "d" })])).toBeNull();
    // A choice with nothing to send is a button that silently does nothing, and an
    // embedded CR would submit two lines into the PTY.
    expect(send([choice({ text: "" }), other])).toBeNull();
    expect(send([choice({ text: "   " }), other])).toBeNull();
    expect(send([choice({ text: "yes\rrm -rf /" }), other])).toBeNull();
    expect(send([choice({ label: "" }), other])).toBeNull();
    expect(send([choice({ choiceId: "" }), other])).toBeNull();
    expect(send([choice({ choiceId: "z".repeat(41) }), other])).toBeNull();
    // Every surface resolves a tap by first match, so a repeated id sends the text
    // of a chip the user did not read.
    expect(send([choice(), choice({ label: "Approve with tests", text: "yes, and run the suite" })]))
      .toBeNull();
  });

  test("status snapshot escalations carry kind and choices through the replay", () => {
    const msg = createMessage("handler:status", {
      snapshots: [],
      projectId: "p", defaultNotifyOnly: false, sessions: [{
        terminalId: "t1", notifyOnly: true, state: "needs_you", pendingEscalations: 1,
        armedAt: 1, goal: "g", backlog,
        escalations: [{
          escalationId: "e1", question: "q", reasoning: "r", draftReply: "",
          urgency: "high", at: 2, kind: "resolve_in_session",
        }, {
          escalationId: "e2", question: "q", reasoning: "r", draftReply: "ship it",
          urgency: "normal", at: 3,
          choices: [
            { choiceId: "approve", label: "Approve", text: "ship it" },
            { choiceId: "reject", label: "Reject", text: "no" },
          ],
        }],
      }],
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.sessions[0].escalations[1].choices[0].text).toBe("ship it");
  });

  test("status carries a parked session with its park fields", () => {
    const msg = createMessage("handler:status", {
      snapshots: [],
      projectId: "p", defaultNotifyOnly: false, sessions: [{
        terminalId: "t1", notifyOnly: false, state: "parked", pendingEscalations: 0,
        armedAt: 1, goal: "g", backlog: [], escalations: [],
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
      armedAt: 1, goal: "g", backlog, escalations: [],
    };
    for (const observability of ["full", "escalate_only", "unsupported"] as const) {
      const msg = createMessage("handler:status", {
        snapshots: [],
        projectId: "p", defaultNotifyOnly: false,
        sessions: [{ ...session, observability }],
      });
      const parsed = parseMessage(JSON.stringify(msg)) as any;
      expect(parsed.sessions[0].observability).toBe(observability);
    }
    // Absent is what an older bridge sends; it must parse rather than read as a
    // capability verdict.
    const bare = parseMessage(JSON.stringify(createMessage("handler:status", {
      snapshots: [], projectId: "p", defaultNotifyOnly: false, sessions: [session],
    }))) as any;
    expect(bare).toBeTruthy();
    expect(bare.sessions[0].observability).toBeUndefined();
    // A value outside the enum is a bug on the sender, not a field to widen.
    expect(parseMessage(JSON.stringify(createMessage("handler:status", {
      snapshots: [], projectId: "p", defaultNotifyOnly: false,
      sessions: [{ ...session, observability: "partly" }],
    } as never)))).toBeNull();
  });

  test("observability is appended last, so no existing key moved", () => {
    // The app reads by key, but the snapshot's byte layout is what an older app
    // was tested against — a new field ahead of the others would reorder it.
    const msg = createMessage("handler:status", {
      snapshots: [],
      projectId: "p", defaultNotifyOnly: false, sessions: [{
        terminalId: "t1", notifyOnly: false, state: "watching", pendingEscalations: 0,
        armedAt: 1, goal: "g", backlog, escalations: [],
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

  test("the retired plan message types are no longer routable", () => {
    for (const type of ["handler:planRequest", "handler:planResult"]) {
      expect(parseMessage(JSON.stringify({
        id: crypto.randomUUID(), timestamp: 1, type, projectId: "p", terminalId: "t1",
      }))).toBeNull();
    }
  });

  test("handler:status carries judge per session, not at top level", () => {
    const msg = createMessage("handler:status", {
      snapshots: [],
      projectId: "p", defaultTool: "claude-code", defaultNotifyOnly: false,
      sessions: [{
        terminalId: "t", notifyOnly: false, state: "watching", pendingEscalations: 0,
        armedAt: 1, goal: "g", backlog: [],
        escalations: [], judgeTool: "codex", judgeModel: "gpt-5.3-codex",
      }],
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.sessions[0].judgeTool).toBe("codex");
    expect(parsed.tool).toBeUndefined();
    expect(parsed.model).toBeUndefined();
  });
});

// parseMessageFast validates ONLY the message type, so agent-core re-parses the
// configure payload with HandlerConfigureWire before arming. notifyOnly is the
// reason it re-parses everything rather than the one field it acts on: arriving
// absent it reads as falsy and would arm an auto-injecting session for a user who
// asked for notify-only.
describe("HandlerConfigureWire (hot-path re-validation)", () => {
  it("accepts a well-formed arm payload", () => {
    const r = HandlerConfigureWire.safeParse({
      terminalId: "t1", armed: true, notifyOnly: true,
      goal: "migrate auth", backlog: [item("i1")],
    });
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.notifyOnly).toBe(true);
  });

  it("rejects a missing notifyOnly instead of letting it read as false", () => {
    expect(HandlerConfigureWire.safeParse({ terminalId: "t1", armed: true }).success).toBe(false);
  });

  it("rejects a non-boolean notifyOnly", () => {
    expect(
      HandlerConfigureWire.safeParse({ terminalId: "t1", armed: true, notifyOnly: "false" }).success,
    ).toBe(false);
  });

  it("rejects a non-string terminalId and a non-boolean armed", () => {
    expect(HandlerConfigureWire.safeParse({ terminalId: 7, armed: false, notifyOnly: false }).success).toBe(false);
    expect(HandlerConfigureWire.safeParse({ terminalId: "t1", armed: "yes", notifyOnly: false }).success).toBe(false);
  });

  // Absent is not empty: a re-arm or a notify-only toggle ships neither field and
  // must leave the bridge's copy — which holds the statuses this session banked —
  // exactly as it was. `[]` is the explicit clear.
  it("accepts goal and backlog absent, and an explicitly empty backlog", () => {
    const bare = HandlerConfigureWire.safeParse({ terminalId: "t1", armed: true, notifyOnly: false });
    expect(bare.success).toBe(true);
    if (bare.success) {
      expect(bare.data.goal).toBeUndefined();
      expect(bare.data.backlog).toBeUndefined();
    }
    expect(HandlerConfigureWire.safeParse({
      terminalId: "t1", armed: true, notifyOnly: false, backlog: [],
    }).success).toBe(true);
  });
});

// The two schemas are deliberate duplicates: the hot path re-validates the payload
// alone, the union validates it inside an envelope. A field-level rule that reaches
// only one of them means the hot path admits what the union rejects (or the
// reverse), so every case below asserts the two verdicts AGREE, not merely that
// each is right on its own.
describe("HandlerConfigureWire and HandlerConfigureMessage stay in lockstep", () => {
  const cases: Array<{ name: string; payload: Record<string, unknown>; valid: boolean }> = [
    { name: "1-tap arm", payload: { terminalId: "t1", armed: true, notifyOnly: false }, valid: true },
    { name: "disarm", payload: { terminalId: "t1", armed: false, notifyOnly: false }, valid: true },
    {
      name: "full payload",
      payload: {
        terminalId: "t1", armed: true, notifyOnly: true, goal: "g",
        backlog: [item("i1"), item("i2", { dependsOn: ["i1"] })],
        judgeTool: "codex", judgeModel: "gpt-5.3-codex",
      },
      valid: true,
    },
    { name: "explicit backlog clear", payload: { terminalId: "t1", armed: true, notifyOnly: false, backlog: [] }, valid: true },
    { name: "missing notifyOnly", payload: { terminalId: "t1", armed: true }, valid: false },
    { name: "non-boolean notifyOnly", payload: { terminalId: "t1", armed: true, notifyOnly: "false" }, valid: false },
    { name: "non-string terminalId", payload: { terminalId: 7, armed: true, notifyOnly: false }, valid: false },
    { name: "non-boolean armed", payload: { terminalId: "t1", armed: "yes", notifyOnly: false }, valid: false },
    { name: "non-string goal", payload: { terminalId: "t1", armed: true, notifyOnly: false, goal: 7 }, valid: false },
    {
      name: "duplicate backlog id",
      payload: { terminalId: "t1", armed: true, notifyOnly: false, backlog: [item("i1"), item("i1")] },
      valid: false,
    },
    {
      name: "item with an unknown status",
      payload: { terminalId: "t1", armed: true, notifyOnly: false, backlog: [{ ...item("i1"), status: "in_progress" }] },
      valid: false,
    },
    {
      name: "item missing createdAt",
      payload: { terminalId: "t1", armed: true, notifyOnly: false, backlog: [{ id: "i1", text: "t", status: "queued" }] },
      valid: false,
    },
  ];

  for (const c of cases) {
    it(`agrees on ${c.name}`, () => {
      const viaPayload = HandlerConfigureWire.safeParse(c.payload).success;
      const viaEnvelope = parseMessage(JSON.stringify({
        id: crypto.randomUUID(), timestamp: 1, type: "handler:configure", projectId: "p", ...c.payload,
      })) !== null;
      expect(viaPayload).toBe(viaEnvelope);
      expect(viaPayload).toBe(c.valid);
    });
  }
});

describe("handler:instruct", () => {
  test("routes through both parse paths with the instruction text", () => {
    const msg = createMessage("handler:instruct", {
      projectId: "p", terminalId: "t1", text: "run the tests then open a PR",
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.text).toBe("run the tests then open a PR");
    expect(parseMessageFast(JSON.stringify(msg))?.type).toBe("handler:instruct");
  });

  const cases: Array<{ name: string; payload: Record<string, unknown>; valid: boolean }> = [
    { name: "a stacked instruction", payload: { terminalId: "t1", text: "fix lint" }, valid: true },
    { name: "empty text", payload: { terminalId: "t1", text: "" }, valid: true },
    { name: "missing text", payload: { terminalId: "t1" }, valid: false },
    { name: "non-string text", payload: { terminalId: "t1", text: 7 }, valid: false },
    { name: "missing terminalId", payload: { text: "fix lint" }, valid: false },
    { name: "text at the cap", payload: { terminalId: "t1", text: "x".repeat(10_000) }, valid: true },
    { name: "text over the cap", payload: { terminalId: "t1", text: "x".repeat(10_001) }, valid: false },
  ];

  for (const c of cases) {
    it(`payload and envelope agree on ${c.name}`, () => {
      const viaPayload = HandlerInstructWire.safeParse(c.payload).success;
      const viaEnvelope = parseMessage(JSON.stringify({
        id: crypto.randomUUID(), timestamp: 1, type: "handler:instruct", projectId: "p", ...c.payload,
      })) !== null;
      expect(viaPayload).toBe(viaEnvelope);
      expect(viaPayload).toBe(c.valid);
    });
  }
});

describe("handler:snapshot / handler:undo (§5.2)", () => {
  const snapshot = {
    snapshotId: "s1", terminalId: "t1", at: 5, action: "reset_hard" as const,
    trigger: "git reset --hard HEAD~1", summary: "saved HEAD abc1234", state: "available" as const,
  };

  test("an undo offer routes through both parse paths", () => {
    const msg = createMessage("handler:snapshot", { projectId: "p", ...snapshot });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.snapshotId).toBe("s1");
    expect(parsed.action).toBe("reset_hard");
    expect(parsed.state).toBe("available");
    expect(parseMessageFast(JSON.stringify(msg))?.type).toBe("handler:snapshot");
  });

  test("status replays undo offers at the project level", () => {
    const msg = createMessage("handler:status", {
      projectId: "p", defaultNotifyOnly: false, sessions: [],
      snapshots: [{ ...snapshot, state: "failed", detail: "backup ref is gone" }],
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.snapshots[0].detail).toBe("backup ref is gone");
  });

  test("an unknown snapshot state is refused", () => {
    const msg = { ...createMessage("handler:snapshot", { projectId: "p", ...snapshot }), state: "maybe" };
    expect(parseMessage(JSON.stringify(msg))).toBeNull();
  });

  test("the undo verb routes through both parse paths", () => {
    const msg = createMessage("handler:undo", { projectId: "p", snapshotId: "s1" });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.snapshotId).toBe("s1");
    // The hot path admits it on the discriminator alone, which is why agent-core
    // re-parses with HandlerUndoWire before anything touches git.
    expect(parseMessageFast(JSON.stringify(msg))?.type).toBe("handler:undo");
  });

  const cases: Array<{ name: string; payload: Record<string, unknown>; valid: boolean }> = [
    { name: "a well-formed undo", payload: { snapshotId: "s1" }, valid: true },
    { name: "missing snapshotId", payload: {}, valid: false },
    { name: "non-string snapshotId", payload: { snapshotId: 7 }, valid: false },
  ];

  for (const c of cases) {
    it(`payload and envelope agree on ${c.name}`, () => {
      const viaPayload = HandlerUndoWire.safeParse(c.payload).success;
      const viaEnvelope = parseMessage(JSON.stringify({
        id: crypto.randomUUID(), timestamp: 1, type: "handler:undo", projectId: "p", ...c.payload,
      })) !== null;
      expect(viaPayload).toBe(viaEnvelope);
      expect(viaPayload).toBe(c.valid);
    });
  }
});
