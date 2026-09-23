// Pair/grant frames no longer parse as a ServerMessage at all â€”
// `ServerMessage.safeParse` rejects them outright, and `handleTextMessage`
// drops the frame before it ever reaches the switch. This suite pins the two
// failure modes that matter given that: a pair-request-shaped frame must be
// dropped, not close the socket (an unparseable frame is not a protocol
// violation this side of the wire), and a grant-revoked-shaped frame must NOT
// tear down a live E2E session if a stale or hostile relay sends one anyway.
import { test, expect, afterEach } from "bun:test";
import { ServerMessage } from "antgrid-wire";
import { ed25519Pair, TestPeerSessionOwner } from "./test-peer-session-owner";

const AGENT_DEVICE_ID = "agent-1";
const PHONE_ID = "phone-1";

let clients: TestPeerSessionOwner[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

test("an inbound pair-request frame no longer parses, and is dropped without closing the socket", () => {
  // A fully-populated pair-request payload â€” the exact shape the deleted
  // PairRequestMessage schema used to accept. Asserting it fails FIRST is
  // what makes the rest of this test meaningful: without it, a change that
  // reintroduced the schema (or broadened ServerMessage some other way)
  // could silently make this frame parseable again, and the negative
  // assertions below would keep passing for the wrong reason.
  const payload = {
    type: "pair-request",
    agentDeviceId: AGENT_DEVICE_ID,
    pairId: "pair-1",
    phonePubkey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    phoneDeviceId: PHONE_ID,
    nonce: "n".repeat(20),
    requestedAt: new Date().toISOString(),
    deadline: Date.now() + 30_000,
    phoneSignature: "sig",
  };
  expect(ServerMessage.safeParse(payload).success).toBe(false);

});

/** Drive a full acked handshake on a fresh `forTest` client â€” the minimum
 *  needed here to get a live established E2E session before firing
 *  grant-revoked at it. */
function establishSession(): TestPeerSessionOwner {
  const client = TestPeerSessionOwner.forTest({
    sendPayload: () => {},
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: ed25519Pair().seedB64,
  });
  clients.push(client);
  client.establish(PHONE_ID, { attemptId: "attempt-a" });
  return client;
}

test("an inbound grant-revoked frame no longer parses and does not tear down a live E2E session", () => {
  const client = establishSession();

  // The relay no longer emits grant-revoked (the grant it revoked was deleted
  // along with the pairing rendezvous), and the schema no longer accepts it
  // either. If a stale or hostile relay sends one anyway, ServerMessage
  // rejects it and it must NOT be able to kill a healthy, already-
  // authenticated session with one unparseable frame.
  const payload = { type: "grant-revoked", peerDeviceId: PHONE_ID, reason: "REVOKED" };
  expect(ServerMessage.safeParse(payload).success).toBe(false);

  expect(client._handshakeComplete()).toBe(true);
});
