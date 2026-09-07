// bridge/tests/handler/session-store.test.ts
import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import {
  loadHandlerSession, saveHandlerSession,
  OpenEscalationSchema, HandlerSessionRecordSchema,
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
      parkKind: "limit", parkedUntil: 1770000000000,
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
