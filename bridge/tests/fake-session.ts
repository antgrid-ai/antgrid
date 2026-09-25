// One established PeerSession, installed by hand for tests that need a client
// past the hello without running one. Payloads are plaintext on the wire, and
// QUIC flow control is the only backpressure, so there is nothing to fake
// beyond the session's own bookkeeping fields.
import type { PeerSessionOwner } from "../src/peer-session-owner";

/** Install a session for `peerId` directly. A queued frame reads straight off
 *  the wire and `TestPeerSessionOwner.sendFromPeer` can deliver into it. */
export function installFakeSession(
  client: PeerSessionOwner,
  peerId: string,
  over: Record<string, unknown> = {},
): Record<string, unknown> {
  const c = client as unknown as {
    sessions: Map<string, Record<string, unknown>>;
  };
  const session: Record<string, unknown> = {
    attemptId: "a1",
    peerId,
    checkoutRouting: false,
    unreachableSince: 0,
    lastRecvAt: Date.now(),
    missedPongs: 0,
    pullsTree: false,
    terminalFramesV1: false,
    ...over,
  };
  c.sessions.set(peerId, session);
  return session;
}
