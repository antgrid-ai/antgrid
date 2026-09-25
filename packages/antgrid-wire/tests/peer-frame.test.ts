import { describe, expect, it } from "bun:test";
import {
  decodePeerFrame,
  encodePeerFrame,
  FRAME_VERSION,
  FrameError,
  FrameKind,
  MAX_TRANSFER_BYTES,
} from "../src/index";

const messageHeader = { type: "message" } as const;
const sessionHeader = { type: "session" } as const;

describe("encodePeerFrame", () => {
  it("produces the v4 prefix, peer header, and payload", () => {
    const payload = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);
    const frame = encodePeerFrame(messageHeader, payload);

    expect(frame[0]).toBe(0x04);
    expect(frame[0]).toBe(FRAME_VERSION);
    expect(frame[1]).toBe(FrameKind.message);
    const headerLen = (frame[2] << 8) | frame[3];
    expect(JSON.parse(Buffer.from(frame.subarray(4, 4 + headerLen)).toString("utf8")))
      .toEqual(messageHeader);
    expect(Array.from(frame.subarray(4 + headerLen))).toEqual([...payload]);
  });

  it("rejects a header carrying any key beyond type", () => {
    expect(() => encodePeerFrame(
      { ...messageHeader, channel: "control" } as unknown as typeof messageHeader,
      new Uint8Array(),
    )).toThrow(expect.objectContaining({ reason: "BAD_HEADER" }));
    expect(() => encodePeerFrame(
      { ...messageHeader, to: "agent-1" } as unknown as typeof messageHeader,
      new Uint8Array(),
    )).toThrow(expect.objectContaining({ reason: "BAD_HEADER" }));
  });

  it("rejects payloads beyond the record bound", () => {
    expect(() => encodePeerFrame(
      messageHeader,
      new Uint8Array(MAX_TRANSFER_BYTES + 1),
    )).toThrow(expect.objectContaining({ reason: "PAYLOAD_TOO_LARGE" }));
  });
});

describe("decodePeerFrame", () => {
  it("round-trips both header kinds and returns a payload view", () => {
    for (const header of [messageHeader, sessionHeader]) {
      const payload = new Uint8Array([1, 2, 3, 4, 5]);
      const frame = encodePeerFrame(header, payload);
      const decoded = decodePeerFrame(frame);

      expect(decoded.header).toEqual(header);
      expect([...decoded.payload]).toEqual([...payload]);
    }
    const frame = encodePeerFrame(messageHeader, new Uint8Array([1, 2, 3]));
    const decoded = decodePeerFrame(frame);
    frame[frame.length - 1] = 9;
    expect(decoded.payload[decoded.payload.length - 1]).toBe(9);
  });

  it("rejects v3 and unknown versions", () => {
    for (const version of [0x03, 0x99]) {
      expect(() => decodePeerFrame(
        new Uint8Array([version, FrameKind.message, 0, 0]),
      )).toThrow(expect.objectContaining({ reason: "BAD_VERSION" }));
    }
  });

  it("rejects truncated, unknown-kind, and oversized-header records", () => {
    expect(() => decodePeerFrame(new Uint8Array([0x04, 0, 0])))
      .toThrow(expect.objectContaining({ reason: "TRUNCATED" }));
    expect(() => decodePeerFrame(new Uint8Array([0x04, 0x7f, 0, 0])))
      .toThrow(expect.objectContaining({ reason: "BAD_KIND" }));
    expect(() => decodePeerFrame(new Uint8Array([0x04, 0x01, 0, 0])))
      .toThrow(expect.objectContaining({ reason: "BAD_KIND" }));
    expect(() => decodePeerFrame(new Uint8Array([0x04, 0, 0x04, 0x01])))
      .toThrow(expect.objectContaining({ reason: "HEADER_TOO_LARGE" }));
    expect(() => decodePeerFrame(new Uint8Array([0x04, 0, 0, 2, 0x7b])))
      .toThrow(expect.objectContaining({ reason: "TRUNCATED" }));
  });

  it("rejects malformed and non-peer headers", () => {
    const record = (json: string) => {
      const encoded = Buffer.from(json);
      return new Uint8Array([
        0x04,
        FrameKind.message,
        encoded.length >> 8,
        encoded.length & 0xff,
        ...encoded,
      ]);
    };
    expect(() => decodePeerFrame(record("{")))
      .toThrow(expect.objectContaining({ reason: "BAD_JSON" }));
    for (const value of [
      { type: "message", channel: "control" },
      { type: "other" },
      { type: "message", from: "app-1" },
    ]) {
      expect(() => decodePeerFrame(record(JSON.stringify(value))))
        .toThrow(expect.objectContaining({ reason: "BAD_HEADER" }));
    }
  });

  it("uses a bounded header and exposes typed errors", () => {
    expect(FrameError).toBeDefined();
    const decoded = decodePeerFrame(encodePeerFrame(messageHeader, new Uint8Array()));
    expect(decoded.payload).toHaveLength(0);
  });
});
