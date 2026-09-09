// bridge/tests/handler/session-store.test.ts
import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import {
  loadHandlerSession, saveHandlerSession, normalizeInstruction, pushInstruction,
  MAX_INSTRUCTION_CHARS, MAX_INSTRUCTIONS,
  OpenEscalationSchema, HandlerSessionRecordSchema, EscalationChoiceSchema,
  type HandlerSessionRecord,
} from "../../src/handler/session-store";

function tmpAbDir(): string { return mkdtempSync(join(tmpdir(), "ab-session-")); }

function item(id: string, over: Record<string, unknown> = {}) {
  return { id, text: `do ${id}`, status: "queued" as const, createdAt: 1, ...over };
}

function record(over: Partial<HandlerSessionRecord> = {}): HandlerSessionRecord {
  return {
    version: 2, terminalId: "t1", armed: true,
    goal: "migrate the auth module", backlog: [item("i1")],
    armedAt: 123, escalations: [],
    ...over,
  } as HandlerSessionRecord;
}

// Write a file the schema never produced, to exercise the load-side parse.
function writeRaw(abDir: string, terminalId: string, body: string): void {
  const dir = join(abDir, "agents", "proj");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `handler-session-${terminalId}.json`), body, "utf8");
}

describe("session record round-trip", () => {
  it("returns null before anything is written, then the record after", () => {
    const abDir = tmpAbDir();
    expect(loadHandlerSession(abDir, "proj", "t1")).toBeNull();
    saveHandlerSession(abDir, "proj", record());
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.goal).toBe("migrate the auth module");
    expect(loaded?.backlog).toEqual([item("i1")]);
  });

  it("carries banked item state, so a restart re-arms onto the same progress", () => {
    const abDir = tmpAbDir();
    saveHandlerSession(abDir, "proj", record({
      backlog: [
        item("i1", { status: "done", evidence: "3 passed", outcome: "tests green" }),
        item("i2", { dependsOn: ["i1"], condition: "only if the build succeeds" }),
      ],
    }));
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.backlog[0].status).toBe("done");
    expect(loaded?.backlog[0].evidence).toBe("3 passed");
    expect(loaded?.backlog[1].dependsOn).toEqual(["i1"]);
    expect(loaded?.backlog[1].condition).toBe("only if the build succeeds");
  });

  it("round-trips judge choice, park state and open escalations", () => {
    const abDir = tmpAbDir();
    saveHandlerSession(abDir, "proj", record({
      judgeTool: "codex", judgeModel: "gpt-5.3-codex",
      parkKind: "limit", parkCause: "agent_limit", parkedUntil: 1770000000000,
      transientFailures: 2, parkAwaitingJudge: true,
      escalations: [{
        escalationId: "e1", question: "q", reasoning: "r", draftReply: "",
        urgency: "high", kind: "resolve_in_session", at: 2,
      }],
    }));
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.judgeTool).toBe("codex");
    expect(loaded?.judgeModel).toBe("gpt-5.3-codex");
    expect(loaded?.parkKind).toBe("limit");
    // The attribution has to survive alongside the policy: a restart that kept
    // only the kind resumes rendering "temporary failure" for our own judge.
    expect(loaded?.parkCause).toBe("agent_limit");
    expect(loaded?.parkedUntil).toBe(1770000000000);
    expect(loaded?.transientFailures).toBe(2);
    expect(loaded?.parkAwaitingJudge).toBe(true);
    expect(loaded?.escalations[0].kind).toBe("resolve_in_session");
  });

  it("round-trips a guard_blocked escalation, so a restart still owes the user a dismiss", () => {
    // The persisted mirror of the widened enum: nothing but an explicit dismiss
    // retires one, so losing it on a restart is the reported bug by another route.
    const abDir = tmpAbDir();
    saveHandlerSession(abDir, "proj", record({
      escalations: [{
        escalationId: "b1", question: "Handler did not send its reply",
        reasoning: "reply contains control characters", draftReply: "yes[B",
        urgency: "normal", kind: "guard_blocked", at: 2,
      }],
    }));
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.escalations[0].kind).toBe("guard_blocked");
    expect(loaded?.escalations[0].draftReply).toBe("yes[B");
  });

  it("round-trips quick choices, so a restart re-offers the same card", () => {
    // The card is replayed from this record on re-arm and from every status
    // snapshot; a persisted escalation that lost its choices would come back as a
    // free-text row the user already answered once.
    const abDir = tmpAbDir();
    saveHandlerSession(abDir, "proj", record({
      escalations: [{
        escalationId: "e1", question: "q", reasoning: "r", draftReply: "ship it",
        urgency: "normal", at: 2,
        choices: [
          { choiceId: "approve", label: "Approve", text: "ship it" },
          { choiceId: "reject", label: "Reject", text: "Do not proceed." },
        ],
      }],
    }));
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.escalations[0].choices?.map((c) => c.choiceId)).toEqual(["approve", "reject"]);
  });

  it("refuses a card whose ids collide or whose text is only whitespace", () => {
    // Both are chips that lie about what a tap does — a repeated id resolves to
    // the first entry's text, and a blank one is dropped by every send path. The
    // schema is the only thing standing between a hand-edited record and a card
    // the user cannot read the truth off.
    const abDir = tmpAbDir();
    const withChoices = (choices: unknown) => record({
      escalations: [{
        escalationId: "e1", question: "q", reasoning: "r", draftReply: "ship it",
        urgency: "normal", at: 2, choices,
      }],
    } as never);
    saveHandlerSession(abDir, "proj", withChoices([
      { choiceId: "approve", label: "Approve", text: "ship it" },
      { choiceId: "approve", label: "Approve with tests", text: "ship it, run the suite" },
    ]));
    expect(loadHandlerSession(abDir, "proj", "t1")).toBeNull();

    saveHandlerSession(abDir, "proj", withChoices([
      { choiceId: "approve", label: "Approve", text: "   " },
      { choiceId: "reject", label: "Reject", text: "no" },
    ]));
    expect(loadHandlerSession(abDir, "proj", "t1")).toBeNull();
  });

  it("round-trips an ask row and the answer parked against it", () => {
    // The parked answer is the one thing a restart cannot re-derive: the row it
    // answered is already retired, so losing it leaves the user believing they
    // answered with nothing on any surface saying otherwise.
    const abDir = tmpAbDir();
    saveHandlerSession(abDir, "proj", record({
      escalations: [{
        escalationId: "a1", question: "Which database should the migration target?",
        reasoning: "the two are not interchangeable", draftReply: "",
        urgency: "normal", at: 2,
        nonBlocking: true, unblocked: ["i1"],
        askOptions: [
          { choiceId: "staging", label: "Point it at staging for now", cost: "one extra deploy later" },
          { choiceId: "prod", label: "Go straight at production", cost: "no second cutover", recommended: true },
        ],
      }],
      askAnswer: {
        escalationId: "a1", question: "Which database should the migration target?",
        answer: "Point it at staging for now", tapped: true, at: 3,
      },
    }));
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.escalations[0].nonBlocking).toBe(true);
    expect(loaded?.escalations[0].unblocked).toEqual(["i1"]);
    expect(loaded?.escalations[0].askOptions?.map((o) => o.choiceId)).toEqual(["staging", "prod"]);
    expect(loaded?.escalations[0].askOptions?.[1].recommended).toBe(true);
    expect(loaded?.askAnswer?.answer).toBe("Point it at staging for now");
    expect(loaded?.askAnswer?.tapped).toBe(true);
    expect(loaded?.askAnswer?.blocking).toBeUndefined();
  });

  it("round-trips a BLOCKING escalation's answer, and a record written before it stays an ask", () => {
    // `blocking` distinguishes an answer that already reached the agent (relaying
    // it would be a second copy) from an ask's answer (which still has to be
    // relayed) — losing it on a restart would relay an answer the agent already
    // has, straight back at it.
    const abDir = tmpAbDir();
    saveHandlerSession(abDir, "proj", record({
      askAnswer: {
        escalationId: "e1", question: "Handler has a question",
        answer: "Yes, reuse the existing migration table.", tapped: true, blocking: true, at: 3,
      },
    }));
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.askAnswer?.blocking).toBe(true);

    // Absent is every record on disk today, and it must read as an ASK's answer —
    // the conservative direction, since a wrongly-relayed instruction costs a
    // duplicate line while a wrongly-withheld one costs the answer outright.
    saveHandlerSession(abDir, "proj", record({
      askAnswer: {
        escalationId: "a1", question: "Which database?", answer: "staging", tapped: true, at: 3,
      },
    }));
    expect(loadHandlerSession(abDir, "proj", "t1")?.askAnswer?.blocking).toBeUndefined();
  });

  it("round-trips staleAskIds, and a record written before it stays unset", () => {
    // Read back into the decide prompt on the very next arm — a silent
    // persist/reload regression here would surface only as prompt noise, not as
    // a failing assertion anywhere else.
    const abDir = tmpAbDir();
    saveHandlerSession(abDir, "proj", record({ staleAskIds: true }));
    expect(loadHandlerSession(abDir, "proj", "t1")?.staleAskIds).toBe(true);
    saveHandlerSession(abDir, "proj", record());
    expect(loadHandlerSession(abDir, "proj", "t1")?.staleAskIds).toBeUndefined();
  });

  it("round-trips evidenceReasks, and a record written before it spends nothing", () => {
    // The one durable trace that a session was in a refusal episode, and what a
    // stalled session is diagnosed from. Absent has to read as none spent: it is
    // a SPEND, so the conservative reading is a full budget, not an exhausted one.
    const abDir = tmpAbDir();
    saveHandlerSession(abDir, "proj", record({ evidenceReasks: 2 }));
    expect(loadHandlerSession(abDir, "proj", "t1")?.evidenceReasks).toBe(2);
    writeRaw(abDir, "t2", JSON.stringify({ ...record({ terminalId: "t2" }), evidenceReasks: undefined }));
    expect(loadHandlerSession(abDir, "proj", "t2")?.evidenceReasks).toBeUndefined();
    expect(loadHandlerSession(abDir, "proj", "t2")?.backlog).toHaveLength(1);
  });

  it("round-trips the refusal lines the budget was spent on", () => {
    // They ride with evidenceReasks and are read back with it: the counter alone
    // says a spend was made and nothing about what for, and the escalation it ends
    // in puts these lines on the card.
    const abDir = tmpAbDir();
    const rejections = [{ id: "i1", line: `"ship the migration" — nothing on record says so` }];
    saveHandlerSession(abDir, "proj", record({ evidenceReasks: 1, evidenceRejections: rejections }));
    expect(loadHandlerSession(abDir, "proj", "t1")?.evidenceRejections).toEqual(rejections);
    writeRaw(abDir, "t2", JSON.stringify({ ...record({ terminalId: "t2" }), evidenceRejections: undefined }));
    expect(loadHandlerSession(abDir, "proj", "t2")?.evidenceRejections).toBeUndefined();
  });

  it("reads a record written before the ask fields existed as a stopped session", () => {
    // Every record on disk today is this one, and the absent reading has to be the
    // conservative one: no ask, nothing parked, a row the session stopped for.
    const abDir = tmpAbDir();
    saveHandlerSession(abDir, "proj", record({
      escalations: [{
        escalationId: "e1", question: "q", reasoning: "r", draftReply: "",
        urgency: "normal", at: 2,
      }],
    }));
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.escalations[0].nonBlocking).toBeUndefined();
    expect(loaded?.escalations[0].unblocked).toBeUndefined();
    expect(loaded?.escalations[0].askOptions).toBeUndefined();
    expect(loaded?.askAnswer).toBeUndefined();
  });

  it("round-trips the lens and the brief", () => {
    const abDir = tmpAbDir();
    saveHandlerSession(abDir, "proj", record({
      role: "qa", brief: "watch the migration path",
    }));
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.role).toBe("qa");
    expect(loaded?.brief).toBe("watch the migration path");
  });

  // The record field is a lenient string and never the wire enum, because a value
  // this build cannot name would otherwise fail the parse — and loadHandlerSession
  // turns any failure into null, after which arm() rebuilds an empty session and
  // the user's backlog is gone with no error anywhere.
  it("loads a record naming a lens it does not know, with the backlog intact", () => {
    const abDir = tmpAbDir();
    writeRaw(abDir, "t1", JSON.stringify({ ...record(), role: "not-a-lens" }));
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.goal).toBe("migrate the auth module");
    expect(loaded?.backlog).toEqual([item("i1")]);
    expect(loaded?.role).toBe("not-a-lens");
  });

  // The retired posture reaches this schema off any record an older bridge wrote,
  // and refusing one would cost that session its backlog on the upgrade — the one
  // failure this whole field exists to avoid.
  it("loads a record naming a posture no build has ever defined", () => {
    const abDir = tmpAbDir();
    writeRaw(abDir, "t1", JSON.stringify({ ...record(), personality: "anything-at-all" }));
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded).not.toBeNull();
    expect(loaded?.backlog).toEqual([item("i1")]);
  });

  // The three spellings that were actually written to disk. Named one by one
  // rather than covered by the arbitrary-string case above, because the edit this
  // guards against is a cleanup narrowing the field back to the enum it used to
  // be: that reads as tidying, parses these three, and wipes the backlog of every
  // session on the machine the first time a fourth spelling turns up.
  for (const posture of ["watchdog", "closer", "autopilot"]) {
    it(`loads a record written under the ${posture} posture`, () => {
      const abDir = tmpAbDir();
      writeRaw(abDir, "t1", JSON.stringify({ ...record(), personality: posture }));
      const loaded = loadHandlerSession(abDir, "proj", "t1");
      expect(loaded?.personality).toBe(posture);
      expect(loaded?.backlog).toEqual([item("i1")]);
    });
  }

  // Same reason, for length: the prompt budget is the engine's to clip to, and a
  // bound on disk could only cost a session that was written under a looser one.
  it("loads a brief far longer than any prompt would print", () => {
    const abDir = tmpAbDir();
    writeRaw(abDir, "t1", JSON.stringify({ ...record(), brief: "x".repeat(5_000) }));
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.brief).toHaveLength(5_000);
    expect(loaded?.goal).toBe("migrate the auth module");
  });

  it("keeps records apart per terminal", () => {
    const abDir = tmpAbDir();
    saveHandlerSession(abDir, "proj", record({ terminalId: "t1", goal: "one" }));
    saveHandlerSession(abDir, "proj", record({ terminalId: "t2", goal: "two" }));
    expect(loadHandlerSession(abDir, "proj", "t1")?.goal).toBe("one");
    expect(loadHandlerSession(abDir, "proj", "t2")?.goal).toBe("two");
  });
});

// A tripwire against a "tidy-up" `.max()` on this schema: the row is clipped at
// MINT (engine.ts), never bounded here, because a bound here would make a longer
// row already on disk fail HandlerSessionRecordSchema, and loadHandlerSession
// answers a failed parse with null — the session comes back disarmed with an
// empty backlog.
describe("question and reasoning stay unbounded on the record", () => {
  it("parses a 5000-char question and reasoning", () => {
    const parsed = OpenEscalationSchema.safeParse({
      escalationId: "e1", question: "q".repeat(5000), reasoning: "r".repeat(5000),
      draftReply: "", urgency: "normal", at: 1,
    });
    expect(parsed.success).toBe(true);
  });
});

// The button says what it does, `cost` says what it commits to.
describe("an escalation choice's cost", () => {
  const base = { choiceId: "approve", label: "Drop the pricing page", text: "drop it" };

  it("round-trips with a cost", () => {
    const parsed = EscalationChoiceSchema.safeParse({ ...base, cost: "FAQ ships now" });
    expect(parsed.success).toBe(true);
    expect(parsed.success && parsed.data.cost).toBe("FAQ ships now");
  });

  it("round-trips with no cost at all — an app that predates it renders unchanged", () => {
    const parsed = EscalationChoiceSchema.safeParse(base);
    expect(parsed.success).toBe(true);
    expect(parsed.success && parsed.data.cost).toBeUndefined();
  });

  it("refuses a control character in cost", () => {
    expect(EscalationChoiceSchema.safeParse({ ...base, cost: "ships now\r" }).success).toBe(false);
  });

  it("refuses a whitespace-only cost", () => {
    expect(EscalationChoiceSchema.safeParse({ ...base, cost: "   " }).success).toBe(false);
  });

  it("refuses a whitespace-only label", () => {
    expect(EscalationChoiceSchema.safeParse({ ...base, label: "   " }).success).toBe(false);
  });

  it("still accepts every label ever persisted", () => {
    expect(EscalationChoiceSchema.safeParse({ ...base, label: "Approve" }).success).toBe(true);
    expect(EscalationChoiceSchema.safeParse({ ...base, label: "Reject" }).success).toBe(true);
  });
});

describe("session record rejection", () => {
  it("returns null rather than throwing on unparseable json", () => {
    const abDir = tmpAbDir();
    writeRaw(abDir, "t1", "{ not json");
    expect(loadHandlerSession(abDir, "proj", "t1")).toBeNull();
  });

  // The version bump is what makes a clean-slate cutover possible: a record the
  // previous vocabulary wrote loads as null and the session comes back disarmed,
  // rather than rehydrating into a shape the engine no longer drives.
  it("refuses a version-1 record instead of salvaging it", () => {
    const abDir = tmpAbDir();
    writeRaw(abDir, "t1", JSON.stringify({
      version: 1, terminalId: "t1", armed: true, armedAt: 1,
      brief: { taskSummary: "x", willHandle: [], wakeFor: [], thenItems: [] },
      doneWhenMet: false, ledger: [], escalations: [],
    }));
    expect(loadHandlerSession(abDir, "proj", "t1")).toBeNull();
  });

  // The ask fields ride version 2 rather than buying a bump. A record naming any
  // other version is refused whichever direction it came from, which is what makes
  // `version` too expensive to spend on an optional field: loadHandlerSession
  // returns null on it and the session comes back armed at nothing.
  it("refuses a version it does not name, in either direction", () => {
    const abDir = tmpAbDir();
    writeRaw(abDir, "t1", JSON.stringify({ ...record(), version: 3 }));
    expect(loadHandlerSession(abDir, "proj", "t1")).toBeNull();
  });

  // A duplicate id leaves the shadowed item undrivable and the session unable to
  // wrap up, so refusing the record beats rehydrating one that can never finish.
  it("refuses a backlog carrying a duplicate id", () => {
    const abDir = tmpAbDir();
    writeRaw(abDir, "t1", JSON.stringify(record({ backlog: [item("i1"), item("i1")] })));
    expect(loadHandlerSession(abDir, "proj", "t1")).toBeNull();
  });

  it("refuses a record missing goal or backlog", () => {
    const abDir = tmpAbDir();
    const { goal: _g, ...noGoal } = record();
    writeRaw(abDir, "t1", JSON.stringify(noGoal));
    expect(loadHandlerSession(abDir, "proj", "t1")).toBeNull();
    const { backlog: _b, ...noBacklog } = record({ terminalId: "t2" });
    writeRaw(abDir, "t2", JSON.stringify(noBacklog));
    expect(loadHandlerSession(abDir, "proj", "t2")).toBeNull();
  });

  it("refuses an item whose status is not one the state machine drives", () => {
    const abDir = tmpAbDir();
    writeRaw(abDir, "t1", JSON.stringify({
      ...record(), backlog: [item("i1", { status: "in_progress" })],
    }));
    expect(loadHandlerSession(abDir, "proj", "t1")).toBeNull();
  });
});

// A Store rollback puts a bridge that predates the ask in front of a record this
// one wrote, and what it does with the four new fields decides whether the user's
// session survives it. The shape below is derived from the live schemas by
// removal, so it cannot drift away from what it claims to model.
describe("a record this bridge writes stays readable to one that predates the ask", () => {
  const priorEscalation = OpenEscalationSchema.omit({
    nonBlocking: true, unblocked: true, askOptions: true,
  });
  const priorRecord = HandlerSessionRecordSchema
    .omit({ askAnswer: true, escalations: true })
    .extend({ escalations: z.array(priorEscalation) });

  it("strips all four fields and keeps the session armed rather than failing", () => {
    // Every schema here is a plain z.object with no .strict()/.passthrough(), so
    // zod drops what the older shape does not declare and the parse SUCCEEDS. The
    // goal, the backlog and the rows come through, and the ask degrades to an
    // ordinary blocking question — which is that bridge's only correct behaviour.
    // A refusal instead would take the whole session: loadHandlerSession returns
    // null on any failure and arm() then builds a fresh one with goal "" and an
    // empty backlog, silently.
    const parsed = priorRecord.safeParse(record({
      escalations: [{
        escalationId: "a1", question: "Which database should the migration target?",
        reasoning: "r", draftReply: "", urgency: "normal", at: 2,
        nonBlocking: true, unblocked: ["i1"],
        askOptions: [
          { choiceId: "staging", label: "Point it at staging for now", cost: "one extra deploy later" },
          { choiceId: "prod", label: "Go straight at production", cost: "no second cutover" },
        ],
      }, {
        escalationId: "e2", question: "q", reasoning: "r", draftReply: "ship it",
        urgency: "normal", at: 3,
        choices: [
          { choiceId: "approve", label: "Approve", text: "ship it" },
          { choiceId: "reject", label: "Reject", text: "no" },
        ],
      }],
      askAnswer: {
        escalationId: "a1", question: "Which database should the migration target?",
        answer: "Point it at staging for now", tapped: true, at: 4,
      },
    }));
    expect(parsed.success).toBe(true);
    const data = parsed.data as Record<string, unknown> & { escalations: Record<string, unknown>[] };
    expect(data.goal).toBe("migrate the auth module");
    expect(data.askAnswer).toBeUndefined();
    expect(data.escalations).toHaveLength(2);
    const ask = data.escalations[0];
    expect(ask.escalationId).toBe("a1");
    expect(ask.question).toBe("Which database should the migration target?");
    expect("nonBlocking" in ask).toBe(false);
    expect("unblocked" in ask).toBe(false);
    expect("askOptions" in ask).toBe(false);
    // The field this change deliberately did not touch: an ordinary quick-choice
    // row must come back sendable, not merely present.
    expect(data.escalations[1].choices).toEqual([
      { choiceId: "approve", label: "Approve", text: "ship it" },
      { choiceId: "reject", label: "Reject", text: "no" },
    ]);
  });
});

// The same cell one release later: a Store rollback puts a bridge that predates
// the lens in front of a record this one wrote. Derived from the live schema by
// removal, so it cannot drift away from what it claims to model.
describe("a record this bridge writes stays readable to one that predates the lens", () => {
  const priorRecord = HandlerSessionRecordSchema.omit({ role: true, brief: true });

  it("strips the lens and the brief and keeps the session armed rather than failing", () => {
    // No .strict() anywhere on this schema, so zod drops what the older shape does
    // not declare and the parse SUCCEEDS. The session survives under that bridge's
    // own default and loses only the lens, which it could not have printed anyway.
    const parsed = priorRecord.safeParse(record({
      role: "release", brief: "note the changelog",
    }));
    expect(parsed.success).toBe(true);
    const data = parsed.data as Record<string, unknown>;
    expect(data.goal).toBe("migrate the auth module");
    expect(data.backlog).toEqual([item("i1")]);
    expect("role" in data).toBe(false);
    expect("brief" in data).toBe(false);
  });
});


// The list replaced `goal` as the source of truth without a version bump, so the
// two halves that makes possible are what this covers: a record written before it
// existed still parses, and it comes back saying what the user asked for.
describe("the instruction list", () => {
  it("round-trips entries verbatim and in order", () => {
    const abDir = tmpAbDir();
    saveHandlerSession(abDir, "proj", record({
      instructions: [{ text: "ship the migration", at: 1 }, { text: "then open a PR", at: 2 }],
    }));
    expect(loadHandlerSession(abDir, "proj", "t1")?.instructions)
      .toEqual([{ text: "ship the migration", at: 1 }, { text: "then open a PR", at: 2 }]);
  });

  // A version-2 record written before the field existed. Refusing it would have
  // cost the session its backlog for a field the goal can seed, which is the whole
  // argument for not bumping `version` — see its note in session-store.ts.
  it("seeds one entry from the goal of a record that predates the field", () => {
    const abDir = tmpAbDir();
    writeRaw(abDir, "t1", JSON.stringify({
      version: 2, terminalId: "t1", armed: true, goal: "migrate the auth module",
      backlog: [item("i1")], armedAt: 123, escalations: [],
    }));
    const loaded = loadHandlerSession(abDir, "proj", "t1");
    expect(loaded?.instructions).toEqual([{ text: "migrate the auth module", at: 123 }]);
    expect(loaded?.backlog).toEqual([item("i1")]);
  });

  it("seeds nothing from an empty goal, so a one-tap arm stays one that asked nothing", () => {
    const abDir = tmpAbDir();
    writeRaw(abDir, "t1", JSON.stringify({
      version: 2, terminalId: "t1", armed: true, goal: "  ",
      backlog: [], armedAt: 123, escalations: [],
    }));
    expect(loadHandlerSession(abDir, "proj", "t1")?.instructions).toEqual([]);
  });

  // The seed only ever fills an empty list: a record carrying both is one this
  // build wrote, where `goal` is the mirror of the first entry and not a second
  // opinion about it.
  it("leaves a record that already carries entries alone", () => {
    const abDir = tmpAbDir();
    writeRaw(abDir, "t1", JSON.stringify({
      version: 2, terminalId: "t1", armed: true, goal: "the first one",
      instructions: [{ text: "the first one", at: 1 }, { text: "and then this", at: 2 }],
      backlog: [], armedAt: 123, escalations: [],
    }));
    expect(loadHandlerSession(abDir, "proj", "t1")?.instructions.map((i) => i.text))
      .toEqual(["the first one", "and then this"]);
  });

  it("refuses a record whose list is past the cap rather than silently keeping part of it", () => {
    const abDir = tmpAbDir();
    writeRaw(abDir, "t1", JSON.stringify({
      version: 2, terminalId: "t1", armed: true, goal: "g",
      instructions: Array.from({ length: MAX_INSTRUCTIONS + 1 }, (_, n) => ({ text: `i${n}`, at: n })),
      backlog: [], armedAt: 123, escalations: [],
    }));
    expect(loadHandlerSession(abDir, "proj", "t1")).toBeNull();
  });
});

describe("pushInstruction", () => {
  it("drops the oldest past the cap, the same end the prompt budget trims from", () => {
    const list = Array.from({ length: MAX_INSTRUCTIONS }, (_, n) => ({ text: `i${n}`, at: n }));
    pushInstruction(list, "newest", 999);
    expect(list).toHaveLength(MAX_INSTRUCTIONS);
    expect(list[0]!.text).toBe("i1");
    expect(list.at(-1)!.text).toBe("newest");
  });

  it("normalizes to the wire's own ceiling so an unbounded arm goal cannot write an unreadable record", () => {
    const abDir = tmpAbDir();
    const list: { text: string; at: number }[] = [];
    pushInstruction(list, normalizeInstruction(`  ${"x".repeat(MAX_INSTRUCTION_CHARS * 2)}  `), 1);
    expect(list[0]!.text).toHaveLength(MAX_INSTRUCTION_CHARS);
    saveHandlerSession(abDir, "proj", record({ instructions: list }));
    expect(loadHandlerSession(abDir, "proj", "t1")?.instructions).toEqual(list);
  });
});
