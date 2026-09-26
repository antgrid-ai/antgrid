import { z } from "zod";

/** App → bridge, 2nd record on an HTTP tunnel stream (after the A0b open
 *  frame). Carries no body: the body follows as exactly `bodyLength` raw
 *  bytes, which both ends check against
 *  (docs/iroh-reduction/stage-A-A3-contract.md §1.3, the truncation trap). */
export const TunnelHttpRequest = z.object({
  type: z.literal("tunnel:http-request"),
  requestId: z.string(),
  port: z.number().int().positive(),
  scheme: z.enum(["http", "https"]).optional(),
  method: z.string(),
  path: z.string(),
  headers: z.record(z.string(), z.string()).optional(),
  bodyLength: z.number().int().nonnegative().default(0),
  checkoutId: z.string().default("main"),
});

/** Bridge → app, first record on an HTTP tunnel stream (unless refused). The
 *  response body follows as raw bytes, then FIN; a reset instead of FIN is a
 *  truncated response (D4: Dart tells the two apart natively). */
export const TunnelHttpHead = z.object({
  type: z.literal("tunnel:http-head"),
  requestId: z.string(),
  status: z.number().int(),
  headers: z.record(z.string(), z.string()),
  setCookies: z.array(z.string()).optional(),
  checkoutId: z.string().default("main"),
});

export type TunnelHttpRequest = z.infer<typeof TunnelHttpRequest>;
export type TunnelHttpHead = z.infer<typeof TunnelHttpHead>;

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

/** Max raw response-body piece sent to the app, bounded by
 *  `STREAM_RECORD_SLICE_BYTES` (262 144) from the native binding below and
 *  `STREAM_TUNNEL_DATA_MAX_BYTES` (1 MiB) from the wire above. */
export const TUNNEL_BODY_SLICE_BYTES = 262_144;

/** How long bytes short of a full slice wait for more before shipping,
 *  measured from the FIRST pending byte — never re-armed by a later read, or
 *  an event stream ticking faster than this would withhold the head (slice 0
 *  rides the head record) until a full slice or EOF. Bounds first-byte
 *  latency for a trickling body; a body that finishes arrives with its `done`
 *  immediately and never pays it. */
export const TUNNEL_CHUNK_FLUSH_MS = 50;

/** Cap on the request-body bytes `fetchWithSchemeRecovery` keeps buffered for
 *  a retry after the http/https scheme guess fails. Over this, the
 *  first attempt's error surfaces directly rather than replaying a body that
 *  exceeds what was buffered for the retry. */
export const TUNNEL_BODY_REPLAY_MAX_BYTES = 262_144;
