// The outbox: every message this bridge sent to another machine and has not yet
// seen acknowledged, kept so a link that was down for a moment, a relay that
// restarted, or a recipient that was asleep does not cost a message.
//
// DELIVERY IS AT-LEAST-ONCE. A frame stays here until the recipient's signed
// ack says it stored it (or says it will never be stored), and it is offered
// again on a backoff until then, so the recipient may see the same message id
// more than once. That is safe only because the receiving side remembers every
// id it has verdicted (`seen-store.ts`) and answers a repeat from the stored
// verdict instead of applying it again. The two halves are one contract:
// loosening either alone turns a retry into a duplicate or a loss.
//
// Nothing is dropped silently. Past the cap the oldest entry is evicted and past
// the TTL the stale ones expire; the caller stamps each of them refused on the
// message log, so the sender can read what became of it.

import { z } from "zod";
import { SessionMemberKeySchema } from "../protocol";
import { BUS_MESSAGE_TTL_MS, MAX_HELD_MESSAGES } from "./constants";
import { readBusDb, readRecords, replaceRecords, withBusDb } from "./bus-db";

export const HELD_MESSAGE_TTL_MS = BUS_MESSAGE_TTL_MS;

export const HeldMessageSchema = z.object({
  messageId: z.string().min(1).max(200),
  contextId: z.string().min(1).max(200),
  to: SessionMemberKeySchema,
  /** The serialized send frame, opaque here: this store is a parking space for
   *  a send, never a reader of what it carries. */
  frame: z.unknown(),
  heldAt: z.number().int().nonnegative(),
  /** Offers made so far, the first one included. */
  attempts: z.number().int().nonnegative(),
  /** Earliest time the next offer may be made. Persisted so a restart resumes
   *  the backoff rather than offering every held message at once. */
  nextAttemptAt: z.number().int().nonnegative(),
  /** When the relay said it holds the message. From then the resend is only a
   *  safety net for a relay that lost its queue. */
  relayedAt: z.number().int().optional(),
  /** Why the last offer did not complete, for the send line and the thread. */
  lastReason: z.string().max(64).optional(),
});
export type HeldMessage = z.infer<typeof HeldMessageSchema>;

export interface HeldState {
  readonly held: readonly HeldMessage[];
}

export function emptyHeld(): HeldState {
  return { held: [] };
}

export function hasHeld(s: HeldState, messageId: string): boolean {
  return s.held.some((m) => m.messageId === messageId);
}

/** Hold one unacknowledged message. Appended at the end and evicted from the
 *  front, so the order a sender wrote in is the order the target reads. The
 *  evicted entries are returned so the caller can say what became of them. */
export function holdMessage(s: HeldState, m: HeldMessage): { state: HeldState; evicted: HeldMessage[] } {
  const held = [...s.held, m];
  if (held.length <= MAX_HELD_MESSAGES) return { state: { held }, evicted: [] };
  const cut = held.length - MAX_HELD_MESSAGES;
  return { state: { held: held.slice(cut) }, evicted: held.slice(0, cut) };
}

export function expireHeld(s: HeldState, now: number): { state: HeldState; expired: HeldMessage[] } {
  const expired = s.held.filter((m) => now - m.heldAt >= HELD_MESSAGE_TTL_MS);
  if (expired.length === 0) return { state: s, expired };
  return { state: { held: s.held.filter((m) => now - m.heldAt < HELD_MESSAGE_TTL_MS) }, expired };
}

/** Drop the ones the far side has settled, applied or refused. Never the ones
 *  merely offered. */
export function releaseHeld(s: HeldState, messageIds: readonly string[]): HeldState {
  if (messageIds.length === 0) return s;
  const gone = new Set(messageIds);
  return { held: s.held.filter((m) => !gone.has(m.messageId)) };
}

export function loadHeld(abDir: string, projectId: string, sessionId: string): HeldState {
  return readBusDb(
    abDir,
    (db) => ({ held: readRecords(db, "bus_held", "held", { projectId, sessionId }, MAX_HELD_MESSAGES, HeldMessageSchema) }),
    emptyHeld(),
  );
}

export function saveHeld(abDir: string, projectId: string, sessionId: string, s: HeldState): void {
  withBusDb(
    abDir,
    (db) => replaceRecords(db, "bus_held", "held", { projectId, sessionId }, s.held.slice(-MAX_HELD_MESSAGES)),
    undefined,
  );
}
