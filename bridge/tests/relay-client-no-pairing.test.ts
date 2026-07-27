// Pair/grant frames no longer parse as a ServerMessage at all —
// `ServerMessage.safeParse` rejects them outright, and `handleTextMessage`
// drops the frame before it ever reaches the switch. This suite pins the two
// failure modes that matter given that: a pair-request-shaped frame must be
// dropped, not close the socket (an unparseable frame is not a protocol
// violation this side of the wire), and a grant-revoked-shaped frame must NOT
// tear down a live E2E session if a stale or hostile relay sends one anyway.
import { test, expect, afterEach } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { encodeRouteFrame, FrameKind, ServerMessage } from "antgrid-wire";
import { RelayClient } from "../src/relay-client";
import { generateEphemeralKeypair, deriveSharedSecret } from "../src/key-exchange";
import {
  buildTranscript, deriveSessionKeys, phoneConfirmTag, agentConfirmTag,
  verifyConfirmTag, E2eTransport, signTranscript,
} from "../src/e2e";
import vector from "../../evals/fixtures/relay-hello-vector.json";

const AGENT_DEVICE_ID = "agent-1";
const PHONE_ID = "phone-1";

let clients: RelayClient[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

/** A client whose socket is stubbed OPEN, mirroring relay-client-hello.test.ts's
 *  `makeClient` — lets `handleTextMessage` be driven directly without a live
 *  relay, while still observing every outbound frame and any `ws.close()`. */
function makeClient() {
  const seed = Buffer.from(vector.ed25519.seedHex, "hex").toString("base64");
  const sent: string[] = [];
  let closed = false;
  const client = new RelayClient({
    url: "ws://relay.antgrid.ai:8443/ws",
    identity: {
      deviceId: vector.fields.deviceId,
      deviceName: "agent",
      createdAt: new Date().toISOString(),
      ed25519PublicKey: vector.fields.publicKey,
      ed25519PrivateKey: seed,
    },
    generateKeypair: () => { throw new Error("not used"); },
    getLicenseToken: () => vector.fields.licenseToken,
  });
  clients.push(client);
  (client as any).ws = {
    readyState: WebSocket.OPEN,
    send: (d: string) => sent.push(d),
    close: () => { closed = true; },
  };
  return { client, sent, isClosed: () => closed };
}

test("an inbound pair-request frame no longer parses, and is dropped without closing the socket", () => {
  const { client, sent, isClosed } = makeClient();

  // A fully-populated pair-request payload — the exact shape the deleted
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

  (client as any).handleTextMessage(JSON.stringify(payload));

  const types = sent.map((s) => { try { return JSON.parse(s).type; } catch { return ""; } });
  expect(types).not.toContain("pair-approval");
  expect(types).not.toContain("pair-rejected");
  expect(isClosed()).toBe(false); // an unparseable frame must never kill the socket
});

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

function injectFrame(client: RelayClient, kind: FrameKind, payload: Buffer): void {
  const frame = encodeRouteFrame({ type: "message", from: PHONE_ID, channel: "control" }, payload, kind);
  (client as any).handleBinaryFrame(Buffer.from(frame));
}

/** Drive a full acked handshake on a fresh `forTest` client, same shape as
 *  handshake-pull.test.ts's `establishSession` — the minimum needed here to
 *  get a live established E2E session before firing grant-revoked at it. */
function establishSession(): RelayClient {
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
  const nonce = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
  const attemptId = "attempt-a";
  const phoneTranscript = buildTranscript({
    registrationId: AGENT_DEVICE_ID,
    role: "phone",
    agentDeviceId: AGENT_DEVICE_ID,
    phoneDeviceId: PHONE_ID,
    agentX25519Pub: Buffer.alloc(0),
    phoneX25519Pub: app.publicKey,
    nonce,
  });
  const sig = signTranscript(phoneTranscript, Buffer.from(phoneEd.seedB64, "base64"));
  injectFrame(client, FrameKind.handshake, Buffer.from(JSON.stringify({
    type: "handshake:client-hello",
    attemptId,
    pubkey: app.publicKey.toString("base64"),
    nonce: nonce.toString("base64"),
    sig,
  })));

  const agentHello = JSON.parse(sent[0] as string);
  const agentPubkey = Buffer.from(agentHello.pubkey, "base64");
  const agentTranscript = buildTranscript({
    registrationId: AGENT_DEVICE_ID,
    role: "agent",
    agentDeviceId: AGENT_DEVICE_ID,
    phoneDeviceId: PHONE_ID,
    agentX25519Pub: agentPubkey,
    phoneX25519Pub: app.publicKey,
    nonce,
  });
  const sharedSecret = deriveSharedSecret(app.privateKey, agentPubkey);
  const phoneKeys = deriveSessionKeys(sharedSecret, agentTranscript);
  const phoneTransport = new E2eTransport({ sendKey: phoneKeys.p2a, recvKey: phoneKeys.a2p });
  const readyMsg = JSON.parse(phoneTransport.open(sent[1] as Buffer)!);
  expect(verifyConfirmTag(agentConfirmTag(phoneKeys.confirm), Buffer.from(readyMsg.confirm, "base64"))).toBe(true);

  const appReadyJson = JSON.stringify({ type: "app:ready", attemptId, confirm: phoneConfirmTag(phoneKeys.confirm).toString("base64") });
  injectFrame(client, FrameKind.sealed, phoneTransport.seal(appReadyJson));
  expect(client._handshakeComplete()).toBe(true);

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

  (client as any).handleTextMessage(JSON.stringify(payload));

  expect(client._handshakeComplete()).toBe(true);
});
