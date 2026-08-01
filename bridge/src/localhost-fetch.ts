import { TUNNEL_GZIP_ENCODING } from "./tunnel-protocol";

const MAX_BODY_SIZE = 100 * 1024 * 1024; // 100MB
// Generous: dev-server cold compiles (Next/webpack first page) routinely
// exceed 10s. Kept under the app's 30s tunnel timeout so the bridge's 502
// (with the real error) wins over a phone-side TimeoutException.
const FETCH_TIMEOUT_MS = 25_000;

const ALLOWED_HOSTNAMES = new Set(["localhost", "127.0.0.1", "[::1]", "0.0.0.0"]);

// Text content types that are safe to decode as utf8.
// Everything else is treated as binary (base64) by default.
const TEXT_CONTENT_TYPES = new Set([
  "application/json",
  "application/xml",
  "application/xhtml+xml",
  "application/javascript",
  "application/ecmascript",
  "application/x-javascript",
  "application/ld+json",
  "application/manifest+json",
  "application/schema+json",
  "application/graphql",
  "application/x-www-form-urlencoded",
  "image/svg+xml",
]);

function isTextContentType(ct: string): boolean {
  const lower = ct.toLowerCase().split(";")[0].trim();
  if (lower.startsWith("text/")) return true;
  return TEXT_CONTENT_TYPES.has(lower);
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
// is caught by the size check in `encodeBody`, but one it BLOCKS is never
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

/** Length of the base64 encoding of `n` bytes, without encoding anything. */
function base64Length(n: number): number {
  return Math.ceil(n / 3) * 4;
}

export interface LocalhostFetchResult {
  status: number;
  headers: Record<string, string>;
  setCookies: string[];
  body: string;
  bodyEncoding: "utf8" | "base64" | typeof TUNNEL_GZIP_ENCODING;
}

/**
 * Serialize the body for the tunnel, compressing when the caller advertised
 * support and it actually pays. The phone's cost is dominated by JSON-decoding
 * this string on its UI isolate, and gzip helps that twice over: ~3x fewer
 * bytes, and base64 has no characters JSON must escape — whereas raw JS/CSS is
 * dense with quotes and backslashes, which drops Dart's parser onto its slow
 * unescape path.
 */
function encodeBody(
  merged: Buffer,
  opts: { text: boolean; contentType: string; acceptsGzip: boolean },
): { body: string; bodyEncoding: LocalhostFetchResult["bodyEncoding"] } {
  const plainEncoding = opts.text ? "utf8" : "base64";
  const plainLength = opts.text ? merged.byteLength : base64Length(merged.byteLength);

  if (
    opts.acceptsGzip &&
    merged.byteLength >= GZIP_MIN_BYTES &&
    !isPrecompressedContentType(opts.contentType)
  ) {
    // Zero-copy view: Buffer.concat never allocates on a SharedArrayBuffer, so
    // the cast the Uint8Array<ArrayBuffer> parameter needs is sound — and the
    // alternative would copy the whole body just to satisfy the type.
    const gzipped = Bun.gzipSync(
      new Uint8Array(merged.buffer as ArrayBuffer, merged.byteOffset, merged.byteLength),
    );
    // The content-type list is a shortcut, not the authority. Anything it lets
    // through that turns out incompressible — a pre-minified asset served as
    // text/plain, an opaque blob under a novel type — is caught here, for the
    // price of one gzip we discard.
    if (base64Length(gzipped.byteLength) < plainLength) {
      return {
        body: Buffer.from(gzipped).toString("base64"),
        bodyEncoding: TUNNEL_GZIP_ENCODING,
      };
    }
  }

  return { body: merged.toString(plainEncoding), bodyEncoding: plainEncoding };
}

export async function fetchLocalhost(opts: {
  url: string;
  method?: string;
  headers?: Record<string, string>;
  body?: string;
  /** Body encodings the phone advertised (`TunnelHttpRequest.acceptEncodings`). */
  acceptEncodings?: string[];
}): Promise<LocalhostFetchResult> {
  const parsed = new URL(opts.url);
  if (!ALLOWED_HOSTNAMES.has(parsed.hostname)) {
    return {
      status: 403,
      headers: {},
      setCookies: [],
      body: "Forbidden: only localhost URLs are allowed",
      bodyEncoding: "utf8",
    };
  }

  const resp = await fetch(opts.url, {
    method: opts.method ?? "GET",
    headers: opts.headers ?? {},
    body: opts.body,
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    // Don't follow 3xx here: the WebView is the real client and must see the
    // redirect itself. Following it would swallow the response headers of the
    // intermediate hop — and auth flows put the Set-Cookie on the redirecting
    // response, so a followed redirect silently drops the session/handoff cookie.
    redirect: "manual",
    // Dev HTTPS servers almost always use self-signed certs. The hostname is
    // already gated to localhost above, so skipping cert verification here is
    // scoped to local dev preview only.
    ...(parsed.protocol === "https:" ? { tls: { rejectUnauthorized: false } } : {}),
  });

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
  const text = isTextContentType(contentType);
  const acceptsGzip = opts.acceptEncodings?.includes(TUNNEL_GZIP_ENCODING) ?? false;

  const reader = resp.body?.getReader();
  let bodyResult: string;
  let bodyEncoding: LocalhostFetchResult["bodyEncoding"];

  if (!reader) {
    return { status: resp.status, headers: respHeaders, setCookies, body: "", bodyEncoding: "utf8" };
  }

  try {
    const chunks: Buffer[] = [];
    let totalBytes = 0;
    while (totalBytes < MAX_BODY_SIZE) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      chunks.push(Buffer.from(value));
    }

    const merged = Buffer.concat(chunks, Math.min(totalBytes, MAX_BODY_SIZE));

    ({ body: bodyResult, bodyEncoding } = encodeBody(merged, {
      text,
      contentType,
      acceptsGzip,
    }));
  } finally {
    reader.cancel().catch(() => {});
  }

  return { status: resp.status, headers: respHeaders, setCookies, body: bodyResult, bodyEncoding };
}
