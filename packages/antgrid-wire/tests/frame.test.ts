import { describe, it, expect } from "bun:test";
import { encodeRouteFrame, decodeRouteFrame, FrameError, FrameKind } from "../src/index";

describe("encodeRouteFrame", () => {
  it("produces [0x02][kind][len BE u16][header][payload] layout", () => {
    const header = { type: "message", to: "agent-1", channel: "control" };
    const payload = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);

    const frame = encodeRouteFrame(header, payload, FrameKind.sealed);

    expect(frame[0]).toBe(0x02);
    expect(frame[1]).toBe(FrameKind.sealed);
    const headerLen = (frame[2] << 8) | frame[3];
    const headerJson = Buffer.from(frame.subarray(4, 4 + headerLen)).toString("utf8");
    expect(JSON.parse(headerJson)).toEqual(header);
    expect(Array.from(frame.subarray(4 + headerLen))).toEqual([0xde, 0xad, 0xbe, 0xef]);
  });

  it("rejects headers larger than 1024 bytes", () => {
    const header = { type: "message", to: "a".repeat(2000), channel: "control" };
    expect(() => encodeRouteFrame(header, new Uint8Array(0), FrameKind.sealed)).toThrow(
      expect.objectContaining({ reason: "HEADER_TOO_LARGE" }),
    );
  });
});

describe("decodeRouteFrame", () => {
  it("round-trips a sealed frame preserving header, payload bytes, and kind", () => {
    const header = { type: "message", to: "agent-1", channel: "preview" };
    const payload = new Uint8Array(1024).map((_, i) => i & 0xff);

    const frame = encodeRouteFrame(header, payload, FrameKind.sealed);
    const decoded = decodeRouteFrame(frame);

    expect(decoded.header).toEqual(header);
    expect(Array.from(decoded.payload)).toEqual(Array.from(payload));
    expect(decoded.kind).toBe(FrameKind.sealed);
  });

  it("round-trips a handshake frame preserving header, payload bytes, and kind", () => {
    const header = { type: "message", to: "agent-1", channel: "control" };
    const payload = new Uint8Array([1, 2, 3, 4, 5]);

    const frame = encodeRouteFrame(header, payload, FrameKind.handshake);
    const decoded = decodeRouteFrame(frame);

    expect(decoded.header).toEqual(header);
    expect(Array.from(decoded.payload)).toEqual(Array.from(payload));
    expect(decoded.kind).toBe(FrameKind.handshake);
  });

  it("handles empty payload", () => {
    const header = { type: "message", to: "a", channel: "control" };
    const decoded = decodeRouteFrame(encodeRouteFrame(header, new Uint8Array(0), FrameKind.sealed));
    expect(decoded.payload.length).toBe(0);
  });

  it("rejects frame shorter than 4 bytes", () => {
    expect(() => decodeRouteFrame(new Uint8Array([0x02, 0x00, 0x00]))).toThrow(
      expect.objectContaining({ reason: "TRUNCATED" }),
    );
  });

  it("rejects a v1 frame (0x01 first byte) with BAD_VERSION", () => {
    const buf = new Uint8Array([0x01, 0x00, 0x00, 0x00]);
    expect(() => decodeRouteFrame(buf)).toThrow(
      expect.objectContaining({ reason: "BAD_VERSION" }),
    );
  });

  it("rejects an unknown version byte", () => {
    const buf = new Uint8Array([0x99, 0x00, 0x00, 0x00]);
    expect(() => decodeRouteFrame(buf)).toThrow(
      expect.objectContaining({ reason: "BAD_VERSION" }),
    );
  });

  it("rejects an unknown kind byte with BAD_KIND", () => {
    const buf = new Uint8Array([0x02, 0x07, 0x00, 0x00]);
    expect(() => decodeRouteFrame(buf)).toThrow(
      expect.objectContaining({ reason: "BAD_KIND" }),
    );
  });

  it("rejects header_len > 1024", () => {
    const buf = new Uint8Array(4);
    buf[0] = 0x02;
    buf[1] = FrameKind.sealed;
    buf[2] = 0x04; // 1025 BE
    buf[3] = 0x01;
    expect(() => decodeRouteFrame(buf)).toThrow(
      expect.objectContaining({ reason: "HEADER_TOO_LARGE" }),
    );
  });

  it("rejects truncated header (declared length exceeds frame)", () => {
    const buf = new Uint8Array([0x02, FrameKind.sealed, 0x00, 0x10, 0x7b]); // header_len=16 but only 1 byte
    expect(() => decodeRouteFrame(buf)).toThrow(
      expect.objectContaining({ reason: "TRUNCATED" }),
    );
  });

  it("rejects invalid JSON header", () => {
    const badHeader = Buffer.from("not json", "utf8");
    const buf = Buffer.allocUnsafe(4 + badHeader.length);
    buf[0] = 0x02;
    buf[1] = FrameKind.sealed;
    buf.writeUInt16BE(badHeader.length, 2);
    badHeader.copy(buf, 4);
    expect(() => decodeRouteFrame(buf)).toThrow(
      expect.objectContaining({ reason: "BAD_JSON" }),
    );
  });

  it("returns a payload view, not a copy, into the source buffer", () => {
    const header = { type: "message", to: "a", channel: "control" };
    const payload = new Uint8Array([1, 2, 3]);
    const frame = encodeRouteFrame(header, payload, FrameKind.sealed);
    const decoded = decodeRouteFrame(frame);
    frame[frame.length - 1] = 0xff;
    expect(decoded.payload[decoded.payload.length - 1]).toBe(0xff);
  });
});
