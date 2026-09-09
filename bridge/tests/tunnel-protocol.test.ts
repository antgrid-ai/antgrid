// The streamed-tunnel wire: the slice-size arithmetic the flow-control window
// depends on, and what parseTunnelMessage does and does not accept.
import { describe, expect, it } from "bun:test";
import { CHANNEL_WINDOW_BYTES, CREDIT_BATCH_BYTES, FRAG_THRESHOLD, SEAL_OVERHEAD_BYTES } from "antgrid-wire";
import { base64Length, parseTunnelMessage, TUNNEL_CHUNK_BYTES } from "../src/tunnel-protocol";

// Envelope + header slack. A start carrying more than this in headers may
// fragment, which frag1 still delivers — it is simply not single-frame.
const FRAME_SLACK = 4096;

describe("TUNNEL_CHUNK_BYTES sizing", () => {
  it("is a multiple of 3, so base64 has no padding and its length is exact", () => {
    expect(TUNNEL_CHUNK_BYTES % 3).toBe(0);
    expect(base64Length(TUNNEL_CHUNK_BYTES)).toBe(262_144);
  });

  it("keeps an encoded slice inside one fragment", () => {
    expect(base64Length(TUNNEL_CHUNK_BYTES) + FRAME_SLACK).toBeLessThanOrEqual(FRAG_THRESHOLD);
  });

  it("earns a credit within every two chunks", () => {
    expect(2 * (base64Length(TUNNEL_CHUNK_BYTES) + SEAL_OVERHEAD_BYTES))
      .toBeGreaterThanOrEqual(CREDIT_BATCH_BYTES);
  });

  it("lets seven chunks pipeline inside one channel window", () => {
    expect(7 * (base64Length(TUNNEL_CHUNK_BYTES) + FRAME_SLACK + SEAL_OVERHEAD_BYTES))
      .toBeLessThanOrEqual(CHANNEL_WINDOW_BYTES);
  });
});

describe("parseTunnelMessage: the streamed HTTP frames", () => {
  it("accepts a start with and without a body slice, with and without last", () => {
    const base = { type: "tunnel:http-start" as const, requestId: "r1", status: 200, headers: {} };

    expect(parseTunnelMessage({ ...base, data: "", bodyEncoding: "base64", last: true })).toEqual({
      ...base, data: "", bodyEncoding: "base64", last: true, checkoutId: "main",
    });
    expect(parseTunnelMessage({ ...base, data: "aGk=", bodyEncoding: "base64", last: true })).toMatchObject({
      data: "aGk=", last: true,
    });
    const streaming = parseTunnelMessage({ ...base, data: "aGk=", bodyEncoding: "gzip-base64" });
    expect(streaming).toMatchObject({ bodyEncoding: "gzip-base64", checkoutId: "main" });
    expect((streaming as { last?: unknown }).last).toBeUndefined();
    expect(parseTunnelMessage({ ...base, data: "", bodyEncoding: "base64" })).toMatchObject({ data: "" });
  });

  it("accepts a chunk, an end with and without error, and a cancel", () => {
    expect(parseTunnelMessage({ type: "tunnel:http-chunk", requestId: "r1", seq: 1, data: "aGk=", bodyEncoding: "base64" }))
      .toEqual({ type: "tunnel:http-chunk", requestId: "r1", seq: 1, data: "aGk=", bodyEncoding: "base64", checkoutId: "main" });
    expect(parseTunnelMessage({ type: "tunnel:http-end", requestId: "r1", chunks: 0 }))
      .toEqual({ type: "tunnel:http-end", requestId: "r1", chunks: 0, checkoutId: "main" });
    expect(parseTunnelMessage({ type: "tunnel:http-end", requestId: "r1", chunks: 3, error: "upstream body stalled" }))
      .toMatchObject({ chunks: 3, error: "upstream body stalled" });
    expect(parseTunnelMessage({ type: "tunnel:http-cancel", requestId: "r1" }))
      .toEqual({ type: "tunnel:http-cancel", requestId: "r1", checkoutId: "main" });
  });

  it("keeps a non-main checkoutId on every frame", () => {
    for (const frame of [
      { type: "tunnel:http-start", requestId: "r1", status: 200, headers: {}, data: "", bodyEncoding: "base64", last: true },
      { type: "tunnel:http-chunk", requestId: "r1", seq: 1, data: "aGk=", bodyEncoding: "base64" },
      { type: "tunnel:http-end", requestId: "r1", chunks: 1 },
      { type: "tunnel:http-cancel", requestId: "r1" },
    ]) {
      expect(parseTunnelMessage({ ...frame, checkoutId: "wt-1" })).toMatchObject({ checkoutId: "wt-1" });
    }
  });

  it("rejects a non-positive seq, a retired encoding, a negative chunk count and the retired response type", () => {
    const chunk = { type: "tunnel:http-chunk", requestId: "r1", data: "aGk=", bodyEncoding: "base64" };
    expect(parseTunnelMessage({ ...chunk, seq: 0 })).toBeNull();
    expect(parseTunnelMessage({ ...chunk, seq: -1 })).toBeNull();
    // `utf8` left the enum with the whole-body path: every slice is base64 now.
    expect(parseTunnelMessage({ ...chunk, seq: 1, bodyEncoding: "utf8" })).toBeNull();
    expect(parseTunnelMessage({
      type: "tunnel:http-start", requestId: "r1", status: 200, headers: {}, data: "hi", bodyEncoding: "utf8",
    })).toBeNull();
    expect(parseTunnelMessage({ type: "tunnel:http-end", requestId: "r1", chunks: -1 })).toBeNull();
    expect(parseTunnelMessage({
      type: "tunnel:http-response", requestId: "r1", status: 200, headers: {}, body: "hi", bodyEncoding: "utf8",
    })).toBeNull();
  });
});
