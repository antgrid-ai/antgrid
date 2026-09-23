import { describe, expect, it } from "bun:test";
import { buildFragments, isFragEnvelope, MAX_FRAME_PAYLOAD } from "antgrid-wire";
import { ed25519Pair, fragmentForSend, TestPeerSessionOwner } from "./test-peer-session-owner";
import { createMessage } from "../src/protocol";
import { generateEphemeralKeypair } from "../src/key-exchange";

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

/** Establish a real E2E session (see handshake-pull.test.ts / stream-mux.test.ts
 *  for the full-coverage versions of this seam) and return the client, ready
 *  to seal control-plane traffic via `sendFromPeer`. */
function establish(): TestPeerSessionOwner {
  const client = TestPeerSessionOwner.forTest({
    generateKeypair: generateEphemeralKeypair,
    sendPayload: () => {},
    peerId: PHONE_ID,
    deviceId: AGENT_DEVICE_ID,
    agentEd25519PrivB64: ed25519Pair().seedB64,
  });
  client.establish(PHONE_ID);
  return client;
}

describe("TestPeerSessionOwner receive fragmentation seam", () => {
  it("reassembles decrypted fragments before dispatching control-plane messages", () => {
    const client = establish();
    const seen: unknown[] = [];
    (client as any).opts.onMessage = (msg: unknown) => seen.push(msg);

    const msg = createMessage("file:content", {
      projectId: "p1",
      path: "a.txt",
      content: "x".repeat(2500),
      size: 2500,
      encoding: "utf8",
    });
    // Control-plane traffic is the `{ m }` envelope with `s` omitted.
    const json = JSON.stringify({ m: msg });
    const frames = buildFragments(json, "rx-1", { type: "file:content", key: "a.txt" }, 1000);

    client.sendFromPeer(PHONE_ID, frames[1]);
    expect(seen).toEqual([]);
    client.sendFromPeer(PHONE_ID, frames[0]);
    client.sendFromPeer(PHONE_ID, frames[2]);

    expect(seen).toEqual([msg]);
  });
});
