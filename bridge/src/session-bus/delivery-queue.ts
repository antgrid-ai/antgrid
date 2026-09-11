// Turn-boundary delivery (spec 5.2). A rendered line waits here until the
// session it is for has no open turn, and is submitted through the same
// `SessionAdapter.injectReply` a Handler auto-reply uses.
//
// Why a queue and not a direct submit: `PtySubmitQueue` orders writes per
// terminal but knows nothing about turns, so an injected line lands wherever the
// agent's cursor happens to be — inside a tool call, inside a permission prompt,
// halfway through a plan. The turn-open set the work-status reduction already
// maintains is the only thing on this bridge that knows when a line can be read
// as a new instruction rather than as an answer to whatever the agent last
// asked.
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
import { MAX_DELIVERY_CHARS } from "./delivery";
import { readBusDb, readRecords, replaceRecords, withBusDb } from "./bus-db";

const log = logger.child({ component: "session-bus" });

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
  /** The work-status reduction's turn-open set, asked live. A line queued while
   *  this is true waits; the drain that follows the turn's close submits it. */
  isTurnOpen: (sessionId: string) => boolean;
  /** Submit one line into a session. False means it did not go in — no live
   *  agent, or an adapter that refused — and the line stays queued at the head. */
  inject: (line: QueuedLine) => boolean;
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

  constructor(private readonly deps: DeliveryQueueDeps) {
    this.now = deps.now ?? Date.now;
    this.state = loadDeliveries(deps.abDir, deps.projectId);
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
    const next = enqueueLine(this.state, { ...line, queuedAt: this.now() });
    if (next === this.state) return;
    this.commit(next);
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
   * Called on that closing edge and again on every queue, so an idle session gets
   * its line immediately and a busy one gets it the moment its turn ends.
   */
  drain(sessionId: string): void {
    if (this.draining) return;
    if (this.deps.isTurnOpen(sessionId)) return;
    const line = linesFor(this.state, sessionId)[0];
    if (!line) return;
    this.draining = true;
    let delivered = false;
    try {
      delivered = this.deps.inject(line);
    } catch (err) {
      log.warn("could not deliver %s line to session %s: %s", line.kind, sessionId, err);
    } finally {
      this.draining = false;
    }
    // Held at the head rather than dropped or skipped: the next boundary retries
    // it, and delivering the line behind it first would hand the agent a result
    // for work it was never told to do.
    if (!delivered) return;
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

  private commit(next: DeliveryQueueState): void {
    this.state = next;
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

/** Sessions whose turn closed between two work-status reductions — the edge a
 *  delivery waits on. Pure so `commitWork` can compute it before it swaps the
 *  state it is comparing against. */
export function closedTurns(
  prev: { activeTurns: ReadonlySet<string> },
  next: { activeTurns: ReadonlySet<string> },
): string[] {
  return [...prev.activeTurns].filter((id) => !next.activeTurns.has(id));
}
