import { z } from "zod/v4";
import { MAX_TRANSFER_BYTES } from "./frag";
import { PEER_MAX_RECORD_BYTES } from "./peer-authorization";

// The first record on every native peer stream, the session stream included.
// The app writes it in the same call as `openBi` because a Dart stream is
// invisible to the peer until its first write; the bridge reads and validates
// it under a deadline before the stream reaches its dispatch table.
//
// `MAX_TRANSFER_BYTES` and `PEER_MAX_RECORD_BYTES` are re-exported so stream
// code has one import that outlives frag.ts; the values still live in frag.ts
// and peer-authorization.ts.
export { MAX_TRANSFER_BYTES, PEER_MAX_RECORD_BYTES };

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

export const StreamOpen = z.discriminatedUnion("kind", [
  SessionStreamOpen,
  ProjectStreamOpen,
  TerminalStreamOpen,
  TunnelHttpStreamOpen,
  TunnelWsStreamOpen,
]);

export type SessionStreamOpen = z.infer<typeof SessionStreamOpen>;
export type ProjectStreamOpen = z.infer<typeof ProjectStreamOpen>;
export type TerminalStreamOpen = z.infer<typeof TerminalStreamOpen>;
export type TunnelHttpStreamOpen = z.infer<typeof TunnelHttpStreamOpen>;
export type TunnelWsStreamOpen = z.infer<typeof TunnelWsStreamOpen>;
export type StreamOpen = z.infer<typeof StreamOpen>;
export type StreamOpenKind = StreamOpen["kind"];

// Dart cannot read a QUIC reset code, so every refusal the app must act on is
// this in-band record followed by FIN; a reset code is bridge diagnostics only.
//   NOT_READY: the project core this stream would bind to has not finished
//     starting (hazard J, §1.5); the app should wait for the session-stream
//     ready notice and retry, not park the open.
//   UPDATE_REQUIRED: mirrors the existing `UPDATE_REQUIRED` code
//     (host-server.ts / project-core.ts) for a peer too old to speak this
//     stream's protocol.
//   NOT_ALLOWED: remote access is off, the project is unknown or unsafe, or
//     the peer's project binding does not authorize this stream (a terminal
//     or tunnel open with no open project stream for the same projectId).
//   CAP_EXCEEDED: a D7 per-peer cap below is already at its limit.
//   INVALID: the open frame failed to parse or exceeded STREAM_OPEN_MAX_BYTES.
export const StreamRefusedCode = z.enum([
  "NOT_READY",
  "UPDATE_REQUIRED",
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

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });

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
