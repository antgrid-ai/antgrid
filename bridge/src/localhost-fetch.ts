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

export interface LocalhostFetchResult {
  status: number;
  headers: Record<string, string>;
  setCookies: string[];
  body: string;
  bodyEncoding: "utf8" | "base64";
}

export async function fetchLocalhost(opts: {
  url: string;
  method?: string;
  headers?: Record<string, string>;
  body?: string;
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

  const reader = resp.body?.getReader();
  let bodyResult: string;
  let bodyEncoding: "utf8" | "base64";

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

    if (text) {
      bodyResult = merged.toString("utf8");
      bodyEncoding = "utf8";
    } else {
      bodyResult = merged.toString("base64");
      bodyEncoding = "base64";
    }
  } finally {
    reader.cancel().catch(() => {});
  }

  return { status: resp.status, headers: respHeaders, setCookies, body: bodyResult, bodyEncoding };
}
