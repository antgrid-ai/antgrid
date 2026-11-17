// Thread rows authorize replies even when a peer's directory row is absent.
// Only admitted sends and inbound frames may mint them; upsertThread freezes
// the peer and context so a later frame cannot redirect an existing exchange.
// Expiry runs on warm reads too, bounding this authority without a restart.
import { z } from "zod";
import { THREAD_TTL_MS, MAX_THREADS_PER_SESSION } from "./constants";
import { SessionMemberKeySchema } from "../protocol";
import { readBusDb, readRecords, replaceRecords, withBusDb } from "./bus-db";

export const ThreadRowSchema = z.object({
  threadId: z.string().min(1).max(200),
  /** The exchange the thread rides on. NOT the thread id under another name:
   *  routing derives from `contextId === sessionId` and a per-thread context
   *  would flip every reply's role. */
  contextId: z.string().min(1).max(200),
  /** The other end, as a bare key — a label here is display text that goes
   *  stale under a rename, and this row is read to address a send. */
  peer: SessionMemberKeySchema,
  lastAt: z.number().int().nonnegative(),
  /** True when the peer opened it, which is what says this session must reply on
   *  the id it was given rather than mint one. */
  openedByPeer: z.boolean(),
});
export type ThreadRow = z.infer<typeof ThreadRowSchema>;

export interface ThreadState {
  readonly threads: readonly ThreadRow[];
}

export function emptyThreads(): ThreadState {
  return { threads: [] };
}

export function threadById(s: ThreadState, threadId: string): ThreadRow | null {
  return s.threads.find((t) => t.threadId === threadId) ?? null;
}

/**
 * Record a thread, or advance the one already held.
 *
 * A row that exists keeps its `contextId`, its `peer` and who opened it, and
 * only `lastAt` moves. Those three are what a reply routes on, and a later
 * frame naming the same thread — a peer's, or a stale one — must not be able to
 * re-point them.
 */
export function upsertThread(s: ThreadState, row: ThreadRow): ThreadState {
  const held = threadById(s, row.threadId);
  const next: ThreadRow = held ? { ...held, lastAt: Math.max(held.lastAt, row.lastAt) } : row;
  const threads = [...s.threads.filter((t) => t.threadId !== row.threadId), next];
  return { threads: threads.length > MAX_THREADS_PER_SESSION ? withoutOldest(threads) : threads };
}

export function expireThreads(s: ThreadState, now: number): ThreadState {
  const threads = s.threads.filter((t) => now - t.lastAt < THREAD_TTL_MS);
  return threads.length === s.threads.length ? s : { threads };
}

/** By `lastAt` rather than by position: an upsert moves a row to the end, so the
 *  head is USUALLY the oldest and a clock that stepped is the case where it is
 *  not. Evicting the wrong thread costs a reply its route. */
function withoutOldest(threads: readonly ThreadRow[]): ThreadRow[] {
  let oldest = 0;
  for (let i = 1; i < threads.length; i += 1) {
    if (threads[i]!.lastAt < threads[oldest]!.lastAt) oldest = i;
  }
  return threads.filter((_, i) => i !== oldest);
}

/** Expiry runs on the way out of the database, so a session reloaded after a
 *  long silence does not come back holding threads the TTL had already retired.
 *  An upsert only bounds the count: a row it touches is one being written to,
 *  which is the definition of not expired. */
export function loadThreads(abDir: string, projectId: string, sessionId: string, now = Date.now()): ThreadState {
  const state = readBusDb(
    abDir,
    (db) => ({ threads: readRecords(db, "bus_threads", "thread", { projectId, sessionId }, MAX_THREADS_PER_SESSION, ThreadRowSchema) }),
    emptyThreads(),
  );
  return expireThreads(state, now);
}

export function saveThreads(abDir: string, projectId: string, sessionId: string, s: ThreadState): void {
  withBusDb(
    abDir,
    (db) => replaceRecords(db, "bus_threads", "thread", { projectId, sessionId }, s.threads.slice(-MAX_THREADS_PER_SESSION)),
    undefined,
  );
}
