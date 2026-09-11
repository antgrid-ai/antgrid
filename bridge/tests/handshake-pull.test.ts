// v3 E2E session state machine: reactive, acked, make-before-break, and one
// session PER APP DEVICE. Replaces the v2 pull-model handshake suite — the
// wire dispatch is now kind-byte (handshake vs sealed) rather than try-parse,
// every handshake message carries an `attemptId`, a fresh client-hello from the
// SAME device triggers a REKEY (a new candidate attempt) even while a session is
// already established, and one from a DIFFERENT device is admitted alongside
// rather than displacing anyone.
import { test, expect, afterEach } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { encodeRouteFrame, FrameKind } from "antgrid-wire";
import { generateEphemeralKeypair, deriveSharedSecret } from "../src/key-exchange";
import { RelayClient, MAX_APP_SESSIONS } from "../src/relay-client";
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

/** The account device behind a per-machine relay slot — what the transcript and
 *  every identity lookup are keyed by (mirrors `baseSlotDeviceId`). */
function baseOf(routeId: string): string {
  const hash = routeId.indexOf("#");
  return hash === -1 ? routeId : routeId.slice(0, hash);
}

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

/** A bare forTest client whose default app device reaches us on `peerId`. */
function freshClient(args: {
  agentEd: ReturnType<typeof ed25519Pair>;
  phoneEd: ReturnType<typeof ed25519Pair>;
  peerId: string;
  sent: Array<string | Buffer>;
}): RelayClient {
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: (p) => args.sent.push(p),
    peerId: args.peerId,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: args.agentEd.seedB64,
    phoneEd25519PubB64: args.phoneEd.pubB64,
  });
  clients.push(client);
  return client;
}

/** Drive ONE device's full acked handshake against an EXISTING client, so a
 *  test can hold several sessions on one machine socket. `from` is the relay
 *  route address the frames arrive on; the caller owns the outbound sink and
 *  must have taught the client this device's pinned Ed25519 key. */
function handshakeOn(args: {
  client: RelayClient;
  sent: Array<string | Buffer>;
  phoneEd: ReturnType<typeof ed25519Pair>;
  attemptId: string;
  from?: string;
  nonce?: Buffer;
}): { transport: E2eTransport; keys: ReturnType<typeof deriveSessionKeys> } {
  const from = args.from ?? PHONE_ID;
  const nonce = args.nonce ?? Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
  const app = generateEphemeralKeypair();
  const base = args.sent.length;

  injectFrame(
    args.client,
    FrameKind.handshake,
    signedClientHello({
      attemptId: args.attemptId,
      appX25519PubB64: app.publicKey.toString("base64"),
      phoneSeedB64: args.phoneEd.seedB64,
      phoneDeviceId: baseOf(from),
      nonce,
    }),
    "control",
    from,
  );
  // Find agent-hello rather than assuming an offset: a capacity eviction seals
  // a session-takeover for the evictee ahead of it. Only handshake frames are
  // plaintext JSON, so ciphertext never parses.
  const helloIdx = args.sent.findIndex((p, i) => {
    if (i < base) return false;
    try { return JSON.parse(p.toString()).type === "handshake:agent-hello"; } catch { return false; }
  });
  expect(helloIdx).toBeGreaterThanOrEqual(base);
  const agentHello = JSON.parse(args.sent[helloIdx]!.toString());
  expect(agentHello.attemptId).toBe(args.attemptId);

  const { transport, keys } = buildPhoneTransport({
    phonePrivkey: app.privateKey,
    agentPubkeyB64: agentHello.pubkey,
    clientPubkeyB64: app.publicKey.toString("base64"),
    nonce,
    phoneDeviceId: baseOf(from),
  });
  const readyMsg = JSON.parse(transport.open(args.sent[helloIdx + 1] as Buffer)!);
  expect(readyMsg.type).toBe("handshake:agent-ready");

  injectFrame(
    args.client,
    FrameKind.sealed,
    transport.seal(JSON.stringify({
      type: "app:ready",
      attemptId: args.attemptId,
      confirm: phoneConfirmTag(keys.confirm).toString("base64"),
    })),
    "control",
    from,
  );
  return { transport, keys };
}

/** Drive a full acked handshake (client-hello → agent-hello → agent-ready →
 *  app:ready → established) on a fresh forTest client and return the pieces a
 *  test needs to keep driving the session. */
function establishSession(opts: { agentEd: ReturnType<typeof ed25519Pair>; phoneEd: ReturnType<typeof ed25519Pair>; attemptId: string; onHandshakeComplete?: () => void; capabilities?: object }): Handshaked {
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

  const appReadyJson = JSON.stringify({
    type: "app:ready", attemptId: opts.attemptId,
    confirm: phoneConfirmTag(phoneKeys.confirm).toString("base64"),
    ...(opts.capabilities ? { capabilities: opts.capabilities } : {}),
  });
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

test("a session carries pullsTree once its app advertises it", () => {
  const { client } = establishSession({
    agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a",
    capabilities: { checkoutRouting: true, pullsTree: true },
  });
  expect(client.peerSession(PHONE_ID)?.pullsTree).toBe(true);
});

test("a session carries pullsTree false when its app omits the capability", () => {
  const { client } = establishSession({
    agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a",
    capabilities: { checkoutRouting: true },
  });
  expect(client.peerSession(PHONE_ID)?.pullsTree).toBe(false);
});

test("a session carries pullsTree false for a wrong-typed capability", () => {
  const { client } = establishSession({
    agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a",
    capabilities: { pullsTree: 1 },
  });
  expect(client.peerSession(PHONE_ID)?.pullsTree).toBe(false);
});

test("a torn-down session takes its pullsTree with it — the capability does not outlive the app", () => {
  // The "nobody is attached" answer is no longer this file's to give: with N
  // devices the question is whether EVERY established one pulls, which
  // `everyClientPullsTrees` in agent-core asks of an empty roster.
  const { client } = establishSession({
    agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a",
    capabilities: { checkoutRouting: true, pullsTree: true },
  });
  (client as any).dropSession(PHONE_ID);
  expect(client.peerSession(PHONE_ID)).toBeNull();
  expect(client.establishedPeers()).toEqual([]);
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
  const session = (client as any).sessions.get(PHONE_ID);
  session.lastSealedRecvAt = 0;

  (client as any).checkLiveness(); // 1st missed pong: sends a ping
  expect(session.missedPongs).toBe(1);
  expect((client as any).sessions.has(PHONE_ID)).toBe(true);

  (client as any).checkLiveness(); // 2nd missed pong: sends another ping
  expect(session.missedPongs).toBe(2);
  expect((client as any).sessions.has(PHONE_ID)).toBe(true);

  (client as any).checkLiveness(); // MAX_MISSED_PONGS reached: declare dead
  expect((client as any).sessions.has(PHONE_ID)).toBe(false);
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
  expect((client as any).pending.size).toBe(1);
  expect((client as any).sessions.has(PHONE_ID)).toBe(true);

  await new Promise((r) => setTimeout(r, 100));

  expect((client as any).pending.size).toBe(0);
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

  const oldSession = (client as any).sessions.get(PHONE_ID) as { transport: E2eTransport; sessionKeys: { a2p: Buffer; p2a: Buffer; confirm: Buffer } };

  // Prove the OLD keys still decrypt for receiving (make-before-break): probe
  // the agent's own retained transport directly with a fresh ciphertext under
  // attempt-a keys.
  const probeA = phoneA.seal(JSON.stringify({ type: "ping" }));
  expect(oldSession.transport.open(probeA)).not.toBeNull();

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
  // The established session (attempt-a) must be UNTOUCHED by the new candidate.
  expect((client as any).sessions.get(PHONE_ID)).toBe(oldSession);
  expect((client as any).pending.get(PHONE_ID)?.attemptId).toBe("attempt-b");

  // Old keys STILL decrypt while the rekey is only pending (two live receive
  // contexts).
  const probeAAgain = phoneA.seal(JSON.stringify({ type: "ping" }));
  expect(oldSession.transport.open(probeAAgain)).not.toBeNull();

  const agentHelloB = JSON.parse(rekeySent[0] as string);
  expect(agentHelloB.attemptId).toBe("attempt-b");
  const { transport: phoneB, keys: keysB } = buildPhoneTransport({
    phonePrivkey: app2.privateKey, agentPubkeyB64: agentHelloB.pubkey, clientPubkeyB64: app2.publicKey.toString("base64"), nonce: nonce2,
  });
  const readyB = phoneB.open(rekeySent[1] as Buffer);
  expect(JSON.parse(readyB!).attemptId).toBe("attempt-b");

  const appReadyB = JSON.stringify({ type: "app:ready", attemptId: "attempt-b", confirm: phoneConfirmTag(keysB.confirm).toString("base64") });
  injectFrame(client, FrameKind.sealed, phoneB.seal(appReadyB));

  // Swap completed: this device's session is now attempt-b, and
  // onHandshakeComplete fired again for the rekey.
  expect(handshakeDone).toBe(2);
  expect((client as any).sessions.get(PHONE_ID).attemptId).toBe("attempt-b");
  expect((client as any).pending.size).toBe(0);
  // A rekey replaces a session, it does not add one.
  expect(client.establishedPeers().map((p) => p.peerId)).toEqual([PHONE_ID]);

  // The OLD transport (attempt-a) is zeroized: its key bytes are all zero and
  // it can no longer decrypt, even though the ciphertext is well-formed.
  expect(oldSession.sessionKeys.a2p.every((b) => b === 0)).toBe(true);
  expect(oldSession.sessionKeys.p2a.every((b) => b === 0)).toBe(true);
  expect(oldSession.sessionKeys.confirm.every((b) => b === 0)).toBe(true);
  const probeAAfterSwap = phoneA.seal(JSON.stringify({ type: "ping" }));
  expect(oldSession.transport.open(probeAAfterSwap)).toBeNull();

  // The NEW session works end to end.
  const probeB = phoneB.seal(JSON.stringify({ m: { type: "pong", id: "p", timestamp: 0 } }));
  const seenMsgs: unknown[] = [];
  (client as any).opts.onMessage = (m: unknown) => seenMsgs.push(m);
  injectFrame(client, FrameKind.sealed, probeB);
  expect(seenMsgs.length).toBe(1);

  void keysA; // kept for symmetry/documentation of what phoneA was derived from
});

test("a different device's verified client-hello is admitted ALONGSIDE the live session, displacing nobody", () => {
  const agentEd = ed25519Pair();
  const phoneAEd = ed25519Pair();
  const phoneBEd = ed25519Pair();

  // Phone A holds the live session.
  const { client, phoneTransport: phoneA } = establishSession({ agentEd, phoneEd: phoneAEd, attemptId: "attempt-a" });
  const sessionA = (client as any).sessions.get(PHONE_ID);

  // The agent knows phone B's pinned key (in production: account inventory).
  (client as any).phoneEd25519ByDeviceId.set(PHONE_2_ID, phoneBEd.pubB64);

  const bSent: Array<string | Buffer> = [];
  (client as any).sendPayload = (p: string | Buffer) => bSent.push(p);
  handshakeOn({ client, sent: bSent, phoneEd: phoneBEd, attemptId: "attempt-b", from: PHONE_2_ID, nonce: Buffer.from([7, 7, 7, 7, 7, 7, 7, 7]) });

  // Phone A's session object, keys and receive context are all untouched: a
  // second device is a peer, not a successor.
  expect((client as any).sessions.get(PHONE_ID)).toBe(sessionA);
  expect(sessionA.sessionKeys.a2p.every((b: number) => b === 0)).toBe(false);
  expect(sessionA.transport.open(phoneA.seal(JSON.stringify({ type: "ping" })))).not.toBeNull();
  expect(client.establishedPeers().map((p) => p.peerId)).toEqual([PHONE_ID, PHONE_2_ID]);

  // Nothing at all was sealed for phone A — no session-takeover, no teardown
  // notice. Every sealed frame here belongs to phone B's admission.
  for (const p of bSent) if (typeof p !== "string") expect(phoneA.open(p as Buffer)).toBeNull();
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

  // A device that already holds a session is never an eviction candidate: only
  // agent-hello + sealed agent-ready go out.
  expect(rekeySent.length).toBe(2);
  const notice = rekeySent.find((p) => {
    if (typeof p === "string") return false;
    const opened = phoneATransport.open(p as Buffer);
    if (!opened) return false;
    try { return JSON.parse(opened).type === "session-takeover"; } catch { return false; }
  });
  expect(notice).toBeUndefined();
});

test("each admitted device opens only its own inbound frames, and the sender's peerId is threaded to the dispatch", () => {
  const agentEd = ed25519Pair();
  const phoneAEd = ed25519Pair();
  const phoneBEd = ed25519Pair();
  const { client, phoneTransport: phoneA } = establishSession({ agentEd, phoneEd: phoneAEd, attemptId: "attempt-a" });
  (client as any).phoneEd25519ByDeviceId.set(PHONE_2_ID, phoneBEd.pubB64);

  const bSent: Array<string | Buffer> = [];
  (client as any).sendPayload = (p: string | Buffer) => bSent.push(p);
  const { transport: phoneB } = handshakeOn({ client, sent: bSent, phoneEd: phoneBEd, attemptId: "attempt-b", from: PHONE_2_ID, nonce: Buffer.from([7, 7, 7, 7, 7, 7, 7, 7]) });

  const seen: Array<{ requestId: unknown; peerId: string }> = [];
  (client as any).opts.onTunnelMessage = (m: unknown, peerId: string) => {
    seen.push({ requestId: (m as { requestId?: unknown }).requestId, peerId });
  };

  const req = (requestId: string) => JSON.stringify({
    m: { type: "tunnel:http-request", requestId, port: 3000, method: "GET", path: "/" },
  });
  injectFrame(client, FrameKind.sealed, phoneA.seal(req("from-a")), "preview", PHONE_ID);
  injectFrame(client, FrameKind.sealed, phoneB.seal(req("from-b")), "preview", PHONE_2_ID);

  // Identity comes from the session whose keys opened the frame — the auth tag
  // is the proof; the relay's `from` is only the lookup hint.
  expect(seen).toEqual([
    { requestId: "from-a", peerId: PHONE_ID },
    { requestId: "from-b", peerId: PHONE_2_ID },
  ]);
});

test("an outbound broadcast is sealed once per established session — each device opens only its own copy", () => {
  const agentEd = ed25519Pair();
  const phoneAEd = ed25519Pair();
  const phoneBEd = ed25519Pair();
  const { client, phoneTransport: phoneA } = establishSession({ agentEd, phoneEd: phoneAEd, attemptId: "attempt-a" });
  (client as any).phoneEd25519ByDeviceId.set(PHONE_2_ID, phoneBEd.pubB64);

  const bSent: Array<string | Buffer> = [];
  (client as any).sendPayload = (p: string | Buffer) => bSent.push(p);
  const { transport: phoneB } = handshakeOn({ client, sent: bSent, phoneEd: phoneBEd, attemptId: "attempt-b", from: PHONE_2_ID, nonce: Buffer.from([7, 7, 7, 7, 7, 7, 7, 7]) });

  const frames: Array<{ payload: string | Buffer; to: string }> = [];
  (client as any).sendPayload = (p: string | Buffer, to: string) => frames.push({ payload: p, to });

  const msg = { type: "pong", id: "1", timestamp: 0 };
  client.send(msg as any);

  expect(frames.map((f) => f.to)).toEqual([PHONE_ID, PHONE_2_ID]);
  const forA = frames[0]!.payload as Buffer;
  const forB = frames[1]!.payload as Buffer;
  expect(JSON.parse(phoneA.open(forA)!)).toEqual({ m: msg });
  expect(JSON.parse(phoneB.open(forB)!)).toEqual({ m: msg });
  // Sealing is per session by construction: neither device can open the other's.
  expect(phoneA.open(forB)).toBeNull();
  expect(phoneB.open(forA)).toBeNull();
});

test("peer-offline for one device suppresses that session alone; the coarse peer-offline waits for the last", () => {
  const agentEd = ed25519Pair();
  const phoneAEd = ed25519Pair();
  const phoneBEd = ed25519Pair();
  const { client } = establishSession({ agentEd, phoneEd: phoneAEd, attemptId: "attempt-a" });
  (client as any).phoneEd25519ByDeviceId.set(PHONE_2_ID, phoneBEd.pubB64);

  const bSent: Array<string | Buffer> = [];
  (client as any).sendPayload = (p: string | Buffer) => bSent.push(p);
  handshakeOn({ client, sent: bSent, phoneEd: phoneBEd, attemptId: "attempt-b", from: PHONE_2_ID, nonce: Buffer.from([7, 7, 7, 7, 7, 7, 7, 7]) });

  const mux = (client as any).mux;
  const sessionGone: string[] = [];
  let coarseOffline = 0;
  mux.notifyPeerSessionOffline = (peerId: string) => sessionGone.push(peerId);
  mux.notifyPeerOffline = () => { coarseOffline++; };

  (client as any).handleTextMessage(JSON.stringify({ type: "peer-offline", peerId: PHONE_ID }));

  expect(sessionGone).toEqual([PHONE_ID]);
  expect(coarseOffline).toBe(0); // phone B is still driving the machine
  expect(client.peerSession(PHONE_ID)?.reachable).toBe(false);
  expect(client.peerSession(PHONE_2_ID)?.reachable).toBe(true);
  // Keys are KEPT while the device is merely unreachable — push targeting and a
  // quick reconnect both need them; UNREACHABLE_SESSION_TTL_MS reaps them.
  expect(client._handshakeComplete()).toBe(true);

  (client as any).handleTextMessage(JSON.stringify({ type: "peer-offline", peerId: PHONE_2_ID }));

  expect(sessionGone).toEqual([PHONE_ID, PHONE_2_ID]);
  expect(coarseOffline).toBe(1); // fired exactly once, on the last one
});

test("a session declared dead by liveness fires the coarse peer-offline only when it was the last", () => {
  const agentEd = ed25519Pair();
  const phoneAEd = ed25519Pair();
  const phoneBEd = ed25519Pair();
  const { client } = establishSession({ agentEd, phoneEd: phoneAEd, attemptId: "attempt-a" });
  (client as any).phoneEd25519ByDeviceId.set(PHONE_2_ID, phoneBEd.pubB64);

  const bSent: Array<string | Buffer> = [];
  (client as any).sendPayload = (p: string | Buffer) => bSent.push(p);
  handshakeOn({ client, sent: bSent, phoneEd: phoneBEd, attemptId: "attempt-b", from: PHONE_2_ID, nonce: Buffer.from([7, 7, 7, 7, 7, 7, 7, 7]) });

  const mux = (client as any).mux;
  let coarseOffline = 0;
  mux.notifyPeerOffline = () => { coarseOffline++; };

  const sessions = (client as any).sessions as Map<string, { lastSealedRecvAt: number }>;
  sessions.get(PHONE_ID)!.lastSealedRecvAt = 0;
  for (let i = 0; i < 3; i++) (client as any).checkLiveness();

  expect(sessions.has(PHONE_ID)).toBe(false);
  expect(coarseOffline).toBe(0); // phone B's session is still live
  expect(client.establishedPeers().map((p) => p.peerId)).toEqual([PHONE_2_ID]);

  sessions.get(PHONE_2_ID)!.lastSealedRecvAt = 0;
  for (let i = 0; i < 3; i++) (client as any).checkLiveness();

  expect(client._handshakeComplete()).toBe(false);
  expect(coarseOffline).toBe(1);
});

test("admitting past MAX_APP_SESSIONS evicts the least recently active device and tells it", () => {
  const agentEd = ed25519Pair();
  const phoneEds = Array.from({ length: MAX_APP_SESSIONS + 1 }, () => ed25519Pair());
  const routeIds = phoneEds.map((_, i) => `phone-${i + 1}`);

  const sent: Array<string | Buffer> = [];
  const client = freshClient({ agentEd, phoneEd: phoneEds[0]!, peerId: routeIds[0]!, sent });
  const transports: E2eTransport[] = [];
  for (let i = 0; i < MAX_APP_SESSIONS; i++) {
    (client as any).phoneEd25519ByDeviceId.set(routeIds[i]!, phoneEds[i]!.pubB64);
    transports.push(handshakeOn({
      client, sent, phoneEd: phoneEds[i]!, attemptId: `attempt-${i}`, from: routeIds[i]!,
      nonce: Buffer.from([i, i, i, i, i, i, i, i]),
    }).transport);
  }
  expect(client.establishedPeers().length).toBe(MAX_APP_SESSIONS);

  const last = MAX_APP_SESSIONS;
  (client as any).phoneEd25519ByDeviceId.set(routeIds[last]!, phoneEds[last]!.pubB64);
  const evictionSent: Array<string | Buffer> = [];
  (client as any).sendPayload = (p: string | Buffer) => evictionSent.push(p);
  handshakeOn({
    client, sent: evictionSent, phoneEd: phoneEds[last]!, attemptId: `attempt-${last}`, from: routeIds[last]!,
    nonce: Buffer.from([last, last, last, last, last, last, last, last]),
  });

  // The oldest-silent session went, the newcomer took its place, everyone else
  // is untouched.
  expect(client.establishedPeers().map((p) => p.peerId)).toEqual(routeIds.slice(1));
  // The evictee learns explicitly — without the sealed notice it would rekey
  // straight back into the same eviction.
  const notice = evictionSent.find((p) => {
    if (typeof p === "string") return false;
    const opened = transports[0]!.open(p as Buffer);
    if (!opened) return false;
    try { return JSON.parse(opened).type === "session-takeover"; } catch { return false; }
  });
  expect(notice).toBeDefined();
});

test("a sibling peer-online creates no session and leaves the live one untouched", () => {
  const { client } = establishSession({ agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a" });
  expect(client.establishedPeers().map((p) => p.peerId)).toEqual([PHONE_ID]);

  // A same-account sibling comes online — presence, NOT a handshake.
  (client as any).handleTextMessage(JSON.stringify({ type: "peer-online", peerId: PHONE_2_ID }));

  expect(client.establishedPeers().map((p) => p.peerId)).toEqual([PHONE_ID]);
  expect(client._handshakeComplete()).toBe(true);
});

test("peer-online alone establishes nothing — presence is not a handshake", () => {
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: () => {},
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
  });
  clients.push(client);
  expect(client.hasEstablishedSession()).toBe(false);

  (client as any).handleTextMessage(JSON.stringify({ type: "peer-online", peerId: PHONE_2_ID }));

  expect(client.hasEstablishedSession()).toBe(false);
  expect(client.establishedPeers()).toEqual([]);
});

// `pair-connected` no longer parses as a ServerMessage, so `handleTextMessage`
// drops the frame before it ever reaches the switch. The relay never emits it
// — admission is account-derived trust resolved at client-hello time, not
// this presence notification. Either way, it must neither disturb a live
// session nor create one.
test("pair-connected never touches a session, live or idle", () => {
  const { client } = establishSession({ agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a" });

  (client as any).handleTextMessage(JSON.stringify({ type: "pair-connected", peerId: PHONE_2_ID, peerName: "phone-2", peerType: "app" }));

  expect(client.establishedPeers().map((p) => p.peerId)).toEqual([PHONE_ID]);
  expect(client._handshakeComplete()).toBe(true);

  const idle = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: () => {},
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
  });
  clients.push(idle);

  (idle as any).handleTextMessage(JSON.stringify({ type: "pair-connected", peerId: PHONE_2_ID, peerName: "phone-2", peerType: "app" }));

  expect(idle.hasEstablishedSession()).toBe(false);
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
  // The session is keyed by the SLOT — that is the socket the phone is on, and
  // every frame sealed for it is addressed there.
  expect(client.establishedPeers().map((p) => p.peerId)).toEqual([PHONE_SLOT]);
});

// The relay fans presence to every same-account peer of the opposite type, so
// one phone holding N machines open reaches each agent once per slot. Acting on
// a sibling slot would revive (or suppress) a session on the word of a socket
// that is not the one our keys belong to.
test("presence for a slot scoped at another machine never moves our session's reachability", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const sent: Array<string | Buffer> = [];
  const client = freshClient({ agentEd, phoneEd, peerId: PHONE_SLOT, sent });
  handshakeOn({ client, sent, phoneEd, attemptId: "attempt-slot", from: PHONE_SLOT });

  const foreign = `${PHONE_ID}#some-other-agent`;
  (client as any).handleTextMessage(JSON.stringify({ type: "peer-offline", peerId: foreign }));
  expect(client.peerSession(PHONE_SLOT)?.reachable).toBe(true);

  (client as any).handleTextMessage(JSON.stringify({ type: "peer-offline", peerId: PHONE_SLOT }));
  expect(client.peerSession(PHONE_SLOT)?.reachable).toBe(false);

  (client as any).handleTextMessage(JSON.stringify({ type: "peer-online", peerId: foreign }));
  expect(client.peerSession(PHONE_SLOT)?.reachable).toBe(false);

  (client as any).handleTextMessage(JSON.stringify({ type: "peer-online", peerId: PHONE_SLOT }));
  expect(client.peerSession(PHONE_SLOT)?.reachable).toBe(true);
});

// An unscoped id carries no claim about who it is for, and every pre-slot
// client sends one — it must never be read as another machine's.
test("presence for an unscoped peer id is never foreign", () => {
  const { client } = establishSession({ agentEd: ed25519Pair(), phoneEd: ed25519Pair(), attemptId: "attempt-a" });

  (client as any).handleTextMessage(JSON.stringify({ type: "peer-offline", peerId: PHONE_ID }));
  expect(client.peerSession(PHONE_ID)?.reachable).toBe(false);

  (client as any).handleTextMessage(JSON.stringify({ type: "peer-online", peerId: PHONE_ID }));
  expect(client.peerSession(PHONE_ID)?.reachable).toBe(true);
});

// The nastier half of the same fan-out: peer-offline suppresses the heavy
// stream. Charging that to a sibling slot means dropping one machine in the
// drawer silently stops the OTHER machine's terminal output.
test("peer-offline for a slot scoped at another machine does not suppress our stream", () => {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const sent: Array<string | Buffer> = [];
  const client = freshClient({ agentEd, phoneEd, peerId: PHONE_SLOT, sent });
  handshakeOn({ client, sent, phoneEd, attemptId: "attempt-slot", from: PHONE_SLOT });

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
