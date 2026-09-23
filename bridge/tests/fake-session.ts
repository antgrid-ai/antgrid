// One established PeerSession, installed by hand for tests that need a client
// past the handshake without running one. Everything flow-control reads lives
// ON the session now, so a hand-built one that omits a field fails deep inside
// `sendAppEnvelope` rather than at the seam — this keeps the shape in one place.
import type { PeerSessionOwner } from "../src/peer-session-owner";

/** Install a session for `peerId` whose seal and open are the identity, so a
 *  queued frame reads straight off the wire and `TestPeerSessionOwner.sendFromPeer`
 *  can deliver into it. The scheduler and the rx window are built by the
 *  client's own factories: a test that stubbed them would be testing itself. */
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
    transport: {
      seal: (plaintext: string) => Buffer.from(plaintext, "utf8"),
      open: (sealed: Buffer) => sealed.toString("utf8"),
      zeroize: () => {},
    },
    sessionKeys: { a2p: Buffer.alloc(32), p2a: Buffer.alloc(32), confirm: Buffer.alloc(32) },
    peerId,
    checkoutRouting: false,
    unreachableSince: 0,
    lastSealedRecvAt: Date.now(),
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
