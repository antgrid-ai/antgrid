// Drives the real `ProjectStreamRegistry` through a `TestPeerSessionOwner`
// (which owns one internally) plus the `openProjectStream` fake-stream seam
// (`test-peer-session-owner.ts`) — never `PeerStreamAcceptor` itself, whose
// own admission order (session established, the open-frame parse, the
// pending-opens cap) is `native-host-connection.test.ts`'s to cover.
import { describe, test, expect, afterEach, spyOn } from "bun:test";
import { MAX_TRANSFER_BYTES, STREAM_MAX_PROJECTS_PER_PEER } from "antgrid-wire";
import { MessageBus, type Channel } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { STREAM_RECORD_SLICE_BYTES } from "../src/peer/stream-records";
import { netwatch } from "../src/netwatch";
import {
  STREAM_PRIORITY_PROJECT,
  STREAM_RESET_PROJECT,
  STREAM_STOP_PROJECT,
  type PeerSessionView,
} from "../src/project-streams";
import { ed25519Pair, TestPeerSessionOwner } from "./test-peer-session-owner";

function flush(times = 3): Promise<void> {
  return (async () => {
    for (let i = 0; i < times; i++) await new Promise<void>((resolve) => setTimeout(resolve, 0));
  })();
}

const PROJECT = "p1";
const PEER_A = "peer-a";
const PEER_B = "peer-b";

let clients: TestPeerSessionOwner[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { void c.close(); } catch { /* already closed */ } });

/** One agent-side client with the registry's two admission-gate constructor
 *  options under test control; every other caller gets the open-by-default
 *  fixture (`cataloged = {PROJECT}`, remote access on) that
 *  `test-peer-session-owner.ts`'s own `forTest` also defaults to. */
function makeClient(opts: {
  cataloged?: Set<string>;
  remoteAccessEnabled?: () => boolean;
  onError?: (code: string, message: string) => void;
} = {}) {
  const cataloged = opts.cataloged ?? new Set([PROJECT]);
  const client = new TestPeerSessionOwner({
    identity: {
      deviceId: "agent-1", deviceName: "agent", createdAt: new Date().toISOString(),
      ed25519PrivateKey: ed25519Pair().seedB64,
    },
    remoteAccessEnabled: opts.remoteAccessEnabled ?? (() => true),
    projectCataloged: (id) => cataloged.has(id),
    onError: opts.onError,
  });
  clients.push(client);
  client.setNativeWriter(() => true);
  return { client, cataloged };
}

describe("ProjectStreamRegistry (A4)", () => {
  test("row 1: the admitted open's first record is stream-ready; setPriority(0) runs once before the first write; a broadcast lands as a bare AbMessage", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const bus = new MessageBus();
    client.attachStream(bus, { projectId: PROJECT });

    const stream = await client.openProjectStream(PEER_A, PROJECT);
    expect(stream.refusal()).toBeUndefined();
    expect(stream.written()).toEqual([expect.objectContaining({ type: "stream-ready", projectId: PROJECT })]);
    expect(stream.priorities).toEqual([STREAM_PRIORITY_PROJECT]);
    expect(stream.order.indexOf("setPriority")).toBeLessThan(stream.order.indexOf("writeAll"));

    const msg = createMessage("pong", {});
    bus.publish(msg, "control");
    await flush();
    expect(stream.read()).toEqual(msg); // no `s`/`m` envelope keys — a bare AbMessage
  });

  test("row 2: an unsafe id is NOT_ALLOWED even when catalogued; an uncatalogued id is NOT_ALLOWED", async () => {
    const { client } = makeClient({ cataloged: new Set([PROJECT, "../evil"]) });
    client.establish(PEER_A);

    const unsafe = await client.openProjectStream(PEER_A, "../evil");
    expect(unsafe.refusal()?.code).toBe("NOT_ALLOWED");

    const uncatalogued = await client.openProjectStream(PEER_A, "not-catalogued");
    expect(uncatalogued.refusal()?.code).toBe("NOT_ALLOWED");
  });

  test("row 3: remoteAccessEnabled false at open is NOT_ALLOWED", async () => {
    const { client } = makeClient({ remoteAccessEnabled: () => false });
    client.establish(PEER_A);
    const bus = new MessageBus();
    client.attachStream(bus, { projectId: PROJECT });
    const stream = await client.openProjectStream(PEER_A, PROJECT);
    expect(stream.refusal()?.code).toBe("NOT_ALLOWED");
  });

  test("row 4: catalogued but unattached is NOT_READY then FIN and creates no core; the same open after attach is admitted", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);

    const before = await client.openProjectStream(PEER_A, PROJECT);
    expect(before.refusal()?.code).toBe("NOT_READY");
    expect(before.written()).toHaveLength(1); // refusal, then FIN — nothing else

    const bus = new MessageBus();
    client.attachStream(bus, { projectId: PROJECT });
    const after = await client.openProjectStream(PEER_A, PROJECT);
    expect(after.refusal()).toBeUndefined();
    expect(after.written()[0]).toMatchObject({ type: "stream-ready", projectId: PROJECT });
  });

  test("row 5: mayDeliver false at open is NOT_ALLOWED; flipped off after open gates both the next broadcast and the next addressed send", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    let allowed = false;
    const bus = new MessageBus();
    const handle = client.attachStream(bus, { projectId: PROJECT, mayDeliver: () => allowed });

    const refused = await client.openProjectStream(PEER_A, PROJECT);
    expect(refused.refusal()?.code).toBe("NOT_ALLOWED");

    allowed = true;
    const stream = await client.openProjectStream(PEER_A, PROJECT);
    expect(stream.refusal()).toBeUndefined();

    allowed = false;
    bus.publish(createMessage("pong", {}), "control");
    await flush();
    expect(() => stream.read()).toThrow(); // gated: nothing reached the wire

    const outcome = await handle.sendTo(createMessage("pong", {}), "control", { kind: "peer", peerId: PEER_A });
    expect(outcome).toBe("gated");
  });

  test("row 6: authorized() flipping false on an open stream retires the peer through retirePeerConnection", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const bus = new MessageBus();
    client.attachStream(bus, { projectId: PROJECT });
    let authorized = true;
    const stream = await client.openProjectStream(PEER_A, PROJECT, { authorized: () => authorized });
    expect(stream.refusal()).toBeUndefined();

    authorized = false;
    bus.publish(createMessage("pong", {}), "control");
    await flush();

    // The base class's retirePeerConnection is `dropSession` (§3.5); a
    // retired peer no longer holds a session.
    expect((client as unknown as { sessions: Map<string, unknown> }).sessions.has(PEER_A)).toBe(false);
  });

  test("row 6b: an inbound record while authorized() is false retires the connection instead of reaching the bus", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((msg) => received.push(msg));
    client.attachStream(bus, { projectId: PROJECT });
    let authorized = true;
    const stream = await client.openProjectStream(PEER_A, PROJECT, { authorized: () => authorized });
    expect(stream.refusal()).toBeUndefined();

    authorized = false;
    await stream.send(createMessage("pong", {}));

    expect(received).toEqual([]); // never reached the bus
    // Mirrors row 6's outbound check: the base class's retirePeerConnection is
    // `dropSession` (§3.5), so a retired peer no longer holds a session.
    expect((client as unknown as { sessions: Map<string, unknown> }).sessions.has(PEER_A)).toBe(false);
  });

  test("row 7: mid-stream staleness — flipping a mayDeliverTo gate mutes one peer's broadcast and gates its addressed send, leaving the other untouched", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    client.establish(PEER_B);
    let restricted = false;
    const bus = new MessageBus();
    const handle = client.attachStream(bus, {
      projectId: PROJECT,
      mayDeliverTo: (peer: PeerSessionView) => !restricted || peer.peerId === PEER_A,
    });
    const a = await client.openProjectStream(PEER_A, PROJECT);
    const b = await client.openProjectStream(PEER_B, PROJECT);

    const first = createMessage("pong", {});
    bus.publish(first, "control");
    await flush();
    expect(a.read()).toEqual(first);
    expect(b.read()).toEqual(first);

    restricted = true;
    const second = createMessage("pong", {});
    bus.publish(second, "control");
    await flush();
    expect(a.read()).toEqual(second);
    expect(() => b.read()).toThrow();

    const outcome = await handle.sendTo(createMessage("pong", {}), "control", { kind: "peer", peerId: PEER_B });
    expect(outcome).toBe("gated");
  });

  test("row 8: a project-stream open for a peer the session provider does not know is refused NOT_ALLOWED (the §2.3 fail-closed check)", async () => {
    const { client } = makeClient();
    // Deliberately un-established: `admit()` calls `mayAcceptFrom` with
    // whatever `peerSession(peerId)` returns, and PEER_A never ran a
    // session:hello here, so that lookup is null — proving the fail-closed
    // arm rather than the allowed one a real session would take.
    const bus = new MessageBus();
    client.attachStream(bus, {
      projectId: PROJECT,
      mayAcceptFrom: (peer) => (peer === null
        ? { code: "NOT_ALLOWED", message: "no session for this peer" }
        : null),
    });
    const stream = await client.openProjectStream(PEER_A, PROJECT);
    expect(stream.refusal()).toEqual({
      code: "NOT_ALLOWED", message: "no session for this peer",
    });
  });

  test("row 9: a peer that goes stale after open has its records dropped, with one rate-limited control:result notice on the session stream", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    let stale = false;
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((msg) => received.push(msg));
    client.attachStream(bus, {
      projectId: PROJECT,
      mayAcceptFrom: () => (stale ? { code: "NOT_ALLOWED", message: "no longer allowed" } : null),
    });
    const stream = await client.openProjectStream(PEER_A, PROJECT);
    expect(stream.refusal()).toBeUndefined();

    stale = true;
    await stream.send(createMessage("pong", {}));
    expect(received).toEqual([]);
    expect(client.sentTo(PEER_A)).toHaveLength(1);
    // The session stream carries bare AbMessages too — see the
    // handshake-pull.test.ts broadcast test.
    expect(client.readToPeer(PEER_A)).toMatchObject({
      type: "control:result", ok: false, projectId: PROJECT, error: { code: "NOT_ALLOWED" },
    });

    // Still stale, within the cooldown: no second notice queued.
    await stream.send(createMessage("pong", {}));
    expect(client.sentTo(PEER_A)).toHaveLength(0);
  });

  test("row 10: deliverableTo(peer) is false before open, true after, false once mayDeliverTo mutes it, and false once the app FINs", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    let allowed = true;
    const bus = new MessageBus();
    const handle = client.attachStream(bus, { projectId: PROJECT, mayDeliverTo: () => allowed });

    expect(handle.deliverableTo(PEER_A)).toBe(false);
    const stream = await client.openProjectStream(PEER_A, PROJECT);
    expect(stream.refusal()).toBeUndefined();
    expect(handle.deliverableTo(PEER_A)).toBe(true);

    allowed = false;
    expect(handle.deliverableTo(PEER_A)).toBe(false);
    allowed = true;
    expect(handle.deliverableTo(PEER_A)).toBe(true);

    await stream.finish();
    expect(handle.deliverableTo(PEER_A)).toBe(false);
  });

  test("row 11: two peers on one project — an addressed reply reaches only its target, a broadcast reaches both, and A's FIN unbinds only A", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    client.establish(PEER_B);
    const closed: string[] = [];
    const bus = new MessageBus();
    const handle = client.attachStream(bus, { projectId: PROJECT, onPeerStreamClosed: (id) => closed.push(id) });
    const a = await client.openProjectStream(PEER_A, PROJECT);
    const b = await client.openProjectStream(PEER_B, PROJECT);

    const reply = createMessage("pong", {});
    await handle.sendTo(reply, "control", { kind: "peer", peerId: PEER_A });
    expect(a.read()).toEqual(reply);
    expect(() => b.read()).toThrow();

    const broadcast = createMessage("pong", {});
    bus.publish(broadcast, "control");
    await flush();
    expect(a.read()).toEqual(broadcast);
    expect(b.read()).toEqual(broadcast);

    await a.finish();
    expect(closed).toEqual([PEER_A]);

    const again = createMessage("pong", {});
    bus.publish(again, "control");
    await flush();
    expect(b.read()).toEqual(again); // B is untouched by A's close
  });

  test("row 12: an inbound record is dispatched as bus.dispatchInbound(msg, 'control', 'relay', peerId)", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const bus = new MessageBus();
    const received: Array<{ msg: unknown; channel: Channel; source: string; peerId?: string }> = [];
    bus.setInboundHandler((msg, channel, source, peerId) => received.push({ msg, channel, source, peerId }));
    client.attachStream(bus, { projectId: PROJECT });
    const stream = await client.openProjectStream(PEER_A, PROJECT);

    const msg = createMessage("pong", {});
    await stream.send(msg);
    expect(received).toEqual([{ msg, channel: "control", source: "relay", peerId: PEER_A }]);
  });

  test("row 13: a duplicate open for the same (peer, project) is INVALID; the 33rd concurrent project stream for one peer is CAP_EXCEEDED", async () => {
    const { client, cataloged } = makeClient();
    client.establish(PEER_A);
    client.attachStream(new MessageBus(), { projectId: PROJECT });

    const first = await client.openProjectStream(PEER_A, PROJECT);
    expect(first.refusal()).toBeUndefined();
    const dup = await client.openProjectStream(PEER_A, PROJECT);
    expect(dup.refusal()?.code).toBe("INVALID");

    // One more project stream (PROJECT) is already open; 31 more reaches the
    // 32-stream cap, so the 33rd concurrent open overflows it.
    for (let i = 0; i < STREAM_MAX_PROJECTS_PER_PEER - 1; i++) {
      const pid = `extra-${i}`;
      cataloged.add(pid);
      client.attachStream(new MessageBus(), { projectId: pid });
      const stream = await client.openProjectStream(PEER_A, pid);
      expect(stream.refusal()).toBeUndefined();
    }
    cataloged.add("overflow");
    client.attachStream(new MessageBus(), { projectId: "overflow" });
    const overflow = await client.openProjectStream(PEER_A, "overflow");
    expect(overflow.refusal()?.code).toBe("CAP_EXCEEDED");
  });

  test("row 14: overflow resets only that stream and stops its receive half, leaves the peer's other project stream and the connection untouched, and fires onPeerStreamClosed", async () => {
    const { client, cataloged } = makeClient();
    cataloged.add("other");
    client.establish(PEER_A);
    const closed: string[] = [];
    const bus = new MessageBus();
    client.attachStream(bus, { projectId: PROJECT, onPeerStreamClosed: (id) => closed.push(id) });
    const otherBus = new MessageBus();
    client.attachStream(otherBus, { projectId: "other" });

    const stream = await client.openProjectStream(PEER_A, PROJECT);
    const other = await client.openProjectStream(PEER_A, "other");
    expect(stream.refusal()).toBeUndefined();
    expect(other.refusal()).toBeUndefined();

    // `MessageBus.publish` -> `deliver` -> `StreamRecordWriter.send` all run
    // SYNCHRONOUSLY down to `send()`'s own overflow check (only `setPriority`/
    // `writeAll` are async in the fake, deferred to a microtask) — so 60
    // messages published back-to-back with no `await` between them queue
    // faster than the fake's drain can empty the queue, and their cumulative
    // bytes cross PROJECT_STREAM_MAX_QUEUED_BYTES (64 MiB) before any of them
    // is actually written. Every publish is one record and contributes its
    // whole size to the queue.
    const content = "x".repeat(1_300_000);
    for (let i = 0; i < 60; i++) {
      bus.publish(createMessage("file:content", {
        projectId: PROJECT, path: `f${i}.txt`, content, size: content.length, encoding: "utf8",
      }), "control");
    }
    await flush(10);

    expect(stream.resets).toEqual([STREAM_RESET_PROJECT]);
    expect(stream.stops).toEqual([STREAM_STOP_PROJECT]);
    expect(closed).toEqual([PEER_A]);
    // The peer's OTHER project stream, opened against a separate entry, is
    // untouched: it never resets and stays deliverable.
    expect(other.resets).toEqual([]);
    const ping = createMessage("pong", {});
    otherBus.publish(ping, "control");
    await flush();
    expect(other.read()).toEqual(ping);
  });

  test("P1: a message over the app read cap is written as one record, never fragmented", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const bus = new MessageBus();
    client.attachStream(bus, { projectId: PROJECT });
    const stream = await client.openProjectStream(PEER_A, PROJECT);

    const size = 5 * 1024 * 1024;
    const big = createMessage("file:content", {
      projectId: PROJECT, path: "a.txt", content: "x".repeat(size), size, encoding: "utf8",
    });
    bus.publish(big, "control");
    await flush();

    const records = stream.written().slice(1); // drop the opening stream-ready
    expect(records).toHaveLength(1);
    expect(records[0]).not.toHaveProperty("__frag");
    expect(stream.read()).toEqual(big);
  });

  test("P2: a message over MAX_TRANSFER_BYTES is too-large, writes nothing and reports MESSAGE_TOO_LARGE", async () => {
    const errors: Array<{ code: string; message: string }> = [];
    const { client } = makeClient({ onError: (code, message) => errors.push({ code, message }) });
    client.establish(PEER_A);
    const bus = new MessageBus();
    const handle = client.attachStream(bus, { projectId: PROJECT });
    const stream = await client.openProjectStream(PEER_A, PROJECT);

    const huge = createMessage("file:content", {
      projectId: PROJECT, path: "b.txt", content: "x".repeat(MAX_TRANSFER_BYTES + 1),
      size: MAX_TRANSFER_BYTES + 1, encoding: "utf8",
    });
    const before = stream.written().length;
    const outcome = await handle.sendTo(huge, "control", { kind: "peer", peerId: PEER_A });
    expect(outcome).toBe("too-large");
    expect(stream.written().length).toBe(before); // nothing written for the refused message
    expect(errors).toEqual([expect.objectContaining({ code: "MESSAGE_TOO_LARGE" })]);
  });

  test("P2b: the too-large and not-ab-message diagnostics both carry streamKind:\"project\" and this project's own streamId, reaching netwatch", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const bus = new MessageBus();
    const handle = client.attachStream(bus, { projectId: PROJECT });
    const stream = await client.openProjectStream(PEER_A, PROJECT);
    const events: Parameters<typeof netwatch.record>[0][] = [];
    const observer = spyOn(netwatch, "record").mockImplementation((event) => { events.push(event); });
    try {
      const huge = createMessage("file:content", {
        projectId: PROJECT, path: "b.txt", content: "x".repeat(MAX_TRANSFER_BYTES + 1),
        size: MAX_TRANSFER_BYTES + 1, encoding: "utf8",
      });
      await handle.sendTo(huge, "control", { kind: "peer", peerId: PEER_A });
      const tooLarge = events.find((e) => e.reason === "MESSAGE_TOO_LARGE");
      expect(tooLarge).toMatchObject({ streamKind: "project", streamId: PROJECT });

      await stream.send('{"nonsense":true}');
      const notAbMessage = events.find((e) => e.reason === "not-ab-message");
      expect(notAbMessage).toMatchObject({ streamKind: "project", streamId: PROJECT });
    } finally { observer.mockRestore(); }
  });

  test("P3: a 32 MiB record is written as slices, not as one array", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const bus = new MessageBus();
    const handle = client.attachStream(bus, { projectId: PROJECT });
    const stream = await client.openProjectStream(PEER_A, PROJECT);

    // Pad content so the whole record's JSON lands at MAX_TRANSFER_BYTES - 1024.
    const target = MAX_TRANSFER_BYTES - 1024;
    const shape = createMessage("file:content", {
      projectId: PROJECT, path: "big.bin", content: "", size: 0, encoding: "utf8",
    });
    const overhead = Buffer.byteLength(JSON.stringify(shape), "utf8");
    const content = "x".repeat(target - overhead);
    const big = createMessage("file:content", {
      projectId: PROJECT, path: "big.bin", content, size: content.length, encoding: "utf8",
    });
    const json = JSON.stringify(big);

    const outcome = await handle.sendTo(big, "control", { kind: "peer", peerId: PEER_A });
    expect(outcome).toBe("sent");
    for (const len of stream.writeAllLengths) expect(len).toBeLessThanOrEqual(STREAM_RECORD_SLICE_BYTES);
    expect(stream.writeAllLengths.length).toBeGreaterThanOrEqual(128);
    expect(stream.written().at(-1)).toEqual(JSON.parse(json));
  });

  test("P4: an inbound __frag record is dropped, not buffered, and a normal verb right behind it still dispatches", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((msg) => received.push(msg));
    client.attachStream(bus, { projectId: PROJECT });
    const stream = await client.openProjectStream(PEER_A, PROJECT);

    await stream.send('{"__frag":{"id":"rx-1","index":0,"total":2}}');
    const normal = createMessage("pong", {});
    await stream.send(normal);

    expect(received).toEqual([normal]);
  });

  test("P5: an app record over STREAM_PROJECT_APP_RECORD_MAX_BYTES is a protocol violation and retires the connection", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const bus = new MessageBus();
    client.attachStream(bus, { projectId: PROJECT });
    const stream = await client.openProjectStream(PEER_A, PROJECT);
    expect(stream.refusal()).toBeUndefined();

    await stream.sendOverlongPrefix(1_500_001);
    await flush();

    // The base class's retirePeerConnection is `dropSession` (§3.5, mirroring
    // row 6's authorized() check) — a retired peer no longer holds a session.
    expect((client as unknown as { sessions: Map<string, unknown> }).sessions.has(PEER_A)).toBe(false);
  });

  test("row 15c: a peer whose writes are parked does not hold up another peer's copy of the same broadcast", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    client.establish(PEER_B);
    const bus = new MessageBus();
    client.attachStream(bus, { projectId: PROJECT });
    const a = await client.openProjectStream(PEER_A, PROJECT);
    const b = await client.openProjectStream(PEER_B, PROJECT);

    a.holdWrites();
    const broadcast = createMessage("pong", {});
    bus.publish(broadcast, "control");
    await flush(10);
    expect(b.read()).toEqual(broadcast);
    expect(() => a.read()).toThrow();

    a.releaseWrites();
    await flush(10);
    expect(a.read()).toEqual(broadcast);
  });

  test("row 16: a terminal-bound message falls back to the project stream with no terminal stream, and routes through routeTerminal once one is bound", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const bus = new MessageBus();
    const routedCalls: Array<{ peerId: string; msg: AbMessage }> = [];
    let router: ((peerId: string, msg: AbMessage, signal?: AbortSignal) =>
      Promise<"sent" | "dropped"> | undefined) | undefined;
    // routeTerminal is wired at registry construction from PeerSessionOwner's
    // own protected hook (contract §3.5), not passed through attachStream.
    client.setRouteTerminal((peerId, msg, signal) => { routedCalls.push({ peerId, msg }); return router?.(peerId, msg, signal); });
    client.attachStream(bus, { projectId: PROJECT });
    const stream = await client.openProjectStream(PEER_A, PROJECT);

    const fellBack = createMessage("pong", {});
    bus.publishOnly(fellBack, "control", "relay", PEER_A);
    await flush();
    expect(routedCalls).toHaveLength(1);
    expect(stream.read()).toEqual(fellBack); // no terminal stream bound: falls back here

    router = () => Promise.resolve("sent");
    const routed = createMessage("pong", {});
    bus.publishOnly(routed, "control", "relay", PEER_A);
    await flush();
    expect(() => stream.read()).toThrow(); // a bound terminal stream took it instead
  });

  test("row 17: detach() finishes every binding and fires projectDetached once, never onPeerStreamClosed", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    client.establish(PEER_B);
    const detached: string[] = [];
    const closed: string[] = [];
    const bus = new MessageBus();
    // projectDetached is wired at registry construction, same as routeTerminal.
    client.setProjectDetached((id) => detached.push(id));
    const handle = client.attachStream(bus, {
      projectId: PROJECT,
      onPeerStreamClosed: (id) => closed.push(id),
    });
    const a = await client.openProjectStream(PEER_A, PROJECT);
    const b = await client.openProjectStream(PEER_B, PROJECT);

    handle.detach();
    await flush();
    expect(a.finished).toBe(true);
    expect(b.finished).toBe(true);
    expect(detached).toEqual([PROJECT]);
    expect(closed).toEqual([]);
  });

  test("row 17b: dropPeer resets and stops the peer's binding without dispatching, awaiting, or firing onPeerStreamClosed", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const closed: string[] = [];
    const bus = new MessageBus();
    client.attachStream(bus, { projectId: PROJECT, onPeerStreamClosed: (id) => closed.push(id) });
    const stream = await client.openProjectStream(PEER_A, PROJECT);
    expect(stream.refusal()).toBeUndefined();

    (client as unknown as { projectStreams: { dropPeer(peerId: string): void } }).projectStreams.dropPeer(PEER_A);
    await flush();
    expect(stream.resets).toEqual([STREAM_RESET_PROJECT]);
    expect(stream.stops).toEqual([STREAM_STOP_PROJECT]);
    expect(closed).toEqual([]); // session-driven hooks are the owner's to fire, not dropPeer's
  });

  test("row 18: onPeerOnline fires at attach when a session exists; onPeerSessionGone/onPeerOffline are session-driven — opening or closing a project stream fires neither", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const events: string[] = [];
    const bus = new MessageBus();
    client.attachStream(bus, {
      projectId: PROJECT,
      onPeerOnline: () => events.push("online"),
      onPeerOffline: () => events.push("offline"),
      onPeerSessionGone: (peerId) => events.push(`gone:${peerId}`),
    });
    expect(events).toEqual(["online"]); // a session already exists at attach time

    const stream = await client.openProjectStream(PEER_A, PROJECT);
    expect(events).toEqual(["online"]); // opening a stream fires neither hook

    await stream.finish();
    expect(events).toEqual(["online"]); // nor does closing one

    (client as unknown as { dropSession(peerId: string): void }).dropSession(PEER_A);
    expect(events).toEqual(["online", `gone:${PEER_A}`, "offline"]);
  });
});
