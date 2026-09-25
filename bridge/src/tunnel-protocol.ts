import { z } from "zod";

/** The `acceptEncodings` token for a gzipped body record (Stage A A3). Plain
 *  `"gzip"` now that a record travels as raw bytes on its own QUIC stream —
 *  under the old session-stream path this named base64-of-gzip, because what
 *  crossed the relay was itself a base64 JSON field. */
export const TUNNEL_GZIP_ENCODING = "gzip";

/** App → bridge, 2nd record on an HTTP tunnel stream (after the A0b open
 *  frame). Carries no body: the body follows as `0x00`/`0x01` tagged records
 *  summing exactly `bodyLength`, which both ends check against
 *  (docs/iroh-reduction/stage-A-A3-contract.md §1.3, the truncation trap). */
export const TunnelHttpRequest = z.object({
  type: z.literal("tunnel:http-request"),
  requestId: z.string(),
  port: z.number().int().positive(),
  scheme: z.enum(["http", "https"]).optional(),
  method: z.string(),
  path: z.string(),
  headers: z.record(z.string(), z.string()).optional(),
  /** Body encodings the caller can decode BEYOND raw bytes. Absent means
   *  none — an older app renders an unknown-encoded record as raw bytes, so
   *  the bridge must never compress unasked. */
  acceptEncodings: z.array(z.string()).optional(),
  bodyLength: z.number().int().nonnegative().default(0),
  checkoutId: z.string().default("main"),
});

/** Bridge → app, first record on an HTTP tunnel stream (unless refused). The
 *  body follows as `0x00`/`0x01` tagged records, then `TunnelHttpEnd`. */
export const TunnelHttpHead = z.object({
  type: z.literal("tunnel:http-head"),
  requestId: z.string(),
  status: z.number().int(),
  headers: z.record(z.string(), z.string()),
  setCookies: z.array(z.string()).optional(),
  checkoutId: z.string().default("main"),
});

/** Bridge → app, last record before FIN on an HTTP tunnel stream. Required —
 *  Dart cannot tell a clean FIN from a reset (D4), so without an explicit end
 *  record the app could not tell a complete body from one the bridge reset
 *  after an upstream error; a stream that ends without it is TRUNCATED. */
export const TunnelHttpEnd = z.object({
  type: z.literal("tunnel:http-end"),
  requestId: z.string(),
  checkoutId: z.string().default("main"),
});

export type TunnelHttpRequest = z.infer<typeof TunnelHttpRequest>;
export type TunnelHttpHead = z.infer<typeof TunnelHttpHead>;
export type TunnelHttpEnd = z.infer<typeof TunnelHttpEnd>;

/** App → bridge, 2nd record on a WS tunnel stream: open a real upstream
 *  `ws(s)://localhost:<port><path>` connection for the life of the stream
 *  (one stream per browser-side tab WebSocket — a preview page's own WS, e.g.
 *  Vite HMR or a Blazor Server SignalR circuit). `tunnelId` must equal the
 *  A0b open frame's `wsId`. */
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

/** Either direction, optional, on a WS tunnel stream: the tunnel is over
 *  (the browser tab's WS closed, or the upstream dev-server connection did).
 *  FIN follows. A stream that ends with no close record is a close with no
 *  code, from the app's point of view. */
export const TunnelWsClose = z.object({
  type: z.literal("tunnel:ws-close"),
  tunnelId: z.string(),
  code: z.number().int().optional(),
  reason: z.string().optional(),
  checkoutId: z.string().default("main"),
});

export type TunnelWsOpen = z.infer<typeof TunnelWsOpen>;
export type TunnelWsClose = z.infer<typeof TunnelWsClose>;

/** Raw body bytes per slice, a multiple of 3 so a base64 rendering (if a
 *  caller ever needed one) would land exactly — kept even though the wire
 *  itself is now binary, since `STREAM_RECORD_SLICE_BYTES` (262 144) and
 *  `STREAM_TUNNEL_DATA_MAX_BYTES` (1 MiB) both bound it from above and this
 *  is the same 262 144 the app's own upload slicing uses (§1.3). */
export const TUNNEL_BODY_SLICE_BYTES = 262_144;

/** How long bytes short of a full slice wait for more before shipping,
 *  measured from the FIRST pending byte — never re-armed by a later read, or
 *  an event stream ticking faster than this would withhold the head (slice 0
 *  rides the head record) until a full slice or EOF. Bounds first-byte
 *  latency for a trickling body; a body that finishes arrives with its `done`
 *  immediately and never pays it. */
export const TUNNEL_CHUNK_FLUSH_MS = 50;
