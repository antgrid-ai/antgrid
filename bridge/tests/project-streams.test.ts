// Drives the real `ProjectStreamRegistry` through a `TestPeerSessionOwner`
// (which owns one internally) plus the `openProjectStream` fake-stream seam
// (`test-peer-session-owner.ts`) — never `PeerStreamAcceptor` itself, whose
// own admission order (session established, the open-frame parse, the
// pending-opens cap) is `native-host-connection.test.ts`'s to cover. Admission
// shared with every other kind (unsafe/uncatalogued ids, NOT_READY, caps,
// duplicate ids, unauthorized mid-stream, oversize records) is covered once
// by stream-admission.test.ts; this file covers the project stream's own
// body: broadcast/addressed delivery, per-peer and per-project outbound
// gates, oversize-message handling, terminal-routing fallback, and teardown.
import { describe, test, expect, afterEach, spyOn } from "bun:test";
import { MAX_TRANSFER_BYTES } from "antgrid-wire";
import { MessageBus, type Channel } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { netwatch } from "../src/netwatch";
import {
  STREAM_RESET_PROJECT,
  STREAM_STOP_PROJECT,
  type PeerSessionView,
} from "../src/project-streams";
import { flush } from "./support/fake-bi-stream";
import { ed25519Pair, TestPeerSessionOwner } from "./test-peer-session-owner";

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

describe("ProjectStreamRegistry", () => {
  test("the admitted open's first record is stream-ready, and a broadcast lands as a bare AbMessage", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const bus = new MessageBus();
    client.attachStream(bus, { projectId: PROJECT });

    const stream = await client.openProjectStream(PEER_A, PROJECT);
    expect(stream.refusal()).toBeUndefined();
    expect(stream.written()).toEqual([expect.objectContaining({ type: "stream-ready", projectId: PROJECT })]);

    const msg = createMessage("pong", {});
    bus.publish(msg, "control");
    await flush();
    expect(stream.read()).toEqual(msg); // no `s`/`m` envelope keys — a bare AbMessage
  });

  test("mayDeliver gates every peer's open and every send; mayDeliverTo gates one peer's send without touching another's", async () => {
    // mayDeliver: a project-wide outbound gate, checked at open and on every send.
    {
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
    }

    // mayDeliverTo: a per-peer outbound gate, muting one peer's broadcast and
    // addressed send while leaving another peer on the same project untouched.
    {
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
    }
  });

  test("a peer that goes stale after open has its records dropped, with one rate-limited control:result notice on the session stream", async () => {
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

  test("deliverableTo(peer) is false before open, true after, false once mayDeliverTo mutes it, and false once the app FINs", async () => {
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

  test("two peers on one project — an addressed reply reaches only its target, a broadcast reaches both, and A's FIN unbinds only A", async () => {
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

  test("an inbound app record reaches the bus's inbound handler as (msg, \"control\", \"relay\", peerId)", async () => {
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

  test("a message over the app read cap is written as one record, never fragmented", async () => {
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

  test("a message over MAX_TRANSFER_BYTES is too-large, writes nothing and reports MESSAGE_TOO_LARGE", async () => {
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

  test("the too-large and not-ab-message diagnostics both carry streamKind:\"project\" and this project's own streamId, reaching netwatch", async () => {
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

  test("an inbound __frag record is dropped, not buffered, and a normal verb right behind it still dispatches", async () => {
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

  test("a peer whose writes are parked does not hold up another peer's copy of the same broadcast", async () => {
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

  test("a terminal-bound message falls back to the project stream with no terminal stream, and routes through routeTerminal once one is bound", async () => {
    const { client } = makeClient();
    client.establish(PEER_A);
    const bus = new MessageBus();
    const routedCalls: Array<{ peerId: string; msg: AbMessage }> = [];
    let router: ((peerId: string, msg: AbMessage, signal?: AbortSignal) =>
      Promise<"sent" | "dropped"> | undefined) | undefined;
    // routeTerminal is wired at registry construction from PeerSessionOwner's
    // own protected hook, not passed through attachStream.
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

  test("detach() finishes every binding and fires projectDetached once, never onPeerStreamClosed", async () => {
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

  test("dropPeer resets and stops the peer's binding without dispatching, awaiting, or firing onPeerStreamClosed — unlike an overflow, which does fire it", async () => {
    {
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
    }
    {
      // An overflow, in contrast, does fire onPeerStreamClosed — proven once
      // here rather than duplicating admission's SA-covered reset test.
      const { client } = makeClient();
      client.establish(PEER_A);
      const closed: string[] = [];
      const bus = new MessageBus();
      client.attachStream(bus, { projectId: PROJECT, onPeerStreamClosed: (id) => closed.push(id) });
      await client.openProjectStream(PEER_A, PROJECT);
      // `MessageBus.publish` -> `deliver` -> `StreamRecordWriter.send` all run
      // synchronously down to `send()`'s own overflow check, so N messages
      // published back-to-back with no `await` queue faster than the fake's
      // drain can empty them, crossing PROJECT_STREAM_MAX_QUEUED_BYTES before
      // any of them is actually written.
      const content = "x".repeat(1_300_000);
      for (let i = 0; i < 60; i++) {
        bus.publish(createMessage("file:content", {
          projectId: PROJECT, path: `f${i}.txt`, content, size: content.length, encoding: "utf8",
        }), "control");
      }
      await flush(10);
      expect(closed).toEqual([PEER_A]);
    }
  });

  test("onPeerOnline fires at attach when a session exists; onPeerSessionGone/onPeerOffline are session-driven — opening or closing a project stream fires neither", async () => {
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

    client.markPeerOffline(PEER_A);
    expect(events).toEqual(["online", `gone:${PEER_A}`, "offline"]);
  });
});
