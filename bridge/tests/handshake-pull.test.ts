// Stage B: the crypto handshake (client-hello -> agent-hello -> agent-ready ->
// app:ready) is gone. Establishment is now a plaintext `session:hello` ->
// `established`, and identity comes from the QUIC/lease layer, not a
// transcript signature. Core hello mechanics — the pre-establishment drop,
// the lease refusal, strict per-peer frame attribution, the identical re-ack,
// the different-attemptId protocol violation, and newest-wins supersession —
// live in peer-session-hello.test.ts. This suite covers what a session
// carries once established: multi-device isolation, broadcast fan-out, and
// the liveness/offline lifecycle.
import { test, expect, afterEach, spyOn } from "bun:test";
import { TestPeerSessionOwner, ed25519Pair } from "./test-peer-session-owner";
import { MessageBus } from "../src/message-bus";

const AGENT_DEVICE_ID = "agent-1";
const PHONE_ID = "phone-1";
const PHONE_2_ID = "phone-2";

let clients: TestPeerSessionOwner[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

/** A bare forTest client. */
function freshClient(sent: Array<string | Buffer> = []): TestPeerSessionOwner {
  const client = TestPeerSessionOwner.forTest({
    sendPayload: (p) => sent.push(p),
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
  });
  clients.push(client);
  return client;
}

test("onHandshakeComplete fires with the established peer's id", () => {
  // Collected into an array rather than a nullable let: TS narrows a `let x = null`
  // to `null` at the assertion because it cannot see the callback run, and the
  // length also pins that promotion fires the callback exactly once.
  const seen: Array<{ peerId: string }> = [];
  const client = freshClient();
  (client as any).opts.onHandshakeComplete = ((peer: { peerId: string }) => { seen.push(peer); }) as () => void;
  client.establish(PHONE_ID, { attemptId: "attempt-a" });
  expect(seen).toEqual([{ peerId: PHONE_ID }]);
});

test("send() drops app messages when no session is established", () => {
  const client = freshClient();
  client.send({ type: "pong", id: "1", timestamp: 0 } as any);
  client.sendOnChannel({ type: "pong", id: "1", timestamp: 0 } as any, "control");
  expect(client.sentTo(PHONE_ID)).toHaveLength(0);
});

test("a tunnel:http-request on the session stream after establishment reaches no handler", () => {
  // Tunnel traffic rides its own QUIC stream now (A3); a `tunnel:http-request`
  // that still arrives on the session stream parses as no known AbMessage and
  // falls through to the ordinary drop, with nothing left to observe it.
  const client = freshClient();
  client.establish(PHONE_ID, { attemptId: "attempt-a" });
  const tunnelReq = { type: "tunnel:http-request", requestId: "req-1", port: 3000, method: "GET", path: "/" };

  expect(() => client.sendFromPeer(PHONE_ID, tunnelReq)).not.toThrow();
});

test("session:ping is answered with session:pong", () => {
  // Liveness ping/pong are the `session:ping`/`session:pong` names
  // (handleSessionFrame); the old bare `ping` AbMessage is ordinary
  // control-plane traffic and gets no automatic reply (see
  // peer-session-hello.test.ts's H4).
  const client = freshClient();
  client.establish(PHONE_ID, { attemptId: "attempt-a" });

  client.sendFromPeer(PHONE_ID, { type: "session:ping" });

  expect(client.readToPeer(PHONE_ID)).toEqual({ type: "session:pong" });
});

test("a session:pong from the app changes nothing and is not answered", () => {
  // The bridge never pings (QUIC keep-alive/idle is the liveness layer), so a
  // pong reaching it carries no state to update and earns no reply.
  const client = freshClient();
  client.establish(PHONE_ID, { attemptId: "attempt-a" });

  client.sendFromPeer(PHONE_ID, { type: "session:pong" });

  expect(client.sentTo(PHONE_ID)).toHaveLength(0);
  expect(client.peerSession(PHONE_ID)).not.toBeNull();
});

test("establishing a session schedules no interval and sends no ping", () => {
  // QUIC keep-alive/idle is the liveness layer; the bridge never arms a
  // sweep of its own and never speaks first. Driven off the raw hello (rather
  // than the `establish()` seam, which drops its own `established` reply from
  // the outbox) so every frame the owner sent during establishment is still
  // visible to inspect.
  const client = freshClient();
  const interval = spyOn(globalThis, "setInterval");
  try {
    (client as any).admitPeer(PHONE_ID, ed25519Pair().pubB64);
    client.sendFromPeer(PHONE_ID, { type: "session:hello", attemptId: "attempt-a" });
    expect(interval).not.toHaveBeenCalled();
  } finally {
    interval.mockRestore();
  }
  const sentTypes = client.sentTo(PHONE_ID).map((payload) => (JSON.parse(payload.toString("utf8")) as { type?: string }).type);
  expect(sentTypes).toContain("session:established");
  expect(sentTypes).not.toContain("session:ping");
});

test("a different device's session is admitted ALONGSIDE the live session, displacing nobody", () => {
  const client = freshClient();
  client.establish(PHONE_ID, { attemptId: "attempt-a" });
  const sessionA = (client as any).sessions.get(PHONE_ID);

  client.establish(PHONE_2_ID, { attemptId: "attempt-b" });

  // Phone A's session object is untouched: a second device is a peer, not a
  // successor.
  expect((client as any).sessions.get(PHONE_ID)).toBe(sessionA);
  expect(client.establishedPeers().map((p) => p.peerId)).toEqual([PHONE_ID, PHONE_2_ID]);
});

test("a tunnel:http-request from either admitted device reaches no handler, on the session stream", () => {
  const client = freshClient();
  client.establish(PHONE_ID, { attemptId: "attempt-a" });
  client.establish(PHONE_2_ID, { attemptId: "attempt-b" });

  const req = (requestId: string) => ({ type: "tunnel:http-request", requestId, port: 3000, method: "GET", path: "/" });
  expect(() => client.sendFromPeer(PHONE_ID, req("from-a"))).not.toThrow();
  expect(() => client.sendFromPeer(PHONE_2_ID, req("from-b"))).not.toThrow();
});

test("an outbound broadcast is sent once per established session", () => {
  const client = freshClient();
  client.establish(PHONE_ID, { attemptId: "attempt-a" });
  client.establish(PHONE_2_ID, { attemptId: "attempt-b" });

  // An outbound AbMessage rides the wire bare, with no `{s, m}` envelope.
  const msg = { type: "pong", id: "1", timestamp: 0 };
  client.send(msg as any);

  expect(client.readToPeer(PHONE_ID)).toEqual(msg);
  expect(client.readToPeer(PHONE_2_ID)).toEqual(msg);
});

test("native loss retires one session; the coarse peer-offline waits for the last", () => {
  const client = freshClient();
  client.establish(PHONE_ID, { attemptId: "attempt-a" });
  client.establish(PHONE_2_ID, { attemptId: "attempt-b" });

  const sessionGone: string[] = [];
  let coarseOffline = 0;
  client.attachStream(new MessageBus(), {
    onPeerSessionGone: (peerId) => sessionGone.push(peerId),
    onPeerOffline: () => { coarseOffline++; },
  });

  client.markPeerOffline(PHONE_ID);

  expect(sessionGone).toEqual([PHONE_ID]);
  expect(coarseOffline).toBe(0); // phone B is still driving the machine
  expect(client.peerSession(PHONE_ID)).toBeNull();
  expect(client.peerSession(PHONE_2_ID)).not.toBeNull();
  // The remaining native session keeps the machine-level handshake state live.
  expect(client._handshakeComplete()).toBe(true);

  client.markPeerOffline(PHONE_2_ID);

  expect(sessionGone).toEqual([PHONE_ID, PHONE_2_ID]);
  expect(coarseOffline).toBe(1); // fired exactly once, on the last one
});

test("a dropped session fires the coarse peer-offline only when it was the last", () => {
  const client = freshClient();
  client.establish(PHONE_ID, { attemptId: "attempt-a" });
  client.establish(PHONE_2_ID, { attemptId: "attempt-b" });

  let coarseOffline = 0;
  client.attachStream(new MessageBus(), { onPeerOffline: () => { coarseOffline++; } });

  (client as any).dropSession(PHONE_ID);

  expect((client as any).sessions.has(PHONE_ID)).toBe(false);
  expect(coarseOffline).toBe(0); // phone B's session is still live
  expect(client.establishedPeers().map((p) => p.peerId)).toEqual([PHONE_2_ID]);

  (client as any).dropSession(PHONE_2_ID);

  expect(client._handshakeComplete()).toBe(false);
  expect(coarseOffline).toBe(1);
});

// An unscoped id carries no claim about who it is for, and every pre-slot
// client sends one — it must never be read as another machine's.
test("loss for an unscoped peer id retires its native session", () => {
  const client = freshClient();
  client.establish(PHONE_ID, { attemptId: "attempt-a" });

  client.markPeerOffline(PHONE_ID);
  expect(client.peerSession(PHONE_ID)).toBeNull();
});
