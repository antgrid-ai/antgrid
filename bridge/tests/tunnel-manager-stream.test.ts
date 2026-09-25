// The streaming half of TunnelManager: read-side pacing on the exchange's send
// promise, what ends a stream (end() vs fail()), and how a cancel/abort reaches
// the upstream connection. Duplicate requestIds are the registry's concern
// (tunnel-streams.test.ts): each tunnel owns its own QUIC stream, so there is
// no shared queue here to join or interleave on.
import { afterEach, describe, expect, test } from "bun:test";
import { TunnelManager, type TunnelFetchOpts, type TunnelHttpExchange } from "../src/tunnel-manager";
import type { TunnelBodySlice } from "../src/localhost-fetch";
import type { StreamSendOutcome } from "../src/peer/stream-records";
import { createConnState } from "../src/conn-state";
import type { TunnelHttpRequest } from "../src/tunnel-protocol";

const servers: Array<ReturnType<typeof Bun.serve>> = [];
afterEach(() => {
  for (const s of servers.splice(0)) s.stop(true);
});

/** A dev server whose body is written on a timer, so a test can hold the bridge
 *  mid-stream. `cancelled` is the only observable proof that aborting the fetch
 *  closed the upstream connection rather than merely stopping the reads. */
function startRoute(opts: {
  writes: number;
  writeBytes: number;
  gapMs?: number;
  /** Stop writing after `writes` without ever closing the body. */
  stall?: boolean;
  /** Answer with no body at all. */
  empty?: boolean;
  status?: number;
}) {
  let hits = 0;
  const state = { cancelled: false };
  const server = Bun.serve({
    port: 0,
    fetch() {
      hits += 1;
      if (opts.empty) return new Response(null, { status: opts.status ?? 204 });
      const body = new ReadableStream<Uint8Array>({
        start(c) {
          let i = 0;
          const step = () => {
            if (i >= opts.writes) {
              if (!opts.stall) { try { c.close(); } catch { /* socket gone */ } }
              return;
            }
            try { c.enqueue(new Uint8Array(opts.writeBytes).fill(0x41 + (i % 26))); }
            catch { return; }
            i += 1;
            setTimeout(step, opts.gapMs ?? 0);
          };
          setTimeout(step, opts.gapMs ?? 0);
        },
        cancel() { state.cancelled = true; },
      });
      return new Response(body, {
        status: opts.status ?? 200,
        headers: { "content-type": "application/octet-stream" },
      });
    },
  });
  servers.push(server);
  return { port: server.port!, hits: () => hits, state };
}

type Verdict = StreamSendOutcome | "hold";
type SentEntry =
  | { kind: "head"; value: { status: number; headers: Record<string, string>; setCookies?: string[] } }
  | { kind: "body"; value: TunnelBodySlice }
  | { kind: "end" };

/** The exchange as a lever: each call's promise resolves when this test says
 *  it does, which is the whole pacing contract the read loop rides on.
 *  `peerId` defaults to a fixed value since most tests run a single exchange
 *  and never care whose stream it is on; the abort-targeting tests pass two
 *  distinct ids. */
function makeExchange(peerId = "peer-a") {
  const sent: SentEntry[] = [];
  const waiting: Array<(o: StreamSendOutcome) => void> = [];
  const ctrl = new AbortController();
  let failReason: string | undefined;

  const push = (entry: SentEntry): Promise<StreamSendOutcome> => {
    sent.push(entry);
    const verdict = api.plan?.(entry) ?? "sent";
    if (verdict !== "hold") return Promise.resolve(verdict);
    return new Promise<StreamSendOutcome>((resolve) => waiting.push(resolve));
  };

  const api = {
    sent,
    plan: undefined as ((entry: SentEntry) => Verdict) | undefined,
    waiting: () => waiting.length,
    failReason: () => failReason,
    abort: () => ctrl.abort(),
    release(outcome: StreamSendOutcome = "sent") {
      const resolve = waiting.shift();
      if (!resolve) throw new Error("nothing is waiting on the send gate");
      resolve(outcome);
    },
    releaseAll(outcome: StreamSendOutcome = "sent") {
      for (const resolve of waiting.splice(0)) resolve(outcome);
    },
    bodyCalls: () => sent.filter((e): e is Extract<SentEntry, { kind: "body" }> => e.kind === "body"),
    exchange: {
      peerId,
      signal: ctrl.signal,
      head: (h) => push({ kind: "head", value: h }),
      body: (s) => push({ kind: "body", value: s }),
      end: () => push({ kind: "end" }),
      fail: (reason: string) => { failReason = reason; },
    } satisfies TunnelHttpExchange,
  };
  return api;
}

/** Holds exactly the body() call at 0-indexed position `n` among body calls. */
function holdBody(exchange: ReturnType<typeof makeExchange>, n: number) {
  return (entry: SentEntry): Verdict => {
    if (entry.kind !== "body") return "sent";
    const index = exchange.bodyCalls().length - 1; // this call is already pushed
    return index === n ? "hold" : "sent";
  };
}

/** The flush clock is off by default so a slice count is exact on a loaded
 *  host; the cases that exercise it pass their own `flushMs`. */
function makeManager(fetchOpts: TunnelFetchOpts = {}) {
  return new TunnelManager({
    projectId: "proj",
    portLabels: new Map(),
    previewPorts: new Set(),
    sendEncrypted: () => {},
    relayHost: "relay.test",
    connState: createConnState(),
    fetchOpts: { chunkBytes: 1024, flushMs: 5_000, ...fetchOpts },
  });
}

function request(port: number, requestId: string): TunnelHttpRequest {
  return { type: "tunnel:http-request", requestId, port, method: "GET", path: "/asset", bodyLength: 0, checkoutId: "main" };
}

async function waitUntil(condition: () => boolean, ms = 2_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition was not met");
    await Bun.sleep(5);
  }
}

function rawBytes(exchange: ReturnType<typeof makeExchange>): Buffer {
  return Buffer.concat(
    exchange.bodyCalls().map((e) => (e.value.gzip ? Buffer.from(Bun.gunzipSync(e.value.bytes as Uint8Array<ArrayBuffer>)) : Buffer.from(e.value.bytes))),
  );
}

describe("TunnelManager HTTP streaming", () => {
  // The pacing contract: without awaiting the settle promise the loop reads the
  // whole body straight into the send queue, and `sent` runs past head+1 body
  // while the first slice is still held.
  test("body slices are read only after the previous one settled", async () => {
    const route = startRoute({ writes: 8, writeBytes: 1024 });
    const exchange = makeExchange();
    exchange.plan = holdBody(exchange, 0);
    const mgr = makeManager();

    const run = mgr.serveHttp(request(route.port, "paced"), new Uint8Array(0), exchange.exchange);
    await waitUntil(() => exchange.waiting() === 1);
    await Bun.sleep(200);
    expect(exchange.sent).toHaveLength(2);
    expect(exchange.sent[0].kind).toBe("head");
    expect(exchange.sent[1].kind).toBe("body");

    exchange.plan = undefined;
    exchange.release();
    await run;
    expect(exchange.sent.length).toBeGreaterThan(2);
    expect(exchange.sent[exchange.sent.length - 1].kind).toBe("end");
  });

  // A held settle is the bridge waiting on the link, never the dev server going
  // quiet — so the upstream idle clock must not be running against it.
  test("a settle held longer than the read idle limit does not fail a healthy body", async () => {
    const route = startRoute({ writes: 4, writeBytes: 1024, gapMs: 5 });
    const exchange = makeExchange();
    exchange.plan = holdBody(exchange, 0);
    const mgr = makeManager({ readIdleMs: 100 });

    const run = mgr.serveHttp(request(route.port, "parked"), new Uint8Array(0), exchange.exchange);
    await waitUntil(() => exchange.waiting() === 1);
    await Bun.sleep(300);
    exchange.plan = undefined;
    exchange.release();
    await run;

    expect(exchange.sent[exchange.sent.length - 1].kind).toBe("end");
    expect(exchange.failReason()).toBeUndefined();
    expect(rawBytes(exchange).byteLength).toBe(4 * 1024);
  });

  test("a body() call the transport reports dropped aborts the stream: the upstream is cancelled and no end is sent", async () => {
    const route = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
    const exchange = makeExchange();
    exchange.plan = (entry) => (entry.kind === "body" && exchange.bodyCalls().length - 1 === 1 ? "dropped" : "sent");
    const mgr = makeManager();

    await mgr.serveHttp(request(route.port, "lost"), new Uint8Array(0), exchange.exchange);

    expect(exchange.sent.map((e) => e.kind)).toEqual(["head", "body", "body"]);
    await waitUntil(() => route.state.cancelled);
  });

  test("aborting the exchange's signal stops the fetch and no further frames follow", async () => {
    const route = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
    const exchange = makeExchange();
    exchange.plan = holdBody(exchange, 0);
    const mgr = makeManager();

    const run = mgr.serveHttp(request(route.port, "cancelled"), new Uint8Array(0), exchange.exchange);
    await waitUntil(() => exchange.waiting() === 1);
    exchange.abort();
    exchange.plan = undefined;
    exchange.release();
    await run;

    await Bun.sleep(100);
    // The held frame was already handed over; NOTHING after it — the aborted
    // check sits before the send, not after it.
    expect(exchange.sent).toHaveLength(2);
    expect(exchange.sent.some((e) => e.kind === "end")).toBe(false);
    await waitUntil(() => route.state.cancelled);
  });

  test("an upstream that stalls mid-body fails the exchange rather than ending it", async () => {
    const route = startRoute({ writes: 1, writeBytes: 1500, stall: true });
    const exchange = makeExchange();
    const mgr = makeManager({ readIdleMs: 100, flushMs: 50 });

    await mgr.serveHttp(request(route.port, "stalled"), new Uint8Array(0), exchange.exchange);

    // The head already went out (the read failed AFTER it), so the caller must
    // end the stream with an error rather than a clean end record — that is
    // exactly what fail() communicates and end() does not.
    expect(exchange.sent.some((e) => e.kind === "end")).toBe(false);
    expect(exchange.failReason()).toMatch(/stalled/);
  });

  test("a body that fails before the head goes out answers a synthesized 502, not a bare end", async () => {
    // A head the app never got and an end it did are indistinguishable from a
    // head the relay dropped, so a bare end here would send the app back to
    // re-issue the request that has just failed. The cap is tested against the
    // first read before anything is sliced, and a streamed origin declares no
    // length, so the pre-check upstream of this cannot answer it first.
    const route = startRoute({ writes: 1, writeBytes: 4096 });
    const exchange = makeExchange();
    const mgr = makeManager({ maxBodyBytes: 1024 });

    await mgr.serveHttp(request(route.port, "headless"), new Uint8Array(0), exchange.exchange);

    expect(exchange.sent.map((e) => e.kind)).toEqual(["head", "body", "end"]);
    expect(exchange.sent[0]).toMatchObject({ kind: "head", value: { status: 502 } });
    expect(rawBytes(exchange).toString("utf8")).toMatch(/MAX_BODY_SIZE/);
  });

  test("a large body is sliced at chunkBytes, and the slices reassemble byte-exact", async () => {
    const route = startRoute({ writes: 1, writeBytes: 10_000 });
    const exchange = makeExchange();
    const mgr = makeManager({ chunkBytes: 4096 });

    await mgr.serveHttp(request(route.port, "counted"), new Uint8Array(0), exchange.exchange);

    expect(exchange.bodyCalls().map((e) => e.value.bytes.byteLength)).toEqual([4096, 4096, 1808]);
    expect(exchange.sent.map((e) => e.kind)).toEqual(["head", "body", "body", "body", "end"]);
    expect(rawBytes(exchange).byteLength).toBe(10_000);
  });

  test("a request body reaches the upstream byte-exact", async () => {
    let received: Uint8Array | undefined;
    const server = Bun.serve({
      port: 0,
      async fetch(req) {
        received = new Uint8Array(await req.arrayBuffer());
        return new Response("ok", { headers: { "content-type": "text/plain" } });
      },
    });
    servers.push(server);
    const payload = new Uint8Array(3000).map((_, i) => (i * 7) & 0xff);
    const exchange = makeExchange();

    await makeManager().serveHttp(
      { ...request(server.port!, "post"), method: "POST", bodyLength: payload.byteLength },
      payload,
      exchange.exchange,
    );

    expect(received && Buffer.from(received).equals(Buffer.from(payload))).toBe(true);
    expect(exchange.sent.map((e) => e.kind)).toEqual(["head", "body", "end"]);
  });

  test("a compressible body is gzipped only when the app accepted gzip", async () => {
    const text = "a".repeat(6000);
    const server = Bun.serve({
      port: 0,
      fetch: () => new Response(text, { headers: { "content-type": "text/plain" } }),
    });
    servers.push(server);

    // One slice, well above the gzip floor, so every call must carry the flag.
    const mgr = () => makeManager({ chunkBytes: 8192 });
    const plain = makeExchange();
    await mgr().serveHttp(request(server.port!, "plain"), new Uint8Array(0), plain.exchange);
    expect(plain.bodyCalls().every((e) => !e.value.gzip)).toBe(true);

    const gz = makeExchange();
    await mgr().serveHttp(
      { ...request(server.port!, "gz"), acceptEncodings: ["gzip"] },
      new Uint8Array(0),
      gz.exchange,
    );
    expect(gz.bodyCalls().length).toBeGreaterThan(0);
    expect(gz.bodyCalls().every((e) => e.value.gzip)).toBe(true);
    expect(rawBytes(gz).toString("utf8")).toBe(text);
  });

  test("a single-slice body is head, one body call with last, then end", async () => {
    const route = startRoute({ writes: 1, writeBytes: 500 });
    const exchange = makeExchange();
    const mgr = makeManager();

    await mgr.serveHttp(request(route.port, "small"), new Uint8Array(0), exchange.exchange);

    expect(exchange.sent.map((e) => e.kind)).toEqual(["head", "body", "end"]);
    expect(exchange.bodyCalls()[0].value.last).toBe(true);
    expect(rawBytes(exchange).byteLength).toBe(500);
  });

  test("an empty body is a head with no body call, then end", async () => {
    const route = startRoute({ writes: 0, writeBytes: 0, empty: true, status: 204 });
    const exchange = makeExchange();
    const mgr = makeManager();

    await mgr.serveHttp(request(route.port, "empty"), new Uint8Array(0), exchange.exchange);

    expect(exchange.sent.map((e) => e.kind)).toEqual(["head", "end"]);
    expect(exchange.sent[0]).toMatchObject({ kind: "head", value: { status: 204 } });
  });

  test("stop() aborts an in-flight stream", async () => {
    const route = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
    const exchange = makeExchange();
    exchange.plan = holdBody(exchange, 0);
    const mgr = makeManager();

    const run = mgr.serveHttp(request(route.port, "stopped"), new Uint8Array(0), exchange.exchange);
    await waitUntil(() => exchange.waiting() === 1);
    mgr.stop();
    await waitUntil(() => route.state.cancelled);

    exchange.plan = undefined;
    exchange.release();
    await run;
    await Bun.sleep(50);
    expect(exchange.sent).toHaveLength(2);
    expect(exchange.failReason()).toBeDefined();
  });

  // Both shapes of in-flight run must go: a caller that only reaches a run
  // parked on a settle at a given instant would miss the one still reading.
  test("abortHttpStreams(peerId) aborts every in-flight run of that peer whether or not it is parked", async () => {
    const parked = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
    const running = startRoute({ writes: 20, writeBytes: 1024, gapMs: 20 });
    const parkedExchange = makeExchange("peer-a");
    const runningExchange = makeExchange("peer-a");
    parkedExchange.plan = holdBody(parkedExchange, 0);
    const mgr = makeManager();

    const runs = Promise.all([
      mgr.serveHttp(request(parked.port, "parked"), new Uint8Array(0), parkedExchange.exchange),
      mgr.serveHttp(request(running.port, "running"), new Uint8Array(0), runningExchange.exchange),
    ]);
    await waitUntil(() => parkedExchange.waiting() === 1);
    await waitUntil(() => runningExchange.bodyCalls().length > 0);

    mgr.abortHttpStreams("peer-a");
    parkedExchange.plan = undefined;
    parkedExchange.releaseAll();
    await runs;
    await waitUntil(() => parked.state.cancelled && running.state.cancelled);
    expect(parkedExchange.sent.some((e) => e.kind === "end")).toBe(false);
    expect(runningExchange.sent.some((e) => e.kind === "end")).toBe(false);
    // The app on the other end is still alive: without an explicit fail() its
    // stream would neither end nor reset, and it would wait out its idle timer
    // holding a tunnel slot on both ends.
    expect(parkedExchange.failReason()).toBeDefined();
    expect(runningExchange.failReason()).toBeDefined();
  });

  // A3 trap (§3.8): the abort is keyed by peerId, never by project, so a
  // second phone establishing its own tunnel must not cut the first phone's
  // in-flight preview load.
  test("abortHttpStreams(peerId) aborts only that peer's run and leaves a sibling peer's run alone", async () => {
    const routeA = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
    const routeB = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
    const exchangeA = makeExchange("peer-a");
    const exchangeB = makeExchange("peer-b");
    exchangeA.plan = holdBody(exchangeA, 0);
    exchangeB.plan = holdBody(exchangeB, 0);
    const mgr = makeManager();

    const runA = mgr.serveHttp(request(routeA.port, "a"), new Uint8Array(0), exchangeA.exchange);
    const runB = mgr.serveHttp(request(routeB.port, "b"), new Uint8Array(0), exchangeB.exchange);
    await waitUntil(() => exchangeA.waiting() === 1 && exchangeB.waiting() === 1);

    mgr.abortHttpStreams("peer-a");
    await waitUntil(() => routeA.state.cancelled);
    expect(routeB.state.cancelled).toBe(false);

    // fail() runs from inside the read loop, which is blocked on the held
    // body write until it is released — the abort signal alone (checked
    // above via route cancellation) does not unblock it.
    exchangeA.plan = undefined;
    exchangeA.releaseAll();
    await runA;
    expect(exchangeA.failReason()).toBeDefined();
    expect(exchangeB.failReason()).toBeUndefined();

    exchangeB.plan = undefined;
    exchangeB.releaseAll();
    await runB;
    expect(exchangeB.sent.some((e) => e.kind === "end")).toBe(true);
  });

  // stop() has no peer to target: every run on the manager goes, unlike
  // abortHttpStreams(peerId).
  test("stop() aborts in-flight runs of every peer", async () => {
    const routeA = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
    const routeB = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
    const exchangeA = makeExchange("peer-a");
    const exchangeB = makeExchange("peer-b");
    exchangeA.plan = holdBody(exchangeA, 0);
    exchangeB.plan = holdBody(exchangeB, 0);
    const mgr = makeManager();

    const runA = mgr.serveHttp(request(routeA.port, "a"), new Uint8Array(0), exchangeA.exchange);
    const runB = mgr.serveHttp(request(routeB.port, "b"), new Uint8Array(0), exchangeB.exchange);
    await waitUntil(() => exchangeA.waiting() === 1 && exchangeB.waiting() === 1);

    mgr.stop();
    await waitUntil(() => routeA.state.cancelled && routeB.state.cancelled);

    exchangeA.plan = undefined;
    exchangeA.releaseAll();
    exchangeB.plan = undefined;
    exchangeB.releaseAll();
    await Promise.all([runA, runB]);
    expect(exchangeA.failReason()).toBeDefined();
    expect(exchangeB.failReason()).toBeDefined();
  });

  test("an abort that came through the exchange's own signal does not also fail() it", async () => {
    const route = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
    const exchange = makeExchange();
    exchange.plan = holdBody(exchange, 0);
    const mgr = makeManager();

    const run = mgr.serveHttp(request(route.port, "self-aborted"), new Uint8Array(0), exchange.exchange);
    await waitUntil(() => exchange.waiting() === 1);
    exchange.abort();
    exchange.plan = undefined;
    // A cancelled stream's writer has already reset, so the held send settles
    // "dropped" — which aborts the run's own controller as well.
    exchange.releaseAll("dropped");
    await run;
    await waitUntil(() => route.state.cancelled);
    expect(exchange.failReason()).toBeUndefined();
  });
});
