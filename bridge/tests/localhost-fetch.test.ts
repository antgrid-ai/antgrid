import { describe, it, expect, afterAll } from "bun:test";
import {
  fetchLocalhost,
  UpstreamBodyError,
  type LocalhostFetchStream,
  type TunnelRequestBody,
} from "../src/localhost-fetch";
import { TUNNEL_BODY_REPLAY_MAX_BYTES } from "../src/tunnel-protocol";

const servers: Array<ReturnType<typeof Bun.serve>> = [];

function startTestServer() {
  const server = Bun.serve({
    port: 0, // random available port
    async fetch(req) {
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
      if (url.pathname === "/allbytes.bin") {
        return new Response(ALL_BYTE_VALUES, {
          headers: { "Content-Type": "application/octet-stream" },
        });
      }
      if (url.pathname === "/echo") {
        // Echoes the request body byte-exact, plus the content-length the
        // origin actually saw — what the request-body tests below pin.
        const bytes = new Uint8Array(await req.arrayBuffer());
        return new Response(bytes, {
          headers: {
            "Content-Type": "application/octet-stream",
            "X-Echo-Length": String(bytes.byteLength),
            "X-Echo-Content-Length": req.headers.get("content-length") ?? "",
          },
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

async function collect(stream: LocalhostFetchStream): Promise<{ chunks: Uint8Array[]; bytes: Buffer }> {
  const chunks: Uint8Array[] = [];
  for await (const chunk of stream.body) chunks.push(chunk);
  return { chunks, bytes: Buffer.concat(chunks.map((c) => Buffer.from(c))) };
}

/** A `TunnelRequestBody` backed by a fixed byte array — the tunnel-streams
 *  registry's real `TunnelRequestBodySource` does the same thing off the wire
 *  (§4.1), but a fixed array is all a `fetchLocalhost`-level test needs to pin
 *  request-body forwarding and replay. `stream()` may be called more than once
 *  (the scheme retry); `replayCap` models the real cap so a body over
 *  it becomes un-replayable exactly the way a long-since-drained wire read is. */
function fixedRequestBody(bytes: Uint8Array, opts: { replayCap?: number } = {}): TunnelRequestBody {
  const replayCap = opts.replayCap ?? Infinity;
  const { promise, resolve } = Promise.withResolvers<void>();
  let calls = 0;
  return {
    length: bytes.byteLength,
    stream: () => {
      calls++;
      if (calls > 1 && bytes.byteLength > replayCap) return null;
      return new ReadableStream<Uint8Array>({
        start(c) {
          c.enqueue(bytes);
          c.close();
          resolve();
        },
      });
    },
    complete: promise,
  };
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

const TEN_THOUSAND_RANDOM = crypto.getRandomValues(new Uint8Array(10_000));
const EIGHT_K_RANDOM = crypto.getRandomValues(new Uint8Array(8192));
// Every byte value 0-255, repeated — a base64 round trip could mask a
// byte-alignment bug that a raw-bytes pipe cannot: this range includes bytes
// invalid as UTF-8 lone continuation/lead bytes.
const ALL_BYTE_VALUES = (() => {
  const one = new Uint8Array(256);
  for (let i = 0; i < 256; i++) one[i] = i;
  const out = new Uint8Array(one.length * 32);
  for (let i = 0; i < 32; i++) out.set(one, i * one.length);
  return out;
})();

afterAll(() => {
  for (const s of servers.splice(0)) s.stop(true);
});

describe("fetchLocalhost", () => {
  it("rejects non-localhost URLs", async () => {
    const result = await fetchLocalhost({ url: "http://example.com/test" });
    expect(result.status).toBe(403);
    const { bytes } = await collect(result);
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
    const { bytes } = await collect(result);
    expect(JSON.parse(bytes.toString("utf8")).ok).toBe(true);
  });

  it("returns raw bytes for binary content", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/binary`,
      ...NO_FLUSH,
    });
    expect(result.status).toBe(200);
    const { bytes } = await collect(result);
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

  it("round-trips every byte value byte-exact", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/allbytes.bin`,
      ...NO_FLUSH,
    });
    const { bytes } = await collect(result);
    expect(bytes.equals(Buffer.from(ALL_BYTE_VALUES))).toBe(true);
  });
});

describe("fetchLocalhost request body (raw, streamed via TunnelRequestBody)", () => {
  it("forwards a request body byte-exact, with content-length set from the body's own declared length", async () => {
    const server = startTestServer();
    const payload = new TextEncoder().encode("the quick brown fox jumps over the lazy dog");
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/echo`,
      method: "POST",
      body: fixedRequestBody(payload),
      ...NO_FLUSH,
    });
    expect(result.status).toBe(200);
    expect(result.headers["x-echo-content-length"]).toBe(String(payload.byteLength));
    const { bytes } = await collect(result);
    expect(bytes.equals(Buffer.from(payload))).toBe(true);
  });

  it("sends the request as a streamed body (duplex: half) rather than buffering it whole first", async () => {
    // A `ReadableStream` request body needs `duplex: "half"` on `fetch()` or
    // undici/Bun reject it outright — this is the regression a bad refactor
    // would hit immediately, not a subtle behavior difference.
    const server = startTestServer();
    let pulled = 0;
    const body: TunnelRequestBody = {
      length: 6,
      stream: () => new ReadableStream<Uint8Array>({
        pull(c) {
          pulled++;
          if (pulled === 1) { c.enqueue(new TextEncoder().encode("ab")); return; }
          if (pulled === 2) { c.enqueue(new TextEncoder().encode("cd")); return; }
          if (pulled === 3) { c.enqueue(new TextEncoder().encode("ef")); return; }
          c.close();
        },
      }),
      complete: Promise.resolve(),
    };
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/echo`,
      method: "POST",
      body,
      ...NO_FLUSH,
    });
    const { bytes } = await collect(result);
    expect(bytes.toString("utf8")).toBe("abcdef");
    expect(pulled).toBeGreaterThan(1); // proves it streamed rather than being read in one go
  });

  it("arms the head timeout only once the request body finishes, so a slow (but eventually complete) body still succeeds", async () => {
    const server = startTestServer();
    const { promise: gate, resolve: openGate } = Promise.withResolvers<void>();
    const body: TunnelRequestBody = {
      length: 3,
      stream: () => new ReadableStream<Uint8Array>({
        async start(c) {
          await gate; // the body is still streaming well past headTimeoutMs below
          c.enqueue(new TextEncoder().encode("hi!"));
          c.close();
        },
      }),
      complete: gate.then(() => {}),
    };
    const resultPromise = fetchLocalhost({
      url: `http://localhost:${server.port}/echo`,
      method: "POST",
      body,
      headTimeoutMs: 50, // would fire almost immediately if armed at request start
      ...NO_FLUSH,
    });
    await Bun.sleep(150); // well past headTimeoutMs, with the body still gated
    openGate();
    const result = await resultPromise;
    expect(result.status).toBe(200);
    const { bytes } = await collect(result);
    expect(bytes.toString("utf8")).toBe("hi!");
  });

  it("replays a request body already pulled once, for the scheme-guess retry", async () => {
    // No TLS listener is actually stood up here — the point is only that a
    // SECOND `stream()` call (whatever triggers it) replays byte-exact rather
    // than resuming from empty or throwing.
    const payload = new TextEncoder().encode("replay me");
    const body = fixedRequestBody(payload);
    const first = body.stream()!;
    const firstReader = first.getReader();
    const firstBytes: Uint8Array[] = [];
    for (;;) {
      const { done, value } = await firstReader.read();
      if (done) break;
      firstBytes.push(value);
    }
    expect(Buffer.concat(firstBytes.map((b) => Buffer.from(b)))).toEqual(Buffer.from(payload));

    const second = body.stream()!;
    const secondReader = second.getReader();
    const secondBytes: Uint8Array[] = [];
    for (;;) {
      const { done, value } = await secondReader.read();
      if (done) break;
      secondBytes.push(value);
    }
    expect(Buffer.concat(secondBytes.map((b) => Buffer.from(b)))).toEqual(Buffer.from(payload));
  });

  it("a body already over the replay cap refuses a second stream() call", () => {
    const payload = new Uint8Array(TUNNEL_BODY_REPLAY_MAX_BYTES + 1).fill(1);
    const body = fixedRequestBody(payload, { replayCap: TUNNEL_BODY_REPLAY_MAX_BYTES });
    expect(body.stream()).not.toBeNull();
    expect(body.stream()).toBeNull();
  });
});

describe("fetchLocalhost body slicing", () => {
  it("emits chunks of at most chunkBytes, byte-exact overall", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/chunky.bin`,
      chunkBytes: 4096,
      ...NO_FLUSH,
    });

    const { chunks, bytes } = await collect(result);
    expect(chunks.map((c) => c.byteLength)).toEqual([4096, 4096, 1808]);
    expect(bytes.equals(Buffer.from(TEN_THOUSAND_RANDOM))).toBe(true);
  });

  it("handles a body that is an exact multiple of the slice size", async () => {
    const server = startTestServer();
    const result = await fetchLocalhost({
      url: `http://localhost:${server.port}/exact.bin`,
      chunkBytes: 4096,
      ...NO_FLUSH,
    });

    const { chunks, bytes } = await collect(result);
    expect(chunks.map((c) => c.byteLength)).toEqual([4096, 4096]);
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
    const it = result.body;
    const first = await it.next();
    expect(Date.now() - started).toBeLessThan(200);
    expect(first.done).toBe(false);
    expect(first.value!.byteLength).toBe(1024);

    const rest: Uint8Array[] = [first.value!];
    for (;;) {
      const next = await it.next();
      if (next.done) break;
      rest.push(next.value);
    }
    expect(Buffer.concat(rest.map((b) => Buffer.from(b))).byteLength).toBe(2048);
  });

  // The flush deadline is anchored at the FIRST pending byte, never re-armed by
  // a later read: an event stream ticking faster than the window would
  // otherwise withhold slice 0 — and with it the response head — until EOF.
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
    const it = result.body;
    const first = await it.next();
    expect(Date.now() - started).toBeLessThan(150);
    expect(first.done).toBe(false);

    const all: Uint8Array[] = [first.value!];
    for (;;) {
      const next = await it.next();
      if (next.done) break;
      all.push(next.value);
    }
    expect(Buffer.concat(all.map((b) => Buffer.from(b))).byteLength).toBe(50 * 64);
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

    const it = result.body;
    const first = await it.next();
    expect(first.done).toBe(false);
    await Bun.sleep(300);

    const rest: Uint8Array[] = [first.value!];
    for (;;) {
      const next = await it.next();
      if (next.done) break;
      rest.push(next.value);
    }
    expect(Buffer.concat(rest.map((b) => Buffer.from(b))).byteLength).toBe(200);
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
      const { chunks, bytes } = await collect(declared);
      expect(chunks).toHaveLength(1);
      expect(bytes.toString("utf8")).toContain("too large");
      await waitUntil(() => sized.state.closed);
    } finally {
      sized.stop();
    }
  });

  it("does not apply the head timeout to the response body", async () => {
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

    const it = result.body;
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

    const it = result.body;
    expect((await it.next()).done).toBe(false);
    await it.return(undefined);
    await waitUntil(() => up.state.cancelled);
  });
});

describe("UpstreamBodyError", () => {
  it("is exported for callers (tunnel-streams.ts) to recognize a request-body-originated failure", () => {
    expect(new UpstreamBodyError("x")).toBeInstanceOf(Error);
  });
});
