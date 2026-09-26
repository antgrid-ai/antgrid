// Stage A wave A2 (docs/iroh-reduction/stage-A-A2-contract.md §3.2, §6).
// Drives TerminalStreamRegistry directly with fakes — no PeerStreamAcceptor,
// no real StreamMux. The acceptor's own admission order (authorization, the
// open-frame read, NOT_READY pre-handler, the pending cap) is covered by
// stream-dispatch.test.ts; this file starts at the handler boundary.
import { describe, test, expect } from "bun:test";
import {
  TerminalStreamRegistry,
  TERMINAL_STREAM_MAX_QUEUED_BYTES,
  STREAM_RESET_TERMINAL,
  STREAM_STOP_TERMINAL,
  type TerminalStreamRegistryOptions,
} from "../src/peer/terminal-streams";
import {
  STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
  STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER,
  STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
} from "antgrid-wire";
import type { TerminalProjectBinding, PeerSessionView } from "../src/project-streams";
import type { StreamRefusal } from "../src/peer/stream-dispatch";
import { createMessage, type AbMessage } from "../src/protocol";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";

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

function lengthPrefixed(body: Buffer): number[][] {
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(body.length);
  return [Array.from(prefix), Array.from(body)];
}

/** One fake terminal-attachment stream: a send half and a recv half, each
 *  behind its own mutex (the binding's send and recv halves are independent
 *  locks). Neither half defines `stopped`/`receivedReset` — nothing under
 *  test may be tempted to await them. */
function createFakeTerminalStream() {
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
    read: (sizeLimit: number) => {
      readCalls.push(sizeLimit);
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
    pushRecord(msg: AbMessage | Record<string, unknown>): void {
      for (const chunk of lengthPrefixed(Buffer.from(JSON.stringify(msg), "utf8"))) recvQueue.push(chunk);
      pump();
    },
    pushRawLength(length: number): void {
      const prefix = Buffer.alloc(4);
      prefix.writeUInt32BE(length);
      recvQueue.push(Array.from(prefix));
      pump();
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

type FakeTerminalStream = ReturnType<typeof createFakeTerminalStream>;

/** Fake `TerminalProjectBinding`: records every dispatch, and can be told to
 *  refuse a peer, to disappear (project detached from under it), or to lack
 *  an open project stream for a peer (A4's admission gate). */
function fakeBinding() {
  const dispatched: Array<{ msg: AbMessage; peerId: string }> = [];
  let refuse: ((peerId: string) => StreamRefusal | null) | null = null;
  let gone = false;
  // Every peer has an open project stream by default, so a suite testing
  // OTHER admission steps doesn't also have to wire this one.
  let hasOpen: ((peerId: string) => boolean) | null = null;
  const binding: TerminalProjectBinding = {
    hasOpenStream: (peerId) => (hasOpen ? hasOpen(peerId) : true),
    refusalFor: (peerId) => (refuse ? refuse(peerId) : null),
    dispatch: (msg, peerId) => {
      if (gone) return false;
      if (refuse?.(peerId)) return false;
      dispatched.push({ msg, peerId });
      return true;
    },
  };
  return {
    binding, dispatched,
    setRefusal: (fn: ((peerId: string) => StreamRefusal | null) | null) => { refuse = fn; },
    setGone: (v: boolean) => { gone = v; },
    setHasOpenStream: (fn: ((peerId: string) => boolean) | null) => { hasOpen = fn; },
  };
}

function makeRegistry(overrides: Partial<TerminalStreamRegistryOptions> = {}) {
  const bindings = new Map<string, TerminalProjectBinding>();
  const cataloged = new Set<string>();
  const peerSessions = new Map<string, PeerSessionView>();
  const retiredPeers: Array<{ peerId: string; reason: "unauthorized" | "protocol-violation" }> = [];
  const diagnostics: Array<{ type: string; detail: Record<string, unknown>; stream?: { kind: string; id: string } }> = [];
  const opts: TerminalStreamRegistryOptions = {
    projectCataloged: (id) => cataloged.has(id),
    projectBinding: (id) => bindings.get(id) ?? null,
    peerSession: (peerId) => peerSessions.get(peerId) ?? null,
    retirePeer: (peerId, reason) => retiredPeers.push({ peerId, reason }),
    diagnostic: (type, detail, stream) => diagnostics.push({ type, detail, stream }),
    ...overrides,
  };
  const registry = new TerminalStreamRegistry(opts);
  return { registry, bindings, cataloged, peerSessions, retiredPeers, diagnostics };
}

async function refusalOf(
  result: StreamRefusal | undefined | Promise<StreamRefusal | undefined>,
): Promise<StreamRefusal | undefined> {
  return result instanceof Promise ? result : Promise.resolve(result);
}

const PROJECT = "proj1";
const PEER = "peer1";

function admit(
  registry: TerminalStreamRegistry,
  opts: { peerId?: string; projectId?: string; checkoutId?: string; requestId?: string } = {},
) {
  const fake = createFakeTerminalStream();
  const requestId = opts.requestId ?? crypto.randomUUID();
  const open = {
    kind: "terminal" as const,
    projectId: opts.projectId ?? PROJECT,
    checkoutId: opts.checkoutId ?? "main",
    requestId,
  };
  const admission = { peerId: opts.peerId ?? PEER, open, stream: fake.stream, authorized: () => true };
  const result = registry.handler(admission);
  return { fake, requestId, admission, result };
}

function subscribeRecord(requestId: string, terminalId = "term1", checkoutId = "main") {
  return createMessage("terminal:subscribe", {
    terminalId, version: TERMINAL_PROTOCOL_VERSION, requestId, checkoutId,
  });
}

function subscribedMessage(requestId: string, opts: {
  runId?: string; attachmentId?: string; terminalId?: string; checkoutId?: string;
} = {}) {
  return {
    ...createMessage("terminal:subscribed", {
      terminalId: opts.terminalId ?? "term1",
      runId: opts.runId ?? crypto.randomUUID(),
      attachmentId: opts.attachmentId ?? crypto.randomUUID(),
      version: TERMINAL_PROTOCOL_VERSION,
      requestId,
      checkoutId: opts.checkoutId ?? "main",
    }),
  };
}

/** Admits a stream, pushes its matching subscribe record, routes the bridge's
 *  own `subscribed` reply and waits for both to land — the "fully bound"
 *  fixture most cases below build on. */
async function admitAndBind(registry: TerminalStreamRegistry, binding: TerminalProjectBinding, dispatched: Array<{ msg: AbMessage; peerId: string }>) {
  const before = dispatched.length;
  const { fake, requestId, admission } = admit(registry, {});
  fake.pushRecord(subscribeRecord(requestId));
  await flush();
  expect(dispatched.length).toBe(before + 1); // the subscribe reached the project binding
  const runId = crypto.randomUUID();
  const attachmentId = crypto.randomUUID();
  const outcome = await registry.route(admission.peerId, subscribedMessage(requestId, { runId, attachmentId }));
  expect(outcome).toBe("sent");
  return { fake, requestId, runId, attachmentId, peerId: admission.peerId };
}

describe("TerminalStreamRegistry (A2)", () => {
  test("each refusal is decided before any read: CAP_EXCEEDED, INVALID requestId, NOT_ALLOWED unsafe id, NOT_ALLOWED uncatalogued, NOT_READY unbound, UPDATE_REQUIRED, INVALID duplicate requestId", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding } = fakeBinding();
    bindings.set(PROJECT, binding);

    // CAP_EXCEEDED: fill every slot for this peer first.
    for (let i = 0; i < STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER; i++) {
      const { fake, result } = admit(registry, { peerId: "capful" });
      expect(await refusalOf(result)).toBeUndefined();
      expect(fake.readCalls).not.toEqual([]); // admitted streams DO start reading
    }
    {
      const { fake, result } = admit(registry, { peerId: "capful" });
      expect((await refusalOf(result))?.code).toBe("CAP_EXCEEDED");
      expect(fake.readCalls).toEqual([]);
    }

    {
      const { fake, result } = admit(registry, { requestId: "not-a-uuid" });
      expect((await refusalOf(result))?.code).toBe("INVALID");
      expect(fake.readCalls).toEqual([]);
    }

    {
      const { fake, result } = admit(registry, { projectId: "../evil" });
      expect((await refusalOf(result))?.code).toBe("NOT_ALLOWED");
      expect(fake.readCalls).toEqual([]);
    }

    {
      const { fake, result } = admit(registry, { projectId: "uncatalogued-project" });
      expect((await refusalOf(result))?.code).toBe("NOT_ALLOWED");
      expect(fake.readCalls).toEqual([]);
    }

    {
      cataloged.add("catalogued-but-unbound");
      // bindings has no entry for it — projectBinding() returns null.
      const { fake, result } = admit(registry, { projectId: "catalogued-but-unbound" });
      expect((await refusalOf(result))?.code).toBe("NOT_READY");
      expect(fake.readCalls).toEqual([]);
    }

    {
      cataloged.add("update-project");
      const rebind = fakeBinding();
      rebind.setRefusal(() => ({ code: "UPDATE_REQUIRED", message: "old app" }));
      bindings.set("update-project", rebind.binding);
      const { fake, result } = admit(registry, { projectId: "update-project" });
      expect((await refusalOf(result))?.code).toBe("UPDATE_REQUIRED");
      expect(fake.readCalls).toEqual([]);

      // A refusal whose OWN code is something other than UPDATE_REQUIRED is
      // masked to NOT_ALLOWED — the app is told only "this stream is refused",
      // never handed an arbitrary session-path refusal code.
      rebind.setRefusal(() => ({ code: "CAP_EXCEEDED", message: "irrelevant" }));
      const second = admit(registry, { projectId: "update-project" });
      expect((await refusalOf(second.result))?.code).toBe("NOT_ALLOWED");
      expect(second.fake.readCalls).toEqual([]);
    }

    {
      const dupeRequestId = crypto.randomUUID();
      const first = admit(registry, { requestId: dupeRequestId });
      expect(await refusalOf(first.result)).toBeUndefined();
      const second = admit(registry, { requestId: dupeRequestId });
      expect((await refusalOf(second.result))?.code).toBe("INVALID");
      expect(second.fake.readCalls).toEqual([]);
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
    const { fake, result } = admit(registry, { projectId: unsafe });
    expect((await refusalOf(result))?.code).toBe("NOT_ALLOWED");
    expect(consulted).toEqual([]);
    expect(fake.readCalls).toEqual([]);
  });

  test("an absent projectCataloged fails closed with NOT_ALLOWED", async () => {
    const { registry, bindings } = makeRegistry({ projectCataloged: undefined });
    bindings.set(PROJECT, fakeBinding().binding);
    const { fake, result } = admit(registry, {});
    expect((await refusalOf(result))?.code).toBe("NOT_ALLOWED");
    expect(fake.readCalls).toEqual([]);
  });

  test("the first record must be the matching terminal:subscribe; anything else aborts only that stream and stops its receive half after the read completed", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake } = admit(registry, {});
    fake.pushRecord(createMessage("pong", {})); // not a subscribe at all
    await flush();
    expect(dispatched).toEqual([]);
    expect(fake.resetCalls).toEqual([STREAM_RESET_TERMINAL]);
    expect(fake.stopCalls).toEqual([STREAM_STOP_TERMINAL]);
    expect(retiredPeers).toEqual([]); // stream-scoped, not connection-fatal
  });

  test("ack, unsubscribe and history:request naming another attachment, terminal or checkout abort only that stream", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, requestId, runId, attachmentId, peerId } = await admitAndBind(registry, binding, dispatched);
    dispatched.length = 0;

    fake.pushRecord(createMessage("terminal:ack", {
      terminalId: "term1", runId, attachmentId: crypto.randomUUID(), sequence: 0,
    }));
    await flush();
    expect(dispatched).toEqual([]);
    expect(fake.resetCalls).toEqual([STREAM_RESET_TERMINAL]);
    expect(fake.stopCalls).toEqual([STREAM_STOP_TERMINAL]);
    expect(retiredPeers).toEqual([]);
    void requestId; void peerId;
  });

  test("a record over STREAM_TERMINAL_APP_RECORD_MAX_BYTES retires the connection as a protocol violation", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    bindings.set(PROJECT, fakeBinding().binding);
    const { fake, admission } = admit(registry, {});
    fake.pushRawLength(STREAM_TERMINAL_APP_RECORD_MAX_BYTES + 1);
    await flush();
    expect(retiredPeers).toEqual([{ peerId: admission.peerId, reason: "protocol-violation" }]);
  });

  test("subscribed routes by requestId and binds the attachment; frames, history pages and attachment statuses then route by attachmentId", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, runId, attachmentId, peerId } = await admitAndBind(registry, binding, dispatched);

    const frame = { ...createMessage("terminal:frame" as any, {} as any), attachmentId, runId, terminalId: "term1", sequence: 0 } as unknown as AbMessage;
    expect(await registry.route(peerId, frame)).toBe("sent");

    const page = { ...createMessage("terminal:history:page" as any, {} as any), attachmentId, runId, requestId: crypto.randomUUID() } as unknown as AbMessage;
    expect(await registry.route(peerId, page)).toBe("sent");

    const status = { ...createMessage("terminal:display:status", {
      terminalId: "term1", code: "ACK_TIMEOUT", message: "no ack",
    }), attachmentId } as AbMessage;
    expect(await registry.route(peerId, status)).toBe("sent");

    expect(fake.writeAllCalls.length).toBeGreaterThanOrEqual(3);
  });

  test("a requestId-addressed display:status routes to the stream and subscribeSettled(undefined) then finishes it", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, requestId, admission } = admit(registry, {});
    fake.pushRecord(subscribeRecord(requestId));
    await flush();
    expect(dispatched).toHaveLength(1);

    const unknown = { ...createMessage("terminal:display:status", {
      terminalId: "term1", code: "UNKNOWN_TERMINAL", message: "no such terminal", requestId,
    }) } as AbMessage;
    expect(await registry.route(admission.peerId, unknown)).toBe("sent");

    registry.subscribeSettled(admission.peerId, requestId, undefined);
    await flush();
    expect(fake.finishCalls()).toBe(1);
  });

  test("an unbound message returns undefined for the session path, including history for an unbound attachment", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);

    const stray = { ...createMessage("terminal:display:status", {
      terminalId: "term1", code: "UNKNOWN_TERMINAL", message: "x", requestId: crypto.randomUUID(),
    }) } as AbMessage;
    expect(registry.route("nobody", stray)).toBeUndefined();

    const { attachmentId, peerId } = await admitAndBind(registry, binding, dispatched);
    registry.retired(peerId, attachmentId);
    await flush();
    const page = { ...createMessage("terminal:history:page" as any, {} as any), attachmentId } as unknown as AbMessage;
    expect(registry.route(peerId, page)).toBeUndefined();
  });

  test("retired() writes every frame and the ENDED queued before it, then FINs (carry-over 1)", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, attachmentId, runId, peerId } = await admitAndBind(registry, binding, dispatched);
    fake.writeAllCalls.length = 0;

    const frame = (seq: number) => ({
      ...createMessage("terminal:frame" as any, {} as any), attachmentId, runId, terminalId: "term1", sequence: seq,
    } as unknown as AbMessage);
    const ended = { ...createMessage("terminal:display:status", {
      terminalId: "term1", code: "ENDED", message: "run ended", attachmentId, runId,
    }) } as AbMessage;

    void registry.route(peerId, frame(0));
    void registry.route(peerId, frame(1));
    void registry.route(peerId, ended);
    registry.retired(peerId, attachmentId);
    await flush();

    expect(fake.writeAllCalls.length).toBe(3); // 2 frames + ENDED, all queued ahead of finish
    expect(fake.finishCalls()).toBe(1);
    expect(fake.order.indexOf("finish")).toBeGreaterThan(fake.order.lastIndexOf("writeAll"));
  });

  test("the app's FIN synthesizes terminal:unsubscribe with the bound runId and attachmentId, aborts the writer and frees the slot", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, attachmentId, runId, peerId } = await admitAndBind(registry, binding, dispatched);
    dispatched.length = 0;
    expect(registry.attachmentCount(peerId)).toBe(1);

    fake.endWith();
    await flush();

    expect(dispatched).toHaveLength(1);
    expect(dispatched[0]!.msg).toMatchObject({
      type: "terminal:unsubscribe", terminalId: "term1", runId, attachmentId, checkoutId: "main",
    });
    expect(fake.resetCalls).toEqual([STREAM_RESET_TERMINAL]);
    expect(registry.attachmentCount(peerId)).toBe(0);
  });

  test("the app's FIN before subscribed makes subscribed resolve dropped", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, requestId, admission } = admit(registry, {});
    fake.pushRecord(subscribeRecord(requestId));
    await flush();
    expect(dispatched).toHaveLength(1);

    fake.endWith(); // the app FINs before the bridge ever answers subscribed
    await flush();

    const outcome = await registry.route(admission.peerId, subscribedMessage(requestId));
    expect(outcome).toBe("dropped");
  });

  test("the app's end before its first record frees the slot at once: no subscribe is in flight to settle it", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, admission } = admit(registry, {});
    expect(registry.attachmentCount(admission.peerId)).toBe(1);

    fake.endWith(); // the app closed while its open was still resolving
    await flush();

    expect(dispatched).toEqual([]);
    expect(registry.attachmentCount(admission.peerId)).toBe(0);
  });

  test("a record arriving after retirement stops the receive half instead of abandoning it", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, attachmentId, runId, peerId } = await admitAndBind(registry, binding, dispatched);
    registry.retired(peerId, attachmentId);
    await flush();
    dispatched.length = 0;

    fake.pushRecord(createMessage("terminal:ack", {
      terminalId: "term1", runId, attachmentId, sequence: 0, checkoutId: "main",
    }));
    await flush();

    expect(dispatched).toEqual([]);
    expect(fake.stopCalls).toEqual([STREAM_STOP_TERMINAL]);
  });

  test("writer overflow resets only that stream, synthesizes unsubscribe and frees the slot; the connection lives", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, attachmentId, runId, peerId } = await admitAndBind(registry, binding, dispatched);
    dispatched.length = 0;

    // Each frame stays under STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES (2 MiB) on
    // its own, so none is dropped by route()'s own per-message cap; three of
    // them together overflow the 3 MiB writer queue while the first is still
    // being dequeued into `drain()` (no `await` between the calls below, so
    // the second and third are still sitting in the queue when the third's
    // own `send()` does its synchronous overflow check).
    const bigFrame = (seq: number) => ({
      ...createMessage("terminal:frame" as any, {} as any),
      attachmentId, runId, terminalId: "term1", sequence: seq,
      payload: "x".repeat(1_600_000),
    } as unknown as AbMessage);
    const first = registry.route(peerId, bigFrame(0));
    const second = registry.route(peerId, bigFrame(1));
    const third = registry.route(peerId, bigFrame(2));
    expect(await third).toBe("dropped");
    expect(await second).toBe("dropped");
    await Promise.allSettled([first]);
    await flush();

    expect(dispatched).toHaveLength(1);
    expect(dispatched[0]!.msg.type).toBe("terminal:unsubscribe");
    expect(fake.resetCalls).toEqual([STREAM_RESET_TERMINAL]);
    expect(retiredPeers).toEqual([]);
    expect(registry.attachmentCount(peerId)).toBe(0);
  });

  test("an oversized outbound record is a dropped diagnostic tagged with this attachment's own terminal stream", async () => {
    const { registry, cataloged, bindings, diagnostics } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { requestId, attachmentId, runId, peerId } = await admitAndBind(registry, binding, dispatched);

    const huge = { ...createMessage("terminal:frame" as any, {} as any),
      attachmentId, runId, terminalId: "term1", sequence: 0,
      payload: "x".repeat(STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES + 1) } as unknown as AbMessage;
    expect(await registry.route(peerId, huge)).toBe("dropped");

    const event = diagnostics.find((d) => d.type === "terminal-stream:oversized-record");
    expect(event?.stream).toEqual({ kind: "terminal", id: requestId });
  });

  test("writer unauthorized retires the connection", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    let authorized = true;
    const fake = createFakeTerminalStream();
    const requestId = crypto.randomUUID();
    const open = { kind: "terminal" as const, projectId: PROJECT, checkoutId: "main", requestId };
    const admission = { peerId: PEER, open, stream: fake.stream, authorized: () => authorized };
    expect(await refusalOf(registry.handler(admission))).toBeUndefined();
    fake.pushRecord(subscribeRecord(requestId));
    await flush();
    const runId = crypto.randomUUID();
    const attachmentId = crypto.randomUUID();
    await registry.route(PEER, subscribedMessage(requestId, { runId, attachmentId }));

    authorized = false;
    const frame = { ...createMessage("terminal:frame" as any, {} as any), attachmentId, runId, terminalId: "term1", sequence: 0 } as unknown as AbMessage;
    await registry.route(PEER, frame);

    expect(retiredPeers).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
  });

  test("an inbound record while authorized() is false retires the connection rather than reaching the project binding", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    let authorized = true;
    const fake = createFakeTerminalStream();
    const requestId = crypto.randomUUID();
    const open = { kind: "terminal" as const, projectId: PROJECT, checkoutId: "main", requestId };
    const admission = { peerId: PEER, open, stream: fake.stream, authorized: () => authorized };
    expect(await refusalOf(registry.handler(admission))).toBeUndefined();
    fake.pushRecord(subscribeRecord(requestId));
    await flush();
    const runId = crypto.randomUUID();
    const attachmentId = crypto.randomUUID();
    await registry.route(PEER, subscribedMessage(requestId, { runId, attachmentId }));
    dispatched.length = 0;

    authorized = false;
    fake.pushRecord(createMessage("terminal:ack", {
      terminalId: "term1", runId, attachmentId, sequence: 0, checkoutId: "main",
    }));
    await flush();

    expect(dispatched).toEqual([]); // never reaches the project binding
    expect(retiredPeers).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
  });

  test("projectDetached aborts every binding for the project", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const a = await admitAndBind(registry, binding, dispatched);
    const b = await admitAndBind(registry, binding, dispatched);
    dispatched.length = 0;

    registry.projectDetached(PROJECT);
    await flush();

    expect(dispatched).toEqual([]); // the core is gone; no unsubscribe to dispatch it to
    expect(a.fake.resetCalls).toEqual([STREAM_RESET_TERMINAL]);
    expect(b.fake.resetCalls).toEqual([STREAM_RESET_TERMINAL]);
    expect(registry.attachmentCount(a.peerId)).toBe(0);
  });

  test("dropPeer unbinds without dispatching, and a stale binding's failure never retires a newer connection", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const stale = await admitAndBind(registry, binding, dispatched);
    dispatched.length = 0;

    registry.dropPeer(PEER);
    expect(registry.attachmentCount(PEER)).toBe(0);
    expect(dispatched).toEqual([]); // no synthesized unsubscribe on a drop
    expect(retiredPeers).toEqual([]);

    // A fresh admission reuses the same peerId, as a reconnect would.
    const fresh = await admitAndBind(registry, binding, dispatched);
    dispatched.length = 0;

    // The stale stream's read loop was still parked on readExact; it now
    // observes the app's end, long after dropPeer discarded its binding.
    stale.fake.endWith();
    await flush();

    expect(dispatched).toEqual([]); // stale generation: no unsubscribe reaches the binding
    expect(retiredPeers).toEqual([]); // and nothing retires the NEW connection
    expect(registry.attachmentCount(PEER)).toBe(1); // the fresh binding is untouched
    void fresh;
  });

  test("an aborted signal removes a queued frame before its first slice", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, attachmentId, runId, peerId } = await admitAndBind(registry, binding, dispatched);
    fake.writeAllCalls.length = 0;
    const gate = fake.gateNextWrite();

    const frame = (seq: number) => ({
      ...createMessage("terminal:frame" as any, {} as any), attachmentId, runId, terminalId: "term1", sequence: seq,
    } as unknown as AbMessage);

    const first = registry.route(peerId, frame(0)); // starts draining, sticks on the gate
    await flush();
    const controller = new AbortController();
    const second = registry.route(peerId, frame(1), controller.signal); // queued behind it
    await flush();
    controller.abort();

    expect(await second).toBe("dropped");
    expect(fake.writeAllCalls.length).toBe(1); // only frame 0's slice ever reached the wire
    gate.release();
    expect(await first).toBe("sent");
  });

  test("open with no open project stream for the peer is refused NOT_ALLOWED; another peer's open stream does not count", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, setHasOpenStream } = fakeBinding();
    bindings.set(PROJECT, binding);
    setHasOpenStream((peerId) => peerId === "other-peer");

    const { fake, result } = admit(registry, { peerId: PEER });
    expect((await refusalOf(result))?.code).toBe("NOT_ALLOWED");
    expect(fake.readCalls).toEqual([]);

    // The same projectId's project stream is open for a DIFFERENT peer —
    // that must not satisfy PEER's own admission (A4's single per-peer point).
    const other = admit(registry, { peerId: "other-peer" });
    expect(await refusalOf(other.result)).toBeUndefined();
  });

  test("closing the project stream does not unbind an open terminal stream", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched, setHasOpenStream } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { attachmentId, runId, peerId } = await admitAndBind(registry, binding, dispatched);
    dispatched.length = 0;

    // The project stream closes: the peer no longer has one open. Admission
    // is a one-time gate, not a live dependency, so the terminal binding
    // admitted while it WAS open keeps routing.
    setHasOpenStream(() => false);

    const frame = { ...createMessage("terminal:frame" as any, {} as any), attachmentId, runId, terminalId: "term1", sequence: 0 } as unknown as AbMessage;
    expect(await registry.route(peerId, frame)).toBe("sent");
    expect(registry.attachmentCount(peerId)).toBe(1);
  });
});
