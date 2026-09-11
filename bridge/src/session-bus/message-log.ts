// A bounded ring of the envelopes that crossed, for a human or the app to read
// back what a session said and was told.
//
// THE LOG IS NOT THE DURABLE COPY — an Artifact is. A message is allowed to be
// lost, so nothing may be reconstructed from this file, and every part is
// trimmed to MAX_LOGGED_PART_CHARS on the way in: anything worth keeping whole
// was published as an artifact, and a log that grew to hold it would outweigh
// what it annotates. It is written on the same flush as the held store, so a
// crash can lose the tail of the log but never a message still waiting to go.

import { z } from "zod";
import { BusEnvelopeSchema, trimEnvelopeForLog, type BusEnvelope } from "./envelope";
import { MAX_LOG_ENTRIES } from "./constants";
import { SessionMemberKeySchema, type SessionMemberKey } from "../protocol";
import { readBusDb, readRecords, replaceRecords, withBusDb } from "./bus-db";

export const LoggedEnvelopeSchema = z.object({
  at: z.number(),
  direction: z.enum(["in", "out"]),
  /** The other end. The bare key, not the labelled ref: a log line is scanned by
   *  address, and a label is display text that goes stale under a rename. */
  peer: SessionMemberKeySchema,
  envelope: BusEnvelopeSchema,
  /** When the other end's receipt arrived, on an outbound entry. Absent is "no
   *  receipt yet" and never "it failed": a receipt is fire-and-forget and an
   *  unacked one is not retried, so its absence is the only thing a reader may
   *  conclude from it. */
  deliveredAt: z.number().optional(),
});
export type LoggedEnvelope = z.infer<typeof LoggedEnvelopeSchema>;

export interface MessageLogState {
  readonly entries: readonly LoggedEnvelope[];
}

export function emptyLog(): MessageLogState {
  return { entries: [] };
}

export interface LogInput {
  at: number;
  direction: "in" | "out";
  peer: SessionMemberKey;
  envelope: BusEnvelope;
}

/** Append, trimming the envelope's parts and dropping the oldest past the cap.
 *  Trimming HERE rather than at the call sites is what keeps the cap honest:
 *  every writer goes through this one door. */
export function appendLog(s: MessageLogState, e: LogInput): MessageLogState {
  const entry: LoggedEnvelope = {
    at: e.at,
    direction: e.direction,
    peer: e.peer,
    envelope: trimEnvelopeForLog(e.envelope),
  };
  return { entries: [...s.entries, entry].slice(-MAX_LOG_ENTRIES) };
}

/** Every entry on one thread, both directions. Keyed by the thread and not by
 *  the context: one context carries every exchange with a peer, so filtering by
 *  it would answer "what has this thread said" with the whole conversation. */
export function entriesForThread(s: MessageLogState, threadId: string): LoggedEnvelope[] {
  return s.entries.filter((e) => e.envelope.threadId === threadId);
}

/** What this session last said on [threadId], so a reply's header can place it.
 *
 *  The outbound half of its own log and nothing else: a thread row carries the
 *  route, the mailbox carries only posts, and this is the one record of what
 *  THIS session put on the thread. The log is a bounded ring, so an exchange
 *  older than it yields nothing and the header omits the clause rather than
 *  guessing at one. */
export function lastOutboundSummary(s: MessageLogState, threadId: string): string | undefined {
  for (let i = s.entries.length - 1; i >= 0; i -= 1) {
    const e = s.entries[i]!;
    if (e.direction === "out" && e.envelope.threadId === threadId) return e.envelope.metadata.summary;
  }
  return undefined;
}

/** Stamp a receipt onto the outbound entry it answers, or return the state
 *  unchanged when there is nothing to stamp — a message already trimmed out of
 *  the ring, or a second receipt for one already stamped. Outbound only: a peer
 *  mints its own message ids, so an inbound entry can carry the same one. */
export function markDelivered(s: MessageLogState, messageId: string, at: number): MessageLogState {
  const i = s.entries.findIndex((e) => e.direction === "out" && e.envelope.messageId === messageId);
  if (i === -1 || s.entries[i]!.deliveredAt !== undefined) return s;
  const entries = [...s.entries];
  entries[i] = { ...entries[i]!, deliveredAt: at };
  return { entries };
}

export function loadMessageLog(abDir: string, projectId: string, sessionId: string): MessageLogState {
  return readBusDb(
    abDir,
    (db) => ({ entries: readRecords(db, "bus_messages", "entry", { projectId, sessionId }, MAX_LOG_ENTRIES, LoggedEnvelopeSchema) }),
    emptyLog(),
  );
}

export function saveMessageLog(abDir: string, projectId: string, sessionId: string, s: MessageLogState): void {
  withBusDb(
    abDir,
    (db) => replaceRecords(db, "bus_messages", "entry", { projectId, sessionId }, s.entries.slice(-MAX_LOG_ENTRIES)),
    undefined,
  );
}
