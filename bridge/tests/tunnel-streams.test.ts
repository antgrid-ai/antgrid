// Stage A wave A3 (docs/iroh-reduction/stage-A-A3-contract.md §3.3, §6).
// Drives TunnelStreamRegistry directly with fakes — no PeerStreamAcceptor, no
// real StreamMux, no real TunnelManager. The acceptor's own admission order
// (authorization, the open-frame read, NOT_READY pre-handler, the pending cap)
// is covered by stream-dispatch.test.ts; this file starts at the handler
// boundary, mirroring terminal-streams.test.ts's pattern for the A2 registry.
import { describe, test, expect } from "bun:test";
import {
  TunnelStreamRegistry,
  TUNNEL_STREAM_MAX_QUEUED_BYTES,
  STREAM_PRIORITY_TUNNEL,
  STREAM_RESET_TUNNEL,
  STREAM_STOP_TUNNEL,
  type TunnelStreamRegistryOptions,
} from "../src/peer/tunnel-streams";
import {
  encodeTunnelDataRecord,
  STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
  STREAM_TUNNEL_DATA_MAX_BYTES,
  STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES,
  TUNNEL_RECORD_TAG_BODY,
  type TunnelHttpStreamOpen,
  type TunnelWsStreamOpen,
} from "antgrid-wire";
import type { TunnelProjectBinding } from "../src/stream-mux";
import type { StreamRefusal } from "../src/peer/stream-dispatch";
import type {
  TunnelAdmission,
  TunnelHttpExchange,
  TunnelManager,
  TunnelWsFrame,
  TunnelWsPeer,
  TunnelWsUpstreamSink,
} from "../src/tunnel-manager";
import type { TunnelHttpRequest, TunnelWsOpen } from "../src/tunnel-protocol";

/** Serializes calls exactly like the real binding's `Arc<Mutex<..>>`, mirroring
 *  stream-records.test.ts's FakeMutex: a call queued behind another does not
 *  start running its body until the prior one's promise settles. */
class FakeMutex {
  private tail: Promise<unknown> = Promise.resolve();
  run<T>(fn: () => Promise<T>): Promise<T> {
    const result = this.tail.then(fn);
    this.tail = result.then(() => undefined, () => undefined);
    return result;
  }
}

function flush(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function lengthPrefixed(body: Uint8Array): number[][] {
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(body.length);
  return [Array.from(prefix), Array.from(body)];
}

/** One fake tunnel stream: a send half and a recv half, each behind its own
 *  mutex, matching the binding's independent send/recv locks. */
function createFakeStream() {
  const sendMutex = new FakeMutex();
  const recvMutex = new FakeMutex();
  const writeAllCalls: number[][] = [];
  const setPriorityCalls: number[] = [];
  const resetCalls: bigint[] = [];
  const stopCalls: bigint[] = [];
  const readCalls: number[] = [];
  const order: string[] = [];
  let finishCalls = 0;
  let pendingGate: Promise<void> | null = null;

  const recvQueue: number[][] = [];
  const waiters: Array<{ resolve: (v: number[]) => void; reject: (e: unknown) => void }> = [];
  let endError: unknown = null;

  function pump(): void {
    while (waiters.length && (recvQueue.length || endError !== null)) {
      const waiter = waiters.shift()!;
      if (recvQueue.length) waiter.resolve(recvQueue.shift()!);
      else waiter.reject(endError);
    }
  }

  const send = {
    writeAll: (bytes: number[]) =>
      sendMutex.run(async () => {
        order.push("writeAll");
        writeAllCalls.push(bytes);
        const gate = pendingGate;
        pendingGate = null;
        if (gate) await gate;
      }),
    setPriority: (p: number) => sendMutex.run(async () => { order.push("setPriority"); setPriorityCalls.push(p); }),
    reset: (code: bigint) => sendMutex.run(async () => { order.push("reset"); resetCalls.push(code); }),
    finish: () => sendMutex.run(async () => { order.push("finish"); finishCalls++; }),
  };
  const recv = {
    readExact: (size: number) => {
      readCalls.push(size);
      return recvMutex.run(() => new Promise<number[]>((resolve, reject) => {
        waiters.push({ resolve, reject });
        pump();
      }));
    },
    stop: (code: bigint) => recvMutex.run(async () => { stopCalls.push(code); }),
  };

  return {
    stream: { send, recv },
    writeAllCalls, setPriorityCalls, resetCalls, stopCalls, readCalls, order,
    finishCalls: () => finishCalls,
    pushRecord(record: Uint8Array): void {
      for (const chunk of lengthPrefixed(record)) recvQueue.push(chunk);
      pump();
    },
    pushJson(value: unknown): void {
      this.pushRecord(new TextEncoder().encode(JSON.stringify(value)));
    },
    endWith(error: unknown = new Error("peer ended")): void {
      endError = error;
      pump();
    },
    /** Blocks the NEXT `writeAll` (through the shared send lock). One-shot. */
    gateNextWrite(): { release: () => void } {
      const { promise, resolve } = Promise.withResolvers<void>();
      pendingGate = promise;
      return { release: () => resolve() };
    },
  };
}

/** Decodes every `[u32 len][json]` record this stream has written so far. Every
 *  test frame is small enough to land as one `writeAll` slice, so one entry in
 *  `writeAllCalls` is one whole record. */
function decodedRecords(fake: ReturnType<typeof createFakeStream>): unknown[] {
  return fake.writeAllCalls.map((bytes) => {
    const buf = Buffer.from(bytes);
    const len = buf.readUInt32BE(0);
    return JSON.parse(buf.subarray(4, 4 + len).toString("utf8"));
  });
}

function refusalRecord(fake: ReturnType<typeof createFakeStream>): { code: string; message: string } | undefined {
  return decodedRecords(fake).find(
    (r): r is { type: string; code: string; message: string } =>
      typeof r === "object" && r !== null && (r as { type?: unknown }).type === "stream:refused",
  );
}

/** Fake `TunnelManager`: records every `serveHttp`/`serveWs` call instead of
 *  actually fetching anything. */
function fakeManager() {
  const httpCalls: Array<{ req: TunnelHttpRequest; body: Uint8Array; exchange: TunnelHttpExchange }> = [];
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

/** Fake `TunnelStreamServer`: what `binding.tunnelBinding.tunnels()` returns. */
function fakeTunnelServer() {
  let refusal: { code: "UPDATE_REQUIRED" | "NOT_ALLOWED"; message: string } | null = null;
  const { manager, httpCalls, wsCalls, setNextSink } = fakeManager();
  const admitCalls: Array<{ peerId: string; checkoutId: string }> = [];
  const admit = (peerId: string, checkoutId: string): TunnelAdmission => {
    admitCalls.push({ peerId, checkoutId });
    if (refusal) return { ok: false, refusal };
    return { ok: true, manager };
  };
  return {
    admit, httpCalls, wsCalls, admitCalls, setNextSink,
    setRefusal: (r: { code: "UPDATE_REQUIRED" | "NOT_ALLOWED"; message: string } | null) => { refusal = r; },
  };
}

/** Fake `TunnelProjectBinding`. */
function fakeBinding(streamId = "project-stream") {
  const server = fakeTunnelServer();
  let refuse: ((peerId: string) => StreamRefusal | null) | null = null;
  let mayDeliver = true;
  let available = true;
  const binding: TunnelProjectBinding = {
    streamId,
    refusalFor: (peerId) => (refuse ? refuse(peerId) : null),
    mayDeliverTo: () => mayDeliver,
    tunnels: () => (available ? { admit: server.admit } : null),
  };
  return {
    binding, server,
    setRefusal: (fn: ((peerId: string) => StreamRefusal | null) | null) => { refuse = fn; },
    setMayDeliver: (v: boolean) => { mayDeliver = v; },
    setAvailable: (v: boolean) => { available = v; },
  };
}

function makeControllableSchedule() {
  const pending: Array<() => void> = [];
  const schedule = (cb: () => void, _ms: number): (() => void) => {
    let fired = false;
    pending.push(() => { if (!fired) { fired = true; cb(); } });
    return () => { fired = true; };
  };
  return { schedule, fireAll: () => { for (const fn of pending.splice(0)) fn(); } };
}

function makeRegistry(overrides: Partial<TunnelStreamRegistryOptions> = {}) {
  const cataloged = new Set<string>();
  const bindings = new Map<string, TunnelProjectBinding>();
  const retiredPeers: Array<{ peerId: string; reason: "unauthorized" | "protocol-violation" }> = [];
  const diagnostics: Array<{ type: string; detail: Record<string, unknown> }> = [];
  const opts: TunnelStreamRegistryOptions = {
    projectCataloged: (id) => cataloged.has(id),
    tunnelBinding: (id) => bindings.get(id) ?? null,
    retirePeer: (peerId, reason) => retiredPeers.push({ peerId, reason }),
    diagnostic: (type, detail) => diagnostics.push({ type, detail }),
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
  const fake = createFakeStream();
  const requestId = opts.requestId ?? crypto.randomUUID();
  const open: TunnelHttpStreamOpen = { kind: "tunnel-http", projectId: opts.projectId ?? PROJECT, requestId };
  const admission = { peerId: opts.peerId ?? PEER, open, stream: fake.stream, authorized: opts.authorized ?? (() => true) };
  // The registry decides every refusal synchronously, before any read.
  const result = registry.httpHandler(admission) as StreamRefusal | undefined;
  return { fake, requestId, admission, result };
}

function admitWs(
  registry: TunnelStreamRegistry,
  opts: { peerId?: string; projectId?: string; wsId?: string; authorized?: () => boolean } = {},
) {
  const fake = createFakeStream();
  const wsId = opts.wsId ?? crypto.randomUUID();
  const open: TunnelWsStreamOpen = { kind: "tunnel-ws", projectId: opts.projectId ?? PROJECT, wsId };
  const admission = { peerId: opts.peerId ?? PEER, open, stream: fake.stream, authorized: opts.authorized ?? (() => true) };
  const result = registry.wsHandler(admission) as StreamRefusal | undefined;
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

describe("TunnelStreamRegistry (A3)", () => {
  test("every refusal is decided before any read: CAP_EXCEEDED shared across HTTP and WS, NOT_ALLOWED unsafe id, NOT_ALLOWED uncatalogued, NOT_READY unbound, UPDATE_REQUIRED masks a non-UPDATE_REQUIRED code, INVALID duplicate id, NOT_ALLOWED tunnels unavailable", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding } = fakeBinding();
    bindings.set(PROJECT, binding);

    // CAP_EXCEEDED is shared across HTTP and WS admissions for one peer.
    for (let i = 0; i < STREAM_MAX_TUNNEL_STREAMS_PER_PEER; i++) {
      const admit = i % 2 === 0 ? admitHttp : admitWs;
      const { fake, result } = admit(registry, { peerId: "capful" });
      expect(result).toBeUndefined();
      expect(fake.readCalls).not.toEqual([]);
    }
    {
      const { fake, result } = admitHttp(registry, { peerId: "capful" });
      expect(result?.code).toBe("CAP_EXCEEDED");
      expect(fake.readCalls).toEqual([]);
    }
    {
      const { fake, result } = admitWs(registry, { peerId: "capful" });
      expect(result?.code).toBe("CAP_EXCEEDED");
      expect(fake.readCalls).toEqual([]);
    }

    {
      const { fake, result } = admitHttp(registry, { projectId: "../evil" });
      expect(result?.code).toBe("NOT_ALLOWED");
      expect(fake.readCalls).toEqual([]);
    }

    {
      const { fake, result } = admitHttp(registry, { projectId: "uncatalogued-project" });
      expect(result?.code).toBe("NOT_ALLOWED");
      expect(fake.readCalls).toEqual([]);
    }

    {
      cataloged.add("catalogued-but-unbound");
      const { fake, result } = admitHttp(registry, { projectId: "catalogued-but-unbound" });
      expect(result?.code).toBe("NOT_READY");
      expect(fake.readCalls).toEqual([]);
    }

    {
      cataloged.add("update-project");
      const rebind = fakeBinding();
      rebind.setRefusal(() => ({ code: "UPDATE_REQUIRED", message: "old app" }));
      bindings.set("update-project", rebind.binding);
      const { fake, result } = admitHttp(registry, { projectId: "update-project" });
      expect(result?.code).toBe("UPDATE_REQUIRED");
      expect(fake.readCalls).toEqual([]);

      rebind.setRefusal(() => ({ code: "CAP_EXCEEDED", message: "irrelevant" }));
      const second = admitHttp(registry, { projectId: "update-project" });
      expect(second.result?.code).toBe("NOT_ALLOWED");
      expect(second.fake.readCalls).toEqual([]);
    }

    {
      const dupeId = crypto.randomUUID();
      const first = admitHttp(registry, { requestId: dupeId });
      expect(first.result).toBeUndefined();
      const second = admitHttp(registry, { requestId: dupeId });
      expect(second.result?.code).toBe("INVALID");
      expect(second.fake.readCalls).toEqual([]);
    }

    {
      cataloged.add("no-tunnels");
      const noTunnels = fakeBinding();
      noTunnels.setAvailable(false);
      bindings.set("no-tunnels", noTunnels.binding);
      const { fake, result } = admitHttp(registry, { projectId: "no-tunnels" });
      expect(result?.code).toBe("NOT_ALLOWED");
      expect(fake.readCalls).toEqual([]);
    }
  });

  test("an unsafe projectId is refused NOT_ALLOWED even when the catalog and the mux both hold it", async () => {
    const consulted: string[] = [];
    const { registry, cataloged, bindings } = makeRegistry({
      projectCataloged: (id) => { consulted.push(id); return cataloged.has(id); },
    });
    const unsafe = "../evil";
    cataloged.add(unsafe);
    bindings.set(unsafe, fakeBinding().binding);
    const { fake, result } = admitHttp(registry, { projectId: unsafe });
    expect(result?.code).toBe("NOT_ALLOWED");
    expect(consulted).toEqual([]);
    expect(fake.readCalls).toEqual([]);
  });

  test("an absent projectCataloged fails closed with NOT_ALLOWED", async () => {
    const { registry, bindings } = makeRegistry({ projectCataloged: undefined });
    bindings.set(PROJECT, fakeBinding().binding);
    const { fake, result } = admitHttp(registry, {});
    expect(result?.code).toBe("NOT_ALLOWED");
    expect(fake.readCalls).toEqual([]);
  });

  test("a duplicate id is scoped per kind: the same id may open one HTTP and one WS stream", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);
    const sameId = crypto.randomUUID();
    const http = admitHttp(registry, { requestId: sameId });
    const ws = admitWs(registry, { wsId: sameId });
    expect(http.result).toBeUndefined();
    expect(ws.result).toBeUndefined();
  });

  test("a head that never arrives resets the writer and frees the slot immediately, stopping the receive half only once the pending read settles", async () => {
    const ctl = makeControllableSchedule();
    const { registry, cataloged, bindings } = makeRegistry({ schedule: ctl.schedule });
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);
    const { fake, admission } = admitHttp(registry, {});
    expect(registry.streamCount(admission.peerId)).toBe(1);

    ctl.fireAll();
    await flush();
    expect(fake.resetCalls).toEqual([STREAM_RESET_TUNNEL]);
    expect(registry.streamCount(admission.peerId)).toBe(0);
    expect(fake.stopCalls).toEqual([]); // the read is still outstanding

    // The pending read settling with an ERROR (the app hung up first) means
    // there is nothing left to stop — `stop()` only fires for a read that
    // resolves late, so a fresh record isn't left to leak past the timeout.
    fake.endWith();
    await flush();
    expect(fake.stopCalls).toEqual([]);
  });

  test("a head record that arrives AFTER the deadline still gets its receive half stopped, once that late read settles", async () => {
    const ctl = makeControllableSchedule();
    const { registry, cataloged, bindings } = makeRegistry({ schedule: ctl.schedule });
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);
    const { fake, requestId, admission } = admitHttp(registry, {});

    ctl.fireAll();
    await flush();
    expect(fake.stopCalls).toEqual([]);

    fake.pushJson(httpRequest(requestId)); // arrives late, after the timeout fired
    await flush();
    expect(fake.stopCalls).toEqual([STREAM_STOP_TUNNEL]);
    expect(registry.streamCount(admission.peerId)).toBe(0);
  });

  test("a head record that isn't the JSON control kind is refused INVALID", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushRecord(encodeTunnelDataRecord(TUNNEL_RECORD_TAG_BODY, new Uint8Array([1, 2, 3])));
    void requestId;
    await flush();
    expect(refusalRecord(fake)).toMatchObject({ code: "INVALID" });
  });

  test("a head record with malformed JSON is refused INVALID", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);
    const { fake } = admitHttp(registry, {});
    fake.pushRecord(new TextEncoder().encode("{not json}"));
    await flush();
    expect(refusalRecord(fake)).toMatchObject({ code: "INVALID" });
  });

  test("a head record that fails the schema, or whose id disagrees with the open frame, is refused INVALID", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);
    {
      const { fake, requestId } = admitHttp(registry, {});
      fake.pushJson({ type: "tunnel:http-request", requestId: "not-the-bound-id", port: 3000, method: "GET", path: "/" });
      void requestId;
      await flush();
      expect(refusalRecord(fake)).toMatchObject({ code: "INVALID" });
    }
    {
      const { fake, requestId } = admitHttp(registry, {});
      fake.pushJson({ type: "tunnel:http-request", requestId, port: -1, method: "GET", path: "/" });
      await flush();
      expect(refusalRecord(fake)).toMatchObject({ code: "INVALID" });
    }
  });

  test("a bodyLength over the wire cap is refused INVALID", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushJson(httpRequest(requestId, { bodyLength: STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES + 1 }));
    await flush();
    expect(refusalRecord(fake)).toMatchObject({ code: "INVALID", message: expect.stringContaining("large") });
  });

  test("a content-length header that disagrees with bodyLength is refused INVALID", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushJson(httpRequest(requestId, { bodyLength: 10, headers: { "Content-Length": "999" } }));
    await flush();
    expect(refusalRecord(fake)).toMatchObject({ code: "INVALID", message: expect.stringContaining("content-length") });
  });

  test("the project's tunnel server going unavailable between admission and the head record is refused NOT_ALLOWED, in-band", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fb.setAvailable(false);
    fake.pushJson(httpRequest(requestId));
    await flush();
    expect(refusalRecord(fake)).toMatchObject({ code: "NOT_ALLOWED" });
  });

  test("admit() refusals are passed through in-band, by code", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    fb.server.setRefusal({ code: "NOT_ALLOWED", message: "mobile access is disabled" });
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushJson(httpRequest(requestId));
    await flush();
    expect(refusalRecord(fake)).toMatchObject({ code: "NOT_ALLOWED", message: "mobile access is disabled" });
    expect(fb.server.httpCalls).toEqual([]);
  });

  test("an admitted HTTP stream sets STREAM_PRIORITY_TUNNEL once, before its first write, and calls manager.serveHttp with the reassembled body", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushJson(httpRequest(requestId, { bodyLength: 5 }));
    fake.pushRecord(encodeTunnelDataRecord(TUNNEL_RECORD_TAG_BODY, new TextEncoder().encode("hello")));
    await flush();

    expect(fb.server.httpCalls).toHaveLength(1);
    expect(new TextDecoder().decode(fb.server.httpCalls[0]!.body)).toBe("hello");

    // Priority is set lazily, on the writer's first actual use.
    expect(fake.setPriorityCalls).toEqual([]);
    await fb.server.httpCalls[0]!.exchange.head({ status: 200, headers: {} });
    expect(fake.setPriorityCalls).toEqual([STREAM_PRIORITY_TUNNEL]);
    expect(fake.order.indexOf("setPriority")).toBeLessThan(fake.order.indexOf("writeAll"));
  });

  test("an admitted WS stream sets STREAM_PRIORITY_TUNNEL once, before its first write, and opens the upstream via manager.serveWs", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, wsId } = admitWs(registry, {});
    fake.pushJson(wsOpenRecord(wsId));
    await flush();
    expect(fb.server.wsCalls).toHaveLength(1);

    // Drive one frame through so the writer actually writes, then check order.
    void fb.server.wsCalls[0]!.peer.send({ binary: false, bytes: new TextEncoder().encode("hi") });
    await flush();
    expect(fake.setPriorityCalls).toEqual([STREAM_PRIORITY_TUNNEL]);
    expect(fake.order.indexOf("setPriority")).toBeLessThan(fake.order.indexOf("writeAll"));
  });

  test("a FIN or reset before the declared body fully arrives abandons the request without ever calling serveHttp", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushJson(httpRequest(requestId, { bodyLength: 10 }));
    await flush();
    fake.endWith(); // the app hangs up mid-body
    await flush();

    expect(fb.server.httpCalls).toEqual([]);
    expect(fake.resetCalls).toEqual([STREAM_RESET_TUNNEL]);
    expect(registry.streamCount(PEER)).toBe(0);
  });

  test("a reader rejection before end() is the app's cancel: aborts the exchange signal and the writer", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushJson(httpRequest(requestId));
    await flush();
    expect(fb.server.httpCalls).toHaveLength(1);
    const exchange = fb.server.httpCalls[0]!.exchange;
    expect(exchange.signal.aborted).toBe(false);

    fake.endWith(); // the app cancels before the manager ever calls end()
    await flush();

    expect(exchange.signal.aborted).toBe(true);
    expect(fake.resetCalls).toEqual([STREAM_RESET_TUNNEL]);
    expect(registry.streamCount(PEER)).toBe(0);
  });

  test("an extra record after the declared body is a stream breach: reset, but no retirePeer", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushJson(httpRequest(requestId)); // bodyLength 0: nothing more is allowed
    await flush();
    expect(fb.server.httpCalls).toHaveLength(1);
    const exchange = fb.server.httpCalls[0]!.exchange;

    fake.pushRecord(encodeTunnelDataRecord(TUNNEL_RECORD_TAG_BODY, new Uint8Array([1])));
    await flush();

    expect(exchange.signal.aborted).toBe(true);
    expect(fake.resetCalls).toEqual([STREAM_RESET_TUNNEL]);
    expect(fake.stopCalls).toEqual([STREAM_STOP_TUNNEL]);
    expect(retiredPeers).toEqual([]);
  });

  test("an unauthorized peer at head time retires the connection rather than merely refusing the stream", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);
    let authorized = false;
    const { fake, requestId } = admitHttp(registry, { authorized: () => authorized });
    fake.pushJson(httpRequest(requestId));
    await flush();
    expect(retiredPeers).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
    void authorized;
  });

  test("an app FIN or reset before the head resets the writer and frees the slot at once, without waiting for the head deadline", async () => {
    const ctl = makeControllableSchedule();
    const { registry, cataloged, bindings } = makeRegistry({ schedule: ctl.schedule });
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const http = admitHttp(registry, {});
    const ws = admitWs(registry, {});
    expect(registry.streamCount(PEER)).toBe(2);

    http.fake.endWith(); // the app cancelled while its open was still in flight
    ws.fake.endWith();
    await flush();

    expect(http.fake.resetCalls).toEqual([STREAM_RESET_TUNNEL]);
    expect(ws.fake.resetCalls).toEqual([STREAM_RESET_TUNNEL]);
    expect(registry.streamCount(PEER)).toBe(0);
    expect(fb.server.httpCalls).toEqual([]);
    expect(fb.server.wsCalls).toEqual([]);
  });

  test("an upstream WS close after mayDeliverTo turns false writes no ws-close record: it resets and unbinds", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, wsId } = admitWs(registry, {});
    fake.pushJson(wsOpenRecord(wsId));
    await flush();
    const peer = fb.server.wsCalls[0]!.peer;
    const writesBefore = fake.writeAllCalls.length;

    fb.setMayDeliver(false);
    peer.close(1000, "bye");
    await flush();

    expect(fake.writeAllCalls.length).toBe(writesBefore);
    expect(fake.finishCalls()).toBe(0);
    expect(fake.resetCalls).toEqual([STREAM_RESET_TUNNEL]);
    expect(registry.streamCount(PEER)).toBe(0);
  });

  test("false mayDeliverTo on an HTTP send reports dropped, aborts the writer and the exchange, and unbinds", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const { fake, requestId } = admitHttp(registry, {});
    fake.pushJson(httpRequest(requestId));
    await flush();
    const exchange = fb.server.httpCalls[0]!.exchange;

    fb.setMayDeliver(false);
    const outcome = await exchange.head({ status: 200, headers: {} });
    expect(outcome).toBe("dropped");
    expect(exchange.signal.aborted).toBe(true);
    expect(fake.resetCalls).toEqual([STREAM_RESET_TUNNEL]);
    expect(registry.streamCount(PEER)).toBe(0);
  });

  test("false mayDeliverTo on a WS send reports dropped, aborts the writer, and closes the sink", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const closedCalls: Array<[number?, string?]> = [];
    fb.server.setNextSink({ data() {}, closed: (code, reason) => { closedCalls.push([code, reason]); } });
    const { fake, wsId } = admitWs(registry, {});
    fake.pushJson(wsOpenRecord(wsId));
    await flush();
    const peer = fb.server.wsCalls[0]!.peer;

    fb.setMayDeliver(false);
    const outcome = await peer.send({ binary: false, bytes: new TextEncoder().encode("x") });
    expect(outcome).toBe("dropped");
    expect(closedCalls).toEqual([[undefined, undefined]]);
    expect(fake.resetCalls).toEqual([STREAM_RESET_TUNNEL]);
  });

  test("WS data records reach the sink in order, and a close record follows only after every queued data record", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    const calls: string[] = [];
    fb.server.setNextSink({
      data: (frame) => { calls.push(`data:${new TextDecoder().decode(frame.bytes)}`); },
      closed: (code) => { calls.push(`closed:${code}`); },
    });
    const { fake, wsId } = admitWs(registry, {});
    fake.pushJson(wsOpenRecord(wsId));
    await flush();

    const { TUNNEL_RECORD_TAG_WS_TEXT } = await import("antgrid-wire");
    fake.pushRecord(encodeTunnelDataRecord(TUNNEL_RECORD_TAG_WS_TEXT, new TextEncoder().encode("one")));
    fake.pushRecord(encodeTunnelDataRecord(TUNNEL_RECORD_TAG_WS_TEXT, new TextEncoder().encode("two")));
    fake.pushJson({ type: "tunnel:ws-close", tunnelId: wsId, code: 1000, checkoutId: "main" });
    await flush();

    expect(calls).toEqual(["data:one", "data:two", "closed:1000"]);
  });

  test("WS writer overflow resets only that stream and closes its own sink, leaving a second stream untouched", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);

    const closedA: unknown[] = [];
    fb.server.setNextSink({ data() {}, closed: (...args) => closedA.push(args) });
    const a = admitWs(registry, {});
    a.fake.pushJson(wsOpenRecord(a.wsId));
    await flush();
    const peerA = fb.server.wsCalls[0]!.peer;

    const closedB: unknown[] = [];
    fb.server.setNextSink({ data() {}, closed: (...args) => closedB.push(args) });
    const b = admitWs(registry, {});
    b.fake.pushJson(wsOpenRecord(b.wsId));
    await flush();
    const peerB = fb.server.wsCalls[1]!.peer;

    // Each frame stays at the wire's own per-message cap
    // (STREAM_TUNNEL_DATA_MAX_BYTES, 1 MiB) so none is dropped by that check
    // alone; five of them together overflow the 4 MiB writer queue. No await
    // between the calls, so none has drained into a real `writeAll` yet when
    // the later ones run their own synchronous overflow check.
    const big = new Uint8Array(STREAM_TUNNEL_DATA_MAX_BYTES);
    const first = peerA.send({ binary: true, bytes: big });
    const second = peerA.send({ binary: true, bytes: big });
    const third = peerA.send({ binary: true, bytes: big });
    const fourth = peerA.send({ binary: true, bytes: big });
    const fifth = peerA.send({ binary: true, bytes: big });
    expect(await fifth).toBe("dropped");
    expect(await fourth).toBe("dropped");
    await Promise.allSettled([first, second, third]);
    await flush();

    expect(a.fake.resetCalls).toEqual([STREAM_RESET_TUNNEL]);
    expect(closedA).toHaveLength(1);
    expect(retiredPeers).toEqual([]);

    // B is untouched.
    expect(await peerB.send({ binary: false, bytes: new TextEncoder().encode("still alive") })).toBe("sent");
    expect(b.fake.resetCalls).toEqual([]);
    expect(closedB).toEqual([]);
  });

  test("projectDetached aborts every binding for the project and leaves other projects alone", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);
    cataloged.add("other");
    const other = fakeBinding();
    bindings.set("other", other.binding);

    const { fake: httpFake, requestId } = admitHttp(registry, {});
    httpFake.pushJson(httpRequest(requestId));
    await flush();
    const exchange = fb.server.httpCalls[0]!.exchange;

    const { fake: otherFake, requestId: otherId } = admitHttp(registry, { projectId: "other" });
    otherFake.pushJson(httpRequest(otherId));
    await flush();

    registry.projectDetached(PROJECT);
    await flush();

    expect(exchange.signal.aborted).toBe(true);
    expect(httpFake.resetCalls).toEqual([STREAM_RESET_TUNNEL]);
    expect(registry.streamCount(PEER)).toBe(1); // the "other"-project stream survives
    expect(otherFake.resetCalls).toEqual([]);
  });

  test("dropPeer unbinds and closes sinks for that peer only, without calling retirePeer", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const fb = fakeBinding();
    bindings.set(PROJECT, fb.binding);

    const closed: unknown[] = [];
    fb.server.setNextSink({ data() {}, closed: (...args) => closed.push(args) });
    const mine = admitWs(registry, { peerId: "mine" });
    mine.fake.pushJson(wsOpenRecord(mine.wsId));
    await flush();

    const others = admitWs(registry, { peerId: "someone-else" });
    others.fake.pushJson(wsOpenRecord(others.wsId));
    await flush();

    registry.dropPeer("mine");

    expect(registry.streamCount("mine")).toBe(0);
    expect(closed).toHaveLength(1);
    expect(retiredPeers).toEqual([]);
    expect(registry.streamCount("someone-else")).toBe(1);
  });
});
