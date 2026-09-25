/**
 * Binary peer-frame envelope shared by native payload endpoints.
 *
 * Wire layout: [version:u8][kind:u8][header length:u16 BE][header JSON][payload].
 * Peer identity is authenticated by the native connection and is deliberately
 * absent from the record.
 */
import { z } from "zod/v4";
import { MAX_TRANSFER_BYTES } from "./stream-open";
import { PeerFrameHeader, type PeerFrameHeader as PeerFrameHeaderValue } from "./peer-protocol";

const FRAME_VERSION = 0x04;
const FIXED_PREFIX = 4;
const MAX_HEADER_LEN = 1024;

export const FrameKind = { message: 0x00 } as const;
export type FrameKind = (typeof FrameKind)[keyof typeof FrameKind];

const KNOWN_KINDS = new Set<number>(Object.values(FrameKind));

export type FrameErrorReason =
  | "BAD_VERSION"
  | "BAD_KIND"
  | "TRUNCATED"
  | "HEADER_TOO_LARGE"
  | "PAYLOAD_TOO_LARGE"
  | "BAD_JSON"
  | "BAD_HEADER";

export class FrameError extends Error {
  constructor(public reason: FrameErrorReason, message: string) {
    super(message);
    this.name = "FrameError";
  }
}

function parseHeader(value: unknown): PeerFrameHeaderValue {
  try {
    return PeerFrameHeader.parse(value);
  } catch (error) {
    const detail =
      error instanceof z.ZodError ? error.issues[0]?.message : String(error);
    throw new FrameError("BAD_HEADER", `Invalid peer frame header: ${detail}`);
  }
}

export function encodePeerFrame(
  header: PeerFrameHeaderValue,
  payload: Uint8Array,
): Uint8Array {
  const parsed = parseHeader(header);
  if (payload.length > MAX_TRANSFER_BYTES) {
    throw new FrameError(
      "PAYLOAD_TOO_LARGE",
      `Payload ${payload.length} bytes > ${MAX_TRANSFER_BYTES}`,
    );
  }
  const headerBytes = Buffer.from(JSON.stringify(parsed), "utf8");
  if (headerBytes.length > MAX_HEADER_LEN) {
    throw new FrameError(
      "HEADER_TOO_LARGE",
      `Header ${headerBytes.length} bytes > ${MAX_HEADER_LEN}`,
    );
  }
  const frame = Buffer.allocUnsafe(FIXED_PREFIX + headerBytes.length + payload.length);
  frame[0] = FRAME_VERSION;
  frame[1] = FrameKind.message;
  frame.writeUInt16BE(headerBytes.length, 2);
  headerBytes.copy(frame, FIXED_PREFIX);
  Buffer.from(payload.buffer, payload.byteOffset, payload.byteLength).copy(
    frame,
    FIXED_PREFIX + headerBytes.length,
  );
  return frame;
}

export function decodePeerFrame(buf: Uint8Array): {
  header: PeerFrameHeaderValue;
  payload: Uint8Array;
} {
  if (buf.length < FIXED_PREFIX) {
    throw new FrameError("TRUNCATED", `Frame shorter than ${FIXED_PREFIX} bytes`);
  }
  if (buf[0] !== FRAME_VERSION) {
    throw new FrameError(
      "BAD_VERSION",
      `Unknown frame version: 0x${buf[0].toString(16)}`,
    );
  }
  if (!KNOWN_KINDS.has(buf[1])) {
    throw new FrameError("BAD_KIND", `Unknown frame kind: 0x${buf[1].toString(16)}`);
  }
  const b = Buffer.from(buf.buffer, buf.byteOffset, buf.byteLength);
  const headerLen = b.readUInt16BE(2);
  if (headerLen > MAX_HEADER_LEN) {
    throw new FrameError(
      "HEADER_TOO_LARGE",
      `Header length ${headerLen} > ${MAX_HEADER_LEN}`,
    );
  }
  if (FIXED_PREFIX + headerLen > buf.length) {
    throw new FrameError("TRUNCATED", "Header extends past frame end");
  }
  const payloadLength = buf.length - FIXED_PREFIX - headerLen;
  if (payloadLength > MAX_TRANSFER_BYTES) {
    throw new FrameError(
      "PAYLOAD_TOO_LARGE",
      `Payload ${payloadLength} bytes > ${MAX_TRANSFER_BYTES}`,
    );
  }
  const headerJson = b.toString("utf8", FIXED_PREFIX, FIXED_PREFIX + headerLen);
  let header: unknown;
  try {
    header = JSON.parse(headerJson);
  } catch (error) {
    throw new FrameError(
      "BAD_JSON",
      `Header JSON parse failed: ${(error as Error).message}`,
    );
  }
  header = parseHeader(header);
  return {
    header: header as PeerFrameHeaderValue,
    payload: buf.slice(FIXED_PREFIX + headerLen),
  };
}

export { FRAME_VERSION, FIXED_PREFIX, MAX_HEADER_LEN };
