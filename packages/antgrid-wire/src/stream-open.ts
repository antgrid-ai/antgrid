import { z } from "zod/v4";

// The first record on every native peer stream, the session stream included.
// The app writes it in the same call as `openBi` because a Dart stream is
// invisible to the peer until its first write; the bridge reads and validates
// it under a deadline before the stream reaches its dispatch table.

/** Largest single `AbMessage` JSON the bridge writes on any stream: one
 *  message is one record, so this is the sender's hard ceiling. */
export const MAX_TRANSFER_BYTES = 33_554_432;

// iroh 1.0's QUIC transport defaults, RECORDED here rather than set: neither
// binding (`@number0/iroh` on the bridge, `iroh_quic` on the app) exposes a
// transport-config setter, so both sides simply run what iroh applies. The
// negotiated idle timeout is the minimum of both sides' values. Mirror by
// hand as `kPeerQuicKeepAliveInterval`/`kPeerQuicMaxIdleTimeout`
// (`packages/antgrid_relay_client/lib/src/models/stream_open.dart`), pinned by
// `peer-transport-vectors.json`'s `quic` block.
export const PEER_QUIC_KEEP_ALIVE_INTERVAL_MS = 5_000;
export const PEER_QUIC_MAX_IDLE_TIMEOUT_MS = 30_000;

/** Wire cap on a serialized open frame, checked before Zod ever runs — a
 *  `{kind, projectId, ...}` record needs a few hundred bytes at most, so this
 *  is generous headroom against a hostile or corrupt peer forcing an
 *  oversized parse. */
export const STREAM_OPEN_MAX_BYTES = 4096;

/** Per-id length bound. Real ids are 16-char hex project ids, checkout names
 *  and UUIDs; at 200 UTF-16 units even a terminal frame whose three ids are
 *  entirely JSON-escaped stays under STREAM_OPEN_MAX_BYTES, so a valid open
 *  can never be refused for size. */
export const STREAM_OPEN_MAX_ID_LENGTH = 200;

const StreamId = z.string().min(1).max(STREAM_OPEN_MAX_ID_LENGTH);

// The first stream on a connection must declare this kind and keeps carrying
// the full legacy protocol (A1). It is part of the union so a dispatch table
// keyed by `kind` has one shape to switch on, not a special case beside it.
export const SessionStreamOpen = z.strictObject({
  kind: z.literal("session"),
});

// No `checkoutId`: a project stream is per PROJECT, and checkout routing
// stays per message on it.
export const ProjectStreamOpen = z.strictObject({
  kind: z.literal("project"),
  projectId: StreamId,
});

// `requestId` is what a terminal stream binds by BEFORE the bridge has minted
// an `attachmentId` — `terminal:subscribe`'s reply and any `UPGRADE_REQUIRED`
// refusal both carry only `requestId`. `checkoutId` is optional for the same
// reason it is on `terminal:subscribe`: absent means the main checkout.
export const TerminalStreamOpen = z.strictObject({
  kind: z.literal("terminal"),
  projectId: StreamId,
  checkoutId: StreamId.optional(),
  requestId: StreamId,
});

// One stream per HTTP request/response pair; `requestId` is the same id the
// app already mints for `tunnel:http-request`.
export const TunnelHttpStreamOpen = z.strictObject({
  kind: z.literal("tunnel-http"),
  projectId: StreamId,
  requestId: StreamId,
});

// One stream per browser-side WebSocket for the tunnel's lifetime; `wsId`
// carries the `tunnelId` the app mints for `tunnel:ws-open`.
export const TunnelWsStreamOpen = z.strictObject({
  kind: z.literal("tunnel-ws"),
  projectId: StreamId,
  wsId: StreamId,
});

export const STREAM_UPLOAD_MAX_FILE_NAME_LENGTH = 255;
export const STREAM_UPLOAD_MAX_MIME_TYPE_LENGTH = 127;

// One stream per file. `checkoutId` follows `TerminalStreamOpen`: absent means
// the main checkout. `size` is the DECLARED byte count — whether it exceeds
// the bridge's upload ceiling is a per-file result (TOO_LARGE), never a
// schema rejection, since only the bridge knows that limit.
export const UploadStreamOpen = z.strictObject({
  kind: z.literal("upload"),
  projectId: StreamId,
  checkoutId: StreamId.optional(),
  requestId: StreamId,
  fileName: z.string().min(1).max(STREAM_UPLOAD_MAX_FILE_NAME_LENGTH),
  size: z.number().int().nonnegative(),
  mimeType: z.string().min(1).max(STREAM_UPLOAD_MAX_MIME_TYPE_LENGTH).optional(),
});

export const StreamOpen = z.discriminatedUnion("kind", [
  SessionStreamOpen,
  ProjectStreamOpen,
  TerminalStreamOpen,
  TunnelHttpStreamOpen,
  TunnelWsStreamOpen,
  UploadStreamOpen,
]);

export type SessionStreamOpen = z.infer<typeof SessionStreamOpen>;
export type ProjectStreamOpen = z.infer<typeof ProjectStreamOpen>;
export type TerminalStreamOpen = z.infer<typeof TerminalStreamOpen>;
export type TunnelHttpStreamOpen = z.infer<typeof TunnelHttpStreamOpen>;
export type TunnelWsStreamOpen = z.infer<typeof TunnelWsStreamOpen>;
export type UploadStreamOpen = z.infer<typeof UploadStreamOpen>;
export type StreamOpen = z.infer<typeof StreamOpen>;
export type StreamOpenKind = StreamOpen["kind"];

// Dart cannot read a QUIC reset code, so every refusal the app must act on is
// this in-band record followed by FIN; a reset code is bridge diagnostics only.
//   NOT_READY: the project core this stream would bind to has not finished
//     starting (hazard J, §1.5); the app should wait for the session-stream
//     ready notice and retry, not park the open. Also covers a project
//     stream itself opened before the project has a relay-registered core.
//   NOT_ALLOWED: remote access is off, the project is unknown or unsafe, or
//     the peer's project binding does not authorize this stream (a terminal,
//     tunnel or upload open with no open project stream for the same
//     projectId).
//   CAP_EXCEEDED: a D7 per-peer cap below (terminals, tunnels or uploads) is
//     already at its limit.
//   INVALID: the open frame failed to parse or exceeded STREAM_OPEN_MAX_BYTES.
export const StreamRefusedCode = z.enum([
  "NOT_READY",
  "NOT_ALLOWED",
  "CAP_EXCEEDED",
  "INVALID",
]);
export type StreamRefusedCode = z.infer<typeof StreamRefusedCode>;

export const StreamRefused = z.strictObject({
  type: z.literal("stream:refused"),
  code: StreamRefusedCode,
  message: z.string(),
});
export type StreamRefused = z.infer<typeof StreamRefused>;

// Stream caps, mirrored by hand in stream_open.dart. Only the bridge can set
// the QUIC bidi limit (Dart has no setter), so the app holds semaphores at the
// per-peer caps. Their sum plus the session stream must stay under the QUIC
// limit: then an over-cap open is always an in-band CAP_EXCEEDED, never an
// `openBi` that stalls on QUIC flow control.
export const STREAM_MAX_BIDI_STREAMS_PER_CONNECTION = 256;
export const STREAM_MAX_PROJECTS_PER_PEER = 32;
export const STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER = 64;
export const STREAM_MAX_TUNNEL_STREAMS_PER_PEER = 128;
export const STREAM_MAX_PENDING_OPENS_PER_PEER = 16;
// Sum invariant, restated here because a new per-peer cap has to keep it true:
// 32 + 64 + 128 + 4 (uploads) + 1 (session) = 229 < 256.
export const STREAM_MAX_UPLOAD_STREAMS_PER_PEER = 4;

// Per-record caps for the project stream, asymmetric by direction:
// the app sends small verbs and reads back potentially large payloads
// (file:content, diffs), so its read cap is the bridge's write ceiling while
// its own send cap stays far below it.
export const STREAM_PROJECT_APP_RECORD_MAX_BYTES = 1_500_000;
export const STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES = MAX_TRANSFER_BYTES;

// Per-record caps for the terminal attachment stream (A2). The app-to-bridge
// direction only ever carries the four small subscribe/ack/unsubscribe/
// history-request verbs; the bridge-to-app direction carries frames and
// history pages, so its cap is set to twice the bridge's
// `TERMINAL_VIEWER_MAX_BYTES` (1 MiB) — the largest single delivery
// terminal-frames/delivery.ts ever hands over. antgrid-wire sits across the
// licence boundary from bridge/, so that derivation can't be expressed as an
// import; it's restated here as a comment instead.
export const STREAM_TERMINAL_APP_RECORD_MAX_BYTES = 16_384;
export const STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES = 2_097_152;

// Per-record caps for the tunnel stream (A3, one stream per HTTP request or
// browser-side WebSocket). `STREAM_TUNNEL_DATA_MAX_BYTES` bounds the payload
// after a data record's tag byte; `STREAM_TUNNEL_RECORD_MAX_BYTES` is what the
// reader checks against (payload + the tag), and applies in both directions.
export const STREAM_TUNNEL_DATA_MAX_BYTES = 1_048_576;
export const STREAM_TUNNEL_RECORD_MAX_BYTES = STREAM_TUNNEL_DATA_MAX_BYTES + 1;
/** = MAX_TRANSFER_BYTES: a tunneled request body is bounded exactly as a
 *  session-path transfer is. Restated as its own constant because antgrid-wire
 *  sits across the licence boundary from bridge/, so the derivation can't be
 *  expressed as an import there — it is a comment instead. */
export const STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES = MAX_TRANSFER_BYTES;

/** The upload stream's one bridge->app record (a `stream:refused` or a
 *  `file:upload-result`): generous over the ~2.5 KB a valid result ever needs,
 *  the same shape as the terminal/tunnel record caps above. */
export const STREAM_UPLOAD_BRIDGE_RECORD_MAX_BYTES = 16_384;

// Tunnel data records carry only WS frames: an HTTP body rides the stream as
// raw bytes with no tag byte at all, so `0x00`/`0x01` are retired rather than
// reassigned.
export const TUNNEL_RECORD_TAG_WS_TEXT = 0x02;
export const TUNNEL_RECORD_TAG_WS_BINARY = 0x03;

export type TunnelDataTag =
  | typeof TUNNEL_RECORD_TAG_WS_TEXT
  | typeof TUNNEL_RECORD_TAG_WS_BINARY;

const TUNNEL_DATA_TAGS: ReadonlySet<number> = new Set<number>([
  TUNNEL_RECORD_TAG_WS_TEXT,
  TUNNEL_RECORD_TAG_WS_BINARY,
]);

/** A tunnel-stream record's first byte, discriminating JSON control records
 *  from tagged binary data records (§1.1). */
const JSON_RECORD_FIRST_BYTE = 0x7b; // "{"

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });

/** One tag byte + payload, the wire shape of a tunnel stream's binary data
 *  records. Throws `RangeError` for an unknown tag or a payload over
 *  `STREAM_TUNNEL_DATA_MAX_BYTES` — both are this side's own bug to catch
 *  before ever reaching the wire, never a hostile peer's to trigger. */
export function encodeTunnelDataRecord(tag: TunnelDataTag, payload: Uint8Array): Uint8Array {
  if (!TUNNEL_DATA_TAGS.has(tag)) throw new RangeError(`Unknown tunnel data tag: ${tag}`);
  if (payload.length > STREAM_TUNNEL_DATA_MAX_BYTES) {
    throw new RangeError(`Tunnel data payload (${payload.length}) exceeds STREAM_TUNNEL_DATA_MAX_BYTES`);
  }
  const out = new Uint8Array(payload.length + 1);
  out[0] = tag;
  out.set(payload, 1);
  return out;
}

export type TunnelRecord =
  | { kind: "json"; text: string }
  | { kind: "data"; tag: TunnelDataTag; payload: Uint8Array };

/** Decodes one already length-delimited tunnel-stream record (§1.1): a `0x7B`
 *  first byte is UTF-8 JSON, any other recognized byte is a tagged data
 *  record whose payload is a VIEW into `record`, not a copy. `null` for an
 *  empty record, an unrecognized tag, or a `0x7B`-led body that fails to
 *  decode as UTF-8 — never throws, so a malformed record is refusable by its
 *  caller rather than connection-fatal. */
export function decodeTunnelRecord(record: Uint8Array): TunnelRecord | null {
  if (record.length === 0) return null;
  const first = record[0]!;
  if (first === JSON_RECORD_FIRST_BYTE) {
    try {
      return { kind: "json", text: textDecoder.decode(record) };
    } catch {
      return null;
    }
  }
  if (!TUNNEL_DATA_TAGS.has(first)) return null;
  return { kind: "data", tag: first as TunnelDataTag, payload: record.subarray(1) };
}

/** The open-frame body: `StreamOpen.parse(open)` then UTF-8 JSON. There is no
 *  length prefix here — the caller frames it (`[u32 BE len][body]`), matching
 *  the bytes `PeerStreamOpener` writes on the Dart side. */
export function encodeStreamOpen(open: StreamOpen): Uint8Array {
  return textEncoder.encode(JSON.stringify(StreamOpen.parse(open)));
}

/** Never throws: a hostile or corrupt peer's open frame must be refusable,
 *  not fatal to the connection. `STREAM_OPEN_MAX_BYTES` is checked before the
 *  UTF-8 decode so an oversized frame is rejected without paying for it. */
export function decodeStreamOpen(bytes: Uint8Array): StreamOpen | null {
  if (bytes.length > STREAM_OPEN_MAX_BYTES) return null;
  let text: string;
  try {
    text = textDecoder.decode(bytes);
  } catch {
    return null;
  }
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch {
    return null;
  }
  const parsed = StreamOpen.safeParse(json);
  return parsed.success ? parsed.data : null;
}

/** `StreamRefused.parse(refused)` then UTF-8 JSON, unframed like `encodeStreamOpen`. */
export function encodeStreamRefused(refused: StreamRefused): Uint8Array {
  return textEncoder.encode(JSON.stringify(StreamRefused.parse(refused)));
}

/** Never throws, mirroring `decodeStreamOpen`. */
export function decodeStreamRefused(bytes: Uint8Array): StreamRefused | null {
  let text: string;
  try {
    text = textDecoder.decode(bytes);
  } catch {
    return null;
  }
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch {
    return null;
  }
  const parsed = StreamRefused.safeParse(json);
  return parsed.success ? parsed.data : null;
}
