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
// Why it is persisted: the wake for a completed task is the ONLY thing that
// tells a lead its peer finished. A bridge restart between the transition
// landing and the turn closing would otherwise drop it silently, and D11 forbids
// the lead inferring the outcome from the absence.
//
// Ordering is FIFO per session, and exactly ONE line goes in per turn boundary:
// the turn a submitted line opens is only observed asynchronously, so a second
// line submitted in the same drain would land inside the turn the first just
// started -- the mid-turn arrival this whole module exists to prevent. A session
// whose agent is down keeps its queue in the order the events happened rather
// than skipping ahead to whatever the adapter happens to accept.

import { join } from "node:path";
import { z } from "zod";
import { logger } from "../logger";
import { MAX_DELIVERY_CHARS } from "./delivery";
import { readStoreFile, sessionBusProjectDir, writeStoreFile } from "./store-fs";

const log = logger.child({ component: "session-bus" });

export const DELIVERY_QUEUE_VERSION = 1;

/** Lines held across every session of one project. Small on purpose: past it the
 *  agent is not reading its queue at all, and a hundred stale wakes delivered at
 *  once is a worse prompt than the newest few. */
export const MAX_QUEUED_LINES = 64;

/** Which template produced the line. Recorded so a queue dumped after a restart
 *  says what is waiting without re-parsing the rendered text.
 *
 *  A `brief` reaches its peer one of two ways. An ARMED Handler takes it as an
 *  instruction at arm time (`flushPendingBrief`), which is a boundary by
 *  construction and queues nothing. Everything else queues it here: a machine
 *  added to a session starts its agent in terminal mode, where no Handler ever
 *  arms, and a brief with no other route would otherwise be held on disk
 *  forever while the dialog that collected it reported success. `joined` is the
 *  same brief travelling the other way, to the LEAD, where it is context rather
 *  than a mandate to adopt. */
export const DeliveryKindSchema = z.enum(["brief", "joined", "task", "wake", "answer", "cancel", "note"]);
export type DeliveryKind = z.infer<typeof DeliveryKindSchema>;

export const QueuedLineSchema = z.object({
  /** The message or task id the line was rendered from. Idempotency key: a
   *  duplicate frame the coordinator re-emits must not queue a second copy. */
  id: z.string().min(1).max(300),
  sessionId: z.string().min(1).max(200),
  kind: DeliveryKindSchema,
  text: z.string().max(MAX_DELIVERY_CHARS),
  queuedAt: z.number(),
});
export type QueuedLine = z.infer<typeof QueuedLineSchema>;

export const DeliveryQueueFileSchema = z.object({
  version: z.literal(DELIVERY_QUEUE_VERSION),
  lines: z.array(QueuedLineSchema).max(MAX_QUEUED_LINES),
});

export interface DeliveryQueueState {
  readonly lines: readonly QueuedLine[];
}

export function emptyDeliveries(): DeliveryQueueState {
  return { lines: [] };
}

/** Which lines may be dropped to make room. A `task` is an assignment and a
 *  `cancel` is its withdrawal: lose either and the two machines disagree about
 *  what is being worked, which is the exact failure the sequenced half of the
 *  protocol exists to prevent. A `joined` is load-bearing for a third reason —
 *  it is the ONLY place the human's brief for a peer is ever shown on the lead's
 *  machine, since the durable brief record lives on the peer — so losing one
 *  leaves the lead a machine it was never told the mandate for. A `brief` is
 *  that same mandate on the peer's own side and the only one it is ever given.
 *  A `wake`, an `answer` and a `note` only narrate something the task record
 *  already holds. */
const EVICTABLE_KINDS: ReadonlySet<DeliveryKind> = new Set<DeliveryKind>(["wake", "answer", "note"]);

/** Append, or return the state unchanged when the id is already queued. The
 *  no-op is what makes a redelivered transition — the outbox retries until
 *  acked — cost nothing. */
export function enqueueLine(s: DeliveryQueueState, line: QueuedLine): DeliveryQueueState {
  if (s.lines.some((l) => l.id === line.id)) return s;
  const lines = [...s.lines, line];
  if (lines.length <= MAX_QUEUED_LINES) return { lines };
  // Over the cap something has to go, and it goes by KIND before age. The cap is
  // one project's whole queue, so a chatty session's wakes would otherwise evict
  // another session's assign — and the coordinator acked whatever produced this
  // line before it ever got here, so a dropped one is gone with nothing to
  // retry it. Oldest evictable first; oldest outright only when every held line
  // is load-bearing.
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

/** Drop everything held for a session that no longer exists. Called from the
 *  session delete path: a line for a deleted session can never be delivered, and
 *  keeping it would hold a slot against the cap forever. */
export function forgetSession(s: DeliveryQueueState, sessionId: string): DeliveryQueueState {
  const lines = s.lines.filter((l) => l.sessionId !== sessionId);
  return lines.length === s.lines.length ? s : { lines };
}

function queuePath(abDir: string, projectId: string): string {
  return join(sessionBusProjectDir(abDir, projectId), "deliveries.json");
}

export function loadDeliveries(abDir: string, projectId: string): DeliveryQueueState {
  const file = readStoreFile<z.infer<typeof DeliveryQueueFileSchema> | null>(
    queuePath(abDir, projectId),
    DeliveryQueueFileSchema,
    null,
  );
  return file ? { lines: file.lines } : emptyDeliveries();
}

export function saveDeliveries(abDir: string, projectId: string, s: DeliveryQueueState): void {
  const dir = sessionBusProjectDir(abDir, projectId);
  writeStoreFile(join(dir, "deliveries.json"), dir, {
    version: DELIVERY_QUEUE_VERSION,
    lines: s.lines.slice(-MAX_QUEUED_LINES),
  });
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
