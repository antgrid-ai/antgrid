import { z } from "zod/v4";

/** The five frames the session stream carries at the application layer, one
 *  scheme (`session:` + verb). Everything else on that stream after
 *  establishment is one `AbMessage` of the control plane — see
 *  `PeerSessionOwner.receiveSessionRecord` (bridge/src/peer-session-owner.ts). */
export const SESSION_FRAME_TYPES = [
  "session:hello",
  "session:established",
  "session:ping",
  "session:pong",
  "session:takeover",
] as const;
export type SessionFrameType = (typeof SESSION_FRAME_TYPES)[number];
export const SessionFrameTypeSchema = z.enum(SESSION_FRAME_TYPES);

const SESSION_FRAME_TYPE_SET = new Set<string>(SESSION_FRAME_TYPES);
export function isSessionFrameType(type: unknown): type is SessionFrameType {
  return typeof type === "string" && SESSION_FRAME_TYPE_SET.has(type);
}

// Non-strict on purpose: these exist only for the vectors generator to
// validate its samples against, and dispatch is on `type` alone — an extra
// key on a ping must never cost a pong.
export const SessionPingFrame = z.object({ type: z.literal("session:ping") });
export const SessionPongFrame = z.object({ type: z.literal("session:pong") });
export const SessionTakeoverFrame = z.object({ type: z.literal("session:takeover") });
