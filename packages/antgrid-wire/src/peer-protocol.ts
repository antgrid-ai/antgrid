import { z } from "zod/v4";

/** Authenticated peer-record header. Peer identity belongs to the connection. */
export const PeerFrameHeader = z.strictObject({
  type: z.literal("message"),
  channel: z.enum(["control", "preview"]),
});

export type PeerFrameHeader = z.infer<typeof PeerFrameHeader>;
export type PeerChannel = PeerFrameHeader["channel"];

// Wraps every sealed payload as `{ s?, m }` so one authenticated peer
// connection can multiplex project streams. Central control never sees it.
export interface StreamEnvelope {
  s?: string;
  m: unknown;
}

/** Machine control plane; omitted from encoded stream envelopes. */
export const CONTROL_STREAM_ID = "0";
