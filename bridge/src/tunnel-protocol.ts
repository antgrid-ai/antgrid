import { z } from "zod";

/** `gzip-base64` = base64 of the gzipped body. Compressing before base64 is the
 *  only compression this tunnel can have: what crosses the relay is AES-GCM
 *  ciphertext, so WebSocket permessage-deflate would have nothing to squeeze. */
export const TUNNEL_GZIP_ENCODING = "gzip-base64";

export const TunnelHttpRequest = z.object({
  type: z.literal("tunnel:http-request"),
  requestId: z.string(),
  port: z.number().int().positive(),
  scheme: z.enum(["http", "https"]).optional(),
  method: z.string(),
  path: z.string(),
  headers: z.record(z.string(), z.string()).optional(),
  body: z.string().optional(),
  /** Body encodings the caller can decode BEYOND the mandatory utf8/base64.
   *  Absent means neither — an older app renders an unknown bodyEncoding as
   *  text, so the bridge must never compress unasked. New app + old bridge is
   *  safe for the mirror-image reason: `z.object` strips unknown keys, so this
   *  field just vanishes and the response comes back uncompressed. */
  acceptEncodings: z.array(z.string()).optional(),
  checkoutId: z.string().default("main"),
});

/** Encoding of ONE body slice. Decided per slice, never once per response: a
 *  gzip slice is an independent gzip member, so the app inflates each one on
 *  its own and a slice that would have grown under gzip ships plain. */
const TunnelSliceEncoding = z.enum(["base64", TUNNEL_GZIP_ENCODING]);

/** Bridge → app: the head of a tunneled HTTP response plus body slice 0.
 *  Exactly one per response. [last] present means slice 0 was the whole body,
 *  which is the single-frame shape nearly every page asset takes. */
export const TunnelHttpStart = z.object({
  type: z.literal("tunnel:http-start"),
  requestId: z.string(),
  status: z.number().int(),
  headers: z.record(z.string(), z.string()),
  setCookies: z.array(z.string()).optional(),
  data: z.string(),
  bodyEncoding: TunnelSliceEncoding,
  last: z.literal(true).optional(),
  checkoutId: z.string().default("main"),
});

/** Bridge → app: body slice [seq] (1-based; slice 0 rode the start). Dense and
 *  in order — a gap is the app's only signal that the relay dropped a frame,
 *  since a drop is reported to the SENDER alone. */
export const TunnelHttpChunk = z.object({
  type: z.literal("tunnel:http-chunk"),
  requestId: z.string(),
  seq: z.number().int().positive(),
  data: z.string(),
  bodyEncoding: TunnelSliceEncoding,
  checkoutId: z.string().default("main"),
});

/** Bridge → app: the response is over. [chunks] is the last `seq` emitted, so
 *  a dropped FINAL chunk — the one hole an in-order channel cannot show — is
 *  caught. [error] means the body is incomplete and must not be served as a
 *  whole response. Never sent after a `last` start. */
export const TunnelHttpEnd = z.object({
  type: z.literal("tunnel:http-end"),
  requestId: z.string(),
  chunks: z.number().int().nonnegative(),
  error: z.string().optional(),
  checkoutId: z.string().default("main"),
});

/** App → bridge: stop streaming this response. Idempotent and best-effort —
 *  an unknown requestId is a no-op. Without it a closed browser tab leaves the
 *  bridge shipping a whole body through the phone's window. */
export const TunnelHttpCancel = z.object({
  type: z.literal("tunnel:http-cancel"),
  requestId: z.string(),
  checkoutId: z.string().default("main"),
});

export type TunnelHttpRequest = z.infer<typeof TunnelHttpRequest>;
export type TunnelHttpStart = z.infer<typeof TunnelHttpStart>;
export type TunnelHttpChunk = z.infer<typeof TunnelHttpChunk>;
export type TunnelHttpEnd = z.infer<typeof TunnelHttpEnd>;
export type TunnelHttpCancel = z.infer<typeof TunnelHttpCancel>;

/** App → bridge: open a real upstream `ws(s)://localhost:<port><path>`
 *  connection, keyed by [tunnelId] for the life of the tab's WebSocket (a
 *  preview page's own WS, e.g. Vite HMR or a Blazor Server SignalR circuit —
 *  distinct from [TunnelHttpRequest]'s one-shot request/response shape). */
export const TunnelWsOpen = z.object({
  type: z.literal("tunnel:ws-open"),
  tunnelId: z.string(),
  port: z.number().int().positive(),
  scheme: z.enum(["http", "https"]).optional(),
  path: z.string(),
  /** The browser's own handshake headers, minus the ones the upstream
   *  handshake owns. Chiefly `Cookie`: a dev server that authenticates by
   *  cookie reads the WebSocket request, not the page load that preceded it,
   *  so without these the socket opens ANONYMOUSLY behind an authenticated
   *  page — which a Blazor circuit renders as "not authorized" rather than as
   *  a failure. Optional so an app predating it still opens a tunnel. */
  headers: z.record(z.string(), z.string()).optional(),
  checkoutId: z.string().default("main"),
});

/** Bidirectional once the tunnel is open: app→bridge is a browser-sent frame
 *  to relay upstream, bridge→app is an upstream-sent frame to relay to the
 *  browser. [binary] mirrors the WS frame's own text/binary distinction —
 *  absent/false means [data] is UTF-8 text verbatim; true means it is
 *  base64 of the raw bytes. Without it neither side can tell a base64-shaped
 *  TEXT frame from an encoded BINARY one. */
export const TunnelWsData = z.object({
  type: z.literal("tunnel:ws-data"),
  tunnelId: z.string(),
  data: z.string(),
  binary: z.boolean().optional(),
  checkoutId: z.string().default("main"),
});

/** Bidirectional: either side tears the tunnel down (the browser tab's WS
 *  closed, or the upstream dev-server connection did) and the other side
 *  mirrors it — never a reply the sender waits on. */
export const TunnelWsClose = z.object({
  type: z.literal("tunnel:ws-close"),
  tunnelId: z.string(),
  code: z.number().int().optional(),
  reason: z.string().optional(),
  checkoutId: z.string().default("main"),
});

export type TunnelWsOpen = z.infer<typeof TunnelWsOpen>;
export type TunnelWsData = z.infer<typeof TunnelWsData>;
export type TunnelWsClose = z.infer<typeof TunnelWsClose>;

const TunnelMessageSchema = z.discriminatedUnion("type", [
  TunnelHttpRequest,
  TunnelHttpStart,
  TunnelHttpChunk,
  TunnelHttpEnd,
  TunnelHttpCancel,
  TunnelWsOpen,
  TunnelWsData,
  TunnelWsClose,
]);

export type TunnelMessage = z.infer<typeof TunnelMessageSchema>;

export function isTunnelMessage(raw: string): boolean {
  try {
    const json = JSON.parse(raw);
    return typeof json?.type === "string" && json.type.startsWith("tunnel:");
  } catch {
    return false;
  }
}

/** Raw body bytes per slice. 192 KiB: a multiple of 3 so base64 is exactly
 *  262_144 chars; ~262 KB sealed, so two slices fill one CREDIT_BATCH_BYTES and
 *  seven pipeline inside CHANNEL_WINDOW_BYTES; well under FRAG_THRESHOLD so a
 *  slice is always a single frame (base64 needs no JSON escaping, so the bound
 *  is exact). The app does not mirror this — its contract is `seq`, not size. */
export const TUNNEL_CHUNK_BYTES = 196_608;

/** How long bytes short of a full slice wait for more before shipping,
 *  measured from the FIRST pending byte — never re-armed by a later read, or
 *  an event stream ticking faster than this would withhold the head (slice 0
 *  rides `start`) until 192 KiB or EOF. Bounds first-byte latency for a
 *  trickling body; a body that finishes arrives with its `done` immediately
 *  and never pays it. */
export const TUNNEL_CHUNK_FLUSH_MS = 50;

/** Length of the base64 encoding of `n` bytes, without encoding anything. */
export function base64Length(n: number): number {
  return Math.ceil(n / 3) * 4;
}

export function parseTunnelMessage(raw: string | object): TunnelMessage | null {
  try {
    const json = typeof raw === "string" ? JSON.parse(raw) : raw;
    const result = TunnelMessageSchema.safeParse(json);
    return result.success ? result.data : null;
  } catch {
    return null;
  }
}
