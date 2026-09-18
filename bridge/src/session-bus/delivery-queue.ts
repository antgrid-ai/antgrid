// Turn-boundary delivery (spec 5.2). A rendered line waits here until the
// session it is for is clear — no open turn, no unanswered block — and is
// submitted through the same `SessionAdapter.injectReply` a Handler auto-reply
// uses.
//
// Why a queue and not a direct submit: `PtySubmitQueue` orders writes per
// terminal but knows nothing about turns, so an injected line lands wherever the
// agent's cursor happens to be — inside a tool call, inside a permission prompt,
// halfway through a plan. The work-status reduction is the only thing on this
// bridge that knows when a line can be read as a new instruction rather than as
// an answer to whatever the agent last asked, so the gate is its own predicate
// (`busDeliverable`) rather than a second reading of its inputs.
//
// Why it is persisted: a queued line is the only trace an arrival leaves that
// the receiving agent ever sees, and the wait for a turn boundary is unbounded.
// A bridge restart between the arrival landing and the turn closing would drop
// it with the sender already told it was sent.
//
// Ordering is FIFO per session, and exactly ONE line goes in per turn boundary:
// the turn a submitted line opens is only observed asynchronously, so a second
// line submitted in the same drain would land inside the turn the first just
// started -- the mid-turn arrival this whole module exists to prevent. A session
// whose agent is down keeps its queue in the order the events happened rather
// than skipping ahead to whatever the adapter happens to accept.

import { z } from "zod";
import { logger } from "../logger";
import { errorName, lineKey } from "../line-key";
import { SUBMIT_READY_TIMEOUT_MS } from "../submit-gate";
import { MAX_DELIVERY_CHARS } from "./delivery";
import { readBusDb, readRecords, replaceRecords, withBusDb } from "./bus-db";

const log = logger.child({ component: "session-bus" });

/** What one submit attempt is worth.
 *
 *  `"submitted"` is a WRITE-side answer — the adapter took the text — and on an
 *  agent that announces nothing it is the only answer available, so the line is
 *  removed on it. `"awaiting-turn"` says the agent will announce the turn this
 *  text opens, so the queue keeps the line until it does. */
export type BusInjectOutcome = "refused" | "submitted" | "awaiting-turn";

/** How long a line waits for the turn its own submit should have opened.
 *
 *  Derived from the submit gate rather than chosen, and the direction matters:
 *  a cold-starting agent's keystrokes are held for up to
 *  {@link SUBMIT_READY_TIMEOUT_MS} before a byte reaches its PTY, so any window
 *  inside that would re-inject the first delivery of every cold start. */
export const CONFIRM_TIMEOUT_MS = SUBMIT_READY_TIMEOUT_MS + 15_000;

/** How many times one line may be handed to the adapter. The second attempt is
 *  the retry this confirmation exists to make possible; without a bound, a line
 *  no agent will ever confirm cycles at the head of its session's queue for
 *  good, and every later arrival for that session waits behind it. */
export const MAX_SUBMIT_ATTEMPTS = 2;

/** Lines held across every session of one project. Small on purpose: past it the
 *  agent is not reading its queue at all, and a hundred stale arrivals delivered
 *  at once is a worse prompt than the newest few. */
export const MAX_QUEUED_LINES = 64;

/** Which template produced the line. Recorded so a queue dumped after a restart
 *  says what is waiting without re-parsing the rendered text.
 *
 *  Only a notify produces a line at all — a post is read when the target chooses
 *  (§7.1) — and the two kinds split on whether the RECEIVER already held the
 *  thread when the message landed, which is what decides whether the reader is
 *  being introduced to an exchange or continued in one. */
export const DeliveryKindSchema = z.enum(["notify", "reply"]);
export type DeliveryKind = z.infer<typeof DeliveryKindSchema>;

export const QueuedLineSchema = z.object({
  /** The message id the line was rendered from. Idempotency key: a duplicate
   *  frame the coordinator re-emits must not queue a second copy. */
  id: z.string().min(1).max(300),
  sessionId: z.string().min(1).max(200),
  kind: DeliveryKindSchema,
  text: z.string().max(MAX_DELIVERY_CHARS),
  queuedAt: z.number(),
  /** When this line was last handed to the adapter, on a session whose agent
   *  announces turn-starts. Set means "submitted, not yet confirmed". */
  sentAt: z.number().optional(),
  /** Submits attempted, bounded by {@link MAX_SUBMIT_ATTEMPTS}.
   *
   *  Optional, like `sentAt`, because `readRecords` drops a row whose parse
   *  fails: a required field on a persisted row empties every session's queue on
   *  the upgrade that adds it, and the lines it drops are the ones nothing
   *  re-sends. */
  attempts: z.number().optional(),
});
export type QueuedLine = z.infer<typeof QueuedLineSchema>;

export interface DeliveryQueueState {
  readonly lines: readonly QueuedLine[];
}

export function emptyDeliveries(): DeliveryQueueState {
  return { lines: [] };
}

/** Which lines may be dropped to make room. Both kinds are: a message is
 *  conversation and is allowed to be lost (§4.1), and the durable half of what
 *  a session says is an artifact, which this queue never carries. A kind added
 *  to the enum without being added HERE is treated as load-bearing instead, and
 *  the eviction below then drops the oldest line outright — possibly another
 *  session's. The enum forces a type edit; this Set does not. */
const EVICTABLE_KINDS: ReadonlySet<DeliveryKind> = new Set<DeliveryKind>(["notify", "reply"]);

/** Append, or return the state unchanged when the id is already queued. The
 *  no-op is what makes a redelivered transition — the outbox retries until
 *  acked — cost nothing. */
export function enqueueLine(s: DeliveryQueueState, line: QueuedLine): DeliveryQueueState {
  if (s.lines.some((l) => l.id === line.id)) return s;
  const lines = [...s.lines, line];
  if (lines.length <= MAX_QUEUED_LINES) return { lines };
  // Over the cap something has to go, and it goes by KIND before age: the cap is
  // one project's whole queue, so a kind that may not be lost has to survive one
  // chatty session filling it. A dropped line is gone outright — the sender was
  // answered before this line existed and nothing retries it. Oldest evictable
  // first; oldest outright only when every held line is load-bearing.
  const evictable = lines.findIndex((l) => EVICTABLE_KINDS.has(l.kind));
  const drop = evictable === -1 ? 0 : evictable;
  return { lines: lines.filter((_, i) => i !== drop) };
}

export function linesFor(s: DeliveryQueueState, sessionId: string): QueuedLine[] {
  return s.lines.filter((l) => l.sessionId === sessionId);
}

export function removeLine(s: DeliveryQueueState, id: string): DeliveryQueueState {
  const lines = s.lines.filter((l) => l.id !== id);
  return lines.length === s.lines.length ? s : { lines };
}

/** Mark [id] as submitted and awaiting the turn it should open. */
function stampSubmitted(s: DeliveryQueueState, id: string, at: number): DeliveryQueueState {
  return { lines: s.lines.map((l) => (l.id === id ? { ...l, sentAt: at, attempts: (l.attempts ?? 0) + 1 } : l)) };
}

/** Drop everything held for a session that no longer exists. Reached only by a
 *  session delete that runs on a WARM core: a line for a deleted session can
 *  never be delivered, and keeping it would hold a slot against the cap
 *  forever. A session deleted while its project is cold reaches nothing here —
 *  `HostServer.deleteColdSessionBusThenRow` owns no core to reach it through,
 *  and says there why it leaves those lines for the next warm-up. */
export function forgetSession(s: DeliveryQueueState, sessionId: string): DeliveryQueueState {
  const lines = s.lines.filter((l) => l.sessionId !== sessionId);
  return lines.length === s.lines.length ? s : { lines };
}

export function loadDeliveries(abDir: string, projectId: string): DeliveryQueueState {
  return readBusDb(
    abDir,
    (db) => ({ lines: readRecords(db, "bus_deliveries", "line", { projectId }, MAX_QUEUED_LINES, QueuedLineSchema) }),
    emptyDeliveries(),
  );
}

/** Restore a persisted queue as one no submit is outstanding on.
 *
 *  `sentAt` means "in the agent's composer, waiting for the turn it opens", and
 *  that composer died with the previous process's PTY. Carried across a restart
 *  it is worse than useless: the confirm timer that would retry it lives in
 *  memory and is gone, so nothing re-enters the drain inside the window, and the
 *  next turn that session opens for ANY reason retires the line as read —
 *  losing an arrival the sender was told had been sent. Cleared, the line goes
 *  in again at the next boundary, which is the repeated-line cost this module
 *  already prefers to a silent loss. `attempts` is kept: it bounds how many
 *  times one line may be handed to an adapter, however many processes do it. */
function asUnsubmitted(s: DeliveryQueueState): DeliveryQueueState {
  if (!s.lines.some((l) => l.sentAt !== undefined)) return s;
  return {
    lines: s.lines.map((l) => {
      if (l.sentAt === undefined) return l;
      const { sentAt: _sentAt, ...rest } = l;
      return rest;
    }),
  };
}

export function saveDeliveries(abDir: string, projectId: string, s: DeliveryQueueState): void {
  withBusDb(
    abDir,
    (db) => replaceRecords(db, "bus_deliveries", "line", { projectId }, s.lines.slice(-MAX_QUEUED_LINES)),
    undefined,
  );
}

export interface DeliveryQueueDeps {
  abDir: string;
  projectId: string;
  /** Is the session at a point where a line can be read as a new instruction?
   *  Asked live of the work-status reduction (`busDeliverable`). A line queued
   *  while this is false waits for the edge that makes it true; every condition
   *  the predicate holds on has one, which is what keeps the wait finite
   *  without a clock. */
  canDeliver: (sessionId: string) => boolean;
  /** Submit one line into a session. `"refused"` means it did not go in — no
   *  live agent, or an adapter that refused — and the line stays queued at the
   *  head. See {@link BusInjectOutcome} for why the other two differ. */
  inject: (line: QueuedLine) => BusInjectOutcome;
  now?: () => number;
}

/**
 * The queue plus its disk copy and its drain.
 *
 * Owned by `ProjectCore`, because the turn-open set it reads is that core's
 * reduction and nothing below it can see one.
 */
export class SessionBusDeliveryQueue {
  private state: DeliveryQueueState;
  private readonly now: () => number;
  /** Injecting can reach the terminal, which can move the work status, which
   *  re-enters `commitWork`. Draining from inside a drain would submit the same
   *  head line twice before the first return removed it. */
  private draining = false;
  /** One per session holding a submitted-but-unconfirmed head. The confirmation
   *  is an edge, and an edge that never arrives produces no event, so this is
   *  the only thing that re-enters the drain for a line whose turn never
   *  opened. */
  private readonly confirmTimers = new Map<string, ReturnType<typeof setTimeout>>();

  constructor(private readonly deps: DeliveryQueueDeps) {
    this.now = deps.now ?? Date.now;
    this.state = asUnsubmitted(loadDeliveries(deps.abDir, deps.projectId));
  }

  /** What is currently held, for tests and for a caller reporting queue depth. */
  get lines(): readonly QueuedLine[] {
    return this.state.lines;
  }

  /**
   * Hold a rendered line for [sessionId], and deliver it now if the session is
   * idle.
   *
   * Persisted BEFORE the delivery attempt: a crash mid-submit costs a repeated
   * line, which the wrapper makes obvious and the agent can absorb, where
   * persisting after would cost the wake outright.
   */
  queue(line: Omit<QueuedLine, "queuedAt">): void {
    // AHEAD of the dedup short-circuit below: an arrival that produced no queue
    // row is otherwise indistinguishable from one that never reached this
    // module.
    const key = lineKey(line.text);
    const next = enqueueLine(this.state, { ...line, queuedAt: this.now() });
    if (next === this.state) {
      log.debug({ ...key, id: line.id, sessionId: line.sessionId, kind: line.kind }, "bus queue: already held, not queued again");
    } else {
      log.debug({ ...key, id: line.id, sessionId: line.sessionId, kind: line.kind, depth: next.lines.length }, "bus queue: held");
      this.commit(next);
    }
    // Drained on the duplicate path too. The head it would skip may be one that
    // was submitted and never confirmed, and a redelivery is a chance to notice
    // that — the outbox retrying is often the only event this session gets.
    this.drain(line.sessionId);
  }

  /**
   * Submit the oldest line held for [sessionId], if the session is idle.
   *
   * ONE line, never the whole queue: the line just submitted opens a turn that
   * this bridge only learns about a round trip later, so a second submit in the
   * same pass lands mid-turn — the thing the queue exists to prevent. The rest
   * follow on the next closing edge, which is the turn this delivery started.
   *
   * Called on every queue and on the edge where the session became deliverable
   * again (`becameDeliverable`, work-status.ts), so an idle session gets its
   * line immediately and a blocked one gets it the moment the block lifts.
   */
  drain(sessionId: string): void {
    if (this.draining) return;
    const line = linesFor(this.state, sessionId)[0];
    if (!line) return;
    const key = lineKey(line.text);
    if (line.sentAt !== undefined) {
      const waitedMs = this.now() - line.sentAt;
      if (waitedMs < CONFIRM_TIMEOUT_MS) {
        log.debug({ ...key, id: line.id, sessionId, waitedMs }, "bus drain: skipped, the last submit has not opened its turn yet");
        return;
      }
      if ((line.attempts ?? 0) >= MAX_SUBMIT_ATTEMPTS) {
        // Dropped rather than retried forever: a line the agent never acts on
        // blocks every later arrival for this session, and re-injecting it
        // appends another copy behind the ones already sitting in the composer.
        log.warn({ ...key, id: line.id, sessionId, attempts: line.attempts }, "bus drain: dropped, submitted to no effect");
        this.commit(removeLine(this.state, line.id));
        // The drop opens no turn and clears no block, so it produces none of the
        // edges that re-enter this drain. Without the re-entry the line behind it
        // waits for an unrelated event on a session that is already idle.
        this.drain(sessionId);
        return;
      }
    }
    if (!this.deps.canDeliver(sessionId)) {
      log.debug({ ...key, id: line.id, sessionId, heldMs: this.now() - line.queuedAt }, "bus drain: skipped, session not at a boundary");
      return;
    }
    this.draining = true;
    let outcome: BusInjectOutcome = "refused";
    try {
      outcome = this.deps.inject(line);
    } catch (err) {
      log.warn("could not deliver %s line to session %s: %s", line.kind, sessionId, errorName(err));
    } finally {
      this.draining = false;
    }
    log.debug({ ...key, id: line.id, sessionId, kind: line.kind, outcome }, "bus drain: inject returned");
    // Held at the head rather than dropped or skipped: the next boundary retries
    // it, and delivering the line behind it first would hand the agent a result
    // for work it was never told to do.
    if (outcome === "refused") return;
    if (outcome === "submitted") {
      this.commit(removeLine(this.state, line.id));
      return;
    }
    this.commit(stampSubmitted(this.state, line.id, this.now()));
    this.armConfirm(sessionId);
  }

  /**
   * The session opened a turn, so the line it was submitted is being read.
   *
   * Driven from the turn-OPEN edge (`openedTurns`, work-status.ts) — the mirror
   * of the closing edge {@link drain} rides. An unstamped head confirms nothing:
   * the session simply started a turn of its own.
   *
   * No drain follows. A turn is open, so the next line is not deliverable
   * anyway, and its boundary is the close of the turn this one just opened.
   */
  confirm(sessionId: string): void {
    const line = linesFor(this.state, sessionId)[0];
    if (!line || line.sentAt === undefined) return;
    log.debug({ ...lineKey(line.text), id: line.id, sessionId, kind: line.kind }, "bus confirm: submitted line opened its turn");
    this.commit(removeLine(this.state, line.id));
  }

  /** Attempt one line for every session holding one. The startup drain: nothing
   *  has an open turn on a bridge that just booted, so a wake that outlived a
   *  restart goes in as soon as its agent is up. */
  drainAll(): void {
    for (const sessionId of new Set(this.state.lines.map((l) => l.sessionId))) {
      this.drain(sessionId);
    }
  }

  forget(sessionId: string): void {
    const next = forgetSession(this.state, sessionId);
    if (next !== this.state) this.commit(next);
  }

  /** Drop every pending confirmation. The queue itself is on disk; what would
   *  otherwise outlive the project is a timer holding the torn-down core it
   *  would submit through. */
  dispose(): void {
    for (const timer of this.confirmTimers.values()) clearTimeout(timer);
    this.confirmTimers.clear();
  }

  /** Keyed to the STAMP, not to the map being empty. A drain driven by anything
   *  other than this timer can re-stamp the head just before the timer armed for
   *  the previous attempt fires; keeping that one measures the fresh stamp
   *  against a window already over, and its expiry then finds the wait too short
   *  and schedules nothing at all. */
  private armConfirm(sessionId: string): void {
    const pending = this.confirmTimers.get(sessionId);
    if (pending) clearTimeout(pending);
    const timer = setTimeout(() => {
      this.confirmTimers.delete(sessionId);
      this.drain(sessionId);
    }, CONFIRM_TIMEOUT_MS);
    timer.unref?.();
    this.confirmTimers.set(sessionId, timer);
  }

  private commit(next: DeliveryQueueState): void {
    this.state = next;
    // A stamped head can leave without its own timer firing — confirmed by a
    // turn, dropped past the attempt cap, or evicted by the project-wide cap
    // because a sibling session filled the queue. Clearing here is what keeps
    // one from outliving the line it was armed for.
    for (const [sessionId, timer] of this.confirmTimers) {
      if (linesFor(next, sessionId)[0]?.sentAt !== undefined) continue;
      clearTimeout(timer);
      this.confirmTimers.delete(sessionId);
    }
    try {
      saveDeliveries(this.deps.abDir, this.deps.projectId, next);
    } catch (err) {
      // In memory the queue is still correct, and losing the file costs a
      // redelivery the sender's outbox already retries. Throwing here would
      // instead take down the work-status commit that called it.
      log.warn("could not persist session-bus deliveries: %s", err);
    }
  }
}
