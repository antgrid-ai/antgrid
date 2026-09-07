// The streaming half of TunnelManager: read-side pacing on the send promise,
// what ends a stream, and how a cancel reaches the upstream connection.
import { afterEach, describe, expect, test } from "bun:test";
import { TunnelManager, type TunnelFetchOpts } from "../src/tunnel-manager";
import { createConnState } from "../src/conn-state";
import type { SendOutcome } from "../src/send-scheduler";
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

type Verdict = SendOutcome | "hold";

/** The send path as a lever: each frame's promise resolves when this test says
 *  it does, which is the whole pacing contract the chunk loop rides on. */
function makeSender() {
  const sent: Record<string, unknown>[] = [];
  const waiting: Array<(o: SendOutcome) => void> = [];
  const api = {
    sent,
    plan: undefined as ((frame: Record<string, unknown>) => Verdict) | undefined,
    waiting: () => waiting.length,
    release(outcome: SendOutcome = "sent") {
      const resolve = waiting.shift();
      if (!resolve) throw new Error("nothing is waiting on the send gate");
      resolve(outcome);
    },
    releaseAll(outcome: SendOutcome = "sent") {
      for (const resolve of waiting.splice(0)) resolve(outcome);
    },
    send: async (data: object): Promise<SendOutcome> => {
      const frame = data as Record<string, unknown>;
      sent.push(frame);
      const verdict = api.plan?.(frame) ?? "sent";
      if (verdict !== "hold") return verdict;
      return new Promise<SendOutcome>((resolve) => waiting.push(resolve));
    },
  };
  return api;
}

/** The flush clock is off by default so a slice count is exact on a loaded
 *  host; the cases that exercise it pass their own `flushMs`. */
function makeManager(sender: ReturnType<typeof makeSender>, fetchOpts: TunnelFetchOpts = {}) {
  return new TunnelManager({
    projectId: "proj",
    portLabels: new Map(),
    previewPorts: new Set(),
    sendTunnel: sender.send,
    sendEncrypted: () => {},
    relayHost: "relay.test",
    connState: createConnState(),
    fetchOpts: { chunkBytes: 1024, flushMs: 5_000, ...fetchOpts },
  });
}

function request(port: number, requestId: string): TunnelHttpRequest {
  return { type: "tunnel:http-request", requestId, port, method: "GET", path: "/asset", checkoutId: "main" };
}

async function waitUntil(condition: () => boolean, ms = 2_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition was not met");
    await Bun.sleep(5);
  }
}

function rawBytes(frames: Record<string, unknown>[]): Buffer {
  return Buffer.concat(
    frames
      .filter((f) => typeof f.data === "string")
      .map((f) => {
        const raw = Buffer.from(f.data as string, "base64");
        return f.bodyEncoding === "gzip-base64" ? Buffer.from(Bun.gunzipSync(raw)) : raw;
      }),
  );
}

const holdChunk = (seq: number) => (frame: Record<string, unknown>): Verdict =>
  frame.type === "tunnel:http-chunk" && frame.seq === seq ? "hold" : "sent";

describe("TunnelManager HTTP streaming", () => {
  // The pacing contract: without awaiting the settle promise the loop reads the
  // whole body straight into the send queue, and `sent` runs past 2 while the
  // first chunk is still held.
  test("chunks are read only after the previous frame settled", async () => {
    const route = startRoute({ writes: 8, writeBytes: 1024 });
    const sender = makeSender();
    sender.plan = holdChunk(1);
    const mgr = makeManager(sender);

    const run = mgr.onHttpRequest(request(route.port, "paced"));
    await waitUntil(() => sender.waiting() === 1);
    await Bun.sleep(200);
    expect(sender.sent).toHaveLength(2);
    expect(sender.sent[0].type).toBe("tunnel:http-start");
    expect(sender.sent[1]).toMatchObject({ type: "tunnel:http-chunk", seq: 1 });

    sender.plan = undefined;
    sender.release();
    await run;
    expect(sender.sent.length).toBeGreaterThan(2);
  });

  // A held settle is the bridge waiting on the link, never the dev server going
  // quiet — so the upstream idle clock must not be running against it.
  test("a settle held longer than the read idle limit does not fail a healthy body", async () => {
    const route = startRoute({ writes: 4, writeBytes: 1024, gapMs: 5 });
    const sender = makeSender();
    sender.plan = holdChunk(1);
    const mgr = makeManager(sender, { readIdleMs: 100 });

    const run = mgr.onHttpRequest(request(route.port, "parked"));
    await waitUntil(() => sender.waiting() === 1);
    await Bun.sleep(300);
    sender.plan = undefined;
    sender.release();
    await run;

    const last = sender.sent[sender.sent.length - 1];
    expect(last.type).toBe("tunnel:http-end");
    expect(last.error).toBeUndefined();
    expect(rawBytes(sender.sent).byteLength).toBe(4 * 1024);
  });

  for (const outcome of ["dropped", "gated"] as const) {
    test(`a frame the transport reports ${outcome} aborts the stream: the upstream is cancelled and no end is sent`, async () => {
      const route = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
      const sender = makeSender();
      sender.plan = (frame) =>
        frame.type === "tunnel:http-chunk" && frame.seq === 2 ? outcome : "sent";
      const mgr = makeManager(sender);

      await mgr.onHttpRequest(request(route.port, "lost"));

      expect(sender.sent.map((f) => f.type)).toEqual([
        "tunnel:http-start",
        "tunnel:http-chunk",
        "tunnel:http-chunk",
      ]);
      await waitUntil(() => route.state.cancelled);

      // Nothing partial is retained, so the app's retry gets a real answer.
      sender.plan = undefined;
      await mgr.onHttpRequest(request(route.port, "lost"));
      expect(route.hits()).toBe(2);
    });
  }

  test("tunnel:http-cancel stops the fetch and no further frames follow", async () => {
    const route = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
    const sender = makeSender();
    sender.plan = holdChunk(1);
    const mgr = makeManager(sender);

    const run = mgr.onHttpRequest(request(route.port, "cancelled"));
    await waitUntil(() => sender.waiting() === 1);
    mgr.onHttpCancel({ type: "tunnel:http-cancel", requestId: "cancelled", checkoutId: "main" });
    sender.plan = undefined;
    sender.release();
    await run;

    await Bun.sleep(100);
    // The held frame was already handed over; NOTHING after it — the aborted
    // check sits before the send, not after it.
    expect(sender.sent).toHaveLength(2);
    expect(sender.sent.some((f) => f.type === "tunnel:http-end")).toBe(false);
    await waitUntil(() => route.state.cancelled);
  });

  // Two waiters resuming together would stream one requestId twice at once,
  // splicing two independent seq spaces into one body.
  test("duplicates for one requestId never run concurrently", async () => {
    const route = startRoute({ writes: 4, writeBytes: 1024, gapMs: 20 });
    const sender = makeSender();
    const mgr = makeManager(sender);

    await Promise.all([
      mgr.onHttpRequest(request(route.port, "dup")),
      mgr.onHttpRequest(request(route.port, "dup")),
      mgr.onHttpRequest(request(route.port, "dup")),
    ]);

    let expected = 0;
    let runs = 0;
    for (const frame of sender.sent) {
      expect(frame.requestId).toBe("dup");
      if (frame.type === "tunnel:http-start") { expected = 1; runs += 1; continue; }
      if (frame.type === "tunnel:http-chunk") { expect(frame.seq).toBe(expected); expected += 1; continue; }
      expect(frame.type).toBe("tunnel:http-end");
      expect(frame.chunks).toBe(expected - 1);
      expected = 0;
    }
    expect(runs).toBe(3);
    expect(route.hits()).toBeLessThanOrEqual(2);
  });

  test("an upstream that stalls mid-body ends the stream with an error end", async () => {
    const route = startRoute({ writes: 1, writeBytes: 1500, stall: true });
    const sender = makeSender();
    const mgr = makeManager(sender, { readIdleMs: 100, flushMs: 50 });

    await mgr.onHttpRequest(request(route.port, "stalled"));

    const last = sender.sent[sender.sent.length - 1];
    expect(last.type).toBe("tunnel:http-end");
    expect(String(last.error)).toMatch(/stalled/);
    expect(last.chunks).toBe(sender.sent.filter((f) => f.type === "tunnel:http-chunk").length);
  });

  test("an end frame's chunk count equals the chunks sent", async () => {
    const route = startRoute({ writes: 1, writeBytes: 10_000 });
    const sender = makeSender();
    const mgr = makeManager(sender, { chunkBytes: 4096 });

    await mgr.onHttpRequest(request(route.port, "counted"));

    const sizes = sender.sent
      .filter((f) => typeof f.data === "string")
      .map((f) => Buffer.from(f.data as string, "base64").byteLength);
    expect(sizes).toEqual([4096, 4096, 1808]);
    expect(sender.sent.map((f) => f.type)).toEqual([
      "tunnel:http-start",
      "tunnel:http-chunk",
      "tunnel:http-chunk",
      "tunnel:http-end",
    ]);
    expect(sender.sent[3].chunks).toBe(2);
    expect(rawBytes(sender.sent).byteLength).toBe(10_000);
  });

  test("a single-slice body is one frame with last", async () => {
    const route = startRoute({ writes: 1, writeBytes: 500 });
    const sender = makeSender();
    const mgr = makeManager(sender);

    await mgr.onHttpRequest(request(route.port, "small"));

    expect(sender.sent).toHaveLength(1);
    expect(sender.sent[0]).toMatchObject({ type: "tunnel:http-start", last: true });
    expect(rawBytes(sender.sent).byteLength).toBe(500);
  });

  test("an empty body is a start with empty data and last", async () => {
    const route = startRoute({ writes: 0, writeBytes: 0, empty: true, status: 204 });
    const sender = makeSender();
    const mgr = makeManager(sender);

    await mgr.onHttpRequest(request(route.port, "empty"));

    expect(sender.sent).toHaveLength(1);
    expect(sender.sent[0]).toMatchObject({
      type: "tunnel:http-start",
      status: 204,
      data: "",
      bodyEncoding: "base64",
      last: true,
    });
  });

  // One request must not monopolise the link: each stream holds at most one
  // queued frame, so the credit window hands the next slot to whoever is next.
  test("two requests interleave chunk by chunk", async () => {
    const routeA = startRoute({ writes: 6, writeBytes: 1024, gapMs: 5 });
    const routeB = startRoute({ writes: 6, writeBytes: 1024, gapMs: 5 });
    const sender = makeSender();
    sender.plan = () => "hold";
    const mgr = makeManager(sender);

    const runs = Promise.all([
      mgr.onHttpRequest(request(routeA.port, "a")),
      mgr.onHttpRequest(request(routeB.port, "b")),
    ]);

    for (let round = 1; round <= 3; round++) {
      await waitUntil(() => sender.waiting() === 2);
      // Both are parked, so each has emitted exactly `round` frames: neither
      // ran ahead while the other still had one pending.
      const ids = sender.sent.map((f) => f.requestId);
      expect(ids.filter((id) => id === "a")).toHaveLength(round);
      expect(ids.filter((id) => id === "b")).toHaveLength(round);
      sender.release();
      sender.release();
    }

    sender.plan = undefined;
    sender.releaseAll();
    await runs;
  });

  test("a replayed stream is paced and cancellable", async () => {
    const route = startRoute({ writes: 3, writeBytes: 1024 });
    const sender = makeSender();
    const mgr = makeManager(sender);

    await mgr.onHttpRequest(request(route.port, "replayed"));
    expect(sender.sent[sender.sent.length - 1].type).toBe("tunnel:http-end");
    sender.sent.length = 0;

    sender.plan = () => "hold";
    const replay = mgr.onHttpRequest(request(route.port, "replayed"));
    await waitUntil(() => sender.waiting() === 1);
    mgr.onHttpCancel({ type: "tunnel:http-cancel", requestId: "replayed", checkoutId: "main" });
    sender.release();
    await replay;

    expect(route.hits()).toBe(1);
    expect(sender.sent).toHaveLength(1);
    expect(sender.sent[0].type).toBe("tunnel:http-start");
  });

  test("stop() aborts an in-flight stream", async () => {
    const route = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
    const sender = makeSender();
    sender.plan = holdChunk(1);
    const mgr = makeManager(sender);

    const run = mgr.onHttpRequest(request(route.port, "stopped"));
    await waitUntil(() => sender.waiting() === 1);
    mgr.stop();
    await waitUntil(() => route.state.cancelled);

    sender.plan = undefined;
    sender.release();
    await run;
    await Bun.sleep(50);
    expect(sender.sent).toHaveLength(2);
  });

  // Both shapes of in-flight run must go: the relay client's queue clear only
  // ever reaches one that happens to be parked on a settle at that instant.
  test("abortHttpStreams() aborts every in-flight run whether or not it is parked", async () => {
    const parked = startRoute({ writes: 8, writeBytes: 1024, gapMs: 20 });
    const running = startRoute({ writes: 20, writeBytes: 1024, gapMs: 20 });
    const sender = makeSender();
    sender.plan = (frame) =>
      frame.requestId === "parked" && frame.type === "tunnel:http-chunk" ? "hold" : "sent";
    const mgr = makeManager(sender);

    const runs = Promise.all([
      mgr.onHttpRequest(request(parked.port, "parked")),
      mgr.onHttpRequest(request(running.port, "running")),
    ]);
    await waitUntil(() => sender.waiting() === 1);
    await waitUntil(() => sender.sent.some((f) => f.requestId === "running" && f.type === "tunnel:http-chunk"));

    mgr.abortHttpStreams();
    sender.plan = undefined;
    sender.releaseAll();
    await runs;
    await waitUntil(() => parked.state.cancelled && running.state.cancelled);
    expect(sender.sent.some((f) => f.type === "tunnel:http-end")).toBe(false);

    const before = sender.sent.length;
    await Bun.sleep(100);
    expect(sender.sent).toHaveLength(before);

    // Nothing was retained, so each id re-fetches.
    await Promise.all([
      mgr.onHttpRequest(request(parked.port, "parked")),
      mgr.onHttpRequest(request(running.port, "running")),
    ]);
    expect(parked.hits()).toBe(2);
    expect(running.hits()).toBe(2);
  });

  // Register-before-invoke: a third request joining mid-registration must find
  // the entry, or it starts a second upstream run for the same id.
  test("a run registered by a duplicate is visible to a third waiter before its first await", async () => {
    const route = startRoute({ writes: 1, writeBytes: 512 });
    const sender = makeSender();
    const mgr = makeManager(sender);

    const run = mgr.onHttpRequest(request(route.port, "sync"));
    expect((mgr as unknown as { inflight: Map<string, unknown> }).inflight.has("sync")).toBe(true);
    await run;
  });
});
