import { describe, expect, it } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { buildFragments, isFragEnvelope, MAX_FRAME_PAYLOAD, encodeRouteFrame, FrameKind } from "antgrid-wire";
import { fragmentForSend, RelayClient } from "../src/relay-client";
import { createMessage } from "../src/protocol";
import { generateEphemeralKeypair, deriveSharedSecret } from "../src/key-exchange";
import { buildTranscript, deriveSessionKeys, phoneConfirmTag, E2eTransport, signTranscript } from "../src/e2e";

describe("fragmentForSend", () => {
  it("returns the json unchanged when under threshold", () => {
    const json = JSON.stringify({ type: "file:content", path: "a", content: "x" });

    expect(fragmentForSend(json, "file:content", "a")).toEqual({ ok: true, frames: [json] });
  });

  it("splits an over-threshold file content message into frag envelopes that rejoin", () => {
    const big = "y".repeat(3_000_000);
    const json = JSON.stringify({ type: "file:content", path: "a.png", content: big });
    const result = fragmentForSend(json, "file:content", "a.png");

    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("expected fragmented frames");
    expect(result.frames.length).toBeGreaterThan(1);

    for (const frame of result.frames) {
      expect(isFragEnvelope(JSON.parse(frame))).toBe(true);
      expect(Buffer.byteLength(frame, "utf8")).toBeLessThanOrEqual(MAX_FRAME_PAYLOAD);
    }
    expect(result.frames.map((frame) => JSON.parse(frame).data).join("")).toBe(json);
  });

  it("returns a typed error for an oversized message", () => {
    const json = "x".repeat(33_554_433);

    expect(fragmentForSend(json, "git:diff")).toEqual({
      ok: false,
      error: {
        code: "MESSAGE_TOO_LARGE",
        message: "git:diff exceeds MAX_TRANSFER_BYTES",
      },
    });
  });

  it("repeats file content hint on every fragment", () => {
    const big = "z".repeat(3_000_000);
    const json = JSON.stringify({ type: "file:content", path: "dir/a.txt", content: big });
    const result = fragmentForSend(json, "file:content", "dir/a.txt");

    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("expected fragmented frames");

    for (const frame of result.frames) {
      expect(JSON.parse(frame).__frag.hint).toEqual({
        type: "file:content",
        key: "dir/a.txt",
      });
    }
  });

  it("hints any path-keyed type so the app can recover the right pane", () => {
    const big = "d".repeat(3_000_000);
    const json = JSON.stringify({ type: "git:diff-content", path: "src/a.dart", diff: big });
    const result = fragmentForSend(json, "git:diff-content", "src/a.dart");

    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("expected fragmented frames");

    for (const frame of result.frames) {
      expect(JSON.parse(frame).__frag.hint).toEqual({
        type: "git:diff-content",
        key: "src/a.dart",
      });
    }
  });

  it("omits the hint when no key is available", () => {
    const big = "t".repeat(3_000_000);
    const json = JSON.stringify({ type: "tree:full", blob: big });
    const result = fragmentForSend(json, "tree:full");

    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("expected fragmented frames");
    expect(JSON.parse(result.frames[0]).__frag.hint).toBeUndefined();
  });
});

const AGENT_DEVICE_ID = "agent-1";
const PHONE_ID = "phone-1";

function ed25519Pair(): { seedB64: string; pubB64: string } {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    seedB64: Buffer.from(privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32)).toString("base64"),
    pubB64: Buffer.from(publicKey.export({ format: "der", type: "spki" }).subarray(-32)).toString("base64"),
  };
}

/** Establish a real E2E session (see handshake-pull.test.ts / stream-mux.test.ts
 *  for the full-coverage versions of this helper) and return the phone-side
 *  transport to seal control-plane traffic with. */
function establish(): { client: RelayClient; phoneTransport: E2eTransport } {
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

  const app = generateEphemeralKeypair();
  const nonce = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
  const phoneTranscript = buildTranscript({
    registrationId: AGENT_DEVICE_ID, role: "phone", agentDeviceId: AGENT_DEVICE_ID, phoneDeviceId: PHONE_ID,
    agentX25519Pub: Buffer.alloc(0), phoneX25519Pub: app.publicKey, nonce,
  });
  const sig = signTranscript(phoneTranscript, Buffer.from(phoneEd.seedB64, "base64"));
  const frame = encodeRouteFrame(
    { type: "message", from: PHONE_ID, channel: "control" },
    Buffer.from(JSON.stringify({ type: "handshake:client-hello", attemptId: "a1", pubkey: app.publicKey.toString("base64"), nonce: nonce.toString("base64"), sig })),
    FrameKind.handshake,
  );
  (client as any).handleBinaryFrame(Buffer.from(frame));

  const agentHello = JSON.parse(sent[0] as string);
  const agentPubkey = Buffer.from(agentHello.pubkey, "base64");
  const agentTranscript = buildTranscript({
    registrationId: AGENT_DEVICE_ID, role: "agent", agentDeviceId: AGENT_DEVICE_ID, phoneDeviceId: PHONE_ID,
    agentX25519Pub: agentPubkey, phoneX25519Pub: app.publicKey, nonce,
  });
  const sharedSecret = deriveSharedSecret(app.privateKey, agentPubkey);
  const keys = deriveSessionKeys(sharedSecret, agentTranscript);
  const phoneTransport = new E2eTransport({ sendKey: keys.p2a, recvKey: keys.a2p });

  const appReadyFrame = encodeRouteFrame(
    { type: "message", from: PHONE_ID, channel: "control" },
    phoneTransport.seal(JSON.stringify({ type: "app:ready", attemptId: "a1", confirm: phoneConfirmTag(keys.confirm).toString("base64") })),
    FrameKind.sealed,
  );
  (client as any).handleBinaryFrame(Buffer.from(appReadyFrame));
  expect(client._handshakeComplete()).toBe(true);

  return { client, phoneTransport };
}

describe("RelayClient receive fragmentation seam", () => {
  it("reassembles decrypted fragments before dispatching control-plane messages", () => {
    const { client, phoneTransport } = establish();
    const seen: unknown[] = [];
    (client as any).opts.onMessage = (msg: unknown) => seen.push(msg);

    const msg = createMessage("file:content", {
      projectId: "p1",
      path: "a.txt",
      content: "x".repeat(2500),
      size: 2500,
      encoding: "utf8",
    });
    // Control-plane traffic is the `{ m }` envelope with `s` omitted (design §7.1).
    const json = JSON.stringify({ m: msg });
    const frames = buildFragments(json, "rx-1", { type: "file:content", key: "a.txt" }, 1000);

    const inject = (frag: string) => {
      const wire = encodeRouteFrame({ type: "message", from: PHONE_ID, channel: "control" }, phoneTransport.seal(frag), FrameKind.sealed);
      (client as any).handleBinaryFrame(Buffer.from(wire));
    };

    inject(frames[1]);
    expect(seen).toEqual([]);
    inject(frames[0]);
    inject(frames[2]);

    expect(seen).toEqual([msg]);
  });
});
