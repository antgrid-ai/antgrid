// bridge/tests/session-bus-task-store.test.ts
import { test, expect } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  ackOutbound,
  applyTransition,
  dueOutbox,
  emptyTasks,
  isLegalTransition,
  isTerminal,
  loadTasks,
  mintOutbound,
  mintTask,
  noteAttempt,
  noteRepair,
  recordArtifact,
  recordFinding,
  saveTasks,
  setHumanWait,
  taskCreatedAts,
  taskFor,
  tasksFor,
  tickExpiry,
  type InboundTransition,
  type TaskState,
  type TaskStoreState,
} from "../src/session-bus/task-store";
import { SESSION_BUS_RETRY_BACKOFF_MS, TASK_EXPIRY_MS } from "../src/session-bus/constants";
import { sessionBusSessionDir } from "../src/session-bus/store-fs";
import type { SessionMemberRef } from "../src/protocol";

const PEER: SessionMemberRef = { machineId: "m2", projectId: "p2", sessionId: "s2", machineLabel: "Laptop" };
const T0 = 1_000_000;

function lead(now = T0): { state: TaskStoreState; seq: number } {
  const { next, seq } = mintTask(emptyTasks(), {
    taskId: "t1",
    contextId: "c1",
    peer: PEER,
    title: "run the suite",
    now,
  });
  return { state: next, seq };
}

function assign(over: Partial<InboundTransition> = {}): InboundTransition {
  return {
    taskId: "t1",
    contextId: "c1",
    seq: 0,
    state: "submitted",
    peer: PEER,
    messageId: "m-0",
    summary: "run the suite",
    title: "run the suite",
    ...over,
  };
}

function inbound(seq: number, state: TaskState, over: Partial<InboundTransition> = {}): InboundTransition {
  return { ...assign(), seq, state, messageId: `m-${seq}`, summary: `now ${state}`, ...over };
}

/** A peer-side store holding one assigned task, i.e. after the assign landed. */
function peerSide(now = T0): TaskStoreState {
  const out = applyTransition(emptyTasks(), assign(), now);
  expect(out.kind).toBe("applied");
  return out.next;
}

/** Apply a transition that the test asserts elsewhere, keeping the fold going. */
function step(s: TaskStoreState, t: InboundTransition, now = T0): TaskStoreState {
  return applyTransition(s, t, now).next;
}

function tmpAbDir(): string {
  return mkdtempSync(join(tmpdir(), "ab-bus-"));
}

test("mintTask opens a lead-side task at seq 0 with a default expiry", () => {
  const { state, seq } = lead();
  const t = taskFor(state, "t1")!;
  expect(seq).toBe(0);
  expect(t.role).toBe("lead");
  expect(t.state).toBe("submitted");
  expect(t.nextSeq).toBe(1);
  expect(t.expiresAt).toBe(T0 + TASK_EXPIRY_MS);
  expect(tasksFor(state, "c1")).toHaveLength(1);
  expect(taskCreatedAts(state)).toEqual([T0]);
});

// `origin` is the one fact `role` cannot carry, because `role` is per machine
// and reverses across the wire. Get the reversal backwards and the raiser waits
// on itself while the lead is handed work it cannot report on.
test("a raise mints the opposite role on each machine, and both record who asked", () => {
  const raised = mintTask(emptyTasks(), {
    taskId: "t1",
    contextId: "c1",
    peer: PEER,
    title: "pin the relay's bun",
    now: T0,
    origin: "peer",
  });
  const mine = taskFor(raised.next, "t1")!;
  expect(mine.role).toBe("peer");
  expect(mine.origin).toBe("peer");

  const received = applyTransition(emptyTasks(), assign({ origin: "peer" }), T0);
  expect(received.kind).toBe("applied");
  const theirs = taskFor(received.next, "t1")!;
  expect(theirs.role).toBe("lead");
  expect(theirs.origin).toBe("peer");
});

// Every task written before a peer could raise one carries no `origin` at all,
// and must keep reading as the lead's.
test("a task with no origin is the lead's on both sides", () => {
  expect(taskFor(lead().state, "t1")!.origin).toBeUndefined();
  expect(taskFor(peerSide(), "t1")!.origin).toBeUndefined();
  expect(taskFor(peerSide(), "t1")!.role).toBe("peer");
});

test("every legal transition is applied and every illegal one is refused", () => {
  const states: TaskState[] = ["submitted", "working", "input-required", "completed", "failed", "canceled"];
  for (const from of states) {
    for (const to of states) {
      // Reach `from` using only legal moves, so the case under test is the only
      // questionable one in the fold.
      let s = peerSide();
      if (from === "working") {
        s = step(s, inbound(1, "working"));
      } else if (from === "input-required") {
        s = step(s, inbound(1, "working"));
        s = step(s, inbound(2, "input-required", { waitingOn: "lead" }));
      } else if (from === "completed") {
        // Through `working`, which is the path a peer that opened its task takes
        // — the direct one is legal too and is covered on its own below.
        s = step(s, inbound(1, "working"));
        s = step(s, inbound(2, "completed"));
      } else if (from !== "submitted") {
        s = step(s, inbound(1, from));
      }

      const seq = taskFor(s, "t1")!.appliedSeq + 1;
      const out = applyTransition(s, inbound(seq, to), T0 + 1);
      if (isTerminal(from)) {
        expect(out.kind).toBe("post-terminal");
        expect(taskFor(out.next, "t1")!.state).toBe(from);
      } else if (isLegalTransition(from, to)) {
        expect(out.kind).toBe("applied");
        expect(taskFor(out.next, "t1")!.state).toBe(to);
      } else {
        expect(out.kind).toBe("illegal");
        expect(taskFor(out.next, "t1")!.state).toBe(from);
      }
    }
  }
});

test("a duplicate seq is a no-op and leaves the state untouched (the caller still acks)", () => {
  const s = peerSide();
  const first = applyTransition(s, inbound(1, "working"), T0 + 5);
  expect(first.kind).toBe("applied");
  const again = applyTransition(first.next, inbound(1, "working"), T0 + 9);
  expect(again.kind).toBe("duplicate");
  expect(again.next).toBe(first.next);
  expect(taskFor(again.next, "t1")!.updatedAt).toBe(T0 + 5);
});

test("a stale seq below the applied one is dropped, and a gap is never applied", () => {
  let s = peerSide();
  s = step(s, inbound(1, "working"));
  s = step(s, inbound(2, "input-required", { waitingOn: "lead" }));

  expect(applyTransition(s, inbound(1, "working"), T0).kind).toBe("stale");
  const gap = applyTransition(s, inbound(9, "completed"), T0);
  expect(gap.kind).toBe("gap");
  expect(taskFor(gap.next, "t1")!.state).toBe("input-required");
});

test("a transition naming an unknown task is a gap, and only an assign opens one", () => {
  expect(applyTransition(emptyTasks(), inbound(3, "completed"), T0).kind).toBe("gap");
  expect(applyTransition(emptyTasks(), inbound(0, "working"), T0).kind).toBe("gap");
  const opened = applyTransition(emptyTasks(), assign(), T0);
  expect(opened.kind).toBe("applied");
  expect(taskFor(opened.next, "t1")!.role).toBe("peer");
});

test("a report after a terminal state becomes a finding, not a state change", () => {
  let s = peerSide();
  s = step(s, inbound(1, "canceled", { cancelReason: "lead said stop" }));
  const after = applyTransition(s, inbound(2, "completed", { summary: "undid the migration" }), T0 + 1);
  expect(after.kind).toBe("post-terminal");
  const t = taskFor(after.next, "t1")!;
  expect(t.state).toBe("canceled");
  expect(t.cancelReason).toBe("lead said stop");
  expect(t.findings.map((f) => f.summary)).toEqual(["undid the migration"]);
  // The seq still advanced, so a resend of that same report is a duplicate.
  expect(applyTransition(after.next, inbound(2, "completed"), T0 + 2).kind).toBe("duplicate");
});

test("stop-and-wait: a second outbound transition is blocked until the first is acked", () => {
  const { state } = lead();
  const first = mintOutbound(state, { taskId: "t1", frame: { a: 1 }, seq: 0, now: T0 });
  expect(first.kind).toBe("queued");
  if (first.kind !== "queued") return;

  expect(mintOutbound(first.next, { taskId: "t1", state: "working", frame: { a: 2 }, now: T0 })).toEqual({
    kind: "blocked",
    reason: "in-flight",
  });

  const acked = ackOutbound(first.next, "t1", 0);
  expect(taskFor(acked, "t1")!.outbox).toHaveLength(0);
  expect(taskFor(acked, "t1")!.ackedSeq).toBe(0);

  const third = mintOutbound(acked, { taskId: "t1", state: "working", frame: { a: 3 }, now: T0 });
  expect(third.kind).toBe("queued");
  if (third.kind === "queued") expect(third.seq).toBe(1);
});

test("an ack for a seq that is not in flight is ignored", () => {
  const { state } = lead();
  const queued = mintOutbound(state, { taskId: "t1", frame: {}, seq: 0, now: T0 });
  if (queued.kind !== "queued") throw new Error("expected queued");

  // Out of order: an ack for a seq never sent, then a repeat of one retired.
  const bogus = ackOutbound(queued.next, "t1", 7);
  expect(bogus).toBe(queued.next);
  expect(taskFor(bogus, "t1")!.ackedSeq).toBe(0);

  const acked = ackOutbound(queued.next, "t1", 0);
  expect(ackOutbound(acked, "t1", 0)).toBe(acked);
  expect(ackOutbound(acked, "nope", 0)).toBe(acked);
});

test("an illegal outbound transition is blocked before anything is queued", () => {
  const { state } = lead();
  const q = mintOutbound(state, { taskId: "t1", frame: {}, seq: 0, now: T0 });
  if (q.kind !== "queued") throw new Error("expected queued");
  const s = ackOutbound(q.next, "t1", 0);

  // A self-transition: the one move `submitted` still cannot make. The refusal
  // names both states, because the agent that reads it holds no tool that could
  // look up the one it is in.
  expect(mintOutbound(s, { taskId: "t1", state: "submitted", frame: {}, now: T0 })).toEqual({
    kind: "blocked",
    reason: "illegal",
    from: "submitted",
    to: "submitted",
  });
  expect(mintOutbound(s, { taskId: "missing", state: "working", frame: {}, now: T0 })).toEqual({
    kind: "blocked",
    reason: "unknown-task",
  });
});

// `working` is a notification, not a gate. Requiring it made `antgrid_open_task`
// load bearing for a peer that is never told to call it and holds no tool to see
// that it did not — so a peer that did the work and reported it finished was
// refused on a precondition it could neither learn nor observe.
test("a peer that never opened its task may still report it finished", () => {
  const s = peerSide();
  const done = applyTransition(s, inbound(1, "completed", { summary: "suite green" }), T0 + 1);
  expect(done.kind).toBe("applied");
  expect(taskFor(done.next, "t1")!.state).toBe("completed");

  const asked = applyTransition(peerSide(), inbound(1, "input-required", { waitingOn: "lead" }), T0 + 1);
  expect(asked.kind).toBe("applied");
  expect(taskFor(asked.next, "t1")!.waitingOn).toBe("lead");
});

// The report that ends a task is the payload the whole exchange existed to
// produce, and it used to be read and thrown away: the fold kept the state and
// none of the message, so `antgrid_get_task` answered "none reported" about the
// task it was simultaneously reporting complete.
test("the report that ends a task is kept on the record", () => {
  const s = peerSide();
  const done = applyTransition(
    s,
    inbound(1, "completed", {
      summary: "suite green",
      text: "424 pass, 0 fail. The flake was a shared temp dir.",
      unexpected: "The staging DSN in .env.example points at production.",
      artifactIds: ["a-1", "a-2"],
    }),
    T0 + 1,
  );
  if (done.kind !== "applied") throw new Error("expected applied");
  const r = taskFor(done.next, "t1")!.result!;
  expect(r.state).toBe("completed");
  expect(r.summary).toBe("suite green");
  expect(r.text).toContain("424 pass");
  expect(r.unexpected).toContain("points at production");
  expect(r.artifactIds).toEqual(["a-1", "a-2"]);
  // Not folded into `findings`: a finding is what turned up along the way, and a
  // completion listed among them reads as one more aside.
  expect(taskFor(done.next, "t1")!.findings).toEqual([]);
});

// A cancel's text is the LEAD's reason, which has its own field. Recording it as
// the peer's result would attribute the lead's words to the peer.
test("a cancel leaves no result behind, only its reason", () => {
  const s = peerSide();
  const out = applyTransition(s, inbound(1, "canceled", { cancelReason: "no longer needed" }), T0 + 1);
  if (out.kind !== "applied") throw new Error("expected applied");
  expect(taskFor(out.next, "t1")!.result).toBeUndefined();
  expect(taskFor(out.next, "t1")!.cancelReason).toBe("no longer needed");
});

// The surprise is the half of a report a lead most needs and the half nothing
// used to keep — it crossed the wire on the envelope and was dropped at every
// surface that could have shown it.
test("a post-terminal report keeps what its sender did not anticipate", () => {
  let s = peerSide();
  s = step(s, inbound(1, "canceled", { cancelReason: "stop" }));
  const late = applyTransition(
    s,
    inbound(2, "completed", { summary: "undid the migration", unexpected: "the rollback script is missing" }),
    T0 + 1,
  );
  if (late.kind !== "post-terminal") throw new Error("expected post-terminal");
  expect(taskFor(late.next, "t1")!.findings[0]!.unexpected).toBe("the rollback script is missing");
});

test("retry backoff climbs and then holds; there is no give-up", () => {
  const { state } = lead();
  const q = mintOutbound(state, { taskId: "t1", frame: {}, seq: 0, now: T0 });
  if (q.kind !== "queued") throw new Error("expected queued");
  let s = q.next;
  expect(dueOutbox(s, T0)).toEqual([]);
  expect(dueOutbox(s, T0 + SESSION_BUS_RETRY_BACKOFF_MS[0]!)).toHaveLength(1);

  for (let i = 1; i < SESSION_BUS_RETRY_BACKOFF_MS.length + 3; i += 1) {
    s = noteAttempt(s, "t1", 0, T0);
    const expected = SESSION_BUS_RETRY_BACKOFF_MS[Math.min(i, SESSION_BUS_RETRY_BACKOFF_MS.length - 1)]!;
    expect(taskFor(s, "t1")!.outbox[0]!.nextAttemptAt).toBe(T0 + expected);
  }
  // Still queued after every attempt: nothing here fails a task for an absence.
  expect(taskFor(s, "t1")!.outbox).toHaveLength(1);
  expect(taskFor(s, "t1")!.state).toBe("submitted");
});

test("expiry pauses while waiting on a human and resumes with the deadline pushed out", () => {
  let s = peerSide();
  s = step(s, inbound(1, "working"));
  const deadline = taskFor(s, "t1")!.expiresAt!;

  s = step(s, inbound(2, "input-required", { waitingOn: "human" }), T0 + 10);
  expect(taskFor(s, "t1")!.pausedAt).toBe(T0 + 10);

  // However long the human takes, the task does not lapse.
  const wayPast = deadline + TASK_EXPIRY_MS;
  expect(tickExpiry(s, wayPast).expired).toEqual([]);

  s = step(s, inbound(3, "working"), wayPast);
  const t = taskFor(s, "t1")!;
  expect(t.pausedAt).toBeUndefined();
  expect(t.waitingOn).toBeUndefined();
  expect(t.expiresAt).toBe(deadline + (wayPast - (T0 + 10)));
});

test("waiting on the LEAD does not pause the clock", () => {
  let s = peerSide();
  s = step(s, inbound(1, "working"));
  const deadline = taskFor(s, "t1")!.expiresAt!;
  s = step(s, inbound(2, "input-required", { waitingOn: "lead" }), T0 + 10);
  expect(taskFor(s, "t1")!.pausedAt).toBeUndefined();
  expect(tickExpiry(s, deadline + 1).expired.map((t) => t.taskId)).toEqual(["t1"]);
});

test("an outbound block on a human pauses the same clock the inbound path does", () => {
  const { state } = lead();
  const q = mintOutbound(state, { taskId: "t1", frame: {}, seq: 0, now: T0 });
  if (q.kind !== "queued") throw new Error("expected queued");
  let s = ackOutbound(q.next, "t1", 0);
  const deadline = taskFor(s, "t1")!.expiresAt!;

  const working = mintOutbound(s, { taskId: "t1", state: "working", frame: {}, now: T0 + 1 });
  if (working.kind !== "queued") throw new Error("expected queued");
  s = ackOutbound(working.next, "t1", working.seq);

  const blocked = mintOutbound(s, {
    taskId: "t1",
    state: "input-required",
    waitingOn: "human",
    frame: {},
    now: T0 + 10,
  });
  if (blocked.kind !== "queued") throw new Error("expected queued");
  expect(taskFor(blocked.next, "t1")!.pausedAt).toBe(T0 + 10);
  expect(tickExpiry(blocked.next, deadline + TASK_EXPIRY_MS).expired).toEqual([]);
});

test("tickExpiry marks rather than fabricates a state, and names each lapse once", () => {
  const { state } = lead();
  const past = T0 + TASK_EXPIRY_MS + 1;
  const first = tickExpiry(state, past);
  expect(first.expired).toHaveLength(1);
  expect(first.expired[0]!.state).toBe("submitted");
  expect(taskFor(first.next, "t1")!.expiredAt).toBe(past);

  const again = tickExpiry(first.next, past + 1_000);
  expect(again.expired).toEqual([]);
  expect(again.next).toBe(first.next);
});

test("a terminal task never expires", () => {
  let s = peerSide();
  s = step(s, inbound(1, "working"));
  s = step(s, inbound(2, "completed"));
  expect(taskFor(s, "t1")!.state).toBe("completed");
  expect(tickExpiry(s, T0 + TASK_EXPIRY_MS * 10).expired).toEqual([]);
});

test("exactly one repair round trip is allowed, and it is per task", () => {
  const { state } = lead();
  const once = noteRepair(state, "t1");
  expect(once).not.toBeNull();
  expect(taskFor(once!, "t1")!.repairs).toBe(1);
  expect(noteRepair(once!, "t1")).toBeNull();
  expect(noteRepair(state, "missing")).toBeNull();
});

test("findings and artifact handles accumulate, and an artifact is recorded once", () => {
  const { state } = lead();
  let s = recordFinding(state, "t1", { at: T0, messageId: "m-9", summary: "flaky on windows" });
  s = recordArtifact(s, "t1", "a1");
  s = recordArtifact(s, "t1", "a1");
  s = recordArtifact(s, "t1", "a2");
  const t = taskFor(s, "t1")!;
  expect(t.findings).toHaveLength(1);
  expect(t.artifactIds).toEqual(["a1", "a2"]);
});

test("retry state, findings and the frame itself survive a reload from disk", () => {
  const abDir = tmpAbDir();
  try {
    const { state } = lead();
    const q = mintOutbound(state, {
      taskId: "t1",
      frame: { type: "session-bus:assign", seq: 0 },
      seq: 0,
      now: T0,
    });
    if (q.kind !== "queued") throw new Error("expected queued");
    let s = noteAttempt(q.next, "t1", 0, T0 + 50);
    s = recordFinding(s, "t1", { at: T0, messageId: "m-1", summary: "kept" });
    saveTasks(abDir, "p1", "s1", s);

    const back = loadTasks(abDir, "p1", "s1");
    const t = taskFor(back, "t1")!;
    expect(t.outbox).toHaveLength(1);
    expect(t.outbox[0]!.attempts).toBe(2);
    expect(t.outbox[0]!.frame).toEqual({ type: "session-bus:assign", seq: 0 });
    expect(t.findings.map((f) => f.summary)).toEqual(["kept"]);
    expect(dueOutbox(back, t.outbox[0]!.nextAttemptAt).map((d) => d.taskId)).toEqual(["t1"]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a paused task reloads still paused, so a restart cannot lapse it", () => {
  const abDir = tmpAbDir();
  try {
    let s = peerSide();
    s = step(s, inbound(1, "working"));
    s = step(s, inbound(2, "input-required", { waitingOn: "human" }), T0 + 10);
    saveTasks(abDir, "p1", "s1", s);

    const back = loadTasks(abDir, "p1", "s1");
    expect(taskFor(back, "t1")!.pausedAt).toBe(T0 + 10);
    expect(tickExpiry(back, T0 + TASK_EXPIRY_MS * 4).expired).toEqual([]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a corrupt, truncated or wrong-version file loads as an empty store", () => {
  const abDir = tmpAbDir();
  try {
    const dir = sessionBusSessionDir(abDir, "p1", "s1");
    mkdirSync(dir, { recursive: true });
    const path = join(dir, "tasks.json");

    writeFileSync(path, "{not json at all");
    expect(loadTasks(abDir, "p1", "s1").tasks).toEqual([]);

    writeFileSync(path, JSON.stringify({ version: 1, guard: { exchanges: 0 }, tasks: [{ taskId: "t1" }] }));
    expect(loadTasks(abDir, "p1", "s1").tasks).toEqual([]);

    writeFileSync(path, JSON.stringify({ version: 99, guard: { exchanges: 0 }, tasks: [] }));
    expect(loadTasks(abDir, "p1", "s1").tasks).toEqual([]);

    expect(loadTasks(abDir, "p1", "never-written").tasks).toEqual([]);
  } finally {
    rmSync(abDir, { recursive: true, force: true });
  }
});

test("a human at this machine pauses the clock on the tasks this session is working", () => {
  let s = peerSide();
  s = step(s, inbound(1, "working"));
  const deadline = taskFor(s, "t1")!.expiresAt!;

  // The producer of `waiting-on: human` (spec 5.3). Without it every pause and
  // resume branch below is code no caller can reach.
  s = setHumanWait(s, true, T0 + 10);
  expect(taskFor(s, "t1")!.waitingOn).toBe("human");
  expect(taskFor(s, "t1")!.pausedAt).toBe(T0 + 10);
  expect(tickExpiry(s, deadline + TASK_EXPIRY_MS).expired).toEqual([]);

  const back = deadline + TASK_EXPIRY_MS;
  s = setHumanWait(s, false, back);
  const t = taskFor(s, "t1")!;
  expect(t.waitingOn).toBeUndefined();
  expect(t.pausedAt).toBeUndefined();
  expect(t.expiresAt).toBe(deadline + (back - (T0 + 10)));
});

test("a human blocking the LEAD does not stall the peer that is working", () => {
  // The lead's own agent sitting on a prompt says nothing about the machine
  // doing the work, and pausing there would hide a peer that really has stalled.
  const { state } = lead();
  expect(setHumanWait(state, true, T0 + 10)).toBe(state);
});

test("a human block never overwrites a task already waiting on its lead", () => {
  let s = peerSide();
  s = step(s, inbound(1, "working"));
  s = step(s, inbound(2, "input-required", { waitingOn: "lead" }), T0 + 5);
  // `answerPeer` routes on this field; clobbering it would leave the lead's
  // answer with no request to satisfy.
  expect(setHumanWait(s, true, T0 + 10)).toBe(s);
  expect(taskFor(s, "t1")!.waitingOn).toBe("lead");
});

test("clearing a human block twice is a no-op, and a terminal task is left alone", () => {
  let s = peerSide();
  s = setHumanWait(s, true, T0 + 10);
  const cleared = setHumanWait(s, false, T0 + 20);
  expect(setHumanWait(cleared, false, T0 + 30)).toBe(cleared);

  const working = step(cleared, inbound(1, "working"), T0 + 35);
  const done = step(working, inbound(2, "completed"), T0 + 40);
  expect(setHumanWait(done, true, T0 + 50)).toBe(done);
});
