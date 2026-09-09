// A bounded ring of the envelopes that crossed, for a human or the app to read
// back what a session said and was told.
//
// THE LOG IS NOT THE DURABLE COPY — an Artifact is. A message is allowed to be
// lost, so nothing may be reconstructed from this file, and every part is
// trimmed to MAX_LOGGED_PART_CHARS on the way in: anything worth keeping whole
// was published as an artifact, and a log that grew to hold it would outweigh
// what it annotates. It is written on the same flush as the held store, so a
// crash can lose the tail of the log but never a message still waiting to go.

import { join } from "node:path";
import { z } from "zod";
import { BusEnvelopeSchema, trimEnvelopeForLog, type BusEnvelope } from "./envelope";
import { MAX_LOG_ENTRIES } from "./constants";
import { SessionMemberKeySchema, type SessionMemberKey } from "../protocol";
import { readStoreFile, sessionBusSessionDir, writeStoreFile } from "./store-fs";

export const MESSAGE_LOG_VERSION = 1;

export const LoggedEnvelopeSchema = z.object({
  at: z.number(),
  direction: z.enum(["in", "out"]),
  /** The other end. The bare key, not the labelled ref: a log line is scanned by
   *  address, and a label is display text that goes stale under a rename. */
  peer: SessionMemberKeySchema,
  envelope: BusEnvelopeSchema,
});
export type LoggedEnvelope = z.infer<typeof LoggedEnvelopeSchema>;

export const MessageLogFileSchema = z.object({
  version: z.literal(MESSAGE_LOG_VERSION),
  entries: z.array(LoggedEnvelopeSchema).max(MAX_LOG_ENTRIES),
});

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

function logPath(abDir: string, projectId: string, sessionId: string): string {
  return join(sessionBusSessionDir(abDir, projectId, sessionId), "messages.json");
}

export function loadMessageLog(abDir: string, projectId: string, sessionId: string): MessageLogState {
  const file = readStoreFile<z.infer<typeof MessageLogFileSchema> | null>(
    logPath(abDir, projectId, sessionId),
    MessageLogFileSchema,
    null,
  );
  return file ? { entries: file.entries } : emptyLog();
}

export function saveMessageLog(
  abDir: string,
  projectId: string,
  sessionId: string,
  s: MessageLogState,
): void {
  const dir = sessionBusSessionDir(abDir, projectId, sessionId);
  writeStoreFile(join(dir, "messages.json"), dir, {
    version: MESSAGE_LOG_VERSION,
    entries: s.entries.slice(-MAX_LOG_ENTRIES),
  });
}
