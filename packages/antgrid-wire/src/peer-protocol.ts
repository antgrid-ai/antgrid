import { z } from "zod/v4";

/** Authenticated peer-record header. Peer identity belongs to the connection.
 *  `type` is the only discriminator between a liveness/session frame and a
 *  control-plane message on the session stream: the JSON `type` field cannot
 *  do it, since `ping`, `pong` and the `session:*` family are also `AbMessage`
 *  literals. */
export const PeerFrameHeader = z.strictObject({
  type: z.enum(["session", "message"]),
});

export type PeerFrameHeader = z.infer<typeof PeerFrameHeader>;
export type PeerFrameKind = PeerFrameHeader["type"];
