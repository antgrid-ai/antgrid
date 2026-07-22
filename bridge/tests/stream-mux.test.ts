// v3 stream multiplexing (design §7, plan B4/B6): one machine socket, project
// cores attach as opaque streamId-tagged streams. Two layers are covered here:
// StreamMux in isolation (against a stub transport — no crypto, no socket),
// and the real RelayClient wiring the envelope through seal/fragment/send so
// `s` provably survives the wire.
import { describe, test, expect, afterEach } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { buildFragments, encodeRouteFrame, FrameKind } from "antgrid-wire";
import { StreamMux, type StreamMuxTransport } from "../src/stream-mux";
import { MessageBus, type Channel } from "../src/message-bus";
import { createMessage } from "../src/protocol";
import { RelayClient } from "../src/relay-client";
import { generateEphemeralKeypair, deriveSharedSecret } from "../src/key-exchange";
import {
  buildTranscript, deriveSessionKeys, phoneConfirmTag,
  E2eTransport, signTranscript,
} from "../src/e2e";

function makeTransport() {
  const opened: string[] = [];
  const closed: string[] = [];
  const sent: Array<{ streamId: string; msg: unknown; channel: Channel }> = [];
  const transport: StreamMuxTransport = {
    openStream: (id) => opened.push(id),
    closeStream: (id) => closed.push(id),
    sendEnvelope: (id, msg, channel) => sent.push({ streamId: id, msg, channel }),
  };
  return { transport, opened, closed, sent };
}

describe("StreamMux (unit, stub transport)", () => {
  test("attach allocates a 16-hex streamId and sends stream-open", () => {
    const { transport, opened } = makeTransport();
    const mux = new StreamMux(transport);
    const handle = mux.attach(new MessageBus(), {});
    expect(handle.streamId).toMatch(/^[0-9a-f]{16}$/);
    expect(opened).toEqual([handle.streamId]);
  });

  test("onOpened resolves onAdmitted exactly once", () => {
    const { transport } = makeTransport();
    const mux = new StreamMux(transport);
    let admitted = 0;
    const handle = mux.attach(new MessageBus(), { onAdmitted: () => admitted++ });
    mux.onOpened(handle.streamId);
    mux.onOpened(handle.streamId); // already settled — no-op
    expect(admitted).toBe(1);
  });

  test("outbound bus traffic is tagged with this stream's id", () => {
    const { transport, sent } = makeTransport();
    const mux = new StreamMux(transport);
    const bus = new MessageBus();
    const handle = mux.attach(bus, {});
    const msg = createMessage("pong", {});
    bus.publish(msg, "control");
    expect(sent).toEqual([{ streamId: handle.streamId, msg, channel: "control" }]);
  });

  test("dispatchInbound routes a parsed AbMessage to the attached stream's bus", () => {
    const { transport } = makeTransport();
    const mux = new StreamMux(transport);
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((msg) => received.push(msg));
    const handle = mux.attach(bus, {});
    const msg = createMessage("pong", {});
    const ok = mux.dispatchInbound(handle.streamId, JSON.stringify(msg), "control");
    expect(ok).toBe(true);
    expect(received).toEqual([msg]);
  });

  test("dispatchInbound for an unknown streamId returns false so the caller drops + logs", () => {
    const { transport } = makeTransport();
    const mux = new StreamMux(transport);
    const ok = mux.dispatchInbound("deadbeefdeadbeef", JSON.stringify(createMessage("pong", {})), "control");
    expect(ok).toBe(false);
  });

  test("a stream-open rejection (SESSION_LIMIT_EXCEEDED) settles onRejected for that stream only — the transport and every other stream stay live", () => {
    const { transport, closed } = makeTransport();
    const mux = new StreamMux(transport);
    const rejectedA: Array<{ code: string; message: string }> = [];
    const admittedB: string[] = [];
    const a = mux.attach(new MessageBus(), { onRejected: (code, message) => rejectedA.push({ code, message }) });
    const b = mux.attach(new MessageBus(), { onAdmitted: (id) => admittedB.push(id) });

    expect(mux.onError(a.streamId, "SESSION_LIMIT_EXCEEDED", "cap reached")).toBe(true);
    expect(rejectedA).toEqual([{ code: "SESSION_LIMIT_EXCEEDED", message: "cap reached" }]);

    // Stream b is untouched — it can still be admitted independently, and
    // neither stream was closed as a side effect of the rejection.
    mux.onOpened(b.streamId);
    expect(admittedB).toEqual([b.streamId]);
    expect(closed).toEqual([]);

    // An id that isn't a live stream (e.g. a pair-request nonce) isn't ours —
    // the caller falls back to normal error handling.
    expect(mux.onError("not-a-stream-id", "SOME_CODE", "x")).toBe(false);
  });

  test("detach is idempotent", () => {
    const { transport, closed } = makeTransport();
    const mux = new StreamMux(transport);
    const handle = mux.attach(new MessageBus(), {});
    handle.detach();
    handle.detach();
    expect(closed).toEqual([handle.streamId]);
  });

  test("reopenAll re-sends stream-open for every attached stream (post-reconnect re-admission)", () => {
    const { transport, opened } = makeTransport();
    const mux = new StreamMux(transport);
    const a = mux.attach(new MessageBus(), {});
    const b = mux.attach(new MessageBus(), {});
    opened.length = 0;
    mux.reopenAll();
    expect(opened.sort()).toEqual([a.streamId, b.streamId].sort());
  });

  test("notifyPeerOnline/Offline/Unpaired broadcast to every attached stream; a late attach inherits an already-online session", () => {
    const { transport } = makeTransport();
    const mux = new StreamMux(transport);
    const events: string[] = [];
    mux.attach(new MessageBus(), {
      onPeerOnline: () => events.push("a-online"),
      onPeerOffline: () => events.push("a-offline"),
      onUnpaired: () => events.push("a-unpaired"),
    });
    mux.notifyPeerOnline();
    expect(events).toEqual(["a-online"]);

    // Drill-in: a stream attached while already established never sees a
    // fresh peer-online event, so attach() must fire it immediately.
    mux.attach(new MessageBus(), { onPeerOnline: () => events.push("b-online") });
    expect(events).toEqual(["a-online", "b-online"]);

    mux.notifyPeerOffline();
    expect(events).toContain("a-offline");
    mux.notifyUnpaired();
    expect(events).toContain("a-unpaired");
  });

  test("detachAll tears every stream down", () => {
    const { transport, closed } = makeTransport();
    const mux = new StreamMux(transport);
    const a = mux.attach(new MessageBus(), {});
    const b = mux.attach(new MessageBus(), {});
    mux.detachAll();
    expect(closed.sort()).toEqual([a.streamId, b.streamId].sort());
  });
});

// --- Integration: the real RelayClient driving the envelope over the wire ---

const AGENT_DEVICE_ID = "agent-1";
const PHONE_ID = "phone-1";

function ed25519Pair(): { seedB64: string; pubB64: string } {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    seedB64: Buffer.from(privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32)).toString("base64"),
    pubB64: Buffer.from(publicKey.export({ format: "der", type: "spki" }).subarray(-32)).toString("base64"),
  };
}

function injectFrame(client: RelayClient, kind: FrameKind, payload: Buffer, channel: Channel = "control"): void {
  const frame = encodeRouteFrame({ type: "message", from: PHONE_ID, channel }, payload, kind);
  (client as any).handleBinaryFrame(Buffer.from(frame));
}

let clients: RelayClient[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

/** Establish a real E2E session on a REAL (non-forTest) RelayClient and return
 *  the phone-side transport the test drives against it. Unlike forTest() —
 *  which stubs the mux to a no-op for handshake-only tests — this needs the
 *  real StreamMux wired to real sendJson/sendAppEnvelope, so it constructs the
 *  client normally and overrides `sendPayload` (same shadowing trick forTest
 *  uses) plus a stubbed OPEN socket so `sendJson`'s stream-open/close land in
 *  the same observable `sent` array as sealed application traffic. */
function establish(): { client: RelayClient; sent: Array<string | Buffer>; phoneTransport: E2eTransport } {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const sent: Array<string | Buffer> = [];
  const client = new RelayClient({
    url: "ws://127.0.0.1:1",
    identity: {
      deviceId: AGENT_DEVICE_ID, deviceName: "agent", createdAt: new Date().toISOString(),
      ed25519PublicKey: "unused", ed25519PrivateKey: agentEd.seedB64,
    },
    generateKeypair: generateEphemeralKeypair,
    getLicenseToken: () => "tok",
  });
  clients.push(client);
  (client as any)._peerId = PHONE_ID;
  (client as any).phoneEd25519ByDeviceId.set(PHONE_ID, phoneEd.pubB64);
  (client as any).sendPayload = (p: string | Buffer) => sent.push(p);
  (client as any).ws = { readyState: WebSocket.OPEN, send: (d: string) => sent.push(d), close: () => {} };

  const app = generateEphemeralKeypair();
  const nonce = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
  const clientPubkey = app.publicKey;
  const phoneTranscript = buildTranscript({
    registrationId: AGENT_DEVICE_ID, role: "phone", agentDeviceId: AGENT_DEVICE_ID, phoneDeviceId: PHONE_ID,
    agentX25519Pub: Buffer.alloc(0), phoneX25519Pub: clientPubkey, nonce,
  });
  const sig = signTranscript(phoneTranscript, Buffer.from(phoneEd.seedB64, "base64"));
  injectFrame(client, FrameKind.handshake, Buffer.from(JSON.stringify({
    type: "handshake:client-hello", attemptId: "a1", pubkey: clientPubkey.toString("base64"), nonce: nonce.toString("base64"), sig,
  })));

  const agentHello = JSON.parse(sent[0] as string);
  const agentPubkey = Buffer.from(agentHello.pubkey, "base64");
  const agentTranscript = buildTranscript({
    registrationId: AGENT_DEVICE_ID, role: "agent", agentDeviceId: AGENT_DEVICE_ID, phoneDeviceId: PHONE_ID,
    agentX25519Pub: agentPubkey, phoneX25519Pub: clientPubkey, nonce,
  });
  const sharedSecret = deriveSharedSecret(app.privateKey, agentPubkey);
  const keys = deriveSessionKeys(sharedSecret, agentTranscript);
  const phoneTransport = new E2eTransport({ sendKey: keys.p2a, recvKey: keys.a2p });

  const appReady = JSON.stringify({ type: "app:ready", attemptId: "a1", confirm: phoneConfirmTag(keys.confirm).toString("base64") });
  injectFrame(client, FrameKind.sealed, phoneTransport.seal(appReady));
  expect(client._handshakeComplete()).toBe(true);

  return { client, sent, phoneTransport };
}

describe("StreamMux over a live RelayClient (wire-level envelope tagging)", () => {
  test("attach opens a stream and onAdmitted resolves on stream-opened", () => {
    const { client, sent } = establish();
    const admitted: string[] = [];
    const handle = client.attachStream(new MessageBus(), { onAdmitted: (id) => admitted.push(id) });

    // attachStream sent a plaintext-JSON `stream-open` control message directly
    // on the socket (not sealed app traffic) — the mux's own wire frame.
    const openMsg = JSON.parse(sent.find((s) => typeof s === "string" && s.includes("stream-open")) as string);
    expect(openMsg).toEqual({ type: "stream-open", streamId: handle.streamId });

    (client as any).handleTextMessage(JSON.stringify({ type: "stream-opened", streamId: handle.streamId }));
    expect(admitted).toEqual([handle.streamId]);
  });

  test("outbound: a bus publish on an attached stream is sealed as {s: streamId, m: msg}", () => {
    const { client, sent, phoneTransport } = establish();
    const bus = new MessageBus();
    const handle = client.attachStream(bus, {});
    const sentBefore = sent.length;

    const msg = createMessage("pong", {});
    bus.publish(msg, "control");

    expect(sent.length).toBe(sentBefore + 1);
    const envelopeJson = phoneTransport.open(sent[sent.length - 1] as Buffer);
    const envelope = JSON.parse(envelopeJson!);
    expect(envelope.s).toBe(handle.streamId);
    expect(envelope.m).toEqual(msg);
  });

  test("inbound: a sealed {s: streamId, m} envelope is routed to the matching stream's bus", () => {
    const { client, phoneTransport } = establish();
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((m) => received.push(m));
    const handle = client.attachStream(bus, {});

    const msg = createMessage("pong", {});
    injectFrame(client, FrameKind.sealed, phoneTransport.seal(JSON.stringify({ s: handle.streamId, m: msg })));

    expect(received).toEqual([msg]);
  });

  test("inbound envelope for an unknown streamId is dropped (no stream sees it, no crash)", () => {
    const { client, phoneTransport } = establish();
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((m) => received.push(m));
    client.attachStream(bus, {});

    injectFrame(client, FrameKind.sealed, phoneTransport.seal(JSON.stringify({ s: "deadbeefdeadbeef", m: createMessage("pong", {}) })));

    expect(received).toEqual([]);
  });

  test("a fragmented inbound envelope reassembles with `s` intact", () => {
    const { client, phoneTransport } = establish();
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((m) => received.push(m));
    const handle = client.attachStream(bus, {});

    const bigMsg = createMessage("file:content", {
      projectId: "p1", path: "a.txt", content: "x".repeat(5000), size: 5000, encoding: "utf8",
    });
    const envelopeJson = JSON.stringify({ s: handle.streamId, m: bigMsg });
    // A tiny budget forces multiple fragments even for this modest payload.
    const frames = buildFragments(envelopeJson, "rx-1", undefined, 500);
    expect(frames.length).toBeGreaterThan(1);

    for (const frame of frames) {
      injectFrame(client, FrameKind.sealed, phoneTransport.seal(frame));
    }

    expect(received).toEqual([bigMsg]);
  });

  test("SESSION_LIMIT_EXCEEDED on one stream leaves the socket and a sibling stream fully live", () => {
    const { client } = establish();
    const rejected: Array<{ code: string; message: string }> = [];
    const admitted: string[] = [];
    const limited = client.attachStream(new MessageBus(), { onRejected: (code, message) => rejected.push({ code, message }) });
    const sibling = client.attachStream(new MessageBus(), { onAdmitted: (id) => admitted.push(id) });

    (client as any).handleErrorFrame({ code: "SESSION_LIMIT_EXCEEDED", message: "cap reached", retryable: false, ref: limited.streamId });
    (client as any).handleTextMessage(JSON.stringify({ type: "stream-opened", streamId: sibling.streamId }));

    expect(rejected).toEqual([{ code: "SESSION_LIMIT_EXCEEDED", message: "cap reached" }]);
    expect(admitted).toEqual([sibling.streamId]);
    // The rejection must not be recorded as the socket-level lastError.
    expect((client as any).lastError).toBeNull();
  });
});
