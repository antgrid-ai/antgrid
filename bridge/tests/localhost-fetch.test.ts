import { describe, it, expect, afterAll } from "bun:test";
import {
  fetchLocalhost,
  UpstreamBodyError,
  type LocalhostFetchStream,
  type TunnelBodySlice,
} from "../src/localhost-fetch";
import { base64Length } from "../src/tunnel-protocol";

const servers: Array<ReturnType<typeof Bun.serve>> = [];

function startTestServer() {
  const server = Bun.serve({
    port: 0, // random available port
    fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/json") {
        return new Response(JSON.stringify({ ok: true }), {
          headers: { "Content-Type": "application/json" },
        });
      }
      if (url.pathname === "/binary") {
        const buf = new Uint8Array([0x89, 0x50, 0x4e, 0x47]); // PNG header
        return new Response(buf, {
          headers: { "Content-Type": "image/png" },
        });
      }
      if (url.pathname === "/slow") {
        return new Promise((resolve) => {
          setTimeout(() => resolve(new Response("slow")), 15_000);
        });
      }
      if (url.pathname === "/redirect") {
        return new Response(null, {
          status: 302,
          headers: { Location: "/landed", "Set-Cookie": "sid=abc; Path=/" },
        });
      }
      if (url.pathname === "/multicookie") {
        const h = new Headers();
        h.append("Set-Cookie", "session=xyz; Path=/; HttpOnly");
        h.append("Set-Cookie", "csrf=123; Path=/");
        return new Response("ok", { headers: h });
      }
      if (url.pathname === "/gzipped.css") {
        // Pre-gzipped body + content-encoding, like a dev server compressing
        // assets. fetch() must decompress it AND the stale framing headers
        // must not survive into the forwarded response.
        const gz = Bun.gzipSync(Buffer.from("body { color: red; }"));
        return new Response(gz, {
          headers: {
            "Content-Type": "text/css",
            "Content-Encoding": "gzip",
            "Content-Length": String(gz.byteLength),
          },
        });
      }
      if (url.pathname === "/bundle.js") {
        return new Response(BUNDLE_JS, {
          headers: { "Content-Type": "application/javascript" },
        });
      }
      if (url.pathname === "/tiny.js") {
        return new Response("export const a = 1;", {
          headers: { "Content-Type": "application/javascript" },
        });
      }
      if (url.pathname === "/big.png") {
        return new Response(INCOMPRESSIBLE_RANDOM, {
          headers: { "Content-Type": "image/png" },
        });
      }
      if (url.pathname === "/blob.bin") {
        return new Response(INCOMPRESSIBLE_RANDOM, {
          headers: { "Content-Type": "application/octet-stream" },
        });
      }
      if (url.pathname === "/clip.mp4") {
        return new Response(COMPRESSIBLE_MEDIA, {
          headers: { "Content-Type": "video/mp4" },
        });
      }
      if (url.pathname === "/favicon.ico") {
        return new Response(COMPRESSIBLE_MEDIA, {
          headers: { "Content-Type": "image/x-icon" },
        });
      }
      if (url.pathname === "/chunky.bin") {
        return new Response(TEN_THOUSAND_RANDOM, {
          headers: { "Content-Type": "application/octet-stream" },
        });
      }
      if (url.pathname === "/exact.bin") {
        return new Response(EIGHT_K_RANDOM, {
          headers: { "Content-Type": "application/octet-stream" },
        });
      }
      if (url.pathname === "/prose.txt") {
        return new Response(COMPRESSIBLE_TEXT, {
          headers: { "Content-Type": "text/plain" },
        });
      }
      return new Response("Hello");
    },
  });
  servers.push(server);
  return server;
}

/** A one-route server whose body is a ReadableStream the test drives, plus the
 *  flag that proves the upstream connection was actually closed — the only
 *  observable difference between aborting the fetch and merely cancelling the
 *  reader, and the whole point of several cases below. */
function startStreamServer(opts: {
  contentType?: string;
  pump: (c: ReadableStreamDefaultController<Uint8Array>) => void;
}) {
  const state = { cancelled: false };
  const server = Bun.serve({
    port: 0,
    fetch() {
      const body = new ReadableStream<Uint8Array>({
        start(c) {
          try { opts.pump(c); } catch { /* the socket went away */ }
        },
        cancel() { state.cancelled = true; },
      });
      return new Response(body, {
        headers: { "Content-Type": opts.contentType ?? "application/octet-stream" },
      });
    },
  });
  servers.push(server);
  return { server, port: server.port!, state };
}

/** A raw HTTP/1.1 origin: Bun's own server chunk-encodes a streamed body and
 *  drops the Content-Length with it, and a declared length is the whole point
 *  of the pre-read size check. `closed` is the origin's view of the abort. */
function startSizedOrigin(declared: number) {
  const state = { closed: false };
  const listener = Bun.listen({
    hostname: "127.0.0.1",
    port: 0,
    socket: {
      data(socket) {
        // Escaped, not a multi-line template: a template literal in a CRLF
        // source normalizes its own line breaks to LF, and an HTTP head
        // framed with bare LF is not parsed as one.
        socket.write(
          "HTTP/1.1 200 OK" + "\r\n"
            + "Content-Type: application/octet-stream" + "\r\n"
            + `Content-Length: ${declared}` + "\r\n\r\n",
        );
        // Under the declared length, so the response never completes on its own.
        socket.write(new Uint8Array(1024));
      },
      close() { state.closed = true; },
    },
  });
  return { port: listener.port, state, stop: () => listener.stop(true) };
}

/** Enqueue what a live controller will still take; a closed one throws. */
function push(c: ReadableStreamDefaultController<Uint8Array>, bytes: number, fill = 0x61): boolean {
  try { c.enqueue(new Uint8Array(bytes).fill(fill)); return true; } catch { return false; }
}

async function collect(
  stream: LocalhostFetchStream,
): Promise<{ slices: TunnelBodySlice[]; bytes: Buffer }> {
  const slices: TunnelBodySlice[] = [];
  for await (const slice of stream.slices) slices.push(slice);
  return { slices, bytes: decodeSlices(slices) };
}

function decodeSlices(slices: TunnelBodySlice[]): Buffer {
  return Buffer.concat(
    slices.map((s) => {
      const raw = Buffer.from(s.data, "base64");
      return s.bodyEncoding === "gzip-base64" ? Buffer.from(Bun.gunzipSync(raw)) : raw;
    }),
  );
}

/** The flush clock off, so a slow read on a loaded host cannot split a slice
 *  and a case may pin an exact slice count. */
const NO_FLUSH = { flushMs: 5_000 } as const;

async function waitUntil(condition: () => boolean, ms = 2_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition was not met");
    await Bun.sleep(5);
  }
}

// Well past GZIP_MIN_BYTES and compressible, like a real dev-server chunk.
const BUNDLE_JS = "export function hello(name) { return `hi ${name}`; }\n".repeat(400);
// Random bytes: gzip cannot shrink these, so they exercise the size check that
// backs the content-type list. NOT usable to pin the list itself — a fixture
// this incompressible is rejected by the size check whichever type it wears.
const INCOMPRESSIBLE_RANDOM = crypto.getRandomValues(new Uint8Array(16 * 1024));
const TEN_THOUSAND_RANDOM = crypto.getRandomValues(new Uint8Array(10_000));
const EIGHT_K_RANDOM = crypto.getRandomValues(new Uint8Array(8192));
// 40 KiB of compressible text: five 8192-byte slices, each of which must gzip
// on its own.
const COMPRESSIBLE_TEXT = "the quick brown fox jumps over the lazy dog\n".repeat(931).slice(0, 40 * 1024);
// Served under two media content-types that differ ONLY in whether
// isPrecompressedContentType claims them, so the pair pins that function rather
// than the size check behind it. Flat runs stand in for the large single-colour
// fields of an app icon, which is what makes a raw-bitmap .ico compressible.
const COMPRESSIBLE_MEDIA = Buffer.concat([
  Buffer.alloc(6 * 1024, 0x00),
  Buffer.alloc(6 * 1024, 0xf8),
  Buffer.alloc(4 * 1024, 0x81),
]);

afterAll(() => {
  for (const s of servers.splice(0)) s.stop(true);
});

describe("fetchLocalhost", () => {
  it("rejects non-localhost URLs", async () => {
    const result = await fetchLocalhost({ url: "http://example.com/test" });
    expect(result.status).toBe(403);
    const { slices, bytes } = await collect(result);
    expect(slices).toHaveLength(1);
    expect(slices[0]).toMatchObject({ bodyEncoding: "base64", last: true });
    expect(bytes.toString("utf8")).toContain("Forbidden");
  });

  it("decompresses gzipped bodies and strips stale framing headers", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/gzipped.css`,
      ...NO_FLUSH,
    });
    expect(result.status).toBe(200);
    expect(result.headers["content-encoding"]).toBeUndefined();
    expect(result.headers["content-length"]).toBeUndefined();
    expect(result.headers["transfer-encoding"]).toBeUndefined();
    const { bytes } = await collect(result);
    expect(bytes.toString("utf8")).toBe("body { color: red; }");
  });

  it("fetches JSON from localhost", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/json`,
      ...NO_FLUSH,
    });
    expect(result.status).toBe(200);
    const { slices, bytes } = await collect(result);
    // No acceptEncodings: every slice is plain base64.
    expect(slices.map((s) => s.bodyEncoding)).toEqual(["base64"]);
    expect(JSON.parse(bytes.toString("utf8")).ok).toBe(true);
  });

  it("returns base64 for binary content", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/binary`,
      ...NO_FLUSH,
    });
    expect(result.status).toBe(200);
    const { slices, bytes } = await collect(result);
    expect(slices).toHaveLength(1);
    expect(slices[0]).toMatchObject({ bodyEncoding: "base64", last: true });
    expect(bytes[0]).toBe(0x89);
    expect(bytes[1]).toBe(0x50);
  });

  it("includes response headers", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({ url: `http://localhost:${server.port}/json` });
    await collect(result);
    expect(result.headers["content-type"]).toContain("application/json");
  });

  it("does not follow redirects, preserving Set-Cookie on the 3xx", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({ url: `http://localhost:${server.port}/redirect` });
    await collect(result);
    // The WebView must see the redirect itself; following it here would swallow
    // the Set-Cookie that auth flows place on the 302.
    expect(result.status).toBe(302);
    expect(result.headers["location"]).toBe("/landed");
    expect(result.setCookies).toContain("sid=abc; Path=/");
  });

  it("captures every Set-Cookie on a multi-cookie response", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({ url: `http://localhost:${server.port}/multicookie` });
    await collect(result);
    expect(result.setCookies).toEqual([
      "session=xyz; Path=/; HttpOnly",
      "csrf=123; Path=/",
    ]);
    // The flattened map must not also carry it, or the proxy would emit a
    // duplicate (last-only) copy alongside the out-of-band list.
    expect(result.headers["set-cookie"]).toBeUndefined();
  });
});

describe("fetchLocalhost body compression", () => {
  it("gzips a compressible body when the caller advertises the encoding", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/bundle.js`,
      acceptEncodings: ["gzip-base64"],
      ...NO_FLUSH,
    });

    const { slices, bytes } = await collect(result);
    expect(slices.map((s) => s.bodyEncoding)).toEqual(["gzip-base64"]);
    expect(bytes.toString("utf8")).toBe(BUNDLE_JS);
    // The point of the exercise: fewer bytes for the phone to decode than the
    // raw text would have been.
    expect(slices[0].data.length).toBeLessThan(base64Length(BUNDLE_JS.length) / 2);
  });

  it("stays uncompressed for a caller that never advertised the encoding", async () => {
    const server = startTestServer();
    // An app predating acceptEncodings would render gzip bytes as text, so
    // silence must mean "send it plain".
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/bundle.js`,
      ...NO_FLUSH,
    });

    const { slices, bytes } = await collect(result);
    expect(slices.map((s) => s.bodyEncoding)).toEqual(["base64"]);
    expect(bytes.toString("utf8")).toBe(BUNDLE_JS);
  });

  it("ignores an advertisement it does not implement", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/bundle.js`,
      acceptEncodings: ["br-base64"],
      ...NO_FLUSH,
    });

    const { slices } = await collect(result);
    expect(slices.map((s) => s.bodyEncoding)).toEqual(["base64"]);
  });

  it("leaves a small body alone", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/tiny.js`,
      acceptEncodings: ["gzip-base64"],
      ...NO_FLUSH,
    });

    const { slices, bytes } = await collect(result);
    expect(slices.map((s) => s.bodyEncoding)).toEqual(["base64"]);
    expect(bytes.toString("utf8")).toBe("export const a = 1;");
  });

  it("leaves an already-compressed format alone", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/big.png`,
      acceptEncodings: ["gzip-base64"],
      ...NO_FLUSH,
    });

    const { slices, bytes } = await collect(result);
    expect(slices.map((s) => s.bodyEncoding)).toEqual(["base64"]);
    expect(bytes.equals(Buffer.from(INCOMPRESSIBLE_RANDOM))).toBe(true);
  });

  // Half of the A/B that pins the image//video//audio prefix rule: the bytes DO
  // compress, so only the content-type can be rejecting them. Skipping the
  // attempt is the point — Bun.gzipSync is synchronous and runs ~16ms/MiB on
  // incompressible input, so at real video sizes the wasted gzip stalls the
  // bridge's event loop for longer than any plausible win.
  it("skips the gzip on a media type even when the bytes would have compressed", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/clip.mp4`,
      acceptEncodings: ["gzip-base64"],
      ...NO_FLUSH,
    });

    const { slices, bytes } = await collect(result);
    expect(slices.map((s) => s.bodyEncoding)).toEqual(["base64"]);
    expect(bytes.equals(COMPRESSIBLE_MEDIA)).toBe(true);
  });

  // The other half, same bytes: raw-bitmap and PCM containers live under a media
  // type but store their samples uncompressed, so the prefix rule has to exempt
  // them. A favicon.ico is the one that recurs — a WebView requests it on every
  // page load, and the classic multi-size BMP form clears GZIP_MIN_BYTES.
  it("compresses a raw-bitmap media type the prefix rule would otherwise claim", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/favicon.ico`,
      acceptEncodings: ["gzip-base64"],
      ...NO_FLUSH,
    });

    const { slices, bytes } = await collect(result);
    expect(slices.map((s) => s.bodyEncoding)).toEqual(["gzip-base64"]);
    expect(bytes.equals(COMPRESSIBLE_MEDIA)).toBe(true);
  });

  // The content-type list can't know every incompressible format, so the size
  // check behind it is the real guard — and only a type that list MISSES
  // reaches it. Without this, inverting the comparison passes every test while
  // making incompressible bodies ~33% larger on the wire.
  it("discards a gzip that came out bigger than the plain encoding", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/blob.bin`,
      acceptEncodings: ["gzip-base64"],
      ...NO_FLUSH,
    });

    const { slices, bytes } = await collect(result);
    expect(slices.map((s) => s.bodyEncoding)).toEqual(["base64"]);
    expect(bytes.equals(Buffer.from(INCOMPRESSIBLE_RANDOM))).toBe(true);
  });

  it("gzips each slice as an independent member", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/prose.txt`,
      acceptEncodings: ["gzip-base64"],
      chunkBytes: 8192,
      ...NO_FLUSH,
    });

    const { slices, bytes } = await collect(result);
    expect(slices).toHaveLength(5);
    for (const slice of slices) {
      expect(slice.bodyEncoding).toBe("gzip-base64");
      // Each one inflates ON ITS OWN — no decoder state crosses a slice, which
      // is what lets the app decode 8 KiB at a time and a replayed frame stand
      // alone.
      expect(() => Bun.gunzipSync(Buffer.from(slice.data, "base64"))).not.toThrow();
    }
    expect(bytes.toString("utf8")).toBe(COMPRESSIBLE_TEXT);
  });
});

describe("fetchLocalhost body slicing", () => {
  it("emits full slices then a remainder, in order", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/chunky.bin`,
      chunkBytes: 4096,
      ...NO_FLUSH,
    });

    const { slices, bytes } = await collect(result);
    expect(slices.map((s) => Buffer.from(s.data, "base64").byteLength)).toEqual([4096, 4096, 1808]);
    expect(slices.map((s) => s.last)).toEqual([false, false, true]);
    expect(bytes.equals(Buffer.from(TEN_THOUSAND_RANDOM))).toBe(true);
  });

  // The `last` flag rides the slice yielded at EOF WITH a remainder; a body that
  // divides evenly ends on a `done` read with nothing pending, so its final
  // slice is not marked and the caller terminates the stream with an `end`.
  it("ends a body that is an exact multiple of the slice size without a last slice", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/exact.bin`,
      chunkBytes: 4096,
      ...NO_FLUSH,
    });

    const { slices, bytes } = await collect(result);
    expect(slices.map((s) => s.last)).toEqual([false, false]);
    expect(bytes.equals(Buffer.from(EIGHT_K_RANDOM))).toBe(true);
  });

  it("flushes a trickling body within the flush window instead of waiting for a full slice", async () => {
    const up = startStreamServer({
      pump: (c) => {
        push(c, 1024);
        setTimeout(() => { push(c, 1024); try { c.close(); } catch {} }, 300);
      },
    });
    const result = await fetchLocalhost({ url: `http://localhost:${up.port}/`, flushMs: 50 });

    const started = Date.now();
    const it = result.slices;
    const first = await it.next();
    expect(Date.now() - started).toBeLessThan(200);
    expect(first.done).toBe(false);
    expect(Buffer.from(first.value!.data, "base64").byteLength).toBe(1024);

    const rest: TunnelBodySlice[] = [first.value!];
    for (;;) {
      const next = await it.next();
      if (next.done) break;
      rest.push(next.value);
    }
    expect(decodeSlices(rest).byteLength).toBe(2048);
  });

  // The flush deadline is anchored at the FIRST pending byte, never re-armed by
  // a later read: an event stream ticking faster than the window would
  // otherwise withhold slice 0 — and with it the response head, which rides the
  // start frame — until EOF.
  it("yields a steady event stream's first slice within the flush window", async () => {
    const up = startStreamServer({
      contentType: "text/event-stream",
      pump: (c) => {
        let n = 0;
        const timer = setInterval(() => {
          if (n++ >= 50 || !push(c, 64)) {
            clearInterval(timer);
            try { c.close(); } catch { /* already gone */ }
          }
        }, 20);
      },
    });
    const result = await fetchLocalhost({ url: `http://localhost:${up.port}/`, flushMs: 50 });

    const started = Date.now();
    const it = result.slices;
    const first = await it.next();
    expect(Date.now() - started).toBeLessThan(150);
    expect(first.done).toBe(false);

    const all: TunnelBodySlice[] = [first.value!];
    for (;;) {
      const next = await it.next();
      if (next.done) break;
      all.push(next.value);
    }
    expect(decodeSlices(all).byteLength).toBe(50 * 64);
  });
});

describe("fetchLocalhost body failures and cancellation", () => {
  it("throws from the iterator and closes the upstream when the body stalls", async () => {
    const up = startStreamServer({ pump: (c) => { push(c, 100); } });
    const result = await fetchLocalhost({ url: `http://localhost:${up.port}/`, readIdleMs: 100, flushMs: 20 });

    await expect(collect(result)).rejects.toThrow(/stalled/);
    await waitUntil(() => up.state.cancelled);
  });

  // A consumer parked between slices is not upstream silence: the idle clock is
  // per outstanding read, so a healthy body survives a park longer than it.
  it("does not fail a healthy body when the consumer parks past the read idle limit", async () => {
    const up = startStreamServer({
      pump: (c) => {
        push(c, 100);
        setTimeout(() => { push(c, 100); try { c.close(); } catch {} }, 30);
      },
    });
    const result = await fetchLocalhost({ url: `http://localhost:${up.port}/`, readIdleMs: 100, flushMs: 20 });

    const it = result.slices;
    const first = await it.next();
    expect(first.done).toBe(false);
    await Bun.sleep(300);

    const rest: TunnelBodySlice[] = [first.value!];
    for (;;) {
      const next = await it.next();
      if (next.done) break;
      rest.push(next.value);
    }
    expect(decodeSlices(rest).byteLength).toBe(200);
  });

  it("throws instead of truncating a body past the size cap", async () => {
    const streamed = startStreamServer({ pump: (c) => { push(c, 8192); } });
    const result = await fetchLocalhost({
      url: `http://localhost:${streamed.port}/`,
      maxBodyBytes: 4096,
      readIdleMs: 500,
      ...NO_FLUSH,
    });
    await expect(collect(result)).rejects.toThrow(/MAX_BODY_SIZE/);

    // A DECLARED length over the cap is answered before a byte is read — and
    // the origin seeing its connection close is the proof the fetch was
    // aborted rather than left streaming behind the 413.
    const sized = startSizedOrigin(8192);
    try {
      const declared = await fetchLocalhost({
        url: `http://127.0.0.1:${sized.port}/`,
        maxBodyBytes: 4096,
        ...NO_FLUSH,
      });
      expect(declared.status).toBe(413);
      const { slices, bytes } = await collect(declared);
      expect(slices).toHaveLength(1);
      expect(bytes.toString("utf8")).toContain("too large");
      await waitUntil(() => sized.state.closed);
    } finally {
      sized.stop();
    }
  });

  it("does not apply the head timeout to the body", async () => {
    const up = startStreamServer({
      pump: (c) => {
        let n = 0;
        const timer = setInterval(() => {
          if (n++ >= 10 || !push(c, 128)) {
            clearInterval(timer);
            try { c.close(); } catch { /* already gone */ }
          }
        }, 50);
      },
    });
    const result = await fetchLocalhost({
      url: `http://localhost:${up.port}/`,
      headTimeoutMs: 200,
      ...NO_FLUSH,
    });
    const { bytes } = await collect(result);
    expect(bytes.byteLength).toBe(10 * 128);
  });

  it("ends the iterator and closes the upstream on a caller abort", async () => {
    const up = startStreamServer({
      pump: (c) => {
        const timer = setInterval(() => { if (!push(c, 512)) clearInterval(timer); }, 20);
      },
    });
    const ctrl = new AbortController();
    const result = await fetchLocalhost({
      url: `http://localhost:${up.port}/`,
      signal: ctrl.signal,
      chunkBytes: 512,
      flushMs: 20,
    });

    const it = result.slices;
    expect((await it.next()).done).toBe(false);
    ctrl.abort();
    await expect(it.next()).rejects.toThrow();
    await waitUntil(() => up.state.cancelled);
  });

  it("closes the upstream when the consumer breaks out of the iterator", async () => {
    const up = startStreamServer({
      pump: (c) => {
        const timer = setInterval(() => { if (!push(c, 512)) clearInterval(timer); }, 20);
      },
    });
    const result = await fetchLocalhost({
      url: `http://localhost:${up.port}/`,
      chunkBytes: 512,
      flushMs: 20,
    });

    const it = result.slices;
    expect((await it.next()).done).toBe(false);
    await it.return(undefined);
    await waitUntil(() => up.state.cancelled);
  });
});
