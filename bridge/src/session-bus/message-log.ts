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
import { readRecords, replaceRecords, withBusDb } from "./bus-db";

export const LoggedEnvelopeSchema = z.object({
  at: z.number(),
  direction: z.enum(["in", "out"]),
  /** The other end. The bare key, not the labelled ref: a log line is scanned by
   *  address, and a label is display text that goes stale under a rename. */
  peer: SessionMemberKeySchema,
  envelope: BusEnvelopeSchema,
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

/** Every entry on one exchange. Uncalled today: the reader that asks a mailbox
 *  "what has this thread said" is what §7.1 builds on top of it. */
export function entriesForContext(s: MessageLogState, contextId: string): LoggedEnvelope[] {
  return s.entries.filter((e) => e.envelope.contextId === contextId);
}

export function loadMessageLog(abDir: string, projectId: string, sessionId: string): MessageLogState {
  return withBusDb(
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
