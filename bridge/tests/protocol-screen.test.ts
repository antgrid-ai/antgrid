import { describe, it, expect } from "bun:test";
import { createMessage, parseMessage, parseMessageFast, type AbMessage } from "../src/protocol";

/** Every `screen:*` type, one well-formed instance each. */
const SAMPLES: AbMessage[] = [
  createMessage("screen:request", { projectId: "demo" }),
  createMessage("screen:request", { projectId: "demo", chooser: "viewer", viewerId: "phone#machine" }),
  createMessage("screen:windows", { windows: [{ id: "w1", title: "app.dart", minimised: true }], viewerId: "phone#machine" }),
  createMessage("screen:pick", { windowId: "w1", viewerId: "phone#machine" }),
  createMessage("screen:state", { status: "no-host" }),
  createMessage("screen:state", { status: "live", windowTitle: "app.dart", width: 1448, height: 903 }),
  createMessage("screen:state", { status: "interrupted", reason: "reconnecting" }),
  createMessage("screen:offer", { sdp: "v=0", dtlsFingerprint: "sha-256 AA:BB", width: 1448, height: 903 }),
  createMessage("screen:answer", { sdp: "v=0", dtlsFingerprint: "sha-256 CC:DD" }),
  createMessage("screen:ice", { candidate: "candidate:1 1 udp", sdpMid: "0", sdpMLineIndex: 0 }),
  createMessage("screen:stop", { reason: "window closed" }),
  createMessage("screen:stop", { reason: "viewer-gone", viewerId: "phone#machine" }),
  createMessage("screen:state", { status: "ended", reason: "screen control turned off", viewerId: "phone#machine" }),
];

describe("screen:* protocol", () => {
  it("round-trips through the full Zod union", () => {
    for (const msg of SAMPLES) {
      const parsed = parseMessage(JSON.stringify(msg));
      expect(parsed).toEqual(msg);
    }
  });

  it("survives parseMessageFast, which the loopback path uses", () => {
    // LocalListener.handleFrame parses with parseMessageFast, which silently
    // drops anything outside KNOWN_TYPES — a schema in the union but not in that
    // set fails only on the loopback hop, which is the whole signalling path.
    for (const msg of SAMPLES) {
      expect(parseMessageFast(JSON.stringify(msg))?.type).toBe(msg.type);
    }
  });

  it("accepts an end-of-candidates ICE frame and a null sdpMid", () => {
    const msg = createMessage("screen:ice", { candidate: "", sdpMid: null, sdpMLineIndex: 0 });
    expect(parseMessage(JSON.stringify(msg))).toEqual(msg);
  });

  it("rejects an unknown screen:state status", () => {
    const msg = { ...createMessage("screen:state", { status: "live" }), status: "streaming" };
    expect(parseMessage(JSON.stringify(msg))).toBeNull();
  });

  it("rejects an empty viewerId", () => {
    // The relay treats a falsy viewerId as unaddressed and drops the frame, so
    // an empty one must fail at the schema rather than read as a real address.
    const msg = { ...createMessage("screen:stop", { reason: "x" }), viewerId: "" };
    expect(parseMessage(JSON.stringify(msg))).toBeNull();
  });

  it("has no window-enumeration verb", () => {
    // By design (findings §6): the remote peer may request a picker, the local
    // user chooses the window. A `screen:sources` message would be a
    // screen-scraping primitive over the network.
    expect(parseMessageFast(JSON.stringify({ type: "screen:sources" }))).toBeNull();
  });
});
