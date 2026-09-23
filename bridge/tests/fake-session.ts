// One established PeerSession, installed by hand for tests that need a client
// past the hello without running one. Everything flow-control reads lives ON
// the session now, so a hand-built one that omits a field fails deep inside
// `sendAppEnvelope` rather than at the seam — this keeps the shape in one place.
import type { PeerSessionOwner } from "../src/peer-session-owner";

/** Install a session for `peerId` directly — payloads are plaintext on the
 *  wire now, so there is no seal/open to fake. A queued frame reads straight
 *  off the wire and `TestPeerSessionOwner.sendFromPeer` can deliver into it.
 *  The scheduler and the rx window are built by the client's own factories: a
 *  test that stubbed them would be testing itself. */
export function installFakeSession(
  client: PeerSessionOwner,
  peerId: string,
  over: Record<string, unknown> = {},
): Record<string, unknown> {
  const c = client as unknown as {
    sessions: Map<string, Record<string, unknown>>;
    newSendScheduler(peerId: string): unknown;
  };
  const session: Record<string, unknown> = {
    attemptId: "a1",
    peerId,
    checkoutRouting: false,
    unreachableSince: 0,
    lastRecvAt: Date.now(),
    missedPongs: 0,
    frag: { accept: () => false, dispose: () => {} },
    scheduler: c.newSendScheduler(peerId),
    rxFlow: {
      consumed: { control: 0, preview: 0 },
      credited: { control: 0, preview: 0 },
    },
    stallWarned: {},
    pullsTree: false,
    terminalFramesV1: false,
    ...over,
  };
  c.sessions.set(peerId, session);
  return session;
}
