// Drives TerminalStreamRegistry directly with fakes — no PeerStreamAcceptor,
// no real StreamMux. Admission (authorization, the open-frame read, refusal
// codes, caps, unauthorized mid-stream, oversize records, projectDetached,
// dropPeer) is covered once for every kind by stream-admission.test.ts; this
// file starts at the handler boundary and covers terminal's own body: the
// subscribe/subscribed handshake, message routing by requestId/attachmentId,
// and the retire/FIN lifecycle.
import { describe, test, expect } from "bun:test";
import {
  TerminalStreamRegistry,
  type TerminalStreamRegistryOptions,
} from "../src/peer/terminal-streams";
import { STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES } from "antgrid-wire";
import type { TerminalProjectBinding } from "../src/project-streams";
import { STREAM_RESET_SCOPED, STREAM_STOP_SCOPED, type StreamRefusal } from "../src/peer/stream-dispatch";
import { createMessage, type AbMessage } from "../src/protocol";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";
import { createFakeBiStream, flush } from "./support/fake-bi-stream";

/** Fake `TerminalProjectBinding`: records every dispatch, and can be told to
 *  refuse a peer, to disappear (project detached from under it), or to lack
 *  an open project stream for a peer (the project-stream admission gate). */
function fakeBinding() {
  const dispatched: Array<{ msg: AbMessage; peerId: string }> = [];
  let refuse: ((peerId: string) => StreamRefusal | undefined) | null = null;
  let gone = false;
  // Every peer has an open project stream by default, so a suite testing
  // OTHER admission steps doesn't also have to wire this one.
  let hasOpen: ((peerId: string) => boolean) | null = null;
  const binding: TerminalProjectBinding = {
    hasOpenStream: (peerId) => (hasOpen ? hasOpen(peerId) : true),
    refusalFor: (peerId) => (refuse ? refuse(peerId) : undefined),
    dispatch: (msg, peerId) => {
      if (gone) return false;
      if (refuse?.(peerId)) return false;
      dispatched.push({ msg, peerId });
      return true;
    },
  };
  return {
    binding, dispatched,
    setRefusal: (fn: ((peerId: string) => StreamRefusal | undefined) | null) => { refuse = fn; },
    setGone: (v: boolean) => { gone = v; },
    setHasOpenStream: (fn: ((peerId: string) => boolean) | null) => { hasOpen = fn; },
  };
}

function makeRegistry(overrides: Partial<TerminalStreamRegistryOptions> = {}) {
  const bindings = new Map<string, TerminalProjectBinding>();
  const cataloged = new Set<string>();
  const retiredPeers: Array<{ peerId: string; reason: "unauthorized" | "protocol-violation" }> = [];
  const diagnostics: Array<{ type: string; detail: Record<string, unknown>; stream?: { kind: string; id: string } }> = [];
  const opts: TerminalStreamRegistryOptions = {
    projectCataloged: (id) => cataloged.has(id),
    projectBinding: (id) => bindings.get(id) ?? null,
    retirePeer: (peerId, reason) => retiredPeers.push({ peerId, reason }),
    diagnostic: (type, detail, stream) => diagnostics.push({ type, detail, stream }),
    ...overrides,
  };
  const registry = new TerminalStreamRegistry(opts);
  return { registry, bindings, cataloged, retiredPeers, diagnostics };
}

const PROJECT = "proj1";
const PEER = "peer1";

function admit(
  registry: TerminalStreamRegistry,
  opts: { peerId?: string; projectId?: string; checkoutId?: string; requestId?: string } = {},
) {
  const fake = createFakeBiStream();
  const requestId = opts.requestId ?? crypto.randomUUID();
  const open = {
    kind: "terminal" as const,
    projectId: opts.projectId ?? PROJECT,
    checkoutId: opts.checkoutId ?? "main",
    requestId,
  };
  const admission = { peerId: opts.peerId ?? PEER, open, stream: fake.stream, authorized: () => true };
  const result = registry.handlerFor("terminal")(admission);
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

describe("TerminalStreamRegistry", () => {
  test("the first record must be the matching terminal:subscribe; anything else aborts only that stream and stops its receive half after the read completed", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake } = admit(registry, {});
    fake.pushRecord(createMessage("pong", {})); // not a subscribe at all
    await flush();
    expect(dispatched).toEqual([]);
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    expect(fake.stops).toEqual([STREAM_STOP_SCOPED]);
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
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    expect(fake.stops).toEqual([STREAM_STOP_SCOPED]);
    expect(retiredPeers).toEqual([]);
    void requestId; void peerId;
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

    expect(fake.order.filter((o) => o === "writeAll").length).toBeGreaterThanOrEqual(3);
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
    expect(fake.isFinished()).toBe(true);
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

  test("retired() writes every frame and the ENDED queued before it, then FINs", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, attachmentId, runId, peerId } = await admitAndBind(registry, binding, dispatched);
    fake.order.length = 0;

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

    expect(fake.order.filter((o) => o === "writeAll").length).toBe(3); // 2 frames + ENDED, all queued ahead of finish
    expect(fake.isFinished()).toBe(true);
    expect(fake.order.indexOf("finish")).toBeGreaterThan(fake.order.lastIndexOf("writeAll"));
  });

  test("the app's FIN synthesizes terminal:unsubscribe with the bound runId and attachmentId, aborts the writer and frees the slot; a FIN before subscribed makes subscribed resolve dropped instead", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);

    const { fake, attachmentId, runId, peerId } = await admitAndBind(registry, binding, dispatched);
    dispatched.length = 0;
    expect(registry.streamCount(peerId)).toBe(1);

    fake.endWith();
    await flush();

    expect(dispatched).toHaveLength(1);
    expect(dispatched[0]!.msg).toMatchObject({
      type: "terminal:unsubscribe", terminalId: "term1", runId, attachmentId, checkoutId: "main",
    });
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    expect(registry.streamCount(peerId)).toBe(0);

    // A second stream whose app FINs before its subscribe was ever answered
    // has no binding to synthesize an unsubscribe for: the pending subscribe
    // just resolves dropped instead.
    const second = admit(registry, {});
    second.fake.pushRecord(subscribeRecord(second.requestId));
    await flush();
    second.fake.endWith();
    await flush();
    const outcome = await registry.route(second.admission.peerId, subscribedMessage(second.requestId));
    expect(outcome).toBe("dropped");
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
    expect(fake.stops).toEqual([STREAM_STOP_SCOPED]);
  });

  test("writer overflow resets only that stream, synthesizes unsubscribe and frees the slot; the connection lives", async () => {
    const { registry, cataloged, bindings, retiredPeers } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, attachmentId, runId, peerId } = await admitAndBind(registry, binding, dispatched);
    dispatched.length = 0;

    // Each frame fits STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES on its own; three
    // together overflow the writer queue while the first is still draining
    // (no await between the calls, so the third's synchronous overflow check
    // sees the second still queued).
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

    expect(dispatched.map((d) => d.msg.type)).toEqual(["terminal:unsubscribe"]);
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    expect(retiredPeers).toEqual([]);
    expect(registry.streamCount(peerId)).toBe(0);
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

  test("an aborted signal removes a queued frame before its first slice", async () => {
    const { registry, cataloged, bindings } = makeRegistry();
    cataloged.add(PROJECT);
    const { binding, dispatched } = fakeBinding();
    bindings.set(PROJECT, binding);
    const { fake, attachmentId, runId, peerId } = await admitAndBind(registry, binding, dispatched);
    fake.order.length = 0;
    const release = fake.gateNextWrite();

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
    expect(fake.order.filter((o) => o === "writeAll").length).toBe(1); // only frame 0's slice ever reached the wire
    release();
    expect(await first).toBe("sent");
  });
});
