// Turn-boundary delivery (spec 5.2). Two guarantees are load-bearing and both
// fail silently if broken: a line never lands mid-turn, and a line never
// vanishes — the wake for a completed task is the ONLY thing that tells a lead
// its peer finished, and D11 forbids inferring that from an absence.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  MAX_QUEUED_LINES,
  SessionBusDeliveryQueue,
  closedTurns,
  emptyDeliveries,
  enqueueLine,
  forgetSession,
  linesFor,
  loadDeliveries,
  removeLine,
  saveDeliveries,
  type QueuedLine,
} from "../src/session-bus/delivery-queue";
import { lineForEvent } from "../src/session-bus/deliver-event";
import { UNATTRIBUTED_TURN, turnOpenFor } from "../src/work-status";
import { renderAnswer, renderCancel, renderNote, renderRaised, renderTask, renderWake } from "../src/session-bus/delivery";
import { briefScope, saveBrief } from "../src/session-bus/brief-store";
import type { SessionBusEvent } from "../src/session-bus/coordinator";
import type { TaskRecord } from "../src/session-bus/task-store";
import type { BusEnvelope, BusPart, SessionMemberOf, SessionMemberRef } from "../src/protocol";

const dirs: string[] = [];
function tempDir(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "bus-queue-")));
  dirs.push(dir);
  return dir;
}

afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

const PROJECT = "p1";
const SESSION = "s1";

const LEAD: SessionMemberOf = {
  machineId: "m1",
  projectId: "pl",
  sessionId: "lead-1",
  sessionName: "lead session",
  role: "lead",
  joinedAt: 1,
  state: "active",
};

const PEER_REF: SessionMemberRef = {
  machineId: "m2",
  projectId: "pp",
  sessionId: "peer-1",
  sessionName: "peer session",
};

function envelope(over: Partial<BusEnvelope> = {}): BusEnvelope {
  const parts: BusPart[] = [{ kind: "text", text: "the body" }];
  return {
    messageId: "msg-1",
    taskId: "t-1",
    contextId: "ctx-1",
    parts,
    metadata: { peer: PEER_REF, summary: "a summary", timestamp: 10 },
    ...over,
  };
}

function task(over: Partial<TaskRecord> = {}): TaskRecord {
  return {
    taskId: "t-1",
    contextId: "ctx-1",
    role: "peer",
    peer: PEER_REF,
    state: "submitted",
    title: "a summary",
    appliedSeq: 0,
    nextSeq: 1,
    ackedSeq: 0,
    acked: false,
    outbox: [],
    findings: [],
    artifactIds: [],
    repairs: 0,
    createdAt: 1,
    updatedAt: 1,
    ...over,
  };
}

function line(over: Partial<QueuedLine> = {}): Omit<QueuedLine, "queuedAt"> {
  return { id: "l-1", sessionId: SESSION, kind: "task", text: "a line", ...over };
}

/** The queue plus the two things `ProjectCore` supplies it: the turn-open set
 *  from the work-status reduction, and a submit that reports whether the line
 *  actually went into a session. */
function harness(abDir: string, opts: { live?: boolean } = {}) {
  const openTurns = new Set<string>();
  const injected: QueuedLine[] = [];
  let live = opts.live !== false;
  const queue = new SessionBusDeliveryQueue({
    abDir,
    projectId: PROJECT,
    // The predicate ProjectCore hands the real queue, not a re-reading of the
    // same set: the unattributed key is what makes the two differ.
    isTurnOpen: (id) => turnOpenFor(openTurns, id),
    inject: (l) => {
      if (!live) return false;
      injected.push(l);
      return true;
    },
    now: () => 1_000,
  });
  return {
    queue,
    injected,
    openTurns,
    setLive(v: boolean) { live = v; },
  };
}

describe("the delivery queue folds", () => {
  test("a duplicate id is not queued twice", () => {
    const one = enqueueLine(emptyDeliveries(), { ...line(), queuedAt: 1 });
    const again = enqueueLine(one, { ...line(), queuedAt: 2 });
    expect(again).toBe(one);
    expect(again.lines).toHaveLength(1);
  });

  test("past the cap the oldest EVICTABLE goes, never an assignment", () => {
    let s = emptyDeliveries();
    s = enqueueLine(s, { ...line({ id: "assign", kind: "task" }), queuedAt: 0 });
    for (let i = 0; i < MAX_QUEUED_LINES; i += 1) {
      s = enqueueLine(s, { ...line({ id: `w-${i}`, kind: "wake" }), queuedAt: i + 1 });
    }
    expect(s.lines).toHaveLength(MAX_QUEUED_LINES);
    // The cap is one project's whole queue, so a chatty session's wakes reach it
    // first. Evicting by age alone would drop the assign at the head, and the
    // coordinator acked it before it ever got here — nothing retries it.
    expect(s.lines[0]!.id).toBe("assign");
    expect(s.lines.map((l) => l.id)).not.toContain("w-0");
  });

  test("with nothing evictable left the oldest goes anyway, rather than growing without bound", () => {
    let s = emptyDeliveries();
    for (let i = 0; i < MAX_QUEUED_LINES + 3; i += 1) {
      s = enqueueLine(s, { ...line({ id: `l-${i}`, kind: "task" }), queuedAt: i });
    }
    expect(s.lines).toHaveLength(MAX_QUEUED_LINES);
    expect(s.lines[0]!.id).toBe("l-3");
  });

  test("lines are read and removed per session", () => {
    let s = emptyDeliveries();
    s = enqueueLine(s, { ...line({ id: "a", sessionId: "s1" }), queuedAt: 1 });
    s = enqueueLine(s, { ...line({ id: "b", sessionId: "s2" }), queuedAt: 2 });
    expect(linesFor(s, "s1").map((l) => l.id)).toEqual(["a"]);
    expect(removeLine(s, "a").lines.map((l) => l.id)).toEqual(["b"]);
    expect(forgetSession(s, "s2").lines.map((l) => l.id)).toEqual(["a"]);
    // An unchanged fold returns the same object, so a caller can skip the write.
    expect(removeLine(s, "nope")).toBe(s);
  });

  test("closedTurns names only the sessions whose turn ended", () => {
    const prev = { activeTurns: new Set(["a", "b"]) };
    const next = { activeTurns: new Set(["b", "c"]) };
    expect(closedTurns(prev, next)).toEqual(["a"]);
  });

  test("the unattributed key survives the diff, because it is a boundary for every session", () => {
    // An agent that cannot attribute its turn-starts records them under the
    // empty-string key, and a falsy-filter here would drop the only edge those
    // agents ever produce. `ProjectCore.commitWork` turns it into a drainAll.
    const prev = { activeTurns: new Set([UNATTRIBUTED_TURN]) };
    const next = { activeTurns: new Set<string>() };
    expect(closedTurns(prev, next)).toEqual([UNATTRIBUTED_TURN]);
  });
});

describe("turn-boundary delivery", () => {
  test("a line queued while a turn is open waits, and goes in exactly once when it closes", () => {
    const h = harness(tempDir());
    h.openTurns.add(SESSION);
    h.queue.queue(line());
    expect(h.injected).toHaveLength(0);
    expect(h.queue.lines).toHaveLength(1);

    // The closing edge is what `ProjectCore.commitWork` drains on.
    h.openTurns.delete(SESSION);
    h.queue.drain(SESSION);
    expect(h.injected.map((l) => l.id)).toEqual(["l-1"]);
    expect(h.queue.lines).toHaveLength(0);

    // Every later boundary must be a no-op: a second copy of a wake reads as a
    // second completion.
    h.queue.drain(SESSION);
    h.queue.drainAll();
    expect(h.injected).toHaveLength(1);
  });

  test("a line waits while an UNATTRIBUTED turn is open, and the project-wide close releases it", () => {
    const h = harness(tempDir());
    // The agent is mid-turn; it just cannot say in which session. Delivering
    // here is the mid-turn arrival the queue exists to prevent.
    h.openTurns.add(UNATTRIBUTED_TURN);
    h.queue.queue(line());
    expect(h.injected).toHaveLength(0);

    h.openTurns.delete(UNATTRIBUTED_TURN);
    h.queue.drainAll();
    expect(h.injected.map((l) => l.id)).toEqual(["l-1"]);
  });

  test("an idle session is delivered to at once", () => {
    const h = harness(tempDir());
    h.queue.queue(line());
    expect(h.injected.map((l) => l.id)).toEqual(["l-1"]);
    expect(h.queue.lines).toHaveLength(0);
  });

  test("a line for a session with no live agent stays queued at the head", () => {
    const h = harness(tempDir(), { live: false });
    h.queue.queue(line({ id: "first" }));
    h.queue.queue(line({ id: "second" }));
    expect(h.injected).toHaveLength(0);
    expect(h.queue.lines.map((l) => l.id)).toEqual(["first", "second"]);

    // Order is kept rather than skipped ahead: delivering the second first would
    // hand the agent a result for work it was never told about. One per
    // boundary, because the line just delivered opened a turn this bridge only
    // hears about a round trip later.
    h.setLive(true);
    h.queue.drain(SESSION);
    expect(h.injected.map((l) => l.id)).toEqual(["first"]);
    h.queue.drain(SESSION);
    expect(h.injected.map((l) => l.id)).toEqual(["first", "second"]);
  });

  test("a submit that throws leaves the line queued rather than losing it", () => {
    const abDir = tempDir();
    const injected: QueuedLine[] = [];
    let throwing = true;
    const queue = new SessionBusDeliveryQueue({
      abDir,
      projectId: PROJECT,
      isTurnOpen: () => false,
      inject: (l) => {
        if (throwing) throw new Error("the adapter is gone");
        injected.push(l);
        return true;
      },
    });
    queue.queue(line());
    expect(queue.lines).toHaveLength(1);
    throwing = false;
    queue.drain(SESSION);
    expect(injected).toHaveLength(1);
    expect(queue.lines).toHaveLength(0);
  });

  test("the queue survives a reload, and its startup drain delivers what outlived the restart", () => {
    const abDir = tempDir();
    const first = harness(abDir, { live: false });
    first.queue.queue(line({ id: "held" }));
    expect(first.injected).toHaveLength(0);

    // A fresh queue over the same directory is what a restarted bridge builds.
    const second = harness(abDir);
    expect(second.queue.lines.map((l) => l.id)).toEqual(["held"]);
    second.queue.drainAll();
    expect(second.injected.map((l) => l.id)).toEqual(["held"]);

    // And the file is written back, so a third boot holds nothing.
    expect(loadDeliveries(abDir, PROJECT).lines).toHaveLength(0);
  });

  test("a persisted queue over the cap is trimmed on the way to disk", () => {
    const abDir = tempDir();
    let s = emptyDeliveries();
    for (let i = 0; i < MAX_QUEUED_LINES; i += 1) {
      s = enqueueLine(s, { ...line({ id: `l-${i}` }), queuedAt: i });
    }
    saveDeliveries(abDir, PROJECT, s);
    expect(loadDeliveries(abDir, PROJECT).lines).toHaveLength(MAX_QUEUED_LINES);
  });

  test("forget drops a deleted session's lines, which can never be delivered", () => {
    const h = harness(tempDir(), { live: false });
    h.queue.queue(line({ id: "a" }));
    h.queue.queue(line({ id: "b", sessionId: "other" }));
    h.queue.forget(SESSION);
    expect(h.queue.lines.map((l) => l.id)).toEqual(["b"]);
  });
});

describe("which events become a line, and what it says", () => {
  const deps = (abDir: string) => ({
    abDir,
    projectId: PROJECT,
    memberOf: (id: string) => (id === SESSION ? LEAD : undefined),
    now: () => 2_000,
  });

  test("an assign becomes the task template, keyed by the envelope's message id", () => {
    const abDir = tempDir();
    saveBrief(abDir, PROJECT, SESSION, { lead: LEAD, brief: "Owns: the codec.", now: 1 });
    const event: SessionBusEvent = {
      kind: "assigned",
      sessionId: SESSION,
      task: task(),
      envelope: envelope(),
    };
    const l = lineForEvent(event, deps(abDir));
    expect(l).toMatchObject({ id: "msg-1", sessionId: SESSION, kind: "task" });
    expect(l!.text).toBe(renderTask({
      lead: LEAD,
      taskId: "t-1",
      summary: "a summary",
      instruction: "the body",
      scope: briefScope(abDir, PROJECT, SESSION),
      artifacts: [],
    }));
  });

  // The other half of `assigned`, and the one with no `memberOf` behind it: a
  // lead has no membership row, so the peer-facing branch answers null for it and
  // the lead would be told nothing about a task it is now waiting on.
  test("a raise reaching the lead becomes the raised template, not the task one", () => {
    const abDir = tempDir();
    const event: SessionBusEvent = {
      kind: "assigned",
      sessionId: SESSION,
      task: task({ role: "lead", origin: "peer" }),
      envelope: envelope({ messageId: "msg-raised" }),
    };
    const l = lineForEvent(event, deps(abDir));
    expect(l).toMatchObject({ id: "msg-raised", sessionId: SESSION, kind: "raised" });
    expect(l!.text).toBe(renderRaised({
      peer: PEER_REF,
      taskId: "t-1",
      summary: "a summary",
      instruction: "the body",
      artifacts: [],
    }));
    // It must not read as an assignment: the peer is already working it.
    expect(l!.text).not.toContain("antgrid_report_complete");
    expect(l!.text).toContain("antgrid_cancel_task");
  });

  test("a completed task wakes its LEAD, rendered by renderWake", () => {
    const abDir = tempDir();
    const event: SessionBusEvent = {
      kind: "transitioned",
      sessionId: SESSION,
      task: task({ role: "lead", state: "completed" }),
      state: "completed",
      envelope: envelope({ messageId: "msg-done" }),
    };
    const l = lineForEvent(event, deps(abDir));
    expect(l).toMatchObject({ id: "msg-done", sessionId: SESSION, kind: "wake" });
    // The envelope's text part rides along: the summary is a title, and the card
    // is the only place the lead reads the result while it can still act on it.
    expect(l!.text).toBe(renderWake({
      peer: PEER_REF,
      taskId: "t-1",
      state: "completed",
      summary: "a summary",
      result: "the body",
    }));
    expect(l!.text).toContain("the body");
  });

  // A lead that withdrew a task has no reason to re-read it, and the peer has no
  // transition left to ride: without this line its answer to the cancellation
  // exists only as a row on a record nobody opens again.
  test("a finding on a task that is already over reaches the lead as a note", () => {
    const abDir = tempDir();
    for (const state of ["canceled", "completed", "failed"] as const) {
      const event: SessionBusEvent = {
        kind: "message",
        sessionId: SESSION,
        taskId: "t-1",
        task: task({ role: "lead", state }),
        peer: PEER_REF,
        envelope: envelope({ messageId: `msg-${state}` }),
      };
      const l = lineForEvent(event, deps(abDir));
      expect(l).toMatchObject({ id: `msg-${state}`, sessionId: SESSION, kind: "note" });
      expect(l!.text).toBe(renderNote({
        peer: PEER_REF,
        taskId: "t-1",
        state,
        summary: "a summary",
        text: "the body",
        artifacts: [],
      }));
    }
  });

  // The rule the note is an exception to, asserted so the exception stays one: a
  // finding on live work is recorded and read, never delivered (5.2).
  test("a finding on a task still running is delivered to nobody", () => {
    const abDir = tempDir();
    for (const state of ["submitted", "working", "input-required"] as const) {
      const event: SessionBusEvent = {
        kind: "message",
        sessionId: SESSION,
        taskId: "t-1",
        task: task({ role: "lead", state }),
        peer: PEER_REF,
        envelope: envelope(),
      };
      expect(lineForEvent(event, deps(abDir))).toBeNull();
    }
  });

  // Nothing on this side can produce one any more — `reportFinding` refuses a
  // finding with no taskId and names `antgrid_raise_task` instead — but the
  // receive side is what a bridge on an older build still sends at, and a line
  // with no task is one nothing can render, list or answer.
  test("a finding naming no task stays undelivered even when it is the only channel left", () => {
    const abDir = tempDir();
    const event: SessionBusEvent = {
      kind: "message",
      sessionId: SESSION,
      taskId: null,
      peer: PEER_REF,
      envelope: envelope({ taskId: null }),
    };
    expect(lineForEvent(event, deps(abDir))).toBeNull();
  });

  // The peer's own side of a closed task: it was already told to stop by its
  // cancel line, and the lead has no verb that would send it a note to mirror.
  test("a note is a lead-side line only", () => {
    const abDir = tempDir();
    const event: SessionBusEvent = {
      kind: "message",
      sessionId: SESSION,
      taskId: "t-1",
      task: task({ role: "peer", state: "canceled" }),
      peer: PEER_REF,
      envelope: envelope(),
    };
    expect(lineForEvent(event, deps(abDir))).toBeNull();
  });

  test("a failed and an input-required task both wake the lead; working does not", () => {
    const abDir = tempDir();
    for (const state of ["failed", "input-required"] as const) {
      const l = lineForEvent({
        kind: "transitioned",
        sessionId: SESSION,
        task: task({ role: "lead", state }),
        state,
        envelope: envelope(),
      }, deps(abDir));
      expect(l?.kind).toBe("wake");
    }
    // Progress the lead already assumed: waking for it costs a turn and says
    // nothing.
    const working = lineForEvent({
      kind: "transitioned",
      sessionId: SESSION,
      task: task({ role: "lead", state: "working" }),
      state: "working",
      envelope: envelope(),
    }, deps(abDir));
    expect(working).toBeNull();
  });

  test("a peer's task returning to working is the lead's answer, and says the question is gone when it is", () => {
    const abDir = tempDir();
    const l = lineForEvent({
      kind: "transitioned",
      sessionId: SESSION,
      task: task({ role: "peer", state: "working" }),
      state: "working",
      envelope: envelope({ parts: [{ kind: "text", text: "development" }] }),
    }, deps(abDir));
    expect(l).toMatchObject({ kind: "answer", sessionId: SESSION });
    expect(l!.text).toBe(renderAnswer({
      lead: LEAD,
      taskId: "t-1",
      question: "(the question this session asked is no longer on record)",
      answer: "development",
      scope: [],
    }));
  });

  test("a cancel reaches the side working the task and nobody else", () => {
    const abDir = tempDir();
    const canceled = lineForEvent({
      kind: "canceled",
      sessionId: SESSION,
      task: task({ role: "peer", state: "canceled" }),
      reason: "no longer needed",
    }, deps(abDir));
    expect(canceled).toMatchObject({ id: "t-1:canceled", kind: "cancel" });
    expect(canceled!.text).toBe(renderCancel({ lead: LEAD, taskId: "t-1", reason: "no longer needed" }));

    // The lead asked for the cancel; its own tool call already answered it.
    const asLead = lineForEvent({
      kind: "canceled",
      sessionId: SESSION,
      task: task({ role: "lead", state: "canceled" }),
      reason: "no longer needed",
    }, deps(abDir));
    expect(asLead).toBeNull();
  });

  test("a finding and an expiry interrupt nobody — they are read off the task", () => {
    const abDir = tempDir();
    expect(lineForEvent({
      kind: "message",
      sessionId: SESSION,
      taskId: "t-1",
      peer: PEER_REF,
      envelope: envelope(),
    }, deps(abDir))).toBeNull();
    expect(lineForEvent({
      kind: "expired",
      sessionId: SESSION,
      task: task(),
    }, deps(abDir))).toBeNull();
  });

  test("a session with no membership row is delivered nothing: every template names its lead", () => {
    const abDir = tempDir();
    const l = lineForEvent({
      kind: "assigned",
      sessionId: "not-a-member",
      task: task(),
      envelope: envelope(),
    }, deps(abDir));
    expect(l).toBeNull();
  });

  test("a rendered wake reaches the adapter through the queue", () => {
    const abDir = tempDir();
    const h = harness(abDir);
    h.openTurns.add(SESSION);
    const l = lineForEvent({
      kind: "transitioned",
      sessionId: SESSION,
      task: task({ role: "lead", state: "completed" }),
      state: "completed",
      envelope: envelope({ messageId: "msg-wake" }),
    }, deps(abDir))!;
    h.queue.queue(l);
    expect(h.injected).toHaveLength(0);

    h.openTurns.delete(SESSION);
    h.queue.drain(SESSION);
    expect(h.injected).toHaveLength(1);
    expect(h.injected[0]!.text).toBe(renderWake({
      peer: PEER_REF,
      taskId: "t-1",
      state: "completed",
      summary: "a summary",
      result: "the body",
    }));
  });
});
