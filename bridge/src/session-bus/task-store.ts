// Spec 3.2's task lifecycle and D13's idempotency rules, as a pure fold plus a
// thin persisted wrapper. `now` is a parameter everywhere and nothing here
// touches a transport, so every rule below is testable with no filesystem and no
// socket — which is the point, because these are the rules a lost frame
// exercises and a lost frame is hard to stage.
//
// THE ACK MEANS "THIS SEQ WILL NEVER CHANGE MY STATE AGAIN", NOT "I LIKED IT".
// Every outcome below is acked by the caller — applied, duplicate, stale, gap,
// illegal, post-terminal — because a lost ack is the common cause of a resend
// and declining to re-ack wedges the sender forever.

import { join } from "node:path";
import { z } from "zod";
import { logger } from "../logger";
import {
  SessionMemberRefSchema,
  TaskStateSchema,
  WaitingOnSchema,
  type SessionMemberRef,
  type TaskState,
  type WaitingOn,
} from "../protocol";
import {
  MAX_FINDINGS,
  MAX_FINDING_CHARS,
  MAX_OUTBOX,
  MAX_SUMMARY_CHARS,
  MAX_TASKS_PERSISTED,
  MAX_TASK_ARTIFACTS,
  SESSION_BUS_RETRY_BACKOFF_MS,
  TASK_EXPIRY_MS,
} from "./constants";
import { GuardStateSchema, emptyGuard, noteProgress, type GuardState } from "./task-guard";
import { readStoreFile, sessionBusSessionDir, writeStoreFile } from "./store-fs";

const log = logger.child({ component: "session-bus" });

export const TASK_STORE_VERSION = 1;

// The lifecycle enums are declared in protocol.ts, where the wire that carries
// them is declared, and re-exported here so the fold below and its callers name
// the states through the store that enforces them.
export { TaskStateSchema, WaitingOnSchema, type TaskState, type WaitingOn };

const TERMINAL_STATES: readonly TaskState[] = ["completed", "failed", "canceled"];

/** Spec 3.2, verbatim. The three terminal states go nowhere: a report that
 *  arrives after one is a finding, not a state change (see `post-terminal`). */
const LEGAL_TRANSITIONS: Record<TaskState, readonly TaskState[]> = {
  submitted: ["working", "failed", "canceled"],
  working: ["input-required", "completed", "failed", "canceled"],
  "input-required": ["working", "failed", "canceled"],
  completed: [],
  failed: [],
  canceled: [],
};

export function isTerminal(state: TaskState): boolean {
  return TERMINAL_STATES.includes(state);
}

export function isLegalTransition(from: TaskState, to: TaskState): boolean {
  return LEGAL_TRANSITIONS[from].includes(to);
}

export const TaskFindingSchema = z.object({
  at: z.number().int().nonnegative(),
  messageId: z.string().min(1).max(200),
  summary: z.string().min(1).max(MAX_SUMMARY_CHARS),
  text: z.string().max(MAX_FINDING_CHARS).optional(),
});
export type TaskFinding = z.infer<typeof TaskFindingSchema>;

/** One transition still waiting for its ack, with its retry bookkeeping.
 *  Persisted with the task so a restart RESUMES retrying rather than dropping a
 *  completed task's report on the floor. */
export const OutboxEntrySchema = z.object({
  seq: z.number().int().nonnegative(),
  /** The serialized `session-bus:*` frame, opaque here on purpose: the store
   *  knows about sequencing and never about the wire. */
  frame: z.unknown(),
  attempts: z.number().int().nonnegative(),
  nextAttemptAt: z.number().int().nonnegative(),
  firstSentAt: z.number().int().nonnegative(),
});
export type OutboxEntry = z.infer<typeof OutboxEntrySchema>;

export const TaskRecordSchema = z.object({
  taskId: z.string().min(1).max(200),
  contextId: z.string().min(1).max(200),
  /** THIS bridge's role on THIS task. A machine can lead one task and work
   *  another, so role is per task and never per session. */
  role: z.enum(["lead", "peer"]),
  /** The other end, labels included so a row renders on a machine that can never
   *  reach the one it names (D7). */
  peer: SessionMemberRefSchema,
  state: TaskStateSchema,
  waitingOn: WaitingOnSchema.optional(),
  title: z.string().max(MAX_SUMMARY_CHARS),
  /** Highest INBOUND seq applied. */
  appliedSeq: z.number().int().nonnegative(),
  /** Next OUTBOUND seq to mint. */
  nextSeq: z.number().int().nonnegative(),
  /** Highest outbound seq the other end acked. */
  ackedSeq: z.number().int().nonnegative(),
  outbox: z.array(OutboxEntrySchema).max(MAX_OUTBOX).default([]),
  findings: z.array(TaskFindingSchema).max(MAX_FINDINGS).default([]),
  artifactIds: z.array(z.string().max(200)).max(MAX_TASK_ARTIFACTS).default([]),
  /** Malformed results repaired so far, capped at one round trip (spec 6.2).
   *  Persisted on the TASK so a restart cannot reset it into a repair loop. */
  repairs: z.number().int().min(0).max(1).default(0),
  createdAt: z.number(),
  updatedAt: z.number(),
  expiresAt: z.number().optional(),
  /** When the expiry clock stopped, set while `waitingOn === "human"`. */
  pausedAt: z.number().optional(),
  /** Set once by {@link tickExpiry}. A lapse is a defined outcome the lead must
   *  see (spec 5.3) but NOT a state change: D11 forbids inferring failure from
   *  an absence, so an expired task stays exactly the state it reached. */
  expiredAt: z.number().optional(),
  canceledAt: z.number().optional(),
  cancelReason: z.string().max(500).optional(),
});
export type TaskRecord = z.infer<typeof TaskRecordSchema>;

export const TaskFileSchema = z.object({
  // A bump makes every existing record unreadable, so a new field is added
  // optional-with-`.catch(undefined)` instead. This literal is the guard.
  version: z.literal(TASK_STORE_VERSION),
  /** The runaway guard's state, a sibling of the array it bounds: it lives and
   *  dies with the store it counts, and is written by the same atomic flush. */
  guard: GuardStateSchema,
  tasks: z.array(TaskRecordSchema).max(MAX_TASKS_PERSISTED),
});

export interface TaskStoreState {
  readonly guard: GuardState;
  readonly tasks: readonly TaskRecord[];
}

export function emptyTasks(): TaskStoreState {
  return { guard: emptyGuard(), tasks: [] };
}

export function taskFor(s: TaskStoreState, taskId: string): TaskRecord | null {
  return s.tasks.find((t) => t.taskId === taskId) ?? null;
}

export function tasksFor(s: TaskStoreState, contextId: string): TaskRecord[] {
  return s.tasks.filter((t) => t.contextId === contextId);
}

/** Every task's `createdAt`, which is what the runaway guard counts. Derived
 *  from the records rather than kept as a counter, so a restart cannot forget a
 *  runaway into existence. */
export function taskCreatedAts(s: TaskStoreState): number[] {
  return s.tasks.map((t) => t.createdAt);
}

function replace(s: TaskStoreState, next: TaskRecord): TaskStoreState {
  return { guard: s.guard, tasks: s.tasks.map((t) => (t.taskId === next.taskId ? next : t)) };
}

function appendFinding(rec: TaskRecord, f: TaskFinding): TaskRecord {
  const findings = [...rec.findings, f];
  return {
    ...rec,
    findings: findings.length > MAX_FINDINGS ? findings.slice(findings.length - MAX_FINDINGS) : findings,
    updatedAt: Math.max(rec.updatedAt, f.at),
  };
}

/**
 * Move the expiry clock in step with `waiting-on`.
 *
 * Entering `waiting-on: human` stops it; leaving pushes `expiresAt` out by the
 * time it was stopped. A task blocked on a human therefore never expires however
 * long the human takes — spec 5.3's rule, and the reason this is one helper
 * shared by the inbound and outbound paths: a task whose clock paused in only
 * one direction would lapse for the human's latency in the other.
 */
function applyWaitingClock(rec: TaskRecord, waitingOn: WaitingOn | undefined, now: number): TaskRecord {
  const wasHuman = rec.waitingOn === "human";
  const isHuman = waitingOn === "human";
  if (isHuman && !wasHuman) return { ...rec, waitingOn, pausedAt: now };
  if (!isHuman && wasHuman) {
    const paused = rec.pausedAt === undefined ? 0 : Math.max(0, now - rec.pausedAt);
    const next: TaskRecord = {
      ...rec,
      waitingOn,
      expiresAt: rec.expiresAt === undefined ? undefined : rec.expiresAt + paused,
    };
    delete next.pausedAt;
    if (waitingOn === undefined) delete next.waitingOn;
    return next;
  }
  const next: TaskRecord = { ...rec, waitingOn };
  if (waitingOn === undefined) delete next.waitingOn;
  return next;
}

/**
 * Report whether a human at THIS machine is what the session's work waits on.
 *
 * The producer of `waiting-on: human`. Spec 5.3 pauses a task's expiry clock for
 * human latency, and the only human a bridge can observe is its own: a peer
 * sitting on a permission prompt is the case that would otherwise lapse a task
 * nobody abandoned.
 *
 * Bounded to the tasks this session is WORKING (`role: "peer"`): a human blocking
 * the lead does not stall the peer, whose clock keeps running because the work
 * keeps running. A task already waiting on its lead keeps that cause — the lead's
 * answer is what unblocks it, and overwriting `waitingOn` would lose the record
 * of what the answer is for.
 */
export function setHumanWait(s: TaskStoreState, blocked: boolean, now: number): TaskStoreState {
  let changed = false;
  const tasks = s.tasks.map((t) => {
    if (t.role !== "peer" || isTerminal(t.state) || t.expiredAt !== undefined) return t;
    if (blocked ? t.waitingOn !== undefined : t.waitingOn !== "human") return t;
    changed = true;
    return applyWaitingClock(t, blocked ? "human" : undefined, now);
  });
  return changed ? { guard: s.guard, tasks } : s;
}

export interface MintTaskInput {
  taskId: string;
  contextId: string;
  peer: SessionMemberRef;
  title: string;
  now: number;
  expiresAt?: number;
}

/**
 * Open a task this bridge LEADS, before its assign frame exists.
 *
 * Returns the seq the assign must carry. Minting and queueing are two steps
 * because the frame is built FROM the seq: the caller mints, renders the frame,
 * then calls {@link mintOutbound} with that seq to put it in the outbox.
 */
export function mintTask(s: TaskStoreState, input: MintTaskInput): { next: TaskStoreState; seq: number } {
  const rec: TaskRecord = {
    taskId: input.taskId,
    contextId: input.contextId,
    role: "lead",
    peer: input.peer,
    state: "submitted",
    title: input.title.slice(0, MAX_SUMMARY_CHARS),
    appliedSeq: 0,
    nextSeq: 1,
    ackedSeq: 0,
    outbox: [],
    findings: [],
    artifactIds: [],
    repairs: 0,
    createdAt: input.now,
    updatedAt: input.now,
    expiresAt: input.expiresAt ?? input.now + TASK_EXPIRY_MS,
  };
  return { next: { guard: s.guard, tasks: [...s.tasks, rec] }, seq: 0 };
}

export type OutboundOutcome =
  | { kind: "queued"; next: TaskStoreState; seq: number; task: TaskRecord }
  | { kind: "blocked"; reason: "unknown-task" | "in-flight" | "illegal" | "outbox-full" };

export interface OutboundTransition {
  taskId: string;
  /** The state this bridge is reporting. Omitted for the assign itself, whose
   *  state is already the record's `submitted`. */
  state?: TaskState;
  waitingOn?: WaitingOn;
  /** The serialized frame to retry until acked. */
  frame: unknown;
  /** The seq minted alongside the record, for the assign. Absent mints the next
   *  one. */
  seq?: number;
  now: number;
  cancelReason?: string;
}

/**
 * Record this bridge's own transition and queue its frame for retry.
 *
 * STOP-AND-WAIT (D13): `nextSeq` does not advance while the outbox holds an
 * unacked frame, so at most one transition per task is ever in flight and the
 * receiver's `appliedSeq + 1` check can never see a legitimate gap. A caller
 * blocked `in-flight` holds its transition and retries after the ack; it must
 * NOT mint a second seq, because two in flight is exactly the case that makes a
 * duplicate indistinguishable from a reorder.
 */
export function mintOutbound(s: TaskStoreState, t: OutboundTransition): OutboundOutcome {
  const rec = taskFor(s, t.taskId);
  if (!rec) return { kind: "blocked", reason: "unknown-task" };
  if (t.state !== undefined && !isLegalTransition(rec.state, t.state)) {
    return { kind: "blocked", reason: "illegal" };
  }
  const reusing = t.seq !== undefined;
  if (!reusing && rec.outbox.length > 0) return { kind: "blocked", reason: "in-flight" };
  if (rec.outbox.length >= MAX_OUTBOX) return { kind: "blocked", reason: "outbox-full" };

  const seq = t.seq ?? rec.nextSeq;
  const entry: OutboxEntry = {
    seq,
    frame: t.frame,
    attempts: 1,
    nextAttemptAt: t.now + SESSION_BUS_RETRY_BACKOFF_MS[0]!,
    firstSentAt: t.now,
  };
  let next: TaskRecord = {
    ...rec,
    nextSeq: Math.max(rec.nextSeq, seq + 1),
    outbox: [...rec.outbox, entry],
    updatedAt: t.now,
  };
  if (t.state !== undefined) {
    next = applyWaitingClock(
      { ...next, state: t.state },
      t.state === "input-required" ? t.waitingOn : undefined,
      t.now,
    );
    if (t.state === "canceled") {
      next = {
        ...next,
        canceledAt: t.now,
        ...(t.cancelReason ? { cancelReason: t.cancelReason.slice(0, 500) } : {}),
      };
    }
  }
  return {
    kind: "queued",
    next: {
      guard: t.state === undefined ? s.guard : noteProgress(s.guard),
      tasks: s.tasks.map((x) => (x.taskId === next.taskId ? next : x)),
    },
    seq,
    task: next,
  };
}

export interface InboundTransition {
  taskId: string;
  contextId: string;
  seq: number;
  state: TaskState;
  waitingOn?: WaitingOn;
  /** The sending session, as the receiving bridge stamped it. */
  peer: SessionMemberRef;
  /** The envelope that carried it — the finding a post-terminal report becomes
   *  is keyed by this. */
  messageId: string;
  summary: string;
  text?: string;
  /** Assign only: the task's title and the lead's expiry. */
  title?: string;
  expiresAt?: number;
  cancelReason?: string;
}

export type TransitionOutcome =
  | { kind: "applied"; next: TaskStoreState; task: TaskRecord }
  | { kind: "duplicate"; next: TaskStoreState }
  | { kind: "stale"; next: TaskStoreState }
  | { kind: "gap"; next: TaskStoreState }
  | { kind: "illegal"; next: TaskStoreState }
  | { kind: "post-terminal"; next: TaskStoreState; task: TaskRecord };

/**
 * Fold one inbound transition. EVERY outcome is acked by the caller.
 *
 * - `seq <= appliedSeq` is a duplicate or a stale resend. No state change; the
 *   ack still goes, because a lost ack is why it arrived twice.
 * - `seq > appliedSeq + 1` is a gap. Unreachable under stop-and-wait, so it
 *   means a buggy or forged sender: a no-op that still acks, because applying it
 *   would push the task into a state its own history never passed through.
 * - a transition on a TERMINAL task is recorded as a finding, not a state
 *   change. That IS spec 3.2's cancel rule — the peer's "here is what I undid"
 *   report landing on the task it was told to stop.
 * - an illegal transition between two live states is a no-op that still acks: it
 *   can never be applied, so re-acking is the only thing that unwedges a sender
 *   which keeps trying.
 */
export function applyTransition(s: TaskStoreState, t: InboundTransition, now: number): TransitionOutcome {
  const rec = taskFor(s, t.taskId);

  if (!rec) {
    // Only an assign opens a task on the receiving side, and only as its first
    // frame. Anything else naming a task this bridge has never seen has the same
    // shape as a gap: acked, so the sender stops, and applied to nothing.
    if (t.state !== "submitted" || t.seq !== 0) {
      log.warn(
        { taskId: t.taskId, seq: t.seq, state: t.state },
        "session-bus: transition for an unknown task; acked and dropped",
      );
      return { kind: "gap", next: s };
    }
    const created: TaskRecord = {
      taskId: t.taskId,
      contextId: t.contextId,
      role: "peer",
      peer: t.peer,
      state: "submitted",
      title: (t.title ?? t.summary).slice(0, MAX_SUMMARY_CHARS),
      appliedSeq: t.seq,
      // One past the assign, not zero: the receiver's fold treats an inbound seq
      // equal to its `appliedSeq` as a duplicate, and a lead sitting at 0 would
      // read the peer's very first report as one.
      nextSeq: t.seq + 1,
      ackedSeq: 0,
      outbox: [],
      findings: [],
      artifactIds: [],
      repairs: 0,
      createdAt: now,
      updatedAt: now,
      expiresAt: t.expiresAt ?? now + TASK_EXPIRY_MS,
    };
    return {
      kind: "applied",
      next: { guard: noteProgress(s.guard), tasks: [...s.tasks, created] },
      task: created,
    };
  }

  if (t.seq < rec.appliedSeq) return { kind: "stale", next: s };
  if (t.seq === rec.appliedSeq) return { kind: "duplicate", next: s };
  if (t.seq > rec.appliedSeq + 1) {
    log.warn(
      { taskId: t.taskId, seq: t.seq, appliedSeq: rec.appliedSeq },
      "session-bus: transition seq gap; acked and dropped",
    );
    return { kind: "gap", next: s };
  }

  if (isTerminal(rec.state)) {
    const finding: TaskFinding = {
      at: now,
      messageId: t.messageId,
      summary: t.summary.slice(0, MAX_SUMMARY_CHARS),
      ...(t.text ? { text: t.text.slice(0, MAX_FINDING_CHARS) } : {}),
    };
    const task = { ...appendFinding(rec, finding), appliedSeq: t.seq };
    return { kind: "post-terminal", next: replace(s, task), task };
  }

  if (!isLegalTransition(rec.state, t.state)) {
    log.warn(
      { taskId: t.taskId, from: rec.state, to: t.state },
      "session-bus: illegal transition; acked and dropped",
    );
    return { kind: "illegal", next: s };
  }

  let task: TaskRecord = { ...rec, state: t.state, appliedSeq: t.seq, updatedAt: now };
  task = applyWaitingClock(task, t.state === "input-required" ? t.waitingOn : undefined, now);
  if (t.state === "canceled") {
    task = {
      ...task,
      canceledAt: now,
      ...(t.cancelReason ? { cancelReason: t.cancelReason.slice(0, 500) } : {}),
    };
  }
  return {
    kind: "applied",
    next: { guard: noteProgress(s.guard), tasks: s.tasks.map((x) => (x.taskId === task.taskId ? task : x)) },
    task,
  };
}

/** Retire an outbound frame the other end acknowledged. An ack for a seq that is
 *  not in the outbox — reordered, duplicated, or for a frame already retired —
 *  is ignored: `ackedSeq` may only advance for something this bridge actually
 *  sent and still holds. */
export function ackOutbound(s: TaskStoreState, taskId: string, seq: number): TaskStoreState {
  const rec = taskFor(s, taskId);
  if (!rec) return s;
  if (!rec.outbox.some((e) => e.seq === seq)) return s;
  const next: TaskRecord = {
    ...rec,
    outbox: rec.outbox.filter((e) => e.seq !== seq),
    ackedSeq: Math.max(rec.ackedSeq, seq),
  };
  return replace(s, next);
}

/** Frames whose next attempt is due. The caller suspends draining entirely while
 *  there is no carrier (D11: an absent carrier is not a failed task) and resumes
 *  on the next owner connect or inbound frame. */
export function dueOutbox(s: TaskStoreState, now: number): { taskId: string; entry: OutboxEntry }[] {
  const due: { taskId: string; entry: OutboxEntry }[] = [];
  for (const t of s.tasks) {
    for (const entry of t.outbox) {
      if (entry.nextAttemptAt <= now) due.push({ taskId: t.taskId, entry });
    }
  }
  return due;
}

/**
 * Put a queued entry back on the clock because the attempt `mintOutbound`
 * presumed never actually happened.
 *
 * Minting schedules the NEXT try on the contract that the caller makes the
 * first one; a caller whose carrier was absent has to say so, or the frame sits
 * out a backoff step for a link that was never touched (D11).
 */
export function holdOutbound(s: TaskStoreState, taskId: string, seq: number, now: number): TaskStoreState {
  const rec = taskFor(s, taskId);
  if (!rec) return s;
  if (!rec.outbox.some((e) => e.seq === seq)) return s;
  return replace(s, {
    ...rec,
    outbox: rec.outbox.map((e) => (e.seq === seq ? { ...e, nextAttemptAt: now } : e)),
  });
}

/** Record that a retry went out, and schedule the next. The backoff is held at
 *  its last step forever: there is no give-up-to-failed, because a peer offline
 *  for an hour has not failed the task (D11). The stall reaches the human through
 *  the progress check and request expiry instead. */
export function noteAttempt(s: TaskStoreState, taskId: string, seq: number, now: number): TaskStoreState {
  const rec = taskFor(s, taskId);
  if (!rec) return s;
  if (!rec.outbox.some((e) => e.seq === seq)) return s;
  const outbox = rec.outbox.map((e) => {
    if (e.seq !== seq) return e;
    const step = Math.min(e.attempts, SESSION_BUS_RETRY_BACKOFF_MS.length - 1);
    return { ...e, attempts: e.attempts + 1, nextAttemptAt: now + SESSION_BUS_RETRY_BACKOFF_MS[step]! };
  });
  return replace(s, { ...rec, outbox });
}

export function recordFinding(s: TaskStoreState, taskId: string, f: TaskFinding): TaskStoreState {
  const rec = taskFor(s, taskId);
  if (!rec) return s;
  return replace(s, appendFinding(rec, f));
}

/** Attach a published artifact to a task, so a task view renders the handles
 *  without a second lookup. */
export function recordArtifact(s: TaskStoreState, taskId: string, artifactId: string): TaskStoreState {
  const rec = taskFor(s, taskId);
  if (!rec || rec.artifactIds.includes(artifactId)) return s;
  const artifactIds = [...rec.artifactIds, artifactId].slice(-MAX_TASK_ARTIFACTS);
  return replace(s, { ...rec, artifactIds });
}

/** Consume the single repair round trip spec 6.2 allows. Returns null once it is
 *  spent: the second malformed result fails the task rather than repeating the
 *  request, because a retry loop does not repair a probabilistic producer. */
export function noteRepair(s: TaskStoreState, taskId: string): TaskStoreState | null {
  const rec = taskFor(s, taskId);
  if (!rec || rec.repairs >= 1) return null;
  return replace(s, { ...rec, repairs: 1 });
}

/**
 * Mark the tasks whose expiry has lapsed, and name them once.
 *
 * A record with `pausedAt` set is skipped — it is waiting on a human, and human
 * latency must never lapse a task. Marking rather than transitioning is
 * deliberate: the lead needs a defined outcome (spec 5.3) but a fabricated
 * `failed` would be exactly the inference from an absence that D11 forbids, and
 * `expiredAt` makes the report idempotent so a tick loop names each lapse once.
 */
export function tickExpiry(s: TaskStoreState, now: number): { next: TaskStoreState; expired: TaskRecord[] } {
  const expired: TaskRecord[] = [];
  const tasks = s.tasks.map((t) => {
    if (t.expiredAt !== undefined || t.pausedAt !== undefined) return t;
    if (isTerminal(t.state)) return t;
    if (t.expiresAt === undefined || t.expiresAt > now) return t;
    const next = { ...t, expiredAt: now, updatedAt: now };
    expired.push(next);
    return next;
  });
  if (expired.length === 0) return { next: s, expired };
  return { next: { guard: s.guard, tasks }, expired };
}

function tasksPath(abDir: string, projectId: string, sessionId: string): string {
  return join(sessionBusSessionDir(abDir, projectId, sessionId), "tasks.json");
}

export function loadTasks(abDir: string, projectId: string, sessionId: string): TaskStoreState {
  const file = readStoreFile<z.infer<typeof TaskFileSchema> | null>(
    tasksPath(abDir, projectId, sessionId),
    TaskFileSchema,
    null,
  );
  if (!file) return emptyTasks();
  return { guard: file.guard, tasks: file.tasks };
}

/** Prune to what the schema will read back. An over-cap array fails
 *  `TaskFileSchema` outright and the whole store then loads as empty, so the cap
 *  is enforced on the way OUT: finished tasks go first, oldest first. */
function pruneForPersist(tasks: readonly TaskRecord[]): TaskRecord[] {
  if (tasks.length <= MAX_TASKS_PERSISTED) return [...tasks];
  const live = tasks.filter((t) => !isTerminal(t.state));
  const done = tasks.filter((t) => isTerminal(t.state)).sort((a, b) => a.updatedAt - b.updatedAt);
  const keepDone = new Set(done.slice(Math.max(0, done.length - Math.max(0, MAX_TASKS_PERSISTED - live.length))));
  return tasks.filter((t) => !isTerminal(t.state) || keepDone.has(t)).slice(-MAX_TASKS_PERSISTED);
}

export function saveTasks(abDir: string, projectId: string, sessionId: string, s: TaskStoreState): void {
  const dir = sessionBusSessionDir(abDir, projectId, sessionId);
  writeStoreFile(join(dir, "tasks.json"), dir, {
    version: TASK_STORE_VERSION,
    guard: s.guard,
    tasks: pruneForPersist(s.tasks),
  });
}
