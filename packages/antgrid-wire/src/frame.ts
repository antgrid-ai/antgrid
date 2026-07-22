/**
 * Binary route-frame envelope shared by every relay peer (bridge, relay, evals).
 *
 * Wire layout: `[version: u8][kind: u8][header length: u16 BE][header JSON][payload]`.
 *
 * `FRAME_VERSION` is the SINGLE SOURCE OF TRUTH for the envelope byte layout.
 * It is intentionally distinct from the relay *message* protocol version
 * (`protocolVersion` in the `hello` message) — the two version different
 * layers and bump independently. Do not copy this constant into a workspace;
 * import it from `antgrid-wire` so a bump can never silently diverge and
 * produce spurious `BAD_VERSION` rejections.
 *
 * The kind byte is meaningful to the two ENDPOINTS only: the relay forwards
 * route frames opaquely (it parses the header for `to`/`channel` and never
 * interprets `kind`). Endpoints dispatch on it instead of try-parsing payload
 * plaintext — `handshake` admits exactly the two E2E handshake messages,
 * everything else must arrive `sealed`.
 */
const FRAME_VERSION = 0x02;
const FIXED_PREFIX = 4; // version byte + kind byte + u16 header length
const MAX_HEADER_LEN = 1024;

export const FrameKind = { sealed: 0x00, handshake: 0x01 } as const;
export type FrameKind = (typeof FrameKind)[keyof typeof FrameKind];

const KNOWN_KINDS = new Set<number>(Object.values(FrameKind));

export type FrameErrorReason =
  | "BAD_VERSION"
  | "BAD_KIND"
  | "TRUNCATED"
  | "HEADER_TOO_LARGE"
  | "BAD_JSON";

export class FrameError extends Error {
  constructor(public reason: FrameErrorReason, message: string) {
    super(message);
    this.name = "FrameError";
  }
}

// `kind` is deliberately required (no default): every call site must state
// what it is sending — a `sealed` default would let a future handshake path
// silently mislabel its frames.
export function encodeRouteFrame(
  header: object,
  payload: Uint8Array,
  kind: FrameKind,
): Uint8Array {
  const headerBytes = Buffer.from(JSON.stringify(header), "utf8");
  if (headerBytes.length > MAX_HEADER_LEN) {
    throw new FrameError(
      "HEADER_TOO_LARGE",
      `Header ${headerBytes.length} bytes > ${MAX_HEADER_LEN}`,
    );
  }
  const frame = Buffer.allocUnsafe(FIXED_PREFIX + headerBytes.length + payload.length);
  frame[0] = FRAME_VERSION;
  frame[1] = kind;
  frame.writeUInt16BE(headerBytes.length, 2);
  headerBytes.copy(frame, FIXED_PREFIX);
  Buffer.from(payload.buffer, payload.byteOffset, payload.byteLength).copy(
    frame,
    FIXED_PREFIX + headerBytes.length,
  );
  return frame;
}

/**
 * Decodes a binary route frame.
 *
 * **IMPORTANT:** The returned `payload` is a *view* into `buf`, NOT a copy.
 * If the caller retains the payload past the current event-loop tick (e.g.
 * by storing it in a pending-messages buffer or any persistent data
 * structure), they MUST copy it first:
 *
 *     const payloadCopy = new Uint8Array(decoded.payload);  // or Buffer.from(...)
 *
 * Callers that consume the payload synchronously (encode + forward, decrypt
 * + dispatch) can use `decoded.payload` directly without copying.
 *
 * This avoids the performance cost of an unnecessary copy on the hot forward
 * path while documenting the contract clearly for consumers that need
 * persistence.
 */
export function decodeRouteFrame(buf: Uint8Array): {
  header: unknown;
  payload: Uint8Array;
  kind: FrameKind;
} {
  if (buf.length < FIXED_PREFIX) {
    throw new FrameError(
      "TRUNCATED",
      `Frame shorter than ${FIXED_PREFIX} bytes`,
    );
  }
  if (buf[0] !== FRAME_VERSION) {
    throw new FrameError(
      "BAD_VERSION",
      `Unknown frame version: 0x${buf[0].toString(16)}`,
    );
  }
  if (!KNOWN_KINDS.has(buf[1])) {
    throw new FrameError(
      "BAD_KIND",
      `Unknown frame kind: 0x${buf[1].toString(16)}`,
    );
  }
  const kind = buf[1] as FrameKind;
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
  const headerJson = b.toString("utf8", FIXED_PREFIX, FIXED_PREFIX + headerLen);
  let header: unknown;
  try {
    header = JSON.parse(headerJson);
  } catch (e) {
    throw new FrameError(
      "BAD_JSON",
      `Header JSON parse failed: ${(e as Error).message}`,
    );
  }
  const payload = buf.slice(FIXED_PREFIX + headerLen);
  return { header, payload, kind };
}

export { FRAME_VERSION, MAX_HEADER_LEN };
