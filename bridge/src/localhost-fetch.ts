import { base64Length, TUNNEL_CHUNK_BYTES, TUNNEL_CHUNK_FLUSH_MS, TUNNEL_GZIP_ENCODING } from "./tunnel-protocol";

/** Hard ceiling on a tunneled body. Enforced, never silently truncated: a known
 *  content-length above it answers 413 before a byte is read, and an unknown
 *  one that crosses it mid-body fails the stream. Does NOT bound this process's
 *  RSS — Bun drains the upstream socket regardless of read pace, so only the
 *  content-length pre-check keeps a huge body out of memory at all. */
const MAX_BODY_SIZE = 100 * 1024 * 1024; // 100MB
// Generous: dev-server cold compiles (Next/webpack first page) routinely
// exceed 10s. Kept under the app's 30s head timeout so the bridge's 502
// (with the real error) wins over a phone-side TimeoutException. Bounds
// HEADERS only — a 100 MB body at phone speed legitimately outlives it.
export const FETCH_HEAD_TIMEOUT_MS = 25_000;
/** How long ONE outstanding `reader.read()` may stay unresolved, clocked from
 *  when it was ISSUED. Bun reads the upstream ahead of us, so a read still
 *  outstanding really did see no upstream data — this measures the dev server's
 *  silence, never the app's: the slice loop parks between reads whenever the
 *  consumer is waiting on a send to settle, and that park is not counted. */
export const FETCH_READ_IDLE_MS = 25_000;

const ALLOWED_HOSTNAMES = new Set(["localhost", "127.0.0.1", "[::1]", "0.0.0.0"]);

// Transport failures where the OTHER scheme is worth exactly one attempt.
// Plaintext at a TLS listener resets (the listener cannot read the bytes as a
// handshake record and hangs up); TLS at a plaintext listener is refused, the
// same as a dead port. Each is listed under both spellings Bun reports it by —
// which of the two arrives is not something this side can pin down. Nothing
// else belongs here — a timeout above all, where a retry would double a wait
// the app is already timing.
const SCHEME_RETRY_CODES = new Set([
  "ECONNRESET",
  "ConnectionClosed",
  "ECONNREFUSED",
  "ConnectionRefused",
]);

function isSchemeRetryable(err: unknown): boolean {
  // The code sits on the error itself, or on the `cause` of a wrapping
  // `TypeError: fetch failed` — reading only the outer one leaves the retry
  // silently never firing, and a TLS-only dev server as unreachable as it was
  // before.
  const e = err as { code?: unknown; cause?: { code?: unknown } } | null;
  const code = typeof e?.code === "string" ? e.code : e?.cause?.code;
  return typeof code === "string" && SCHEME_RETRY_CODES.has(code);
}

// Ports proven to need TLS, so only the first request of a page load pays the
// failed round trip. Keyed by port alone: every hostname above is an alias for
// this machine's loopback, so a listener that speaks TLS speaks it under all of
// them. A dev server the bridge never saw announce itself — anything started
// outside a project terminal, an Aspire AppHost being the common one — reaches
// us with the phone's default `http`, and this is the only place that can
// correct it.
const tlsOnlyPorts = new Set<number>();

/** Whether `localhost:<port>` has been observed to require TLS. The WebSocket
 *  upstream reads this instead of retrying: a failed handshake there is
 *  indistinguishable from a dev server refusing the connection outright. */
export function isTlsOnlyPort(port: number): boolean {
  return tlsOnlyPorts.has(port);
}

// Formats that are already compressed — gzipping them burns CPU on both ends to
// grow the payload.
const PRECOMPRESSED_CONTENT_TYPES = new Set([
  "application/zip",
  "application/gzip",
  "application/x-gzip",
  "application/x-7z-compressed",
  "application/x-rar-compressed",
  "application/x-bzip2",
  "application/pdf",
  "font/woff",
  "font/woff2",
  "application/font-woff",
  "application/font-woff2",
]);

// Media types the prefix rule below would wrongly claim: SVG is markup, and the
// rest are containers that store their samples raw. They need naming because the
// prefix rule is one-way — a body it lets through that turns out incompressible
// is caught by the size check in `encodeChunk`, but one it BLOCKS is never
// reconsidered, and base64 is unconditionally ~33% over the raw bytes. Cheap to
// exempt: these are small (a multi-size favicon.ico gzips in ~0.05ms), unlike
// the megabyte media the prefix rule exists to keep off a synchronous gzip.
const UNCOMPRESSED_MEDIA_CONTENT_TYPES = new Set([
  "image/svg+xml",
  "image/x-icon",
  "image/vnd.microsoft.icon",
  "image/bmp",
  "image/x-ms-bmp",
  "image/tiff",
  "audio/wav",
  "audio/x-wav",
  "audio/wave",
  "audio/vnd.wave",
  "audio/aiff",
  "audio/x-aiff",
]);

function isPrecompressedContentType(ct: string): boolean {
  const lower = ct.toLowerCase().split(";")[0].trim();
  if (UNCOMPRESSED_MEDIA_CONTENT_TYPES.has(lower)) return false;
  if (lower.startsWith("image/") || lower.startsWith("video/") || lower.startsWith("audio/")) {
    return true;
  }
  return PRECOMPRESSED_CONTENT_TYPES.has(lower);
}

// Below this, deflate's own framing plus base64 can outweigh the saving, and the
// phone-side decode cost is already noise.
const GZIP_MIN_BYTES = 4096;

/** One body slice, ready to ride a `tunnel:http-start` or `tunnel:http-chunk`.
 *  [last] means the upstream body ended WITH this slice (see
 *  {@link LocalhostFetchStream.slices}). */
export interface TunnelBodySlice {
  data: string;
  bodyEncoding: "base64" | typeof TUNNEL_GZIP_ENCODING;
  last: boolean;
}

export interface LocalhostFetchStream {
  status: number;
  headers: Record<string, string>;
  setCookies: string[];
  /** Body slices in read order, each ≤ `chunkBytes` raw. Single consumer;
   *  calling `return()` (or breaking out of `for await`) cancels the upstream
   *  read. `last` is true only on a slice yielded at EOF with a pending
   *  remainder — a body that is an exact multiple of `chunkBytes` ends with a
   *  `done` read and no remainder, so its final slice carries `last: false`. */
  slices: AsyncGenerator<TunnelBodySlice, void, void>;
}

/** The body failed AFTER the head went out: the caller must end the stream
 *  with an error rather than synthesise a 502 (headers are already out). */
export class UpstreamBodyError extends Error {}

interface ChunkOpts {
  contentType: string;
  acceptsGzip: boolean;
  chunkBytes: number;
  flushMs: number;
  readIdleMs: number;
  maxBodyBytes: number;
}

/**
 * Serialize ONE body slice for the tunnel, compressing when the caller
 * advertised support and it actually pays. The phone's cost is dominated by
 * JSON-decoding this string on its UI isolate, and gzip helps that twice over:
 * ~3x fewer bytes, and base64 has no characters JSON must escape — whereas raw
 * JS/CSS is dense with quotes and backslashes, which drops Dart's parser onto
 * its slow unescape path. Every gzip slice is an INDEPENDENT member, so no
 * decoder state crosses slices and a slice that grew under gzip ships plain.
 */
function encodeChunk(buf: Buffer, opts: ChunkOpts, last: boolean): TunnelBodySlice {
  const plainLength = base64Length(buf.byteLength);

  if (
    opts.acceptsGzip &&
    buf.byteLength >= GZIP_MIN_BYTES &&
    !isPrecompressedContentType(opts.contentType)
  ) {
    // Zero-copy view: Buffer.concat never allocates on a SharedArrayBuffer, so
    // the cast the Uint8Array<ArrayBuffer> parameter needs is sound — and the
    // alternative would copy the whole slice just to satisfy the type.
    const gzipped = Bun.gzipSync(
      new Uint8Array(buf.buffer as ArrayBuffer, buf.byteOffset, buf.byteLength),
    );
    // The content-type list is a shortcut, not the authority. Anything it lets
    // through that turns out incompressible — a pre-minified asset served as
    // text/plain, an opaque blob under a novel type — is caught here, for the
    // price of one gzip we discard.
    if (base64Length(gzipped.byteLength) < plainLength) {
      return {
        data: Buffer.from(gzipped).toString("base64"),
        bodyEncoding: TUNNEL_GZIP_ENCODING,
        last,
      };
    }
  }

  return { data: buf.toString("base64"), bodyEncoding: "base64", last };
}

/** One slice carrying `text` verbatim — the shape every bridge-synthesised
 *  answer (403, 413) takes, so the caller has exactly one body path. */
async function* singleSlice(text: string): AsyncGenerator<TunnelBodySlice, void, void> {
  yield { data: Buffer.from(text, "utf8").toString("base64"), bodyEncoding: "base64", last: true };
}

async function* emptySlices(): AsyncGenerator<TunnelBodySlice, void, void> {}

/**
 * One fetch, retried once under the other scheme when the failure says the
 * listener disagrees about TLS.
 *
 * The phone names a scheme per port and can only ever guess it for a server it
 * never saw start (it defaults to `http`), so a TLS-only dev server was
 * previously unreachable through the tunnel — with a bare socket error for a
 * page the desktop, whose WebView dials the port directly, renders fine. The
 * mismatched attempt costs nothing upstream: it is rejected at the transport,
 * so no request is ever delivered twice and the retry is safe for any method.
 */
async function fetchWithSchemeRecovery(target: URL, init: RequestInit): Promise<Response> {
  // Empty for a default-port URL, which the tunnel never builds — memoing 0
  // for every such request would be meaningless, so leave it unkeyed.
  const port = target.port ? Number(target.port) : null;
  const knownTls = port !== null && tlsOnlyPorts.has(port);
  const first = target.protocol === "https:" || knownTls ? "https:" : "http:";
  const second = first === "https:" ? "http:" : "https:";

  const attempt = (protocol: string) => {
    const url = new URL(target);
    url.protocol = protocol;
    return fetch(url, {
      ...init,
      // Dev HTTPS servers almost always use self-signed certs. The hostname is
      // already gated to localhost by the caller, so skipping cert verification
      // here is scoped to local dev preview only.
      ...(protocol === "https:" ? { tls: { rejectUnauthorized: false } } : {}),
    });
  };

  try {
    return await attempt(first);
  } catch (err) {
    if (!isSchemeRetryable(err)) throw err;
    let resp: Response;
    try {
      resp = await attempt(second);
    } catch {
      // Both schemes failed: the port is simply not answering. Report the
      // attempt the caller actually asked for, not the speculative one.
      throw err;
    }
    if (port !== null) {
      if (second === "https:") tlsOnlyPorts.add(port);
      // The memo outlives the server that earned it — the next process on the
      // port may speak plaintext.
      else tlsOnlyPorts.delete(port);
    }
    return resp;
  }
}

export interface FetchLocalhostOpts {
  url: string;
  method?: string;
  headers?: Record<string, string>;
  body?: string;
  /** Body encodings the phone advertised (`TunnelHttpRequest.acceptEncodings`).
   *  Only ever compress what this advertised: `bodyEncoding` reaches the app
   *  as a bare string, so an app that predates the field renders the gzip
   *  bytes as the body. Compatibility rides on that one field in both
   *  directions — `z.object` strips it for an old bridge, and an old app
   *  never sends it. */
  acceptEncodings?: string[];
  /** The caller's cancel (`tunnel:http-cancel`, checkout stop). Aborts the head
   *  fetch or the pending read. */
  signal?: AbortSignal;
  // Test seams; production leaves the defaults.
  headTimeoutMs?: number;
  readIdleMs?: number;
  chunkBytes?: number;
  flushMs?: number;
  maxBodyBytes?: number;
}

export async function fetchLocalhost(opts: FetchLocalhostOpts): Promise<LocalhostFetchStream> {
  const parsed = new URL(opts.url);
  if (!ALLOWED_HOSTNAMES.has(parsed.hostname)) {
    return {
      status: 403,
      headers: {},
      setCookies: [],
      slices: singleSlice("Forbidden: only localhost URLs are allowed"),
    };
  }

  const maxBodyBytes = opts.maxBodyBytes ?? MAX_BODY_SIZE;
  // One controller for the whole exchange: aborting it is the only thing that
  // closes the upstream connection and stops the origin producing (Bun's
  // `reader.cancel()` leaves it being pulled), so every exit path below aborts.
  const ctrl = new AbortController();
  // An already-aborted signal never fires its listener, so mirror the state
  // first: without this a caller that cancelled before we were entered gets a
  // full uncancellable upstream fetch.
  if (opts.signal?.aborted) ctrl.abort();
  else opts.signal?.addEventListener("abort", () => ctrl.abort(), { once: true });
  const headTimer = setTimeout(
    () => ctrl.abort(new Error("upstream headers timed out")),
    opts.headTimeoutMs ?? FETCH_HEAD_TIMEOUT_MS,
  );
  let resp: Response;
  try {
    resp = await fetchWithSchemeRecovery(parsed, {
      method: opts.method ?? "GET",
      headers: opts.headers ?? {},
      body: opts.body,
      signal: ctrl.signal,
      // Don't follow 3xx here: the WebView is the real client and must see the
      // redirect itself. Following it would swallow the response headers of the
      // intermediate hop — and auth flows put the Set-Cookie on the redirecting
      // response, so a followed redirect silently drops the session/handoff cookie.
      redirect: "manual",
    });
  } finally {
    clearTimeout(headTimer);
  }

  // Carry Set-Cookie out-of-band: Headers.forEach flattens a repeated header to
  // a single value (Bun keeps the last), which would drop a cookie on any
  // response that sets more than one — e.g. the sign-in step that mints the
  // session and clears its handoff cookie together. getSetCookie() returns the
  // full list; skip the flattened key in the pass below (forEach yields keys
  // already lowercased) so the proxy re-emits each value exactly once.
  // Other headers that can also repeat (WWW-Authenticate, Vary, Link) stay
  // flattened — add them to this carve-out if a tunneled dev server needs them.
  const setCookies = resp.headers.getSetCookie();
  const respHeaders: Record<string, string> = {};
  resp.headers.forEach((v, k) => {
    // fetch() transparently decompressed the body, so the origin's
    // content-encoding/content-length describe bytes we no longer have —
    // forwarding them makes the WebView gunzip plain text (garbled CSS/JS)
    // or truncate on the stale length. The phone-side proxy re-frames.
    if (k === "set-cookie" || k === "content-encoding" || k === "content-length" || k === "transfer-encoding") return;
    respHeaders[k] = v;
  });

  const contentType = resp.headers.get("content-type") ?? "";
  const acceptsGzip = opts.acceptEncodings?.includes(TUNNEL_GZIP_ENCODING) ?? false;

  const declaredLength = Number(resp.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > maxBodyBytes) {
    // The abort is the load-bearing line, not the cancel: without it the origin
    // keeps streaming a >100 MB body into Bun's buffer behind a 413 that claims
    // to have read nothing.
    ctrl.abort();
    resp.body?.cancel().catch(() => {});
    return {
      status: 413,
      headers: {},
      setCookies: [],
      slices: singleSlice("Preview response too large to tunnel"),
    };
  }

  const reader = resp.body?.getReader();
  if (!reader) {
    return { status: resp.status, headers: respHeaders, setCookies, slices: emptySlices() };
  }

  return {
    status: resp.status,
    headers: respHeaders,
    setCookies,
    slices: chunkBody(reader, ctrl, {
      contentType,
      acceptsGzip,
      chunkBytes: opts.chunkBytes ?? TUNNEL_CHUNK_BYTES,
      flushMs: opts.flushMs ?? TUNNEL_CHUNK_FLUSH_MS,
      readIdleMs: opts.readIdleMs ?? FETCH_READ_IDLE_MS,
      maxBodyBytes,
    }),
  };
}

type ReadResult = Awaited<ReturnType<ReadableStreamDefaultReader<Uint8Array>["read"]>>;

/** Slice the upstream body as it arrives. Paces the caller's SEND QUEUE, not
 *  this process's memory: Bun drains the upstream socket regardless of how
 *  slowly we read (measured on 1.3.14 — 60 MB fully buffered while the reader
 *  sat paused), so nothing here bounds RSS and no "pause the reader to save
 *  memory" rule can be added that would. */
async function* chunkBody(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  ctrl: AbortController,
  o: ChunkOpts,
): AsyncGenerator<TunnelBodySlice, void, void> {
  let pending: Buffer[] = [];
  let pendingBytes = 0;
  let total = 0;
  /** When the FIRST byte of the current partial slice was buffered; null while
   *  nothing is pending. */
  let pendingSince: number | null = null;
  /** The ONE outstanding read, never two. */
  let read: Promise<ReadResult> | null = null;
  /** When `read` was created — the idle clock's anchor. */
  let readIssuedAt = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;

  const take = (n: number): Buffer => {
    // A single pending buffer is already contiguous, and everything below works
    // on views of it: concat would copy the whole read for nothing, which on a
    // fast origin (Bun hands us reads close to a megabyte) is the dominant cost
    // of slicing a large body.
    const merged = pending.length === 1 ? pending[0]! : Buffer.concat(pending, pendingBytes);
    const slice = merged.subarray(0, n);
    const rest = merged.subarray(n);
    pending = rest.byteLength > 0 ? [rest] : [];
    pendingBytes = rest.byteLength;
    // A remainder left behind by a full slice starts its own flush clock now;
    // nothing pending clears it.
    pendingSince = pendingBytes > 0 ? Date.now() : null;
    return slice;
  };

  try {
    for (;;) {
      if (read === null) {
        read = reader.read();
        readIssuedAt = Date.now();
      }
      const outstanding = read;
      const now = Date.now();
      // Two clocks, neither re-armed by a read that brings no decision: the
      // flush deadline is fixed at pendingSince + flushMs, the idle deadline at
      // readIssuedAt + readIdleMs. A park at the `yield` below (the consumer
      // waiting on a send to settle) moves neither — a read still outstanding
      // across the park saw no data, which is the only thing the idle clock
      // claims, and a flush deadline re-armed per read would never fire for an
      // event stream ticking faster than it.
      const waitMs = pendingBytes > 0
        ? Math.max(0, pendingSince! + o.flushMs - now)
        : Math.max(0, readIssuedAt + o.readIdleMs - now);
      const r = await Promise.race<{ kind: "read"; v: ReadResult } | { kind: "timer" }>([
        outstanding.then((v) => ({ kind: "read" as const, v })),
        new Promise((res) => { timer = setTimeout(() => res({ kind: "timer" as const }), waitMs); }),
      ]);
      clearTimeout(timer);
      if (r.kind === "timer") {
        // The read stays outstanding, so `readIssuedAt` is untouched.
        if (pendingBytes > 0) { yield encodeChunk(take(pendingBytes), o, false); continue; }
        throw new UpstreamBodyError("upstream body stalled");
      }
      read = null;
      if (r.v.done) {
        if (pendingBytes > 0) yield encodeChunk(take(pendingBytes), o, true);
        return;
      }
      total += r.v.value.byteLength;
      if (total > o.maxBodyBytes) throw new UpstreamBodyError("body exceeds MAX_BODY_SIZE");
      if (pendingBytes === 0) pendingSince = Date.now();
      pending.push(Buffer.from(r.v.value));
      pendingBytes += r.v.value.byteLength;
      while (pendingBytes >= o.chunkBytes) yield encodeChunk(take(o.chunkBytes), o, false);
    }
  } finally {
    clearTimeout(timer);
    // An abort rejects the orphaned read; never an unhandled rejection.
    read?.catch(() => {});
    // THE line that closes the upstream connection and stops the origin on Bun
    // 1.3.14 — `reader.cancel()` alone leaves the origin being pulled and its
    // own `cancel` never firing. It also rejects a pending read.
    ctrl.abort();
    // Releases the reader lock only. Keep it below the abort.
    reader.cancel().catch(() => {});
  }
}
