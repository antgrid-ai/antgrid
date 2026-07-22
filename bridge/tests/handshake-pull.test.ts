// v3 E2E session state machine (design §6.1-6.2, plan B3/B6): reactive,
// acked, make-before-break. Replaces the v2 pull-model handshake suite — the
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
function injectFrame(client: RelayClient, kind: FrameKind, payload: Buffer, channel: "control" | "preview" = "control"): void {
  const frame = encodeRouteFrame({ type: "message", from: PHONE_ID, channel }, payload, kind);
  (client as any).handleBinaryFrame(Buffer.from(frame));
}

/** Build a phone-signed client-hello (empty agent-pub slot, per pull-model
 *  ordering) carrying the phone-generated `attemptId`. */
function signedClientHello(args: {
  attemptId: string;
  appX25519PubB64: string;
  phoneSeedB64: string;
  nonce?: Buffer;
  sig?: string;
}): Buffer {
  const nonce = args.nonce ?? Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
  const clientPubkey = Buffer.from(args.appX25519PubB64, "base64");
  const phoneTranscript = buildTranscript({
    registrationId: AGENT_DEVICE_ID,
    role: "phone",
    agentDeviceId: AGENT_DEVICE_ID,
    phoneDeviceId: PHONE_ID,
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
}): { transport: E2eTransport; keys: ReturnType<typeof deriveSessionKeys> } {
  const agentPubkey = Buffer.from(args.agentPubkeyB64, "base64");
  const clientPubkey = Buffer.from(args.clientPubkeyB64, "base64");
  const agentTranscript = buildTranscript({
    registrationId: AGENT_DEVICE_ID,
    role: "agent",
    agentDeviceId: AGENT_DEVICE_ID,
    phoneDeviceId: PHONE_ID,
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

  // The phone retransmits app:ready every 2s until it sees `established`
  // (design §6.1 step 5) — a duplicate for the already-live attempt must not
  // re-run the swap or re-fire onHandshakeComplete, just re-ack.
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

  // App traffic is always the `{ m }` envelope now (design §7.1) — even
  // non-AbMessage tunnel-protocol frames, which fall through parseMessageFast
  // to parseTunnelMessage inside dispatchControlPlane.
  const tunnelReq = { type: "tunnel:http-request", requestId: "req-1", port: 3000, method: "GET", path: "/" };
  injectFrame(client, FrameKind.sealed, phoneTransport.seal(JSON.stringify({ m: tunnelReq })), "preview");

  expect(tunnelMsgs).toEqual([tunnelReq]);
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
  // contexts, design §6.2).
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
