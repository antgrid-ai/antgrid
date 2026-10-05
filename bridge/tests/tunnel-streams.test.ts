// Drives TunnelStreamRegistry directly with a fake QUIC stream and a real
// TunnelManager dialling real local sockets — no PeerStreamAcceptor, no real
// StreamMux. Admission (authorization, the open-frame read, refusal codes,
// caps, unauthorized mid-stream, oversize records, projectDetached, dropPeer)
// is covered once for every kind by stream-admission.test.ts; this file starts
// at the handler boundary and covers the tunnel-tcp body: the head-record
// protocol, the probe, and the raw pipe in both directions.
import { afterEach, describe, expect, test } from "bun:test";
import net from "node:net";
import tls from "node:tls";
import { TunnelStreamRegistry, type TunnelStreamRegistryOptions } from "../src/peer/tunnel-streams";
import { STREAM_RESET_SCOPED, STREAM_STOP_SCOPED } from "../src/peer/stream-dispatch";
import { createConnState } from "../src/conn-state";
import { TunnelManager, type TunnelAdmission } from "../src/tunnel-manager";
import type { TunnelProjectBinding } from "../src/project-streams";
import type { TunnelTcpStreamOpen } from "antgrid-wire";
import { SELF_SIGNED_LOCALHOST_CERT, SELF_SIGNED_LOCALHOST_KEY } from "./support/self-signed-localhost";
import {
  createFakeBiStream,
  createFakeProjectBinding,
  flush,
  manualSchedule,
  refusalOf,
  until,
  type FakeBiStream,
} from "./support/fake-bi-stream";

const PROJECT = "proj1";
const PEER = "peer1";

const servers: net.Server[] = [];
const upstreamSockets = new Set<net.Socket>();
const managers: TunnelManager[] = [];

afterEach(() => {
  for (const manager of managers.splice(0)) manager.stop();
  for (const socket of upstreamSockets) socket.destroy();
  upstreamSockets.clear();
  for (const server of servers.splice(0)) server.close();
});

async function listen(server: net.Server): Promise<number> {
  servers.push(server);
  server.on("connection", (socket) => {
    upstreamSockets.add(socket);
    socket.on("close", () => upstreamSockets.delete(socket));
  });
  await new Promise<void>((resolve) => server.listen(0, resolve));
  return (server.address() as net.AddressInfo).port;
}

async function deadPort(): Promise<number> {
  const server = net.createServer();
  await new Promise<void>((resolve) => server.listen(0, resolve));
  const { port } = server.address() as net.AddressInfo;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

/** The first four bytes of any raw payload the tests push: the fake stream
 *  parses everything the bridge writes as `[u32 len][body]` records, and a
 *  maximal length prefix keeps it from ever mistaking raw bytes for one. */
const RAW_MARK = Buffer.from([0xff, 0xff, 0xff, 0xff]);

function rawPayload(text: string): Buffer {
  return Buffer.concat([RAW_MARK, Buffer.from(text)]);
}

/** An upstream that records what it received, and how the app's side ended. */
function recordingServer(onConnection?: (socket: net.Socket) => void) {
  const state = {
    received: [] as Buffer[],
    ended: false,
    errors: [] as unknown[],
    closed: false,
    connections: 0,
    socket: undefined as net.Socket | undefined,
  };
  const server = net.createServer((socket) => {
    state.connections++;
    state.socket = socket;
    socket.on("error", (e) => state.errors.push(e));
    socket.on("data", (chunk) => state.received.push(Buffer.from(chunk)));
    socket.on("end", () => { state.ended = true; });
    socket.on("close", () => { state.closed = true; });
    onConnection?.(socket);
  });
  return { server, state, receivedText: () => Buffer.concat(state.received).toString() };
}

function fakeTunnelServer() {
  let refusal: { code: "NOT_ALLOWED"; message: string } | null = null;
  const manager = new TunnelManager({
    projectId: PROJECT,
    portLabels: new Map(),
    previewPorts: new Set(),
    sendEncrypted: () => {},
    relayHost: "",
    connState: createConnState(),
  });
  managers.push(manager);
  const admitCalls: Array<{ peerId: string; checkoutId: string }> = [];
  const admit = (peerId: string, checkoutId: string): TunnelAdmission => {
    admitCalls.push({ peerId, checkoutId });
    if (refusal) return { ok: false, refusal };
    return { ok: true, manager };
  };
  return {
    admit, admitCalls, manager,
    setRefusal: (r: { code: "NOT_ALLOWED"; message: string } | null) => { refusal = r; },
  };
}

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
  const cataloged = new Set<string>([PROJECT]);
  const bindings = new Map<string, TunnelProjectBinding>();
  const retiredPeers: Array<{ peerId: string; reason: "unauthorized" | "protocol-violation" }> = [];
  const diagnostics: Array<{ type: string; detail: Record<string, unknown> }> = [];
  const opts: TunnelStreamRegistryOptions = {
    projectCataloged: (id) => cataloged.has(id),
    projectBinding: (id) => bindings.get(id) ?? null,
    retirePeer: (peerId, reason) => retiredPeers.push({ peerId, reason }),
    diagnostic: (type, detail) => diagnostics.push({ type, detail }),
    ...overrides,
  };
  const registry = new TunnelStreamRegistry(opts);
  const bound = fakeBinding();
  bindings.set(PROJECT, bound.binding);
  return { registry, cataloged, bindings, retiredPeers, diagnostics, ...bound };
}

function admitTcp(
  registry: TunnelStreamRegistry,
  opts: { peerId?: string; projectId?: string; connId?: string; authorized?: () => boolean } = {},
) {
  const fake = createFakeBiStream();
  const connId = opts.connId ?? crypto.randomUUID();
  const open: TunnelTcpStreamOpen = { kind: "tunnel-tcp", projectId: opts.projectId ?? PROJECT, connId };
  const admission = { peerId: opts.peerId ?? PEER, open, stream: fake.stream, authorized: opts.authorized ?? (() => true) };
  const result = registry.handlerFor("tunnel-tcp")(admission);
  return { fake, connId, admission, result };
}

function tcpOpen(connId: string, port: number, extra: Record<string, unknown> = {}) {
  return { type: "tunnel:tcp-open", connId, port, ...extra };
}

/** Admits a stream, pushes its head and waits for the bridge's one reply. */
async function openTunnel(
  ctx: ReturnType<typeof makeRegistry>,
  port: number,
  extra: Record<string, unknown> = {},
  admitOpts: Parameters<typeof admitTcp>[1] = {},
) {
  const admitted = admitTcp(ctx.registry, admitOpts);
  admitted.fake.pushRecord(tcpOpen(admitted.connId, port, extra));
  await until(() => admitted.fake.firstRecord() !== undefined);
  return admitted;
}

function replyOf(fake: FakeBiStream): Record<string, unknown> {
  return JSON.parse(fake.firstRecord()!) as Record<string, unknown>;
}

describe("TunnelStreamRegistry: head and admission", () => {
  test("a head that never arrives resets the writer and frees the slot immediately, stopping the receive half only once the pending read settles", async () => {
    const ctl = manualSchedule();
    const ctx = makeRegistry({ schedule: ctl.schedule });
    const { fake, admission } = admitTcp(ctx.registry);
    expect(ctx.registry.streamCount(admission.peerId)).toBe(1);

    ctl.fire();
    await flush();
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
    expect(ctx.registry.streamCount(admission.peerId)).toBe(0);
    expect(fake.stops).toEqual([]); // the read is still outstanding

    // The pending read settling with an ERROR (the app hung up first) means
    // there is nothing left to stop.
    fake.endWith();
    await flush();
    expect(fake.stops).toEqual([]);
  });

  test("a head record that arrives AFTER the deadline still gets its receive half stopped, once that late read settles", async () => {
    const ctl = manualSchedule();
    const ctx = makeRegistry({ schedule: ctl.schedule });
    const { fake, connId, admission } = admitTcp(ctx.registry);

    ctl.fire();
    await flush();
    expect(fake.stops).toEqual([]);

    fake.pushRecord(tcpOpen(connId, 3000));
    await flush();
    expect(fake.stops).toEqual([STREAM_STOP_SCOPED]);
    expect(ctx.registry.streamCount(admission.peerId)).toBe(0);
    expect(ctx.server.admitCalls).toEqual([]);
  });

  test("a head whose connId differs from the open frame's is refused INVALID, and nothing is dialled or admitted", async () => {
    const { server, state } = recordingServer();
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake } = admitTcp(ctx.registry);
    fake.pushRecord(tcpOpen("some-other-conn", port));
    await flush(5);
    expect(refusalOf(fake)).toMatchObject({ code: "INVALID" });
    expect(fake.isFinished()).toBe(true);
    expect(ctx.server.admitCalls).toEqual([]);
    expect(state.connections).toBe(0);
    expect(ctx.retiredPeers).toEqual([]);
  });

  for (const [name, head] of [
    ["not JSON", "this is not json"],
    ["a JSON array", "[]"],
    ["the wrong record type", JSON.stringify({ type: "tunnel:http-request", connId: "x", port: 3000 })],
    ["a port of zero", JSON.stringify({ type: "tunnel:tcp-open", connId: "$id", port: 0 })],
    ["a port above 65535", JSON.stringify({ type: "tunnel:tcp-open", connId: "$id", port: 65536 })],
    ["a fractional port", JSON.stringify({ type: "tunnel:tcp-open", connId: "$id", port: 80.5 })],
    ["a missing port", JSON.stringify({ type: "tunnel:tcp-open", connId: "$id" })],
  ] as const) {
    test(`a head that is ${name} is refused INVALID without admitting`, async () => {
      const ctx = makeRegistry();
      const { fake, connId, admission } = admitTcp(ctx.registry);
      fake.pushRecord(head.replaceAll("$id", connId));
      await flush(5);
      expect(refusalOf(fake)).toMatchObject({ code: "INVALID" });
      expect(fake.isFinished()).toBe(true);
      expect(ctx.server.admitCalls).toEqual([]);
      expect(ctx.registry.streamCount(admission.peerId)).toBe(0);
    });
  }

  test("a head that is not valid UTF-8 is refused INVALID", async () => {
    const ctx = makeRegistry();
    const { fake } = admitTcp(ctx.registry);
    fake.pushRecord(new Uint8Array([0x7b, 0xff, 0xfe, 0x7d]));
    await flush(5);
    expect(refusalOf(fake)).toMatchObject({ code: "INVALID" });
  });

  test("a head longer than the record cap retires the connection as a protocol violation", async () => {
    const ctx = makeRegistry();
    const { fake } = admitTcp(ctx.registry);
    fake.pushOverlongPrefix(4097);
    await flush(5);
    expect(ctx.retiredPeers).toEqual([{ peerId: PEER, reason: "protocol-violation" }]);
    expect(ctx.server.admitCalls).toEqual([]);
  });

  test("the checkout named in the head is what admit() is asked about, and a refusal there is one stream:refused record then FIN", async () => {
    const { server, state } = recordingServer();
    const port = await listen(server);
    const ctx = makeRegistry();
    ctx.server.setRefusal({ code: "NOT_ALLOWED", message: "unknown checkout" });
    const { fake, admission } = admitTcp(ctx.registry);
    fake.pushRecord(tcpOpen(admission.open.connId, port, { checkoutId: "wt-7" }));
    await flush(5);
    expect(ctx.server.admitCalls).toEqual([{ peerId: PEER, checkoutId: "wt-7" }]);
    expect(refusalOf(fake)).toMatchObject({ code: "NOT_ALLOWED", message: "unknown checkout" });
    expect(fake.records()).toHaveLength(1);
    expect(fake.isFinished()).toBe(true);
    expect(state.connections).toBe(0);
    expect(ctx.registry.streamCount(PEER)).toBe(0);
  });

  test("checkoutId defaults to main", async () => {
    const port = await deadPort();
    const ctx = makeRegistry();
    await openTunnel(ctx, port);
    expect(ctx.server.admitCalls).toEqual([{ peerId: PEER, checkoutId: "main" }]);
  });

  test("tunnels becoming unavailable between admission and the head refuses NOT_ALLOWED", async () => {
    const ctx = makeRegistry();
    const { fake, connId } = admitTcp(ctx.registry);
    ctx.setAvailable(false);
    fake.pushRecord(tcpOpen(connId, 3000));
    await flush(5);
    expect(refusalOf(fake)).toMatchObject({ code: "NOT_ALLOWED", message: "tunnels not available" });
  });
});

describe("TunnelStreamRegistry: unreachable upstream", () => {
  test("a refused port answers tunnel:tcp-error then FIN, frees the slot and never resets", async () => {
    const port = await deadPort();
    const ctx = makeRegistry();
    const { fake, connId } = await openTunnel(ctx, port);
    await until(() => fake.isFinished());
    expect(replyOf(fake)).toMatchObject({ type: "tunnel:tcp-error", connId });
    expect(String(replyOf(fake).message)).toMatch(/refused/i);
    expect(fake.records()).toHaveLength(1);
    expect(fake.resets).toEqual([]);
    expect(ctx.registry.streamCount(PEER)).toBe(0);
    expect(ctx.diagnostics.some((d) => d.type === "tunnel-stream:tcp-unreachable")).toBe(true);
  });
});

describe("TunnelStreamRegistry: probe", () => {
  test("a plaintext server is reported tls:false, the reply is followed by FIN, and nothing is piped", async () => {
    const { server, state } = recordingServer((socket) => {
      socket.on("data", () => socket.end("HTTP/1.1 400 Bad Request\r\nconnection: close\r\n\r\n"));
    });
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake, connId } = await openTunnel(ctx, port, { probe: true });
    await until(() => fake.isFinished());
    expect(replyOf(fake)).toEqual({ type: "tunnel:tcp-ready", connId, tls: false });
    expect(fake.records()).toHaveLength(1);
    expect(fake.rawWritten().length).toBe(0);
    expect(state.received.length).toBeLessThanOrEqual(1);
    expect(ctx.registry.streamCount(PEER)).toBe(0);
    expect(fake.stops).toEqual([STREAM_STOP_SCOPED]);
  });

  test("a self-signed TLS server is reported tls:true", async () => {
    const server = tls.createServer({ cert: SELF_SIGNED_LOCALHOST_CERT, key: SELF_SIGNED_LOCALHOST_KEY }, (socket) => {
      socket.on("error", () => {});
    });
    server.on("tlsClientError", () => {});
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake, connId } = await openTunnel(ctx, port, { probe: true });
    await until(() => fake.isFinished());
    expect(replyOf(fake)).toEqual({ type: "tunnel:tcp-ready", connId, tls: true });
    expect(ctx.registry.streamCount(PEER)).toBe(0);
  });

  test("an unreachable port answers tunnel:tcp-error then FIN", async () => {
    const port = await deadPort();
    const ctx = makeRegistry();
    const { fake, connId } = await openTunnel(ctx, port, { probe: true });
    await until(() => fake.isFinished());
    expect(replyOf(fake)).toMatchObject({ type: "tunnel:tcp-error", connId });
    expect(ctx.registry.streamCount(PEER)).toBe(0);
  });

  test("a probe is still admitted through the checkout gate", async () => {
    const ctx = makeRegistry();
    ctx.server.setRefusal({ code: "NOT_ALLOWED", message: "mobile access is disabled" });
    const { fake, admission } = admitTcp(ctx.registry);
    fake.pushRecord(tcpOpen(admission.open.connId, 3000, { probe: true }));
    await flush(5);
    expect(refusalOf(fake)).toMatchObject({ code: "NOT_ALLOWED" });
  });

  test("a peer dropped while probing gets no reply and the slot is already free", async () => {
    // Silent, so the probe is still waiting when the peer goes.
    const port = await listen(net.createServer((socket) => { socket.on("error", () => {}); }));
    const ctx = makeRegistry();
    const { fake, connId } = admitTcp(ctx.registry);
    fake.pushRecord(tcpOpen(connId, port, { probe: true }));
    await until(() => ctx.server.admitCalls.length === 1);
    ctx.registry.dropPeer(PEER);
    expect(ctx.registry.streamCount(PEER)).toBe(0);
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(fake.records()).toEqual([]);
    expect(ctx.retiredPeers).toEqual([]);
  });
});

describe("TunnelStreamRegistry: raw pipe", () => {
  test("ready is the first record, and app bytes reach the upstream and come back byte for byte", async () => {
    const { server, state, receivedText } = recordingServer((socket) => { socket.on("data", (chunk) => socket.write(chunk)); });
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake, connId } = await openTunnel(ctx, port);
    expect(replyOf(fake)).toEqual({ type: "tunnel:tcp-ready", connId });
    expect(fake.records()).toHaveLength(1);

    const payload = rawPayload("GET / HTTP/1.1\r\nhost: localhost\r\n\r\n");
    fake.pushRaw(payload);
    await until(() => Buffer.concat(state.received).equals(payload));
    await until(() => Buffer.from(fake.rawWritten()).equals(payload));
    expect(receivedText()).toContain("GET / HTTP/1.1");
    expect(ctx.registry.streamCount(PEER)).toBe(1);
    expect(fake.resets).toEqual([]);
  });

  test("bytes flow across many reads without loss or reordering", async () => {
    const { server, state } = recordingServer();
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake } = await openTunnel(ctx, port);
    const parts = Array.from({ length: 20 }, (_, i) => Buffer.alloc(1000, i));
    for (const part of parts) fake.pushRaw(part);
    const expected = Buffer.concat(parts);
    await until(() => Buffer.concat(state.received).length === expected.length);
    expect(Buffer.concat(state.received).equals(expected)).toBe(true);
  });

  test("the app's FIN ends the upstream gracefully (a FIN, never an error), then the bridge FINs and frees the slot", async () => {
    const { server, state } = recordingServer((socket) => { socket.on("end", () => socket.end()); });
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake } = await openTunnel(ctx, port);
    fake.pushRaw(rawPayload("bye"));
    await until(() => state.received.length > 0);
    fake.endWith();
    await until(() => state.ended);
    await until(() => fake.isFinished());
    await until(() => ctx.registry.streamCount(PEER) === 0);
    expect(state.errors).toEqual([]);
    expect(fake.resets).toEqual([]);
    expect(fake.stops).toEqual([STREAM_STOP_SCOPED]);
  });

  test("the app's reset is treated like its FIN: the upstream ends gracefully and the slot is freed", async () => {
    const { server, state } = recordingServer((socket) => { socket.on("end", () => socket.end()); });
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake } = await openTunnel(ctx, port);
    fake.endWith(new Error("stream reset by peer"));
    await until(() => state.ended);
    await until(() => ctx.registry.streamCount(PEER) === 0);
    expect(state.errors).toEqual([]);
    expect(ctx.retiredPeers).toEqual([]);
  });

  test("the upstream closing sends its last bytes, then FIN, without a reset", async () => {
    const { server } = recordingServer((socket) => { socket.on("data", () => socket.end("bye")); });
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake } = await openTunnel(ctx, port);
    fake.pushRaw(rawPayload("go"));
    await until(() => fake.isFinished());
    expect(Buffer.from(fake.rawWritten()).toString()).toBe("bye");
    expect(fake.resets).toEqual([]);
    expect(ctx.registry.streamCount(PEER)).toBe(0);
  });

  test("the upstream closing while the app's read is outstanding still frees the slot at once, and stops the receive half when the app's own end arrives", async () => {
    const { server } = recordingServer((socket) => { socket.end(); });
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake } = await openTunnel(ctx, port);
    await until(() => fake.isFinished());
    expect(ctx.registry.streamCount(PEER)).toBe(0);
    expect(fake.stops).toEqual([]);
    fake.endWith();
    await flush(5);
    expect(fake.stops).toEqual([STREAM_STOP_SCOPED]);
  });

  test("a burst from the upstream never overflows the send queue: at most one chunk is in flight while the QUIC send window is full", async () => {
    let upstream: net.Socket | undefined;
    const { server } = recordingServer((socket) => { upstream = socket; });
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake } = await openTunnel(ctx, port);
    await until(() => upstream !== undefined);
    const writesBefore = fake.writeAllLengths.length;
    fake.holdWrites();
    upstream!.write(Buffer.alloc(16 * 1024 * 1024, 0x61));
    await new Promise((resolve) => setTimeout(resolve, 300));
    // The parked write is the only one issued; the socket is paused behind it.
    expect(fake.writeAllLengths.length - writesBefore).toBeLessThanOrEqual(1);
    expect(fake.resets).toEqual([]);
    expect(ctx.registry.streamCount(PEER)).toBe(1);

    fake.releaseWrites();
    await until(() => fake.writeAllLengths.length - writesBefore >= 3);
    expect(fake.resets).toEqual([]);
  });

  test("an app that stops reading paces a fast app-side sender: the next read is not issued until the upstream took the previous bytes", async () => {
    const { server, state } = recordingServer();
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake } = await openTunnel(ctx, port);
    await until(() => fake.readSizes.length >= 1);
    const outstanding = fake.readSizes.length;
    fake.pushRaw(Buffer.alloc(1000, 1));
    await until(() => state.received.length > 0);
    await until(() => fake.readSizes.length > outstanding);
    // Exactly one raw read is ever outstanding.
    expect(fake.pendingReads()).toBe(1);
  });
});

describe("TunnelStreamRegistry: teardown", () => {
  test("dropPeer ends the upstream gracefully and frees the slot without retiring the connection", async () => {
    const { server, state } = recordingServer((socket) => { socket.on("end", () => socket.end()); });
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake } = await openTunnel(ctx, port);
    ctx.registry.dropPeer(PEER);
    await until(() => state.ended);
    expect(ctx.registry.streamCount(PEER)).toBe(0);
    expect(ctx.retiredPeers).toEqual([]);
    expect(state.errors).toEqual([]);
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
  });

  test("projectDetached ends that project's tunnels' upstreams gracefully", async () => {
    const { server, state } = recordingServer((socket) => { socket.on("end", () => socket.end()); });
    const port = await listen(server);
    const ctx = makeRegistry();
    await openTunnel(ctx, port);
    ctx.registry.projectDetached(PROJECT);
    await until(() => state.ended);
    expect(ctx.registry.streamCount(PEER)).toBe(0);
    expect(state.errors).toEqual([]);
  });

  test("stopping the manager ends every live forward: the upstream gets a FIN and the stream a FIN", async () => {
    const { server, state } = recordingServer((socket) => { socket.on("end", () => socket.end()); });
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake } = await openTunnel(ctx, port);
    ctx.server.manager.stop();
    await until(() => state.ended);
    await until(() => fake.isFinished());
    expect(ctx.registry.streamCount(PEER)).toBe(0);
    expect(fake.resets).toEqual([]);
  });

  test("a peer that may no longer receive ends the tunnel instead of being sent upstream bytes", async () => {
    let upstream: net.Socket | undefined;
    const { server, state } = recordingServer((socket) => {
      upstream = socket;
      socket.on("end", () => socket.end());
    });
    const port = await listen(server);
    const ctx = makeRegistry();
    const { fake } = await openTunnel(ctx, port);
    await until(() => upstream !== undefined);
    const writtenBefore = fake.rawWritten().length;
    ctx.setMayDeliver(false);
    upstream!.write("secret");
    await until(() => ctx.registry.streamCount(PEER) === 0);
    await until(() => state.ended);
    expect(fake.rawWritten().length).toBe(writtenBefore);
    expect(fake.resets).toEqual([STREAM_RESET_SCOPED]);
  });

  test("bytes from an app whose lease is gone retire the connection and never reach the upstream", async () => {
    const { server, state } = recordingServer((socket) => { socket.on("end", () => socket.end()); });
    const port = await listen(server);
    const ctx = makeRegistry();
    let authorized = true;
    const { fake } = await openTunnel(ctx, port, {}, { authorized: () => authorized });
    await until(() => fake.readSizes.length >= 1);
    authorized = false;
    fake.pushRaw(rawPayload("late"));
    await until(() => ctx.retiredPeers.length === 1);
    expect(ctx.retiredPeers).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
    await until(() => state.ended);
    expect(state.received).toEqual([]);
  });
});
