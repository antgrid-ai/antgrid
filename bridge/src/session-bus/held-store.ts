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

import { join } from "node:path";
import { z } from "zod";
import { SessionMemberKeySchema } from "../protocol";
import { BUS_MESSAGE_TTL_MS, MAX_HELD_MESSAGES } from "./constants";
import { readStoreFile, sessionBusSessionDir, writeStoreFile } from "./store-fs";

export const HELD_STORE_VERSION = 1;

export const HELD_MESSAGE_TTL_MS = BUS_MESSAGE_TTL_MS;

export const HeldMessageSchema = z.object({
  messageId: z.string().min(1).max(200),
  contextId: z.string().min(1).max(200),
  /** Which way the send was addressed: out through this machine's own carrier,
   *  or back down the carrier that brought the context in. Kept rather than
   *  re-derived at flush time so the frame goes out the way it was addressed. */
  role: z.enum(["lead", "peer"]),
  to: SessionMemberKeySchema,
  /** The serialized `session-bus:message` frame, opaque here like the outbox's. */
  frame: z.unknown(),
  heldAt: z.number().int().nonnegative(),
});
export type HeldMessage = z.infer<typeof HeldMessageSchema>;

export const HeldFileSchema = z.object({
  version: z.literal(HELD_STORE_VERSION),
  held: z.array(HeldMessageSchema).max(MAX_HELD_MESSAGES),
});

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

function heldPath(abDir: string, projectId: string, sessionId: string): string {
  return join(sessionBusSessionDir(abDir, projectId, sessionId), "held.json");
}

export function loadHeld(abDir: string, projectId: string, sessionId: string): HeldState {
  const file = readStoreFile<z.infer<typeof HeldFileSchema> | null>(
    heldPath(abDir, projectId, sessionId),
    HeldFileSchema,
    null,
  );
  return file ? { held: file.held } : emptyHeld();
}

export function saveHeld(abDir: string, projectId: string, sessionId: string, s: HeldState): void {
  const dir = sessionBusSessionDir(abDir, projectId, sessionId);
  writeStoreFile(join(dir, "held.json"), dir, {
    version: HELD_STORE_VERSION,
    held: s.held.slice(-MAX_HELD_MESSAGES),
  });
}
