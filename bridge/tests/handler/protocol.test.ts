import { describe, test, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  createMessage, parseMessage, parseMessageFast,
  HandlerAnswerWire, HandlerConfigureWire, HandlerInstructWire, HandlerUndoWire, HandlerDismissWire,
  type HandlerInstructionItem,
} from "../../src/protocol";

const item = (id: string, over: Partial<HandlerInstructionItem> = {}): HandlerInstructionItem =>
  ({ id, text: `do ${id}`, status: "queued", createdAt: 1, ...over });

describe("handler wire", () => {
  const backlog = [item("i1"), item("i2", { status: "done", evidence: "3 passed", dependsOn: ["i1"] })];

  test("configure carries the goal and the backlog", () => {
    const msg = createMessage("handler:configure", {
      projectId: "p", terminalId: "t1", armed: true,
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
      projectId: "p", terminalId: "t1", armed: true,
    });
    expect(parseMessage(JSON.stringify(msg))).toBeTruthy();
  });

  test("configure and status carry the judge override fields", () => {
    const cfg = createMessage("handler:configure", {
      projectId: "p", terminalId: "t1", armed: true,
      goal: "g", backlog, judgeTool: "codex", judgeModel: "",
    });
    expect(parseMessage(JSON.stringify(cfg))).toBeTruthy();
    const status = createMessage("handler:status", {
      snapshots: [],
      projectId: "p", defaultTool: "claude-code",
      sessions: [{
        terminalId: "t1", state: "watching", pendingEscalations: 0,
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
      projectId: "p", sessions: [{
        terminalId: "t1", state: "watching", pendingEscalations: 1,
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
      terminalId: "t1", state: "watching" as const, pendingEscalations: 0,
      armedAt: 1, goal: "g", backlog, escalations: [],
    };
    const send = (s: object) => parseMessage(JSON.stringify(createMessage("handler:status", {
      snapshots: [],
      projectId: "p", sessions: [s] as never,
    })));
    const { goal: _g, ...noGoal } = snapshot;
    const { backlog: _b, ...noBacklog } = snapshot;
    expect(send(noGoal)).toBeNull();
    expect(send(noBacklog)).toBeNull();
  });

  test("activity accepts the item-outcome kinds; escalation accepts floorRule", () => {
    for (const decision of ["armed", "goal_edited", "item_done", "item_blocked",
      "item_skipped", "item_failed", "evidence_rejected", "wrapped_up"] as const) {
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
    expect(parseMessage(JSON.stringify(createMessage("handler:escalation", {
      ...base, kind: "guard_blocked",
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
    // Absent = free-text reply, exactly as `kind` is absent — the shape that
    // predates quick choices.
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

  test("escalation carries the ask fields, and survives their absence", () => {
    const base = {
      projectId: "p", escalationId: "e1", terminalId: "t1", question: "q",
      reasoning: "r", draftReply: "", urgency: "normal", at: 1,
    } as const;
    const option = (over: Record<string, unknown> = {}) =>
      ({ choiceId: "staging", label: "Point it at staging", cost: "one extra deploy later", ...over });
    const other = { choiceId: "prod", label: "Go straight at production", cost: "no second cutover" };
    const send = (over: Record<string, unknown>) => parseMessage(JSON.stringify({
      ...createMessage("handler:escalation", base), ...over,
    }));
    // Absent is every row a bridge sends today, and it must read as the stopped
    // session it has always meant.
    const bare = parseMessage(JSON.stringify(createMessage("handler:escalation", base))) as any;
    expect(bare).toBeTruthy();
    expect(bare.nonBlocking).toBeUndefined();
    expect(bare.askOptions).toBeUndefined();

    const full = send({
      nonBlocking: true, unblocked: ["i1", "i2"],
      askOptions: [option(), { ...other, recommended: true }],
    }) as any;
    expect(full.nonBlocking).toBe(true);
    expect(full.unblocked).toEqual(["i1", "i2"]);
    // `label` is the whole payload of a tap, so it has to survive the wire
    // verbatim — there is no second field the answer could be recovered from.
    expect(full.askOptions[0].label).toBe("Point it at staging");
    expect(full.askOptions[1].recommended).toBe(true);
    // Each field stands alone: the app's capability gate strips them one at a
    // time and must never produce a frame this refuses.
    expect(send({ nonBlocking: true })).toBeTruthy();
    expect(send({ unblocked: [] })).toBeTruthy();

    // Four is what a notification action row can carry; one is a question with no
    // alternative, and the composer is app-authored so it is never an entry here.
    expect(send({ askOptions: [option(), other, option({ choiceId: "wait" }), option({ choiceId: "abort" })] })).toBeTruthy();
    expect(send({ askOptions: [option()] })).toBeNull();
    expect(send({ askOptions: [] })).toBeNull();
    expect(send({ askOptions: [option(), other, option({ choiceId: "a" }), option({ choiceId: "b" }), option({ choiceId: "c" })] })).toBeNull();
    // Every surface resolves a tap by first match, so a repeated id parks an
    // answer the user did not read.
    expect(send({ askOptions: [option(), option({ label: "Point it at staging, carefully" })] })).toBeNull();
    // An option with nothing on it is a button whose answer is unreadable.
    expect(send({ askOptions: [option({ label: "" }), other] })).toBeNull();
    expect(send({ askOptions: [option({ cost: "" }), other] })).toBeNull();
    expect(send({ askOptions: [option({ label: "x".repeat(81) }), other] })).toBeNull();
    // `recommended` is z.literal(true) precisely so absent and `false` cannot
    // become two spellings of the same thing.
    expect(send({ askOptions: [option({ recommended: false }), other] })).toBeNull();
    expect(send({ unblocked: Array.from({ length: 11 }, (_, i) => `i${i}`) })).toBeNull();
  });

  test("status snapshot escalations carry kind and choices through the replay", () => {
    const msg = createMessage("handler:status", {
      snapshots: [],
      projectId: "p", sessions: [{
        terminalId: "t1", state: "needs_you", pendingEscalations: 1,
        armedAt: 1, goal: "g", backlog,
        escalations: [{
          escalationId: "e1", question: "q", reasoning: "r", draftReply: "",
          urgency: "high", at: 2, kind: "resolve_in_session",
        }, {
          escalationId: "e3", question: "Handler did not send its reply",
          reasoning: "reply contains control characters", draftReply: "yes[B",
          urgency: "normal", at: 4, kind: "guard_blocked",
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
    expect(parsed.sessions[0].escalations[2].choices[0].text).toBe("ship it");
    // The app rebuilds its rows wholesale from this snapshot, and the kind is
    // what tells it a Dismiss is the only thing that retires one.
    expect(parsed.sessions[0].escalations[1].kind).toBe("guard_blocked");
  });

  test("status carries a parked session with its park fields", () => {
    const msg = createMessage("handler:status", {
      snapshots: [],
      projectId: "p", sessions: [{
        terminalId: "t1", state: "parked", pendingEscalations: 0,
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
      terminalId: "t1", state: "watching" as const, pendingEscalations: 0,
      armedAt: 1, goal: "g", backlog, escalations: [],
    };
    for (const observability of ["full", "escalate_only", "unsupported"] as const) {
      const msg = createMessage("handler:status", {
        snapshots: [],
        projectId: "p",
        sessions: [{ ...session, observability }],
      });
      const parsed = parseMessage(JSON.stringify(msg)) as any;
      expect(parsed.sessions[0].observability).toBe(observability);
    }
    // Absent is what an older bridge sends; it must parse rather than read as a
    // capability verdict.
    const bare = parseMessage(JSON.stringify(createMessage("handler:status", {
      snapshots: [], projectId: "p", sessions: [session],
    }))) as any;
    expect(bare).toBeTruthy();
    expect(bare.sessions[0].observability).toBeUndefined();
    // A value outside the enum is a bug on the sender, not a field to widen.
    expect(parseMessage(JSON.stringify(createMessage("handler:status", {
      snapshots: [], projectId: "p",
      sessions: [{ ...session, observability: "partly" }],
    } as never)))).toBeNull();
  });

  test("observability is appended last, so no existing key moved", () => {
    // The app reads by key, but the snapshot's byte layout is what an older app
    // was tested against — a new field ahead of the others would reorder it.
    const msg = createMessage("handler:status", {
      snapshots: [],
      projectId: "p", sessions: [{
        terminalId: "t1", state: "watching", pendingEscalations: 0,
        armedAt: 1, goal: "g", backlog, escalations: [],
        judgeTool: "codex", observability: "full",
      }],
    });
    const keys = Object.keys((parseMessage(JSON.stringify(msg)) as any).sessions[0]);
    expect(keys.at(-1)).toBe("observability");
  });

  test("status advertises that asks can be answered, and replays an ask row", () => {
    // The advert lives on the SNAPSHOT and not on the row because the row cannot
    // advertise itself: a bridge that reads `nonBlocking` off a record a newer one
    // wrote re-emits it faithfully while having no verb that answers it. An app
    // that acted on the row alone would answer through the reply transport, into a
    // PTY the session never stopped.
    const session = {
      terminalId: "t1", state: "needs_you" as const, pendingEscalations: 1,
      armedAt: 1, goal: "g", backlog,
      escalations: [{
        escalationId: "a1", question: "Which database should the migration target?",
        reasoning: "r", draftReply: "", urgency: "normal" as const, at: 2,
        nonBlocking: true, unblocked: ["i1"],
        askOptions: [
          { choiceId: "staging", label: "Point it at staging for now", cost: "one extra deploy later" },
          { choiceId: "prod", label: "Go straight at production", cost: "no second cutover" },
        ],
      }],
    };
    const msg = createMessage("handler:status", {
      snapshots: [], projectId: "p",
      sessions: [{ ...session, askAnswer: true, askAnswerPending: true }],
    } as never);
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.sessions[0].askAnswer).toBe(true);
    expect(parsed.sessions[0].askAnswerPending).toBe(true);
    expect(parsed.sessions[0].escalations[0].nonBlocking).toBe(true);
    expect(parsed.sessions[0].escalations[0].unblocked).toEqual(["i1"]);
    expect(parsed.sessions[0].escalations[0].askOptions[1].choiceId).toBe("prod");

    // Absent is every bridge that predates the verb, and it must still deliver a
    // frame whose rows carry the flag — that is the rollback case exactly.
    const bare = parseMessage(JSON.stringify(createMessage("handler:status", {
      snapshots: [], projectId: "p", sessions: [session],
    } as never))) as any;
    expect(bare).toBeTruthy();
    expect(bare.sessions[0].askAnswer).toBeUndefined();
    expect(bare.sessions[0].escalations[0].nonBlocking).toBe(true);

    // z.literal(true), so there is no second spelling of "this bridge cannot".
    expect(parseMessage(JSON.stringify(createMessage("handler:status", {
      snapshots: [], projectId: "p", sessions: [{ ...session, askAnswer: false }],
    } as never)))).toBeNull();
  });

  // The record the app reads hours later, when the session that produced it is
  // gone from `sessions` and nothing else on the frame names it.
  const wrapUp = {
    wrapUpId: "w1", terminalId: "t1", at: 5, goal: "migrate auth",
    outcomes: [{ status: "done" as const, total: 4, items: ["land it", "backfill"] }],
    blockedTotal: 1, blockedReasons: ["reply contains control characters"],
  };

  test("status carries the wrap-up records, and survives their absence", () => {
    const msg = createMessage("handler:status", {
      snapshots: [], projectId: "p", sessions: [], wrapUps: [wrapUp],
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.wrapUps).toEqual([wrapUp]);
    // The true total is what makes "+N more" derivable from a sampled list.
    expect(parsed.wrapUps[0].outcomes[0].total).toBe(4);
    // Absent is what a bridge predating the field sends, and what a project with
    // nothing to report sends today — both must still deliver the frame.
    const bare = parseMessage(JSON.stringify(createMessage("handler:status", {
      snapshots: [], projectId: "p", sessions: [],
    }))) as any;
    expect(bare).toBeTruthy();
    expect(bare.wrapUps).toBeUndefined();
  });

  test("wrapUps is appended last, so no existing key moved", () => {
    const msg = createMessage("handler:status", {
      snapshots: [], projectId: "p", defaultTool: "claude-code", sessions: [], wrapUps: [wrapUp],
    });
    expect(Object.keys(parseMessage(JSON.stringify(msg)) as any).at(-1)).toBe("wrapUps");
  });

  test("an outcome status outside the four item outcomes is rejected", () => {
    expect(parseMessage(JSON.stringify(createMessage("handler:status", {
      snapshots: [], projectId: "p", sessions: [],
      wrapUps: [{ ...wrapUp, outcomes: [{ status: "queued", total: 1, items: [] }] }],
    } as never)))).toBeNull();
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
      projectId: "p", defaultTool: "claude-code",
      sessions: [{
        terminalId: "t", state: "watching", pendingEscalations: 0,
        armedAt: 1, goal: "g", backlog: [],
        escalations: [], judgeTool: "codex", judgeModel: "gpt-5.3-codex",
      }],
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.sessions[0].judgeTool).toBe("codex");
    expect(parsed.tool).toBeUndefined();
    expect(parsed.model).toBeUndefined();
  });

  // `lenses` is top-level because the arm sheet reads it for a slot that has no
  // snapshot yet, while a session's own lens is state on the snapshot.
  test("handler:status advertises the lens ids at top level and carries the session's own lens", () => {
    const msg = createMessage("handler:status", {
      snapshots: [],
      projectId: "p", lenses: ["pm", "qa", "critic", "release"],
      sessions: [{
        terminalId: "t", state: "watching", pendingEscalations: 0,
        armedAt: 1, goal: "g", backlog: [],
        escalations: [], role: "release", brief: "note the changelog",
      }],
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.lenses).toEqual(["pm", "qa", "critic", "release"]);
    expect(parsed.sessions[0].role).toBe("release");
    expect(parsed.sessions[0].brief).toBe("note the changelog");
  });

  // Absent is the unnamed default, not a bridge that cannot do lenses — nothing
  // may start defaulting the key on the way through.
  test("a session with no lens carries neither key", () => {
    const msg = createMessage("handler:status", {
      snapshots: [], projectId: "p",
      sessions: [{
        terminalId: "t", state: "watching", pendingEscalations: 0,
        armedAt: 1, goal: "g", backlog: [], escalations: [],
      }],
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.sessions[0].role).toBeUndefined();
    expect(parsed.sessions[0].brief).toBeUndefined();
  });
});

// parseMessageFast validates ONLY the message type, so agent-core re-parses the
// configure payload with HandlerConfigureWire before arming. It re-parses the
// payload wholesale rather than the fields it acts on because BacklogWire's
// duplicate-id refine has to run over the list before it is stored — a shadowed
// item is unreachable by any transition, leaving a session that can never wrap up.
describe("HandlerConfigureWire (hot-path re-validation)", () => {
  it("accepts a well-formed arm payload", () => {
    const r = HandlerConfigureWire.safeParse({
      terminalId: "t1", armed: true,
      goal: "migrate auth", backlog: [item("i1")],
    });
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.goal).toBe("migrate auth");
  });

  // `armed` is the branch agent-core switches on, so one arriving absent would
  // read as falsy and disarm the live session the sender meant to edit.
  it("rejects a missing armed instead of letting it read as a disarm", () => {
    expect(HandlerConfigureWire.safeParse({ terminalId: "t1" }).success).toBe(false);
  });

  it("rejects a non-string terminalId and a non-boolean armed", () => {
    expect(HandlerConfigureWire.safeParse({ terminalId: 7, armed: false }).success).toBe(false);
    expect(HandlerConfigureWire.safeParse({ terminalId: "t1", armed: "yes" }).success).toBe(false);
  });

  // Absent is not empty: a re-arm or a judge pick ships neither field and must
  // leave the bridge's copy — which holds the statuses this session banked —
  // exactly as it was. `[]` is the explicit clear.
  it("accepts goal and backlog absent, and an explicitly empty backlog", () => {
    const bare = HandlerConfigureWire.safeParse({ terminalId: "t1", armed: true });
    expect(bare.success).toBe(true);
    if (bare.success) {
      expect(bare.data.goal).toBeUndefined();
      expect(bare.data.backlog).toBeUndefined();
    }
    expect(HandlerConfigureWire.safeParse({
      terminalId: "t1", armed: true, backlog: [],
    }).success).toBe(true);
  });

  it("carries a lens and a brief, and takes \"\" as the clear back to the default", () => {
    const set = HandlerConfigureWire.safeParse({
      terminalId: "t1", armed: true, role: "qa", brief: "watch the migration path",
    });
    expect(set.success).toBe(true);
    if (set.success) {
      expect(set.data.role).toBe("qa");
      expect(set.data.brief).toBe("watch the migration path");
    }
    const cleared = HandlerConfigureWire.safeParse({
      terminalId: "t1", armed: true, role: "", brief: "",
    });
    expect(cleared.success).toBe(true);
    if (cleared.success) {
      expect(cleared.data.role).toBe("");
      expect(cleared.data.brief).toBe("");
    }
  });

  // The lens ids are the bridge's own, and a value outside them would resolve to
  // nothing the prompt can print.
  it("rejects a lens id it does not define", () => {
    expect(HandlerConfigureWire.safeParse({
      terminalId: "t1", armed: true, role: "yolo",
    }).success).toBe(false);
  });

  // The prompt budget is the ENGINE's, applied by clipping. Refusing a long brief
  // here would drop the goal, the backlog, the judge picks and the arm along with
  // it, since agent-core re-parses the whole payload with this schema.
  it("accepts a brief far past the prompt budget and refuses only the absurd", () => {
    expect(HandlerConfigureWire.safeParse({
      terminalId: "t1", armed: true, brief: "x".repeat(5_000),
    }).success).toBe(true);
    expect(HandlerConfigureWire.safeParse({
      terminalId: "t1", armed: true, brief: "x".repeat(10_001),
    }).success).toBe(false);
  });

  // An older app still ships the retired posture key. Refusing the frame over it
  // would take the arm with it.
  it("still parses a configure whose only posture key is the legacy one", () => {
    expect(HandlerConfigureWire.safeParse({
      terminalId: "t1", armed: true, personality: "closer",
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
    { name: "1-tap arm", payload: { terminalId: "t1", armed: true }, valid: true },
    { name: "disarm", payload: { terminalId: "t1", armed: false }, valid: true },
    {
      name: "full payload",
      payload: {
        terminalId: "t1", armed: true, goal: "g",
        backlog: [item("i1"), item("i2", { dependsOn: ["i1"] })],
        judgeTool: "codex", judgeModel: "gpt-5.3-codex",
      },
      valid: true,
    },
    { name: "explicit backlog clear", payload: { terminalId: "t1", armed: true, backlog: [] }, valid: true },
    {
      name: "a lens and a brief",
      payload: { terminalId: "t1", armed: true, role: "critic", brief: "mind the rollback" },
      valid: true,
    },
    { name: "lens cleared to the default", payload: { terminalId: "t1", armed: true, role: "" }, valid: true },
    { name: "unknown lens id", payload: { terminalId: "t1", armed: true, role: "yolo" }, valid: false },
    { name: "missing armed", payload: { terminalId: "t1" }, valid: false },
    { name: "non-string terminalId", payload: { terminalId: 7, armed: true }, valid: false },
    { name: "non-boolean armed", payload: { terminalId: "t1", armed: "yes" }, valid: false },
    { name: "non-string goal", payload: { terminalId: "t1", armed: true, goal: 7 }, valid: false },
    {
      name: "duplicate backlog id",
      payload: { terminalId: "t1", armed: true, backlog: [item("i1"), item("i1")] },
      valid: false,
    },
    {
      name: "item with an unknown status",
      payload: { terminalId: "t1", armed: true, backlog: [{ ...item("i1"), status: "in_progress" }] },
      valid: false,
    },
    {
      name: "item missing createdAt",
      payload: { terminalId: "t1", armed: true, backlog: [{ id: "i1", text: "t", status: "queued" }] },
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

describe("handler:snapshot / handler:undo", () => {
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
      projectId: "p", sessions: [],
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

describe("handler:dismiss", () => {
  test("the dismiss verb routes through both parse paths", () => {
    const msg = createMessage("handler:dismiss", { projectId: "p", terminalId: "t1", escalationId: "e1" });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.terminalId).toBe("t1");
    expect(parsed.escalationId).toBe("e1");
    // The hot path admits it on the discriminator alone, which is why agent-core
    // re-parses with HandlerDismissWire before the engine drops a row.
    expect(parseMessageFast(JSON.stringify(msg))?.type).toBe("handler:dismiss");
  });

  const cases: Array<{ name: string; payload: Record<string, unknown>; valid: boolean }> = [
    { name: "a well-formed dismiss", payload: { terminalId: "t1", escalationId: "e1" }, valid: true },
    { name: "missing escalationId", payload: { terminalId: "t1" }, valid: false },
    { name: "non-string escalationId", payload: { terminalId: "t1", escalationId: 7 }, valid: false },
    { name: "missing terminalId", payload: { escalationId: "e1" }, valid: false },
  ];

  for (const c of cases) {
    it(`payload and envelope agree on ${c.name}`, () => {
      const viaPayload = HandlerDismissWire.safeParse(c.payload).success;
      const viaEnvelope = parseMessage(JSON.stringify({
        id: crypto.randomUUID(), timestamp: 1, type: "handler:dismiss", projectId: "p", ...c.payload,
      })) !== null;
      expect(viaPayload).toBe(viaEnvelope);
      expect(viaPayload).toBe(c.valid);
    });
  }
});

describe("handler:answer", () => {
  test("the answer verb routes through both parse paths", () => {
    const msg = createMessage("handler:answer", {
      projectId: "p", terminalId: "t1", escalationId: "e1", choiceId: "staging",
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed.escalationId).toBe("e1");
    expect(parsed.choiceId).toBe("staging");
    // The hot path admits it on the discriminator alone, which is why agent-core
    // re-parses with HandlerAnswerWire before the engine parks an answer.
    expect(parseMessageFast(JSON.stringify(msg))?.type).toBe("handler:answer");
  });

  test("a tap carries ids and nothing else", () => {
    // The option's words are judge-authored and are resolved bridge-side from the
    // persisted row. A `text` field here would be the second producer into the one
    // channel that mints authorization lifts.
    expect(Object.keys(HandlerAnswerWire.shape).sort())
      .toEqual(["choiceId", "escalationId", "terminalId"]);
  });

  const cases: Array<{ name: string; payload: Record<string, unknown>; valid: boolean }> = [
    { name: "a well-formed tap", payload: { terminalId: "t1", escalationId: "e1", choiceId: "opt1" }, valid: true },
    // Both ids are REQUIRED so a cross-language field-name typo fails LOUDLY,
    // through agent-core's re-parse warn and its status resync, rather than
    // arriving as a frame that names no row.
    { name: "missing escalationId", payload: { terminalId: "t1", choiceId: "opt1" }, valid: false },
    { name: "missing choiceId", payload: { terminalId: "t1", escalationId: "e1" }, valid: false },
    { name: "missing terminalId", payload: { escalationId: "e1", choiceId: "opt1" }, valid: false },
    { name: "an empty choiceId", payload: { terminalId: "t1", escalationId: "e1", choiceId: "" }, valid: false },
    { name: "a non-string choiceId", payload: { terminalId: "t1", escalationId: "e1", choiceId: 7 }, valid: false },
    {
      name: "a choiceId at the cap",
      payload: { terminalId: "t1", escalationId: "e1", choiceId: "c".repeat(40) },
      valid: true,
    },
    {
      name: "a choiceId over the cap",
      payload: { terminalId: "t1", escalationId: "e1", choiceId: "c".repeat(41) },
      valid: false,
    },
    {
      name: "an escalationId over the cap",
      payload: { terminalId: "t1", escalationId: "e".repeat(65), choiceId: "opt1" },
      valid: false,
    },
  ];

  for (const c of cases) {
    it(`payload and envelope agree on ${c.name}`, () => {
      const viaPayload = HandlerAnswerWire.safeParse(c.payload).success;
      const viaEnvelope = parseMessage(JSON.stringify({
        id: crypto.randomUUID(), timestamp: 1, type: "handler:answer", projectId: "p", ...c.payload,
      })) !== null;
      expect(viaPayload).toBe(viaEnvelope);
      expect(viaPayload).toBe(c.valid);
    });
  }

  test("the verb is wired at all five registration points", () => {
    // Miss one and the type fails SILENTLY: the frame parses and reaches nothing,
    // or it answers and never parses. Modelled on the same assertion
    // checkout-protocol-contract.test.ts makes for session:setup.
    const protocol = readFileSync(join(import.meta.dir, "../../src/protocol.ts"), "utf8");
    // 1. the schema, 2. the exported type.
    expect(protocol).toContain('type: z.literal("handler:answer")');
    expect(protocol).toContain("export type HandlerAnswerMsg =");
    // 3. the handler. CLAUDE.md still calls it "the index.ts switch"; the inbound
    // switch itself lives in agent-core.ts.
    const core = readFileSync(join(import.meta.dir, "../../src/agent-core.ts"), "utf8");
    expect(core).toContain('case "handler:answer"');
    // 4. KNOWN_TYPES and 5. the AbMessageSchema union, proven by behaviour rather
    // than by grep: the two parse paths refuse a type either one has not heard of.
    const raw = JSON.stringify(createMessage("handler:answer", {
      projectId: "p", terminalId: "t1", escalationId: "e1", choiceId: "opt1",
    }));
    expect(parseMessageFast(raw)?.type).toBe("handler:answer");
    expect(parseMessage(raw)).toMatchObject({ type: "handler:answer", choiceId: "opt1" });
  });
});

describe("handler:instruct answers an ask by naming it", () => {
  const send = (over: Record<string, unknown>) => parseMessage(JSON.stringify({
    ...createMessage("handler:instruct", { projectId: "p", terminalId: "t1", text: "use staging" }),
    ...over,
  })) as any;

  test("escalationId rides the frame, and its absence is an ordinary instruction", () => {
    expect(send({ escalationId: "e1" }).escalationId).toBe("e1");
    expect(send({}).escalationId).toBeUndefined();
    expect(send({ escalationId: "e".repeat(64) })).toBeTruthy();
    expect(send({ escalationId: "e".repeat(65) })).toBeNull();
    expect(send({ escalationId: 7 })).toBeNull();
  });

  test("a bridge that predates the field strips it and still parses the instruction", () => {
    // The rollback case, and the whole reason the app may send this only to a
    // session whose snapshot advertised `askAnswer`: the schema is a plain
    // non-strict z.object, so an older bridge silently reads the frame as a new
    // instruction — which is an authorizing, extracting one.
    const old = HandlerInstructWire.omit({ escalationId: true });
    const parsed = old.safeParse({ terminalId: "t1", text: "use staging", escalationId: "e1" });
    expect(parsed.success).toBe(true);
    expect(parsed.success && "escalationId" in parsed.data).toBe(false);
    expect(parsed.success && parsed.data.text).toBe("use staging");
  });
});
