import { test, expect, afterEach } from "bun:test";
import { TunnelManager, type TunnelFetchOpts } from "../src/tunnel-manager";
import { createConnState } from "../src/conn-state";
import type { TunnelHttpRequest } from "../src/tunnel-protocol";

const servers: Array<ReturnType<typeof Bun.serve>> = [];
afterEach(() => {
  for (const s of servers.splice(0)) s.stop(true);
});

/** Upstream dev server that counts how many times it was actually reached —
 *  the whole point of the outbox is that a retry does NOT increment this. */
function startUpstream(opts: { body?: string; delayMs?: number } = {}) {
  let hits = 0;
  const server = Bun.serve({
    port: 0,
    async fetch() {
      hits += 1;
      if (opts.delayMs) await Bun.sleep(opts.delayMs);
      return new Response(opts.body ?? `hit-${hits}`, {
        headers: { "content-type": "text/plain" },
      });
    },
  });
  servers.push(server);
  return { server, port: server.port!, hits: () => hits };
}

/** A trickling upstream, plus the flag that proves an abort really closed the
 *  connection rather than just stopping the reads. */
function startStreamUpstream(opts: { chunks: number; chunkBytes: number; gapMs: number }) {
  let hits = 0;
  const state = { cancelled: false };
  const server = Bun.serve({
    port: 0,
    fetch() {
      hits += 1;
      const body = new ReadableStream<Uint8Array>({
        start(c) {
          let n = 0;
          const timer = setInterval(() => {
            try {
              if (n++ >= opts.chunks) { clearInterval(timer); c.close(); return; }
              c.enqueue(new Uint8Array(opts.chunkBytes).fill(0x61 + (n % 26)));
            } catch { clearInterval(timer); }
          }, opts.gapMs);
        },
        cancel() { state.cancelled = true; },
      });
      return new Response(body, { headers: { "content-type": "application/octet-stream" } });
    },
  });
  servers.push(server);
  return { server, port: server.port!, hits: () => hits, state };
}

function makeManager(fetchOpts?: TunnelFetchOpts) {
  const sent: Record<string, unknown>[] = [];
  const mgr = new TunnelManager({
    projectId: "proj",
    portLabels: new Map(),
    previewPorts: new Set(),
    sendTunnel: async (data) => { sent.push(data as Record<string, unknown>); return "sent"; },
    sendEncrypted: () => {},
    relayHost: "relay.test",
    connState: createConnState(),
    ...(fetchOpts ? { fetchOpts } : {}),
  });
  return { mgr, sent };
}

function request(port: number, requestId: string, checkoutId = "main"): TunnelHttpRequest {
  return {
    type: "tunnel:http-request",
    requestId,
    port,
    method: "GET",
    path: "/asset.js",
    checkoutId,
  };
}

function framesFor(sent: Record<string, unknown>[], requestId: string): Record<string, unknown>[] {
  return sent.filter((f) => f.requestId === requestId);
}

/** Reassemble a stream's body from whatever slices its frames carry. */
function bodyOf(frames: Record<string, unknown>[]): Buffer {
  return Buffer.concat(
    frames
      .filter((f) => typeof f.data === "string")
      .map((f) => {
        const raw = Buffer.from(f.data as string, "base64");
        return f.bodyEncoding === "gzip-base64" ? Buffer.from(Bun.gunzipSync(raw)) : raw;
      }),
  );
}

test("a retry with the same requestId replays the stored stream and never re-fetches", async () => {
  const up = startUpstream();
  const { mgr, sent } = makeManager();

  await mgr.onHttpRequest(request(up.port, "req-1"));
  await mgr.onHttpRequest(request(up.port, "req-1"));

  expect(up.hits()).toBe(1);
  expect(sent).toHaveLength(2);
  expect(sent[0].type).toBe("tunnel:http-start");
  expect(sent[0].last).toBe(true);
  expect(bodyOf([sent[0]]).toString("utf8")).toBe("hit-1");
  expect(sent[1]).toEqual(sent[0]);
});

test("a distinct requestId still reaches the dev server", async () => {
  const up = startUpstream();
  const { mgr, sent } = makeManager();

  await mgr.onHttpRequest(request(up.port, "req-1"));
  await mgr.onHttpRequest(request(up.port, "req-2"));

  expect(up.hits()).toBe(2);
  expect(bodyOf(framesFor(sent, "req-1")).toString("utf8")).toBe("hit-1");
  expect(bodyOf(framesFor(sent, "req-2")).toString("utf8")).toBe("hit-2");
});

// The app cannot see that its first request is still upstream, so a rate-limit
// retry can land mid-flight. Without the in-flight join this is a second fetch.
test("a retry arriving while the original is still upstream does not double-fetch", async () => {
  const up = startUpstream({ delayMs: 120 });
  const { mgr, sent } = makeManager();

  await Promise.all([
    mgr.onHttpRequest(request(up.port, "req-inflight")),
    mgr.onHttpRequest(request(up.port, "req-inflight")),
  ]);

  expect(up.hits()).toBe(1);
  expect(sent).toHaveLength(2);
  expect(sent[1]).toEqual(sent[0]);
});

// A 502 is a real answer to the request and must replay like any other — a
// retry that re-ran it would hit the same dead port and cost another timeout.
test("an upstream failure is replayed too, not retried into the dev server", async () => {
  const { mgr, sent } = makeManager();
  // Port 1 is privileged/unbound in test environments: the fetch fails fast.
  await mgr.onHttpRequest(request(1, "req-502"));
  await mgr.onHttpRequest(request(1, "req-502"));

  expect(sent).toHaveLength(2);
  expect(sent[0].status).toBe(502);
  expect(sent[0].last).toBe(true);
  expect(bodyOf([sent[0]]).toString("utf8")).toStartWith("Proxy error:");
  expect(sent[1]).toEqual(sent[0]);
});

// Bodies past the per-entry cap are deliberately not retained, so this falls
// through to a fresh fetch rather than growing the outbox without bound.
test("a stream over the retention cap is not stored and a retry re-fetches", async () => {
  const big = "x".repeat(3 * 1024 * 1024);
  const up = startUpstream({ body: big });
  const { mgr, sent } = makeManager();

  await mgr.onHttpRequest(request(up.port, "req-big"));
  const first = sent.splice(0);
  await mgr.onHttpRequest(request(up.port, "req-big"));

  expect(up.hits()).toBe(2);
  expect(first[0].type).toBe("tunnel:http-start");
  const chunks = first.filter((f) => f.type === "tunnel:http-chunk");
  expect(chunks.length).toBeGreaterThan(0);
  expect(chunks.map((f) => f.seq)).toEqual(chunks.map((_, i) => i + 1));
  const end = first[first.length - 1];
  expect(end.type).toBe("tunnel:http-end");
  expect(end.chunks).toBe(chunks.length);
  expect(bodyOf(first).toString("utf8")).toBe(big);
});

test("stop() drops retained streams", async () => {
  const up = startUpstream();
  const { mgr, sent } = makeManager();

  await mgr.onHttpRequest(request(up.port, "req-1"));
  mgr.stop();
  await mgr.onHttpRequest(request(up.port, "req-1"));

  expect(up.hits()).toBe(2);
  expect(bodyOf([sent[1]]).toString("utf8")).toBe("hit-2");
});

// A partial stream is not an answer: retaining it would replay a body the app
// can never complete.
test("a cancelled stream is not retained: a retry re-fetches", async () => {
  const up = startStreamUpstream({ chunks: 20, chunkBytes: 2048, gapMs: 10 });
  const sent: Record<string, unknown>[] = [];
  const mgr = new TunnelManager({
    projectId: "proj",
    portLabels: new Map(),
    previewPorts: new Set(),
    sendTunnel: async (data) => {
      const frame = data as Record<string, unknown>;
      sent.push(frame);
      if (frame.type === "tunnel:http-chunk" && frame.seq === 1) {
        mgr.onHttpCancel({ type: "tunnel:http-cancel", requestId: "req-cancel", checkoutId: "main" });
      }
      return "sent";
    },
    sendEncrypted: () => {},
    relayHost: "relay.test",
    connState: createConnState(),
    fetchOpts: { chunkBytes: 1024, flushMs: 5_000 },
  });

  await mgr.onHttpRequest(request(up.port, "req-cancel"));
  expect(sent.some((f) => f.type === "tunnel:http-end")).toBe(false);

  sent.length = 0;
  await mgr.onHttpRequest(request(up.port, "req-cancel"));
  expect(up.hits()).toBe(2);
  expect(sent[0].type).toBe("tunnel:http-start");
});

// The manager is the last place that knows which checkout a body came from: a
// frame without the id lands on main's preview in the app.
test("every frame the manager emits carries checkoutId", async () => {
  const up = startStreamUpstream({ chunks: 6, chunkBytes: 2048, gapMs: 1 });
  const { mgr, sent } = makeManager({ chunkBytes: 1024, flushMs: 5_000, maxBodyBytes: 4096 });

  await mgr.onHttpRequest(request(up.port, "req-wt", "wt-1"));
  await mgr.onHttpRequest(request(1, "req-502", "wt-1"));

  const sized = Bun.serve({ port: 0, fetch: () => new Response(Buffer.alloc(8192)) });
  servers.push(sized);
  await mgr.onHttpRequest(request(sized.port!, "req-413", "wt-1"));

  expect(sent.length).toBeGreaterThan(2);
  for (const frame of sent) expect(frame.checkoutId).toBe("wt-1");
  expect(framesFor(sent, "req-502")[0].status).toBe(502);
  expect(framesFor(sent, "req-413")[0].status).toBe(413);
});
