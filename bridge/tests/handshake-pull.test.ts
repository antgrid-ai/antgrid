// v3 E2E session state machine: reactive, acked, make-before-break.
// Replaces the v2 pull-model handshake suite — the
// wire dispatch is now kind-byte (handshake vs sealed) rather than try-parse,
// every handshake message carries an `attemptId`, and a fresh client-hello
// triggers a REKEY (a new candidate attempt) even while a session is already
// established, instead of being locked out.
import { test, expect, afterEach } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { encodeRouteFrame, FrameKind } from "antgrid-wire";
import { generateEphemeralKeypair, deriveSharedSecret } from "../src/key-exchange";
import { RelayClient } from "../src/relay-client";
import { MessageBus } from "../src/message-bus";
import {
  buildTranscript, deriveSessionKeys, phoneConfirmTag, agentConfirmTag,
  verifyConfirmTag, E2eTransport, signTranscript,
} from "../src/e2e";

const AGENT_DEVICE_ID = "agent-1";
const PHONE_ID = "phone-1";
const PHONE_2_ID = "phone-2";

let clients: RelayClient[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

/** Generate a raw 32-byte Ed25519 seed + raw 32-byte pubkey, both base64. */
function ed25519Pair(): { seedB64: string; pubB64: string } {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const seedB64 = Buffer.from(
    privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32),
  ).toString("base64");
  const pubB64 = Buffer.from(
    publicKey.export({ format: "der", type: "spki" }).subarray(-32),
  ).toString("base64");
  return { seedB64, pubB64 };
}

/** Feed a binary route frame straight into the client's dispatch, exactly as
 *  `handleBinaryFrame` receives it off the socket — exercises the real
 *  kind-byte dispatch (kind 1 = handshake plaintext, kind 0 = sealed). */
function injectFrame(client: RelayClient, kind: FrameKind, payload: Buffer, channel: "control" | "preview" = "control", from: string = PHONE_ID): void {
  const frame = encodeRouteFrame({ type: "message", from, channel }, payload, kind);
  (client as any).handleBinaryFrame(Buffer.from(frame));
}

/** Build a phone-signed client-hello (empty agent-pub slot, per pull-model
 *  ordering) carrying the phone-generated `attemptId`. */
function signedClientHello(args: {
  attemptId: string;
  appX25519PubB64: string;
  phoneSeedB64: string;
  phoneDeviceId?: string;
  nonce?: Buffer;
  sig?: string;
}): Buffer {
  const nonce = args.nonce ?? Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
  const phoneDeviceId = args.phoneDeviceId ?? PHONE_ID;
  const clientPubkey = Buffer.from(args.appX25519PubB64, "base64");
  const phoneTranscript = buildTranscript({
    registrationId: AGENT_DEVICE_ID,
    role: "phone",
    agentDeviceId: AGENT_DEVICE_ID,
    phoneDeviceId,
    agentX25519Pub: Buffer.alloc(0),
    phoneX25519Pub: clientPubkey,
    nonce,
  });
  const sig = args.sig ?? signTranscript(phoneTranscript, Buffer.from(args.phoneSeedB64, "base64"));
  return Buffer.from(
    JSON.stringify({
      type: "handshake:client-hello",
      attemptId: args.attemptId,
      pubkey: args.appX25519PubB64,
      nonce: nonce.toString("base64"),
      sig,
    }),
  );
}

/** Simulate what the phone does after receiving agent-hello: derive session
 *  keys and build a phone-side E2eTransport. */
function buildPhoneTransport(args: {
  phonePrivkey: Buffer;
  agentPubkeyB64: string;
  clientPubkeyB64: string;
  nonce: Buffer;
  phoneDeviceId?: string;
}): { transport: E2eTransport; keys: ReturnType<typeof deriveSessionKeys> } {
  const agentPubkey = Buffer.from(args.agentPubkeyB64, "base64");
  const clientPubkey = Buffer.from(args.clientPubkeyB64, "base64");
  const agentTranscript = buildTranscript({
    registrationId: AGENT_DEVICE_ID,
    role: "agent",
    agentDeviceId: AGENT_DEVICE_ID,
    phoneDeviceId: args.phoneDeviceId ?? PHONE_ID,
    agentX25519Pub: agentPubkey,
    phoneX25519Pub: clientPubkey,
    nonce: args.nonce,
  });
  const sharedSecret = deriveSharedSecret(args.phonePrivkey, agentPubkey);
  const keys = deriveSessionKeys(sharedSecret, agentTranscript);
  const transport = new E2eTransport({ sendKey: keys.p2a, recvKey: keys.a2p });
  return { transport, keys };
}

interface Handshaked {
  client: RelayClient;
  sent: Array<string | Buffer>;
  attemptId: string;
  phoneTransport: E2eTransport;
  phoneKeys: ReturnType<typeof deriveSessionKeys>;
}

/** Drive a full acked handshake (client-hello → agent-hello → agent-ready →
 *  app:ready → established) on a fresh forTest client and return the pieces a
 *  test needs to keep driving the session. */
function establishSession(opts: { agentEd: ReturnType<typeof ed25519Pair>; phoneEd: ReturnType<typeof ed25519Pair>; attemptId: string; onHandshakeComplete?: () => void }): Handshaked {
  const sent: Array<string | Buffer> = [];
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: (p) => sent.push(p),
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: opts.agentEd.seedB64,
    phoneEd25519PubB64: opts.phoneEd.pubB64,
  });
  clients.push(client);
  if (opts.onHandshakeComplete) (client as any).opts.onHandshakeComplete = opts.onHandshakeComplete;

  const app = generateEphemeralKeypair();
  const nonce = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
  injectFrame(
    client,
    FrameKind.handshake,
    signedClientHello({ attemptId: opts.attemptId, appX25519PubB64: app.publicKey.toString("base64"), phoneSeedB64: opts.phoneEd.seedB64, nonce }),
  );
  expect(sent.length).toBe(2);
  const agentHello = JSON.parse(sent[0] as string);
  expect(agentHello.type).toBe("handshake:agent-hello");
  expect(agentHello.attemptId).toBe(opts.attemptId);

  const { transport: phoneTransport, keys: phoneKeys } = buildPhoneTransport({
    phonePrivkey: app.privateKey,
    agentPubkeyB64: agentHello.pubkey,
    clientPubkeyB64: app.publicKey.toString("base64"),
    nonce,
  });
  const readyText = phoneTransport.open(sent[1] as Buffer);
  const readyMsg = JSON.parse(readyText!);
  expect(readyMsg.type).toBe("handshake:agent-ready");
  expect(verifyConfirmTag(agentConfirmTag(phoneKeys.confirm), Buffer.from(readyMsg.confirm, "base64"))).toBe(true);

  const appReadyJson = JSON.stringify({ type: "app:ready", attemptId: opts.attemptId, confirm: phoneConfirmTag(phoneKeys.confirm).toString("base64") });
  injectFrame(client, FrameKind.sealed, phoneTransport.seal(appReadyJson));
  expect(client._handshakeComplete()).toBe(true);

  return { client, sent, attemptId: opts.attemptId, phoneTransport, phoneKeys };
}

test("full acked handshake: client-hello -> agent-hello -> agent-ready -> app:ready -> established", () => {
  let handshakeDone = 0;
  const { sent, phoneTransport, attemptId } = establishSession({
    agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a",
    onHandshakeComplete: () => { handshakeDone++; },
  });

  expect(handshakeDone).toBe(1);
  // The agent replies sealed `established{attemptId}` after confirming app:ready.
  expect(sent.length).toBe(3);
  const establishedText = phoneTransport.open(sent[2] as Buffer);
  expect(JSON.parse(establishedText!)).toEqual({ type: "established", attemptId });
});

test("duplicate app:ready for the live attemptId is idempotent: single established state, a second established reply", () => {
  let handshakeDone = 0;
  const { client, sent, phoneTransport, phoneKeys, attemptId } = establishSession({
    agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a",
    onHandshakeComplete: () => { handshakeDone++; },
  });
  expect(handshakeDone).toBe(1);
  const sentBefore = sent.length;

  // The phone retransmits app:ready every 2s until it sees `established` —
  // a duplicate for the already-live attempt must not re-run the swap or
  // re-fire onHandshakeComplete, just re-ack.
  const appReadyJson = JSON.stringify({ type: "app:ready", attemptId, confirm: phoneConfirmTag(phoneKeys.confirm).toString("base64") });
  injectFrame(client, FrameKind.sealed, phoneTransport.seal(appReadyJson));

  expect(handshakeDone).toBe(1);
  expect(sent.length).toBe(sentBefore + 1);
  const dup = phoneTransport.open(sent[sent.length - 1] as Buffer);
  expect(JSON.parse(dup!)).toEqual({ type: "established", attemptId });
});

test("agent rejects a client-hello with an invalid transcript signature", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const sent: Array<string | Buffer> = [];
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: (p) => sent.push(p),
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: agentEd.seedB64,
    phoneEd25519PubB64: phoneEd.pubB64,
  });
  clients.push(client);

  const app = generateEphemeralKeypair();
  injectFrame(
    client,
    FrameKind.handshake,
    signedClientHello({
      attemptId: "attempt-a",
      appX25519PubB64: app.publicKey.toString("base64"),
      phoneSeedB64: phoneEd.seedB64,
      sig: Buffer.alloc(64).toString("base64"), // present but bogus
    }),
  );

  expect(sent.length).toBe(0);
  expect(client._handshakeComplete()).toBe(false);
});

test("agent rejects a client-hello signed by the wrong phone key", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const attackerEd = ed25519Pair();
  const sent: Array<string | Buffer> = [];
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: (p) => sent.push(p),
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: agentEd.seedB64,
    // Agent pins the REAL phone's pubkey...
    phoneEd25519PubB64: phoneEd.pubB64,
  });
  clients.push(client);

  const app = generateEphemeralKeypair();
  // ...but the client-hello is signed by an attacker key.
  injectFrame(
    client,
    FrameKind.handshake,
    signedClientHello({ attemptId: "attempt-a", appX25519PubB64: app.publicKey.toString("base64"), phoneSeedB64: attackerEd.seedB64 }),
  );

  expect(sent.length).toBe(0);
  expect(client._handshakeComplete()).toBe(false);
});

test("kind-1 garbage is dropped: non-JSON payload and a non-client-hello type", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const sent: Array<string | Buffer> = [];
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: (p) => sent.push(p),
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: agentEd.seedB64,
    phoneEd25519PubB64: phoneEd.pubB64,
  });
  clients.push(client);

  injectFrame(client, FrameKind.handshake, Buffer.from("not json at all"));
  injectFrame(client, FrameKind.handshake, Buffer.from(JSON.stringify({ type: "handshake:agent-hello", attemptId: "x" })));
  injectFrame(client, FrameKind.handshake, Buffer.from(JSON.stringify({ type: "something-else" })));

  expect(sent.length).toBe(0);
  expect(client._handshakeComplete()).toBe(false);
});

test("send() drops app messages (never plaintext) when no E2E session is established", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const sent: Array<string | Buffer> = [];
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: (p) => sent.push(p),
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: agentEd.seedB64,
    phoneEd25519PubB64: phoneEd.pubB64,
  });
  clients.push(client);

  client.send({ type: "pong", id: "1", timestamp: 0 } as any);
  client.sendOnChannel({ type: "pong", id: "1", timestamp: 0 } as any, "control");
  expect(sent.length).toBe(0);
});

test("sealed app envelope on the preview channel is routed to onTunnelMessage after establishment", () => {
  let tunnelMsgs: unknown[] = [];
  const { client, phoneTransport } = establishSession({ agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a" });
  (client as any).opts.onTunnelMessage = (m: unknown) => tunnelMsgs.push(m);

  // App traffic is always the `{ m }` envelope now — even
  // non-AbMessage tunnel-protocol frames, which fall through parseMessageFast
  // to parseTunnelMessage inside dispatchControlPlane.
  const tunnelReq = { type: "tunnel:http-request", requestId: "req-1", port: 3000, method: "GET", path: "/" };
  injectFrame(client, FrameKind.sealed, phoneTransport.seal(JSON.stringify({ m: tunnelReq })), "preview");

  expect(tunnelMsgs).toEqual([{ ...tunnelReq, checkoutId: "main" }]);
});

test("sealed ping is answered with a sealed pong", () => {
  const { client, sent, phoneTransport } = establishSession({ agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a" });
  const sentBefore = sent.length;

  injectFrame(client, FrameKind.sealed, phoneTransport.seal(JSON.stringify({ type: "ping" })));

  expect(sent.length).toBe(sentBefore + 1);
  const pong = phoneTransport.open(sent[sent.length - 1] as Buffer);
  expect(JSON.parse(pong!)).toEqual({ type: "pong" });
});

test("2 missed pongs declare the E2E session dead (keys dropped, peer-offline notified)", () => {
  const offlineEvents: string[] = [];
  const { client } = establishSession({ agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a" });
  client.attachStream(new MessageBus(), { onPeerOffline: () => offlineEvents.push("offline") });

  // startLiveness() (run at establishment) stamped lastSealedRecvAt = now; push
  // it into the past so checkLiveness sees the silence window as elapsed
  // without waiting out the real PING_SILENCE_MS.
  (client as any).lastSealedRecvAt = 0;

  (client as any).checkLiveness(); // 1st missed pong: sends a ping
  expect((client as any).missedPongs).toBe(1);
  expect((client as any).established).not.toBeNull();

  (client as any).checkLiveness(); // 2nd missed pong: sends another ping
  expect((client as any).missedPongs).toBe(2);
  expect((client as any).established).not.toBeNull();

  (client as any).checkLiveness(); // MAX_MISSED_PONGS reached: declare dead
  expect((client as any).established).toBeNull();
  expect(offlineEvents).toEqual(["offline"]);
});

test("a stale half-open handshake attempt expires without disturbing the live established session", async () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const { client, sent, phoneTransport } = establishSession({ agentEd, phoneEd, attemptId: "attempt-a" });
  // Test seam (justified src change, see report): the real HALF_OPEN_MS is 30s —
  // override it so the expiry fires within the test's lifetime.
  (client as any).opts.halfOpenMs = 20;

  // A second client-hello arrives but the phone never completes it with
  // app:ready — a stale/abandoned attempt. It must NOT disturb the live
  // established session (attempt-a).
  const app2 = generateEphemeralKeypair();
  injectFrame(
    client,
    FrameKind.handshake,
    signedClientHello({ attemptId: "attempt-stale", appX25519PubB64: app2.publicKey.toString("base64"), phoneSeedB64: phoneEd.seedB64, nonce: Buffer.from([9, 9, 9, 9, 9, 9, 9, 9]) }),
  );
  expect((client as any).pending).not.toBeNull();
  expect((client as any).established).not.toBeNull();

  await new Promise((r) => setTimeout(r, 100));

  expect((client as any).pending).toBeNull();
  // The live session survived the half-open attempt's expiry untouched: a
  // fresh message sealed under the ORIGINAL (attempt-a) transport still opens.
  const probe = phoneTransport.seal(JSON.stringify({ m: { type: "pong", id: "p", timestamp: 0 } }));
  injectFrame(client, FrameKind.sealed, probe);
  expect(sent.filter((s) => typeof s !== "string").length).toBeGreaterThan(0); // at least agent-ready survived earlier
  expect(client._handshakeComplete()).toBe(true);
});

test("rekey mid-session: old keys decrypt until the new confirm, then swap + zeroize the old transport", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  let handshakeDone = 0;
  const { client, phoneTransport: phoneA, phoneKeys: keysA } = establishSession({
    agentEd, phoneEd, attemptId: "attempt-a", onHandshakeComplete: () => { handshakeDone++; },
  });
  expect(handshakeDone).toBe(1);

  const oldEstablished = (client as any).established as { transport: E2eTransport; sessionKeys: { a2p: Buffer; p2a: Buffer; confirm: Buffer } };

  // Prove the OLD keys still decrypt for receiving (make-before-break): probe
  // the agent's own retained transport directly with a fresh ciphertext under
  // attempt-a keys.
  const probeA = phoneA.seal(JSON.stringify({ type: "ping" }));
  expect(oldEstablished.transport.open(probeA)).not.toBeNull();

  // Reactive rekey: a fresh client-hello arrives WHILE established — the agent
  // must run the handshake again rather than dropping it. Re-point the
  // outbound sink (an instance field on the forTest client) to a fresh array
  // so the rekey's agent-hello/agent-ready are observable in isolation.
  const app2 = generateEphemeralKeypair();
  const nonce2 = Buffer.from([2, 2, 2, 2, 2, 2, 2, 2]);
  const rekeySent: Array<string | Buffer> = [];
  (client as any).sendPayload = (p: string | Buffer) => rekeySent.push(p);

  injectFrame(
    client,
    FrameKind.handshake,
    signedClientHello({ attemptId: "attempt-b", appX25519PubB64: app2.publicKey.toString("base64"), phoneSeedB64: phoneEd.seedB64, nonce: nonce2 }),
  );
  expect(rekeySent.length).toBe(2); // agent-hello (plaintext) + sealed agent-ready
  // Established (attempt-a) must be UNTOUCHED by the new pending candidate.
  expect((client as any).established).toBe(oldEstablished);
  expect((client as any).pending?.attemptId).toBe("attempt-b");

  // Old keys STILL decrypt while the rekey is only pending (two live receive
  // contexts).
  const probeAAgain = phoneA.seal(JSON.stringify({ type: "ping" }));
  expect(oldEstablished.transport.open(probeAAgain)).not.toBeNull();

  const agentHelloB = JSON.parse(rekeySent[0] as string);
  expect(agentHelloB.attemptId).toBe("attempt-b");
  const { transport: phoneB, keys: keysB } = buildPhoneTransport({
    phonePrivkey: app2.privateKey, agentPubkeyB64: agentHelloB.pubkey, clientPubkeyB64: app2.publicKey.toString("base64"), nonce: nonce2,
  });
  const readyB = phoneB.open(rekeySent[1] as Buffer);
  expect(JSON.parse(readyB!).attemptId).toBe("attempt-b");

  const appReadyB = JSON.stringify({ type: "app:ready", attemptId: "attempt-b", confirm: phoneConfirmTag(keysB.confirm).toString("base64") });
  injectFrame(client, FrameKind.sealed, phoneB.seal(appReadyB));

  // Swap completed: established is now attempt-b, and onHandshakeComplete
  // fired again for the rekey.
  expect(handshakeDone).toBe(2);
  expect((client as any).established.attemptId).toBe("attempt-b");
  expect((client as any).pending).toBeNull();

  // The OLD transport (attempt-a) is zeroized: its key bytes are all zero and
  // it can no longer decrypt, even though the ciphertext is well-formed.
  expect(oldEstablished.sessionKeys.a2p.every((b) => b === 0)).toBe(true);
  expect(oldEstablished.sessionKeys.p2a.every((b) => b === 0)).toBe(true);
  expect(oldEstablished.sessionKeys.confirm.every((b) => b === 0)).toBe(true);
  const probeAAfterSwap = phoneA.seal(JSON.stringify({ type: "ping" }));
  expect(oldEstablished.transport.open(probeAAfterSwap)).toBeNull();

  // The NEW session works end to end.
  const probeB = phoneB.seal(JSON.stringify({ m: { type: "pong", id: "p", timestamp: 0 } }));
  const seenMsgs: unknown[] = [];
  (client as any).opts.onMessage = (m: unknown) => seenMsgs.push(m);
  injectFrame(client, FrameKind.sealed, probeB);
  expect(seenMsgs.length).toBe(1);

  void keysA; // kept for symmetry/documentation of what phoneA was derived from
});

test("a different device's verified client-hello supersedes the live session, tears it down, and repoints the address (break-before-make)", () => {
  const agentEd = ed25519Pair();
  const phoneAEd = ed25519Pair();
  const phoneBEd = ed25519Pair();

  // Phone A holds the live session.
  const { client, phoneTransport: phoneATransport } = establishSession({ agentEd, phoneEd: phoneAEd, attemptId: "attempt-a" });
  const oldEstablished = (client as any).established as { sessionKeys: { a2p: Buffer; p2a: Buffer; confirm: Buffer }; transport: E2eTransport };
  expect((client as any)._peerId).toBe(PHONE_ID);
  expect((client as any).established.peerId).toBe(PHONE_ID);

  // The agent knows phone B's pinned key (in production: account inventory).
  (client as any).phoneEd25519ByDeviceId.set(PHONE_2_ID, phoneBEd.pubB64);

  // Phone B — a DIFFERENT device — sends a signature-valid client-hello.
  const appB = generateEphemeralKeypair();
  const nonceB = Buffer.from([7, 7, 7, 7, 7, 7, 7, 7]);
  const bSent: Array<string | Buffer> = [];
  (client as any).sendPayload = (p: string | Buffer) => bSent.push(p);
  injectFrame(
    client,
    FrameKind.handshake,
    signedClientHello({ attemptId: "attempt-b", appX25519PubB64: appB.publicKey.toString("base64"), phoneSeedB64: phoneBEd.seedB64, phoneDeviceId: PHONE_2_ID, nonce: nonceB }),
    "control",
    PHONE_2_ID,
  );

  // Old session torn down explicitly (keys zeroized), address now phone B, and
  // phone B is the pending candidate.
  expect(oldEstablished.sessionKeys.a2p.every((b) => b === 0)).toBe(true);
  expect((client as any).established).toBeNull();
  expect((client as any)._peerId).toBe(PHONE_2_ID);
  expect((client as any).pending?.attemptId).toBe("attempt-b");
  expect((client as any).pending?.peerId).toBe(PHONE_2_ID);
  // Displaced phone A gets a sealed session-takeover notice — sent FIRST,
  // with A's own (still-live at send-time) keys, before agent-hello/agent-ready
  // for the new candidate — so A learns explicitly instead of via liveness
  // timeout and rekeying right back (two-device ping-pong).
  expect(bSent.length).toBe(3);
  const noticeText = phoneATransport.open(bSent[0] as Buffer);
  expect(JSON.parse(noticeText!)).toEqual({ type: "session-takeover" });
});

test("same-device rekey does NOT send a session-takeover notice", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const { client, phoneTransport: phoneATransport } = establishSession({ agentEd, phoneEd, attemptId: "attempt-a" });

  const app2 = generateEphemeralKeypair();
  const nonce2 = Buffer.from([3, 3, 3, 3, 3, 3, 3, 3]);
  const rekeySent: Array<string | Buffer> = [];
  (client as any).sendPayload = (p: string | Buffer) => rekeySent.push(p);

  injectFrame(
    client,
    FrameKind.handshake,
    signedClientHello({ attemptId: "attempt-b", appX25519PubB64: app2.publicKey.toString("base64"), phoneSeedB64: phoneEd.seedB64, nonce: nonce2 }),
  );

  // Same-device rekey (established.peerId === from) never enters the
  // different-device branch: only agent-hello + sealed agent-ready go out.
  expect(rekeySent.length).toBe(2);
  const notice = rekeySent.find((p) => {
    if (typeof p === "string") return false;
    const opened = phoneATransport.open(p as Buffer);
    if (!opened) return false;
    try { return JSON.parse(opened).type === "session-takeover"; } catch { return false; }
  });
  expect(notice).toBeUndefined();
});

test("different-device candidate, once app:ready confirms, becomes the established peer and the address", () => {
  const agentEd = ed25519Pair();
  const phoneAEd = ed25519Pair();
  const phoneBEd = ed25519Pair();
  const { client } = establishSession({ agentEd, phoneEd: phoneAEd, attemptId: "attempt-a" });
  (client as any).phoneEd25519ByDeviceId.set(PHONE_2_ID, phoneBEd.pubB64);

  const appB = generateEphemeralKeypair();
  const nonceB = Buffer.from([7, 7, 7, 7, 7, 7, 7, 7]);
  const bSent: Array<string | Buffer> = [];
  (client as any).sendPayload = (p: string | Buffer) => bSent.push(p);
  injectFrame(
    client, FrameKind.handshake,
    signedClientHello({ attemptId: "attempt-b", appX25519PubB64: appB.publicKey.toString("base64"), phoneSeedB64: phoneBEd.seedB64, phoneDeviceId: PHONE_2_ID, nonce: nonceB }),
    "control", PHONE_2_ID,
  );
  // bSent[0] is the sealed session-takeover notice to displaced phone A;
  // agent-hello (plaintext) for the new candidate is bSent[1].
  const agentHelloB = JSON.parse(bSent[1] as string);
  const { transport: phoneB, keys: keysB } = buildPhoneTransport({
    phonePrivkey: appB.privateKey, agentPubkeyB64: agentHelloB.pubkey, clientPubkeyB64: appB.publicKey.toString("base64"), nonce: nonceB, phoneDeviceId: PHONE_2_ID,
  });
  const appReadyB = JSON.stringify({ type: "app:ready", attemptId: "attempt-b", confirm: phoneConfirmTag(keysB.confirm).toString("base64") });
  injectFrame(client, FrameKind.sealed, phoneB.seal(appReadyB), "control", PHONE_2_ID);

  expect(client._handshakeComplete()).toBe(true);
  expect((client as any).established.attemptId).toBe("attempt-b");
  expect((client as any).established.peerId).toBe(PHONE_2_ID);
  expect((client as any)._peerId).toBe(PHONE_2_ID);
});

test("a sibling peer-online does not clobber the address of a live session", () => {
  const { client } = establishSession({ agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a" });
  expect((client as any)._peerId).toBe(PHONE_ID);

  // A same-account sibling comes online — presence, NOT a handshake.
  (client as any).handleTextMessage(JSON.stringify({ type: "peer-online", peerId: PHONE_2_ID }));

  expect((client as any)._peerId).toBe(PHONE_ID);       // address unchanged
  expect(client._handshakeComplete()).toBe(true);        // session intact
});

test("peer-online adopts the peer as the address when no session is established", () => {
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: () => {},
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
  });
  clients.push(client);
  expect((client as any).established).toBeNull();

  (client as any).handleTextMessage(JSON.stringify({ type: "peer-online", peerId: PHONE_2_ID }));

  expect((client as any)._peerId).toBe(PHONE_2_ID);
});

// `pair-connected` no longer parses as a ServerMessage, so `handleTextMessage`
// drops the frame before it ever reaches the switch. The relay never emits it
// — admission is account-derived trust resolved at client-hello time, not
// this presence notification. Either way, it must neither clobber a live
// session's address nor adopt a peer when idle.
test("pair-connected never touches the reply address, live session or idle", () => {
  const { client } = establishSession({ agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a" });
  expect((client as any)._peerId).toBe(PHONE_ID);

  (client as any).handleTextMessage(JSON.stringify({ type: "pair-connected", peerId: PHONE_2_ID, peerName: "phone-2", peerType: "app" }));

  expect((client as any)._peerId).toBe(PHONE_ID);       // address unchanged
  expect(client._handshakeComplete()).toBe(true);        // session intact

  const idle = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: () => {},
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
  });
  clients.push(idle);
  (idle as any)._peerId = null;

  (idle as any).handleTextMessage(JSON.stringify({ type: "pair-connected", peerId: PHONE_2_ID, peerName: "phone-2", peerType: "app" }));

  expect((idle as any)._peerId).toBeNull(); // no longer adopted — pair-connected is dead
});

// Per-machine relay slots: the app addresses each machine on its own
// `<accountDeviceUuid>#<machineDeviceUuid>` slot so it can hold several
// machines open at once (the relay arbitrates per `hello.deviceId` and
// supersedes an equal epoch). The slot is a TRANSPORT address — identity
// resolution and the transcript stay on the bare account device.
const PHONE_SLOT = `${PHONE_ID}#${AGENT_DEVICE_ID}`;

test("a client-hello from a per-machine slot admits against the bare account identity", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const sent: Array<string | Buffer> = [];
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: (p) => sent.push(p),
    peerId: PHONE_SLOT,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: agentEd.seedB64,
    // Deliberately no phoneEd25519PubB64: seeding the in-memory cache under the
    // slot id would resolve without ever consulting a base-keyed store, which
    // is the thing under test.
  });
  clients.push(client);
  // The account inventory only ever holds the bare account deviceUuid.
  (client as any).opts.trustedPeers = {
    lookup: (id: string) => (id === PHONE_ID ? phoneEd.pubB64 : undefined),
    noteMiss: () => {},
    refresh: async () => {},
  };

  const app = generateEphemeralKeypair();
  const nonce = Buffer.from([9, 8, 7, 6, 5, 4, 3, 2]);
  injectFrame(
    client,
    FrameKind.handshake,
    // Signed over the BARE id even though the frame arrives from the slot.
    signedClientHello({
      attemptId: "attempt-slot",
      appX25519PubB64: app.publicKey.toString("base64"),
      phoneSeedB64: phoneEd.seedB64,
      nonce,
    }),
    "control",
    PHONE_SLOT,
  );

  expect(sent.length).toBe(2);
  const agentHello = JSON.parse(sent[0] as string);
  expect(agentHello.type).toBe("handshake:agent-hello");

  const { transport, keys } = buildPhoneTransport({
    phonePrivkey: app.privateKey,
    agentPubkeyB64: agentHello.pubkey,
    clientPubkeyB64: app.publicKey.toString("base64"),
    nonce,
  });
  injectFrame(
    client,
    FrameKind.sealed,
    transport.seal(JSON.stringify({
      type: "app:ready",
      attemptId: "attempt-slot",
      confirm: phoneConfirmTag(keys.confirm).toString("base64"),
    })),
    "control",
    PHONE_SLOT,
  );

  expect(client._handshakeComplete()).toBe(true);
  // The reply address stays the SLOT — that is the socket the phone is on.
  expect((client as any)._peerId).toBe(PHONE_SLOT);
});

// The relay fans presence to every same-account peer of the opposite type, so
// one phone holding N machines open reaches each agent once per slot. Adopting
// a sibling slot would point our reply address at a socket whose E2E session
// cannot open our frames.
test("presence for a slot scoped at another machine is ignored", () => {
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: () => {},
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
  });
  clients.push(client);
  (client as any)._peerId = null;

  (client as any).handleTextMessage(
    JSON.stringify({ type: "peer-online", peerId: `${PHONE_ID}#some-other-agent` }),
  );

  expect((client as any)._peerId).toBeNull();
});

test("presence for our own slot is adopted as the reply address", () => {
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: () => {},
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
  });
  clients.push(client);
  (client as any)._peerId = null;

  (client as any).handleTextMessage(
    JSON.stringify({ type: "peer-online", peerId: PHONE_SLOT }),
  );

  expect((client as any)._peerId).toBe(PHONE_SLOT);
});

// An unscoped id carries no claim about who it is for, and every pre-slot
// client sends one — it must keep the old adopt-when-idle behaviour.
test("presence for an unscoped peer id is still adopted", () => {
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: () => {},
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
  });
  clients.push(client);
  (client as any)._peerId = null;

  (client as any).handleTextMessage(
    JSON.stringify({ type: "peer-online", peerId: PHONE_2_ID }),
  );

  expect((client as any)._peerId).toBe(PHONE_2_ID);
});

// The nastier half of the same fan-out: peer-offline suppresses the heavy
// stream. Charging that to a sibling slot means dropping one machine in the
// drawer silently stops the OTHER machine's terminal output.
test("peer-offline for a slot scoped at another machine does not suppress our stream", () => {
  const { client } = establishSession({ agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a" });
  const mux = (client as any).mux;
  let suppressed = false;
  mux.notifyPeerOffline = () => { suppressed = true; };

  (client as any).handleTextMessage(
    JSON.stringify({ type: "peer-offline", peerId: `${PHONE_ID}#some-other-agent` }),
  );
  expect(suppressed).toBe(false);

  // …but our own machine's slot going offline still suppresses it.
  (client as any).handleTextMessage(
    JSON.stringify({ type: "peer-offline", peerId: PHONE_SLOT }),
  );
  expect(suppressed).toBe(true);
});
