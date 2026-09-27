// Drives TunnelStreamRegistry directly with fakes — no PeerStreamAcceptor, no
// real StreamMux, no real TunnelManager. Admission (authorization, the
// open-frame read, refusal codes, caps, unauthorized mid-stream, oversize
// records, projectDetached, dropPeer) is covered once for every kind by
// stream-admission.test.ts; this file starts at the handler boundary and
// covers tunnel's own body: the head-record protocol, request-body pumping,
// and the HTTP/WS exchange lifecycle.
import { describe, test, expect } from "bun:test";
import {
  TunnelStreamRegistry,
  type TunnelStreamRegistryOptions,
} from "../src/peer/tunnel-streams";
import { STREAM_RESET_SCOPED, STREAM_STOP_SCOPED } from "../src/peer/stream-dispatch";
import { STREAM_RAW_READ_BYTES } from "../src/peer/stream-records";
import {
  encodeTunnelDataRecord,
  STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES,
  TUNNEL_RECORD_TAG_WS_BINARY,
  type TunnelHttpStreamOpen,
  type TunnelWsStreamOpen,
} from "antgrid-wire";
import type { TunnelProjectBinding } from "../src/project-streams";
import type {
  TunnelAdmission,
  TunnelHttpExchange,
  TunnelManager,
  TunnelWsPeer,
  TunnelWsUpstreamSink,
} from "../src/tunnel-manager";
import type { TunnelHttpRequest, TunnelWsOpen } from "../src/tunnel-protocol";
import type { TunnelRequestBody } from "../src/localhost-fetch";
import { createFakeBiStream, createFakeProjectBinding, flush, manualSchedule, refusalOf, type FakeBiStream } from "./support/fake-bi-stream";

/** Drains a `TunnelRequestBody`'s stream to completion, the way a real fetch
 *  call would — a raw body is pull-based, so nothing reads off the wire until
 *  something calls this (or the manager under test does its own draining). */
async function readBody(body: TunnelRequestBody | null): Promise<Uint8Array> {
  if (!body) return new Uint8Array(0);
  const stream = body.stream();
  if (!stream) return new Uint8Array(0);
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }
  return new Uint8Array(Buffer.concat(chunks.map((c) => Buffer.from(c))));
}

function fakeManager() {
  const httpCalls: Array<{ req: TunnelHttpRequest; body: TunnelRequestBody | null; exchange: TunnelHttpExchange }> = [];
  const wsCalls: Array<{ open: TunnelWsOpen; peer: TunnelWsPeer; sink: TunnelWsUpstreamSink }> = [];
  let nextSink: TunnelWsUpstreamSink | undefined;
  const manager: Pick<TunnelManager, "serveHttp" | "serveWs"> = {
    serveHttp: async (req, body, exchange) => { httpCalls.push({ req, body, exchange }); },
    serveWs: (open, peer) => {
      const sink: TunnelWsUpstreamSink = nextSink ?? { data() {}, closed() {} };
      wsCalls.push({ open, peer, sink });
      return sink;
    },
  };
  return {
    manager: manager as TunnelManager,
    httpCalls,
    wsCalls,
    setNextSink: (sink: TunnelWsUpstreamSink) => { nextSink = sink; },
  };
}

/** Fake `TunnelStreamServer`: what `binding.tunnels()` returns. */
function fakeTunnelServer() {
  let refusal: { code: "NOT_ALLOWED"; message: string } | null = null;
  const { manager, httpCalls, wsCalls, setNextSink } = fakeManager();
  const admitCalls: Array<{ peerId: string; checkoutId: string }> = [];
  const admit = (peerId: string, checkoutId: string): TunnelAdmission => {
    admitCalls.push({ peerId, checkoutId });
    if (refusal) return { ok: false, refusal };
    return { ok: true, manager };
  };
  return {
    admit, httpCalls, wsCalls, admitCalls, setNextSink,
    setRefusal: (r: { code: "NOT_ALLOWED"; message: string } | null) => { refusal = r; },
  };
}

/** A `TunnelProjectBinding` built on the shared fake, plus tunnel's own fake
 *  upstream server wired through `setTunnels`. */
function fakeBinding() {
  const server = fakeTunnelServer();
  const binding = createFakeProjectBinding();
  const setAvailable = (v: boolean) => binding.setTunnels(v ? { admit: server.admit } : null);
  setAvailable(true);
  return {
    binding: binding as TunnelProjectBinding,
    server,
    setMayDeliver: binding.setMayDeliver,
    setAvailable,
  };
}

function makeRegistry(overrides: Partial<TunnelStreamRegistryOptions> = {}) {
  const cataloged = new Set<string>();
  const bindings = new Map<string, TunnelProjectBinding>();
  const retiredPeers: Array<{ peerId: string; reason: "unauthorized" | "protocol-violation" }> = [];
  const diagnostics: Array<{ type: string; detail: Record<string, unknown>; stream?: { kind: string; id: string } }> = [];
  const opts: TunnelStreamRegistryOptions = {
    projectCataloged: (id) => cataloged.has(id),
    projectBinding: (id) => bindings.get(id) ?? null,
    retirePeer: (peerId, reason) => retiredPeers.push({ peerId, reason }),
    diagnostic: (type, detail, stream) => diagnostics.push({ type, detail, stream }),
    ...overrides,
  };
  const registry = new TunnelStreamRegistry(opts);
  return { registry, cataloged, bindings, retiredPeers, diagnostics };
}

const PROJECT = "proj1";
const PEER = "peer1";

function admitHttp(
  registry: TunnelStreamRegistry,
  opts: { peerId?: string; projectId?: string; requestId?: string; authorized?: () => boolean } = {},
) {
  const fake = createFakeBiStream();
  const requestId = opts.requestId ?? crypto.randomUUID();
  const open: TunnelHttpStreamOpen = { kind: "tunnel-http", projectId: opts.projectId ?? PROJECT, requestId };
  const admission = { peerId: opts.peerId ?? PEER, open, stream: fake.stream, authorized: opts.authorized ?? (() => true) };
  const result = registry.handlerFor("tunnel-http")(admission);
  return { fake, requestId, admission, result };
}

function admitWs(
  registry: TunnelStreamRegistry,
  opts: { peerId?: string; projectId?: string; wsId?: string; authorized?: () => boolean } = {},
) {
  const fake = createFakeBiStream();
  const wsId = opts.wsId ?? crypto.randomUUID();
  const open: TunnelWsStreamOpen = { kind: "tunnel-ws", projectId: opts.projectId ?? PROJECT, wsId };
  const admission = { peerId: opts.peerId ?? PEER, open, stream: fake.stream, authorized: opts.authorized ?? (() => true) };
  const result = registry.handlerFor("tunnel-ws")(admission);
  return { fake, wsId, admission, result };
}

function httpRequest(requestId: string, opts: Partial<TunnelHttpRequest> = {}): TunnelHttpRequest {
  return {
    type: "tunnel:http-request",
    requestId,
    port: 3000,
    method: "GET",
    path: "/",
    bodyLength: 0,
    checkoutId: "main",
    ...opts,
  };
}

function wsOpenRecord(wsId: string, opts: Partial<TunnelWsOpen> = {}): TunnelWsOpen {
  return { type: "tunnel:ws-open", tunnelId: wsId, port: 3000, path: "/", checkoutId: "main", ...opts };
}

describe("TunnelStreamRegistry", () => {
  test("a head that never arrives resets the writer and frees the slot immediately, stopping the receive half only once the pending read settles", async () => {
    const ctl = manualSchedule();
    const { registry, cataloged, bindings } = makeRegistry({ schedule: ctl.schedule });
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);
    const { fake, admission } = admitHttp(registry, {});
    expect(registry.streamCount(admission.peerId)).toBe(1);

    ctl.fire();
    await flush();
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    expect(registry.streamCount(admission.peerId)).toBe(0);
    expect(fake.stops).toEqual([]); // the read is still outstanding

    // The pending read settling with an ERROR (the app hung up first) means
    // there is nothing left to stop — `stop()` only fires for a read that
    // resolves late, so a fresh record isn't left to leak past the timeout.
    fake.endWith();
    await flush();
    expect(fake.stops).toEqual([]);
  });

  test("a head record that arrives AFTER the deadline still gets its receive half stopped, once that late read settles", async () => {
    const ctl = manualSchedule();
    const { registry, cataloged, bindings } = makeRegistry({ schedule: ctl.schedule });
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);
    const { fake, requestId, admission } = admitHttp(registry, {});

    ctl.fire();
    await flush();
    expect(fake.stops).toEqual([]);

    fake.pushRecord(httpRequest(requestId)); // arrives late, after the timeout fired
    await flush();
    expect(fake.stops).toEqual([STREAM_STOP_SCOPED]);
    expect(registry.streamCount(admission.peerId)).toBe(0);
  });

  test("a head that fails validation is refused INVALID", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);

    const cases: Array<{ name: string; build: (requestId: string) => unknown; messageContains?: string }> = [
      { name: "not the JSON control kind", build: () => encodeTunnelDataRecord(TUNNEL_RECORD_TAG_WS_BINARY, new Uint8Array([1, 2, 3])) },
      { name: "malformed JSON", build: () => new TextEncoder().encode("{not json}") },
      { name: "id disagrees with the open frame", build: () => ({ type: "tunnel:http-request", requestId: "not-the-bound-id", port: 3000, method: "GET", path: "/" }) },
      { name: "fails the schema", build: (requestId) => ({ type: "tunnel:http-request", requestId, port: -1, method: "GET", path: "/" }) },
      { name: "bodyLength over the wire cap", build: (requestId) => httpRequest(requestId, { bodyLength: STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES + 1 }), messageContains: "large" },
      { name: "content-length disagrees with bodyLength", build: (requestId) => httpRequest(requestId, { bodyLength: 10, headers: { "Content-Length": "999" } }), messageContains: "content-length" },
    ];

    for (const c of cases) {
      const { fake, requestId } = admitHttp(registry, {});
      const record = c.build(requestId);
      fake.pushRecord(record instanceof Uint8Array ? record : (record as never));
      await flush();
      expect(refusalOf(fake)).toMatchObject(
        c.messageContains
          ? { code: "INVALID", message: expect.stringContaining(c.messageContains) }
          : { code: "INVALID" },
      );
    }
  });

  test("a head record whose project has no tunnel server is refused NOT_ALLOWED, whether that was true at admission or only by the time the head arrives", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fb.setAvailable(false); // becomes unavailable between admission and the head record
    fake.pushRecord(httpRequest(requestId));
    await flush();
    expect(refusalOf(fake)).toMatchObject({ code: "NOT_ALLOWED" });
  });

  test("admit() refusals are passed through in-band, by code, and never reach serveHttp", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    fb.server.setRefusal({ code: "NOT_ALLOWED", message: "mobile access is disabled" });
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(httpRequest(requestId));
    await flush();
    expect(refusalOf(fake)).toMatchObject({ code: "NOT_ALLOWED", message: "mobile access is disabled" });
    expect(fb.server.httpCalls).toEqual([]);
  });

  test("exchange.fail is a dropped diagnostic tagged with this request's own tunnel-http stream", async () => {
    const { registry, cataloged, bindings, diagnostics } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(httpRequest(requestId, { bodyLength: 0 }));
    await flush();
    expect(fb.server.httpCalls).toHaveLength(1);

    fb.server.httpCalls[0]!.exchange.fail("upstream-error");
    await flush();

    const event = diagnostics.find((d) => d.type === "tunnel-stream:http-failed");
    expect(event?.stream).toEqual({ kind: "tunnel-http", id: requestId });
  });

  test("a FIN or reset before the declared body fully arrives errors the body stream and resets the tunnel stream", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(httpRequest(requestId, { bodyLength: 10 }));
    await flush();
    // The body is pull-based (highWaterMark 0): serveHttp is called right
    // away, but nothing is read off the wire until the manager drains it.
    expect(fb.server.httpCalls).toHaveLength(1);
    const { body, exchange } = fb.server.httpCalls[0]!;

    const drained = readBody(body);
    await flush();
    fake.endWith(); // the app hangs up mid-body
    await expect(drained).rejects.toThrow();
    await flush();

    expect(exchange.signal.aborted).toBe(true);
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    expect(registry.streamCount(PEER)).toBe(0);
  });

  test("a request body arriving across several raw reads is reassembled byte-exact, even split at odd boundaries", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    const payload = new TextEncoder().encode("the quick brown fox");
    fake.pushRecord(httpRequest(requestId, { bodyLength: payload.byteLength }));
    await flush();
    const { body } = fb.server.httpCalls[0]!;

    const drained = readBody(body);
    await flush();
    // Three uneven pieces, not aligned to any word or record boundary —
    // flushed between each so every one lands on its own pending raw read.
    fake.pushRaw(payload.subarray(0, 3));
    await flush();
    fake.pushRaw(payload.subarray(3, 4));
    await flush();
    fake.pushRaw(payload.subarray(4));
    expect(await drained).toEqual(payload);
  });

  test("a response ends with a clean FIN and no end-of-body record: writer.finish() is the only 'done' signal", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(httpRequest(requestId));
    await flush();
    const exchange = fb.server.httpCalls[0]!.exchange;

    await exchange.head({ status: 200, headers: {} });
    const writesBeforeBody = fake.order.filter((o) => o === "writeAll").length;
    await exchange.body(new TextEncoder().encode("hi"));
    expect(fake.order.filter((o) => o === "writeAll").length).toBe(writesBeforeBody + 1);
    expect(fake.isFinished()).toBe(false);
    await exchange.end();

    // `finish()` alone is the "done" signal — no end-of-body record.
    expect(fake.isFinished()).toBe(true);
    expect(fake.order.filter((o) => o === "writeAll").length).toBe(writesBeforeBody + 1);
  });

  test("more bytes than the declared body length is a stream breach: the upstream body errors and the stream resets", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(httpRequest(requestId, { bodyLength: 3 }));
    await flush();
    const { body, exchange } = fb.server.httpCalls[0]!;

    const drained = readBody(body);
    await flush();
    fake.pushRaw(new TextEncoder().encode("hel")); // exactly the declared length
    expect(await drained).toEqual(new TextEncoder().encode("hel"));
    await flush(); // the body drains, handing the wire to the cancel watcher

    // More bytes than declared arrive next — a stream breach the cancel
    // watcher catches, not the already-closed body.
    fake.pushRaw(new TextEncoder().encode("lo"));
    await flush();

    expect(exchange.signal.aborted).toBe(true);
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    expect(registry.streamCount(PEER)).toBe(0);
  });

  test("a request body that stalls short of its declared length times out, erroring the body and resetting the stream", async () => {
    const ctl = manualSchedule();
    const { registry, cataloged, bindings } = makeRegistry({ schedule: ctl.schedule, requestBodyIdleMs: 5_000 });
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(httpRequest(requestId, { bodyLength: 10 }));
    await flush();
    const { body, exchange } = fb.server.httpCalls[0]!;

    const drained = readBody(body);
    await flush();
    fake.pushRaw(new TextEncoder().encode("abc")); // short of the declared 10
    await flush();
    ctl.fire(); // the idle clock fires before any more bytes arrive

    await expect(drained).rejects.toThrow();
    await flush();
    expect(exchange.signal.aborted).toBe(true);
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
  });

  test("the app's FIN after end() is its own orderly close and is ignored, not treated as a cancel", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(httpRequest(requestId));
    await flush();
    const exchange = fb.server.httpCalls[0]!.exchange;

    await exchange.head({ status: 200, headers: {} });
    await exchange.end();
    fake.endWith(); // the app's own FIN, arriving after our end()
    await flush();

    expect(exchange.signal.aborted).toBe(false);
    expect(fake.resets).toEqual([]);
  });

  test("the app cancelling while a response is already in flight aborts the exchange and resets the stream", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(httpRequest(requestId));
    await flush();
    const exchange = fb.server.httpCalls[0]!.exchange;

    await exchange.head({ status: 200, headers: {} });
    await exchange.body(new TextEncoder().encode("partial"));
    fake.endWith(); // the app hangs up before end() — a cancel, not its own FIN
    await flush();

    expect(exchange.signal.aborted).toBe(true);
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    expect(registry.streamCount(PEER)).toBe(0);
  });

  test("a reader rejection before end() is the app's cancel: aborts the exchange signal and the writer", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(httpRequest(requestId));
    await flush();
    expect(fb.server.httpCalls).toHaveLength(1);
    const exchange = fb.server.httpCalls[0]!.exchange;
    expect(exchange.signal.aborted).toBe(false);

    fake.endWith(); // the app cancels before the manager ever calls end()
    await flush();

    expect(exchange.signal.aborted).toBe(true);
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    expect(registry.streamCount(PEER)).toBe(0);
  });

  test("an extra record after the declared body is a stream breach: reset, but no retirePeer", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(httpRequest(requestId)); // bodyLength 0: nothing more is allowed
    await flush();
    expect(fb.server.httpCalls).toHaveLength(1);
    const exchange = fb.server.httpCalls[0]!.exchange;

    // The watcher reads raw bytes, so any stray byte is a breach — not a
    // specific record shape.
    fake.pushRaw(new Uint8Array([1]));
    await flush();

    expect(exchange.signal.aborted).toBe(true);
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    expect(fake.stops).toEqual([STREAM_STOP_SCOPED]);
    expect(retiredPeers).toEqual([]);
  });

  test("an upstream WS close after mayDeliverTo turns false writes no ws-close record: it resets and unbinds", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, wsId } = admitWs(registry, {});
    fake.pushRecord(wsOpenRecord(wsId));
    await flush();
    const peer = fb.server.wsCalls[0]!.peer;
    const writesBefore = fake.order.filter((o) => o === "writeAll").length;

    fb.setMayDeliver(false);
    peer.close(1000, "bye");
    await flush();

    expect(fake.order.filter((o) => o === "writeAll").length).toBe(writesBefore);
    expect(fake.isFinished()).toBe(false);
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    expect(registry.streamCount(PEER)).toBe(0);
  });

  test("false mayDeliverTo on a send reports dropped and aborts the writer: an HTTP exchange as well as a WS sink", async () => {
    {
      const { registry, cataloged, bindings } = makeRegistry();
      cataloged.add(PROJECT);
      const fb = fakeBinding();
      bindings.set(PROJECT, fb.binding);
      const { fake, requestId } = admitHttp(registry, {});
      fake.pushRecord(httpRequest(requestId));
      await flush();
      const exchange = fb.server.httpCalls[0]!.exchange;

      fb.setMayDeliver(false);
      const outcome = await exchange.head({ status: 200, headers: {} });
      expect(outcome).toBe("dropped");
      expect(exchange.signal.aborted).toBe(true);
      expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
      expect(registry.streamCount(PEER)).toBe(0);
    }
    {
      const { registry, cataloged, bindings } = makeRegistry();
      cataloged.add(PROJECT);
      const fb = fakeBinding();
      bindings.set(PROJECT, fb.binding);
      const closedCalls: Array<[number?, string?]> = [];
      fb.server.setNextSink({ data() {}, closed: (code, reason) => { closedCalls.push([code, reason]); } });
      const { fake, wsId } = admitWs(registry, {});
      fake.pushRecord(wsOpenRecord(wsId));
      await flush();
      const peer = fb.server.wsCalls[0]!.peer;

      fb.setMayDeliver(false);
      const outcome = await peer.send({ binary: false, bytes: new TextEncoder().encode("x") });
      expect(outcome).toBe("dropped");
      expect(closedCalls).toEqual([[undefined, undefined]]);
      expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    }
  });

  test("a request-body raw read never asks for more than the declared bytes still owed", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    const declared = STREAM_RAW_READ_BYTES + 7;
    fake.pushRecord(httpRequest(requestId, { bodyLength: declared }));
    await flush();
    const drained = readBody(fb.server.httpCalls[0]!.body);
    await flush();
    fake.pushRaw(new Uint8Array(STREAM_RAW_READ_BYTES));
    await flush();
    fake.pushRaw(new Uint8Array(7));
    expect((await drained).byteLength).toBe(declared);

    // The second read is sized to the 7 bytes left, never a full raw read
    // that could swallow whatever the app sends after its body.
    expect(fake.readSizes.slice(0, 2)).toEqual([STREAM_RAW_READ_BYTES, 7]);
  });

  test("authorized() turning false after a raw request-body read retires the peer and errors the body", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    let authorized = true;
    const { fake, requestId } = admitHttp(registry, { authorized: () => authorized });
    fake.pushRecord(httpRequest(requestId, { bodyLength: 10 }));
    await flush();
    const drained = readBody(fb.server.httpCalls[0]!.body);
    await flush();

    authorized = false;
    fake.pushRaw(new TextEncoder().encode("abc"));

    await expect(drained).rejects.toThrow();
    expect(retiredPeers).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
  });

  test("a second body stream (the scheme retry) replays what the first pulled, then continues from the wire", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(httpRequest(requestId, { bodyLength: 6 }));
    await flush();
    const body = fb.server.httpCalls[0]!.body!;

    const first = body.stream()!.getReader();
    const firstRead = first.read();
    fake.pushRaw(new TextEncoder().encode("abc"));
    expect(new TextDecoder().decode((await firstRead).value)).toBe("abc");
    void first.cancel();

    const retry = readBody(body);
    await flush();
    fake.pushRaw(new TextEncoder().encode("def"));
    expect(new TextDecoder().decode(await retry)).toBe("abcdef");
  });

  test("a retry started while the first attempt's read is still outstanding gets that read's bytes, in order", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(httpRequest(requestId, { bodyLength: 6 }));
    await flush();
    const body = fb.server.httpCalls[0]!.body!;

    // The first attempt's fetch pulls once and fails before the app's bytes
    // arrive, leaving that raw read outstanding on the stream.
    const first = body.stream()!.getReader();
    void first.read().catch(() => {});
    await flush();
    void first.cancel().catch(() => {});

    const retry = readBody(body);
    await flush();
    fake.pushRaw(new TextEncoder().encode("abc"));
    await flush();
    fake.pushRaw(new TextEncoder().encode("def"));
    expect(new TextDecoder().decode(await retry)).toBe("abcdef");
  });
});
