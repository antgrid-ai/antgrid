// bridge/tests/handler/session-store.test.ts
import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  loadHandlerSession, saveHandlerSession,
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
    notifyOnly: false, armedAt: 123, escalations: [],
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
      version: 1, terminalId: "t1", armed: true, notifyOnly: false, armedAt: 1,
      brief: { taskSummary: "x", willHandle: [], wakeFor: [], thenItems: [] },
      doneWhenMet: false, ledger: [], escalations: [],
    }));
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
