// Messages this bridge's own transport REFUSED, kept so a link that was down for
// a moment does not cost a message.
//
// A message carries no seq and no ack and is allowed to be lossy, which makes
// one already on the wire unretryable: a second copy would land as a second
// message with nothing to tell it from the first. What CAN be redelivered is one
// that never left — `send` returning false is this machine's own refusal,
// decided before anything reached the relay — so nothing here can duplicate at
// the receiver. That distinction is the whole reason this store is allowed to
// exist, and it is why a caller must hold ONLY on a false return and never on a
// silence.
//
// The lossiness is still spent, just deliberately: past the cap the oldest goes,
// and past the TTL the stale go.

import { z } from "zod";
import { SessionMemberKeySchema } from "../protocol";
import { BUS_MESSAGE_TTL_MS, MAX_HELD_MESSAGES } from "./constants";
import { readBusDb, readRecords, replaceRecords, withBusDb } from "./bus-db";

export const HELD_MESSAGE_TTL_MS = BUS_MESSAGE_TTL_MS;

export const HeldMessageSchema = z.object({
  messageId: z.string().min(1).max(200),
  contextId: z.string().min(1).max(200),
  /** Which way the send was addressed: out through this machine's own carrier,
   *  or back down the carrier that brought the context in. Kept rather than
   *  re-derived at flush time so the frame goes out the way it was addressed. */
  role: z.enum(["lead", "peer"]),
  to: SessionMemberKeySchema,
  /** The serialized send frame, opaque here: this store is a parking space for
   *  a send, never a reader of what it carries. */
  frame: z.unknown(),
  heldAt: z.number().int().nonnegative(),
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

/** Hold one refused message. Appended at the end and evicted from the front, so
 *  the order a sender wrote in is the order the target reads. */
export function holdMessage(s: HeldState, m: HeldMessage): HeldState {
  const held = [...s.held, m];
  return { held: held.length > MAX_HELD_MESSAGES ? held.slice(held.length - MAX_HELD_MESSAGES) : held };
}

export function expireHeld(s: HeldState, now: number): HeldState {
  const held = s.held.filter((m) => now - m.heldAt < HELD_MESSAGE_TTL_MS);
  return held.length === s.held.length ? s : { held };
}

/** Drop the ones that got out. Called with what actually left, never with what
 *  was attempted. */
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
