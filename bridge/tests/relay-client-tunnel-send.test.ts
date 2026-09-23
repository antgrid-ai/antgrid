import { describe, expect, it } from "bun:test";
import { encodePeerFrame, FrameKind } from "antgrid-wire";
import { ed25519Pair, TestPeerSessionOwner } from "./test-peer-session-owner";
import { generateEphemeralKeypair } from "../src/key-exchange";

const AGENT_DEVICE_ID = "agent-1";
const PHONE_ID = "phone-1";

function injectFrame(client: TestPeerSessionOwner, kind: FrameKind, payload: Buffer, channel: "control" | "preview" = "control"): void {
  const frame = encodePeerFrame({ type: "message", channel }, payload, kind);
  client.injectPeerFrame(Buffer.from(frame), PHONE_ID);
}

/** Establish a real E2E session on a forTest client. */
function establish(sent: Array<string | Buffer>): { client: TestPeerSessionOwner } {
  const client = TestPeerSessionOwner.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: (p) => sent.push(p),
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: ed25519Pair().seedB64,
  });
  client.establish(PHONE_ID);
  return { client };
}

describe("TestPeerSessionOwner.sendTunnel", () => {
  it("seals the tunnel message in the control-plane envelope and sends it on the preview channel", async () => {
    const sent: Array<string | Buffer> = [];
    const { client } = establish(sent);
    const sentBefore = sent.length;

    const msg = { type: "tunnel:http-start", requestId: "r1", status: 200, headers: {}, data: "b2s=", bodyEncoding: "base64", last: true };
    expect(await client.sendTunnel(msg)).toBe("sent");

    expect(sent.length).toBe(sentBefore + 1);
    expect(client.readToPeer(PHONE_ID)).toEqual({ m: msg });
    expect(client.sentTo(PHONE_ID)).toHaveLength(0);
  });

  it("resolves too-large and writes nothing for a message the fragmenter refuses", async () => {
    const sent: Array<string | Buffer> = [];
    const { client } = establish(sent);
    const sentBefore = sent.length;

    // Body large enough that the JSON envelope exceeds MAX_TRANSFER_BYTES (32 MiB),
    // so fragmentForSend rejects it. The outcome is the answer now â€” the caller
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
    const client = TestPeerSessionOwner.forTest({
      generateKeypair: () => {
        throw new Error("not used");
      },
      sendPayload: (data: Buffer | string) => sent.push(data),
      peerId: "phone-1",
    });
    // No handshake â†’ no established session.
    expect(await client.sendTunnel({ type: "tunnel:http-end", requestId: "r1", chunks: 0 })).toBe("dropped");
    expect(sent).toEqual([]);
  });
});

describe("TestPeerSessionOwner receive: a malformed sealed preview frame never reaches onTunnelMessage", () => {
  it("drops a frame the established transport fails to decrypt", () => {
    const sent: Array<string | Buffer> = [];
    const { client } = establish(sent);
    const tunnelSeen: unknown[] = [];
    (client as any).opts.onTunnelMessage = (m: unknown) => tunnelSeen.push(m);

    // Garbage ciphertext (well-formed frame, but not sealed under the
    // established transport) â€” must fail to decrypt and never dispatch.
    injectFrame(client, FrameKind.sealed, Buffer.alloc(40, 7), "preview");

    expect(tunnelSeen).toEqual([]);
  });
});
