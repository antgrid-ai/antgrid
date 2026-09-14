import { describe, expect, it } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { encodeRouteFrame, FrameKind } from "antgrid-wire";
import { RelayClient } from "../src/relay-client";
import { generateEphemeralKeypair, deriveSharedSecret } from "../src/key-exchange";
import { buildTranscript, deriveSessionKeys, phoneConfirmTag, E2eTransport, signTranscript } from "../src/e2e";

const AGENT_DEVICE_ID = "agent-1";
const PHONE_ID = "phone-1";

function ed25519Pair(): { seedB64: string; pubB64: string } {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    seedB64: Buffer.from(privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32)).toString("base64"),
    pubB64: Buffer.from(publicKey.export({ format: "der", type: "spki" }).subarray(-32)).toString("base64"),
  };
}

function injectFrame(client: RelayClient, kind: FrameKind, payload: Buffer, channel: "control" | "preview" = "control"): void {
  const frame = encodeRouteFrame({ type: "message", from: PHONE_ID, channel }, payload, kind);
  (client as any).handleBinaryFrame(Buffer.from(frame));
}

/** Establish a real E2E session on a forTest client. */
function establish(sent: Array<string | Buffer>): { client: RelayClient; phoneTransport: E2eTransport } {
  const agentEd = ed25519Pair();
  const phoneEd = ed25519Pair();
  const client = RelayClient.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: (p) => sent.push(p),
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: agentEd.seedB64,
    phoneEd25519PubB64: phoneEd.pubB64,
  });

  const app = generateEphemeralKeypair();
  const nonce = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
  const phoneTranscript = buildTranscript({
    registrationId: AGENT_DEVICE_ID, role: "phone", agentDeviceId: AGENT_DEVICE_ID, phoneDeviceId: PHONE_ID,
    agentX25519Pub: Buffer.alloc(0), phoneX25519Pub: app.publicKey, nonce,
  });
  const sig = signTranscript(phoneTranscript, Buffer.from(phoneEd.seedB64, "base64"));
  injectFrame(client, FrameKind.handshake, Buffer.from(JSON.stringify({
    type: "handshake:client-hello", attemptId: "a1", pubkey: app.publicKey.toString("base64"), nonce: nonce.toString("base64"), sig,
  })));

  const agentHello = JSON.parse(sent[0] as string);
  const agentPubkey = Buffer.from(agentHello.pubkey, "base64");
  const agentTranscript = buildTranscript({
    registrationId: AGENT_DEVICE_ID, role: "agent", agentDeviceId: AGENT_DEVICE_ID, phoneDeviceId: PHONE_ID,
    agentX25519Pub: agentPubkey, phoneX25519Pub: app.publicKey, nonce,
  });
  const sharedSecret = deriveSharedSecret(app.privateKey, agentPubkey);
  const keys = deriveSessionKeys(sharedSecret, agentTranscript);
  const phoneTransport = new E2eTransport({ sendKey: keys.p2a, recvKey: keys.a2p });

  injectFrame(client, FrameKind.sealed, phoneTransport.seal(JSON.stringify({
    type: "app:ready", attemptId: "a1", confirm: phoneConfirmTag(keys.confirm).toString("base64"),
  })));
  expect(client._handshakeComplete()).toBe(true);

  return { client, phoneTransport };
}

describe("RelayClient.sendTunnel", () => {
  it("seals the tunnel message in the control-plane envelope and sends it on the preview channel", async () => {
    const sent: Array<string | Buffer> = [];
    const { client, phoneTransport } = establish(sent);
    const sentBefore = sent.length;

    const msg = { type: "tunnel:http-start", requestId: "r1", status: 200, headers: {}, data: "b2s=", bodyEncoding: "base64", last: true };
    expect(await client.sendTunnel(msg)).toBe("sent");

    expect(sent.length).toBe(sentBefore + 1);
    const envelopeJson = phoneTransport.open(sent[sent.length - 1] as Buffer);
    expect(JSON.parse(envelopeJson!)).toEqual({ m: msg });
  });

  it("resolves too-large and writes nothing for a message the fragmenter refuses", async () => {
    const sent: Array<string | Buffer> = [];
    const { client } = establish(sent);
    const sentBefore = sent.length;

    // Body large enough that the JSON envelope exceeds MAX_TRANSFER_BYTES (32 MiB),
    // so fragmentForSend rejects it. The outcome is the answer now — the caller
    // (TunnelManager) ends its stream on it rather than the send path
    // synthesising a reply it cannot attribute to a checkout.
    const huge = "a".repeat(34 * 1024 * 1024);
    expect(await client.sendTunnel({
      type: "tunnel:http-chunk",
      requestId: "r1",
      seq: 1,
      data: huge,
      bodyEncoding: "base64",
    })).toBe("too-large");

    expect(sent.length).toBe(sentBefore);
  });

  it("drops the tunnel message when the E2E session is not established", async () => {
    const sent: unknown[] = [];
    const client = RelayClient.forTest({
      generateKeypair: () => {
        throw new Error("not used");
      },
      sendPayload: (data: Buffer | string) => sent.push(data),
      peerId: "phone-1",
    });
    // No handshake → no established session.
    expect(await client.sendTunnel({ type: "tunnel:http-end", requestId: "r1", chunks: 0 })).toBe("dropped");
    expect(sent).toEqual([]);
  });
});

describe("RelayClient receive: a malformed sealed preview frame never reaches onTunnelMessage", () => {
  it("drops a frame the established transport fails to decrypt", () => {
    const sent: Array<string | Buffer> = [];
    const { client } = establish(sent);
    const tunnelSeen: unknown[] = [];
    (client as any).opts.onTunnelMessage = (m: unknown) => tunnelSeen.push(m);

    // Garbage ciphertext (well-formed frame, but not sealed under the
    // established transport) — must fail to decrypt and never dispatch.
    injectFrame(client, FrameKind.sealed, Buffer.alloc(40, 7), "preview");

    expect(tunnelSeen).toEqual([]);
  });
});
