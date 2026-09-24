// v3 stream multiplexing: one machine socket, project
// cores attach as opaque streamId-tagged streams. Two layers are covered here:
// StreamMux in isolation (against a stub transport â€” no crypto, no socket),
// and the real TestPeerSessionOwner wiring the envelope through seal/fragment/send so
// `s` provably survives the wire.
import { describe, test, expect, afterEach } from "bun:test";
import { buildFragments } from "antgrid-wire";
import {
  StreamMux, CONTROL_STREAM_ID, INVALID_NOTICE_COOLDOWN_MS,
  type StreamMuxTransport, type PeerSessionView, type SendTarget, type TerminalStreamHooks,
} from "../src/stream-mux";
import { MessageBus, type Channel } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import type { StreamSendOutcome } from "../src/peer/stream-records";
import { ed25519Pair, TestPeerSessionOwner } from "./test-peer-session-owner";

function makeTransport(peers: Map<string, PeerSessionView> = new Map()) {
  const closed: string[] = [];
  const sent: Array<{ streamId: string; msg: unknown; channel: Channel }> = [];
  // Kept beside `sent` rather than in it so the existing exact-shape assertions
  // stay readable; index-aligned with it.
  const targets: Array<SendTarget | undefined> = [];
  const transport: StreamMuxTransport = {
    closeStream: (id) => closed.push(id),
    sendEnvelope: (id, msg, channel, target) => {
      targets.push(target);
      sent.push({ streamId: id, msg, channel });
      return Promise.resolve("sent" as const);
    },
    peerSession: (peerId) => peers.get(peerId) ?? null,
  };
  return { transport, closed, sent, targets, peers };
}

/** Same as {@link makeTransport}, plus the three A2 terminal-stream members so
 *  `routeTerminal`/`terminalHooks`/`projectDetached` can be observed and
 *  scripted per test. */
function makeTerminalTransport(peers: Map<string, PeerSessionView> = new Map()) {
  const base = makeTransport(peers);
  const routedCalls: Array<{ peerId: string; msg: AbMessage; signal: AbortSignal | undefined }> = [];
  const projectDetachedCalls: string[] = [];
  let router: (peerId: string, msg: AbMessage, signal?: AbortSignal) => Promise<StreamSendOutcome> | undefined =
    () => Promise.resolve("sent");
  const hooks: TerminalStreamHooks = {
    retired: () => {},
    subscribeSettled: () => {},
  };
  const transport: StreamMuxTransport = {
    ...base.transport,
    routeTerminal: (peerId, msg, signal) => {
      routedCalls.push({ peerId, msg, signal });
      return router(peerId, msg, signal);
    },
    terminalHooks: hooks,
    projectDetached: (projectId) => projectDetachedCalls.push(projectId),
  };
  return {
    ...base,
    transport,
    routedCalls,
    projectDetachedCalls,
    hooks,
    setRouter: (fn: typeof router) => { router = fn; },
  };
}

function peerView(peerId: string, checkoutRouting: boolean): PeerSessionView {
  return { peerId, peerPubkey: `pub-${peerId}`, checkoutRouting, pullsTree: true };
}

describe("StreamMux (unit, stub transport)", () => {
  test("host binding is admitted locally and keeps its opaque id", () => {
    const { transport } = makeTransport();
    const mux = new StreamMux(transport);
    const events: string[] = [];
    const streamId = "0123456789abcdef";
    const handle = mux.attach(new MessageBus(), {
      streamId,
      onLocalReady: (id) => events.push(`local:${id}`),
      onAdmitted: (id) => events.push(`admitted:${id}`),
    });
    expect(handle.streamId).toBe(streamId);
    expect(events).toEqual([`local:${streamId}`, `admitted:${streamId}`]);
    expect(() => mux.attach(new MessageBus(), { streamId })).toThrow("duplicate");
    handle.detach();
  });

  test("attach allocates a 16-hex streamId", () => {
    const { transport } = makeTransport();
    const mux = new StreamMux(transport);
    expect(mux.attach(new MessageBus(), {}).streamId).toMatch(/^[0-9a-f]{16}$/);
  });

  test("outbound bus traffic is tagged with this stream's id", () => {
    const { transport, sent } = makeTransport();
    const mux = new StreamMux(transport);
    const bus = new MessageBus();
    const handle = mux.attach(bus, {});
    const msg = createMessage("pong", {});
    bus.publish(msg, "control");
    expect(sent).toEqual([{ streamId: handle.streamId, msg, channel: "control" }]);
  });

  test("mayDeliver gates outbound bus AND tunnel frames, and is re-read on every send", async () => {
    // The outbound half of the machine mobile-access gate. Read live, not
    // captured: flipping the switch back on must resume the SAME stream â€” the
    // whole point of gating at the send rather than detaching.
    const { transport, sent } = makeTransport();
    const mux = new StreamMux(transport);
    const bus = new MessageBus();
    let allowed = false;
    const handle = mux.attach(bus, { mayDeliver: () => allowed });

    bus.publish(createMessage("pong", {}), "control");
    // "gated", NOT "dropped": the one consumer that awaits this must be able to
    // tell a closed machine switch from a cleared queue â€” a WS tunnel survives
    // the first and not the second.
    expect(await handle.sendTunnel({ t: "tunnel:http-start" })).toBe("gated");
    expect(sent).toEqual([]);

    allowed = true;
    const msg = createMessage("pong", {});
    bus.publish(msg, "control");
    expect(await handle.sendTunnel({ t: "tunnel:http-start" })).toBe("sent");
    expect(sent).toEqual([
      { streamId: handle.streamId, msg, channel: "control" },
      { streamId: handle.streamId, msg: { t: "tunnel:http-start" }, channel: "preview" },
    ]);
  });

  test("mayDeliverTo mutes a PEER-ADDRESSED send too, and a broadcast keeps the caller's own filter under it", () => {
    // A tunnel answer names the session that asked, and asking was never an
    // admission: a device that cannot address a checkout would read an isolated
    // session's preview as the main worktree's whether it requested it or not.
    const { transport, sent, targets, peers } = makeTransport();
    const mux = new StreamMux(transport);
    peers.set("stale", peerView("stale", false));
    peers.set("modern", peerView("modern", true));
    const handle = mux.attach(new MessageBus(), { mayDeliverTo: (peer) => peer.checkoutRouting });

    handle.sendTunnel({ t: "tunnel:http-response" }, { kind: "peer", peerId: "stale" });
    expect(sent).toEqual([]);

    handle.sendTunnel({ t: "tunnel:http-response" }, { kind: "peer", peerId: "modern" });
    expect(targets).toEqual([{ kind: "peer", peerId: "modern" }]);

    handle.sendTunnel({ t: "tunnel:http-response" }, {
      kind: "broadcast", where: (peer) => peer.peerId !== "modern",
    });
    const target = targets[1];
    if (target?.kind !== "broadcast" || !target.where) throw new Error("broadcast filter dropped");
    expect(target.where(peerView("modern", true))).toBe(false);
    expect(target.where(peerView("stale", false))).toBe(false);
    expect(target.where(peerView("other", true))).toBe(true);
  });

  test("a peer target naming a session this machine no longer holds is dropped, never widened to a broadcast", () => {
    // Falling back to a fan-out is the loud failure: one device's HTTP response
    // handed to every other device attached to the same project.
    const { transport, sent } = makeTransport();
    const mux = new StreamMux(transport);
    const handle = mux.attach(new MessageBus(), { mayDeliverTo: () => true });
    handle.sendTunnel({ t: "tunnel:http-response" }, { kind: "peer", peerId: "evicted" });
    expect(sent).toEqual([]);
  });

  test("a stream attached without mayDeliver delivers (local/wizard callers answer to no switch)", () => {
    const { transport, sent } = makeTransport();
    const mux = new StreamMux(transport);
    const bus = new MessageBus();
    mux.attach(bus, {});
    bus.publish(createMessage("pong", {}), "control");
    expect(sent).toHaveLength(1);
  });

  test("dispatchInbound routes a parsed AbMessage to the attached stream's bus", () => {
    const { transport } = makeTransport();
    const mux = new StreamMux(transport);
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((msg) => received.push(msg));
    const handle = mux.attach(bus, {});
    const msg = createMessage("pong", {});
    const ok = mux.dispatchInbound(handle.streamId, JSON.stringify(msg), "control", "phone-1");
    expect(ok).toBe(true);
    expect(received).toEqual([msg]);
  });

  test("dispatchInbound for an unknown streamId returns false so the caller drops + logs, and answers stream-invalid", () => {
    const { transport, sent } = makeTransport();
    const mux = new StreamMux(transport);
    const ok = mux.dispatchInbound("deadbeefdeadbeef", JSON.stringify(createMessage("pong", {})), "control", "phone-1");
    expect(ok).toBe(false);
    expect(sent).toHaveLength(1);
    expect(sent[0]!.streamId).toBe(CONTROL_STREAM_ID);
    expect(sent[0]!.channel).toBe("control");
    expect(sent[0]!.msg).toMatchObject({ type: "stream-invalid", streamId: "deadbeefdeadbeef" });
  });

  // Regression: a bridge restart re-attaches every project under fresh random
  // ids, so the phone's cached id is dead forever. The old behaviour dropped +
  // warned only, which stranded the phone on the dead id until it was force
  // quit â€” backing out of the project and re-entering never renegotiated.
  test("a phone replaying on a dead streamId after a host restart is told the stream is invalid", () => {
    const { transport, sent } = makeTransport();
    const restarted = new StreamMux(transport);
    // The fresh process's stream for the same project â€” a different id.
    const live = restarted.attach(new MessageBus(), {});
    const deadId = "aaaabbbbccccdddd";
    expect(deadId).not.toBe(live.streamId);
    sent.length = 0;

    expect(restarted.dispatchInbound(deadId, JSON.stringify(createMessage("file:read", { projectId: "p1", path: "a.txt" })), "control", "phone-1")).toBe(false);

    expect(sent).toEqual([{
      streamId: CONTROL_STREAM_ID,
      channel: "control",
      msg: expect.objectContaining({ type: "stream-invalid", streamId: deadId }),
    }]);
    // The live stream is untouched â€” stream-scoped, like the relay's error{ref}.
    const msg = createMessage("pong", {});
    expect(restarted.dispatchInbound(live.streamId, JSON.stringify(msg), "control", "phone-1")).toBe(true);
  });

  test("stream-invalid is rate-limited per dead id â€” a burst of replays yields one notice, each dead id its own", () => {
    let now = 1_000_000;
    const { transport, sent } = makeTransport();
    const mux = new StreamMux(transport, () => now);
    const body = JSON.stringify(createMessage("pong", {}));

    for (let i = 0; i < 5; i++) mux.dispatchInbound("deadbeefdeadbeef", body, "control", "phone-1");
    expect(sent).toHaveLength(1);

    // A second dead id is a distinct binding to renegotiate, not a repeat.
    mux.dispatchInbound("beefdeadbeefdead", body, "control", "phone-1");
    expect(sent).toHaveLength(2);

    // Still stranded past the cooldown â†’ say it again rather than go quiet.
    now += INVALID_NOTICE_COOLDOWN_MS + 1;
    mux.dispatchInbound("deadbeefdeadbeef", body, "control", "phone-1");
    expect(sent).toHaveLength(3);
    expect(sent[2]!.msg).toMatchObject({ type: "stream-invalid", streamId: "deadbeefdeadbeef" });
  });

  const refuseIncapable = (peer: PeerSessionView | null) =>
    peer?.checkoutRouting === true
      ? null
      : { code: "UPDATE_REQUIRED", message: "update the app to use this project's isolated sessions" };

  test("mayAcceptFrom refuses an incapable session's frames and answers that session alone", () => {
    // The bind path takes a streamId straight off the `agent:projects` advert
    // with no `project:start`, so the verb's own refusal is never reached and a
    // stale device on a mixed fleet would otherwise wait on silence forever.
    const { transport, sent, targets, peers } = makeTransport();
    const mux = new StreamMux(transport);
    peers.set("stale", peerView("stale", false));
    peers.set("modern", peerView("modern", true));
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((msg) => received.push(msg));
    const handle = mux.attach(bus, { projectId: "p1", mayAcceptFrom: refuseIncapable });
    const body = JSON.stringify(createMessage("file:read", { projectId: "p1", path: "a.txt" }));

    // Handled, not dropped: falling through to the unknown-stream path would
    // tell a device holding a LIVE stream to renegotiate it.
    expect(mux.dispatchInbound(handle.streamId, body, "control", "stale")).toBe(true);
    expect(received).toEqual([]);
    expect(sent).toEqual([{
      streamId: CONTROL_STREAM_ID,
      channel: "control",
      msg: expect.objectContaining({
        type: "control:result",
        ok: false,
        projectId: "p1",
        error: { code: "UPDATE_REQUIRED", message: "update the app to use this project's isolated sessions" },
      }),
    }]);
    expect(targets).toEqual([{ kind: "peer", peerId: "stale" }]);

    // The capable sibling on the same stream keeps its frame and never sees the
    // other device's banner.
    expect(mux.dispatchInbound(handle.streamId, body, "control", "modern")).toBe(true);
    expect(received).toHaveLength(1);
    expect(sent).toHaveLength(1);
  });

  test("a refused session's tunnel frames never reach onTunnel", () => {
    // The tunnel route bypasses the bus entirely, which is why the per-device
    // gate had to sit ahead of both routes rather than inside the dispatch.
    const { transport, peers } = makeTransport();
    const mux = new StreamMux(transport);
    peers.set("stale", peerView("stale", false));
    const tunnels: unknown[] = [];
    const handle = mux.attach(new MessageBus(), {
      projectId: "p1", onTunnel: (raw) => tunnels.push(raw), mayAcceptFrom: refuseIncapable,
    });
    const request = JSON.stringify({
      type: "tunnel:http-request", requestId: "r1", port: 5173, method: "GET", path: "/",
    });

    expect(mux.dispatchInbound(handle.streamId, request, "preview", "stale")).toBe(true);
    expect(tunnels).toEqual([]);
  });

  test("the refusal is rate-limited per (session, stream) â€” a retry loop cannot flood the control plane", () => {
    let now = 1_000_000;
    const { transport, sent, peers } = makeTransport();
    const mux = new StreamMux(transport, () => now);
    peers.set("stale", peerView("stale", false));
    peers.set("older", peerView("older", false));
    const handle = mux.attach(new MessageBus(), { projectId: "p1", mayAcceptFrom: refuseIncapable });
    const body = JSON.stringify(createMessage("pong", {}));

    for (let i = 0; i < 5; i++) mux.dispatchInbound(handle.streamId, body, "control", "stale");
    expect(sent).toHaveLength(1);

    // A second stale device is its own device to inform, not a repeat.
    mux.dispatchInbound(handle.streamId, body, "control", "older");
    expect(sent).toHaveLength(2);

    // Still refused past the cooldown â†’ say it again rather than go quiet.
    now += INVALID_NOTICE_COOLDOWN_MS + 1;
    mux.dispatchInbound(handle.streamId, body, "control", "stale");
    expect(sent).toHaveLength(3);
  });

  test("stream-unbound mutes only that stream, and only outbound â€” a re-open reuses the id, so it must never detach", () => {
    // The mirror of stream-invalid. Without it a core whose peer restarted
    // streams a live PTY at an app that binds nothing, one frame per frame.
    const { transport, sent, closed } = makeTransport();
    const mux = new StreamMux(transport);
    const busA = new MessageBus();
    const busB = new MessageBus();
    const a = mux.attach(busA, {});
    const b = mux.attach(busB, {});

    mux.markUnbound(a.streamId);
    busA.publish(createMessage("pong", {}), "control");
    busB.publish(createMessage("pong", {}), "control");
    expect(sent.map((s) => s.streamId)).toEqual([b.streamId]);
    // Muted, not torn down: host-server re-publishes stream-ready with the
    // SAME id, so a detach here would break the reconnect that heals this.
    expect(closed).toEqual([]);
  });

  test("a muted stream resumes on the peer's own traffic, and on a fresh E2E session", () => {
    const { transport, sent } = makeTransport();
    const mux = new StreamMux(transport);
    const bus = new MessageBus();
    const handle = mux.attach(bus, {});

    // Inbound on the stream is the peer proving it holds a transport â€” the one
    // retraction that needs no cooperation from whoever muted it.
    mux.markUnbound(handle.streamId);
    expect(mux.dispatchInbound(handle.streamId, JSON.stringify(createMessage("pong", {})), "control", "phone-1")).toBe(true);
    bus.publish(createMessage("pong", {}), "control");
    expect(sent).toHaveLength(1);

    // A new session re-adverts every project and the app rebinds off that, so
    // the previous session's mute must not silence this one.
    mux.markUnbound(handle.streamId);
    bus.publish(createMessage("pong", {}), "control");
    expect(sent).toHaveLength(1);
    mux.notifyPeerOnline();
    bus.publish(createMessage("pong", {}), "control");
    expect(sent).toHaveLength(2);
  });

  test("markUnbound/markBound for an id we hold no stream for are no-ops", () => {
    // The notice races a detach: the app answers a frame we sent just before
    // the core shut down. Nothing to mute, and nothing to throw at the caller.
    const { transport } = makeTransport();
    const mux = new StreamMux(transport);
    expect(() => mux.markUnbound("deadbeefdeadbeef")).not.toThrow();
    expect(() => mux.markBound("deadbeefdeadbeef")).not.toThrow();
  });

  test("detach is idempotent", () => {
    const { transport, closed } = makeTransport();
    const mux = new StreamMux(transport);
    const handle = mux.attach(new MessageBus(), {});
    handle.detach();
    handle.detach();
    expect(closed).toEqual([handle.streamId]);
  });

  test("notifyPeerOnline/Offline broadcast to every attached stream; a late attach inherits an already-online session", () => {
    const { transport } = makeTransport();
    const mux = new StreamMux(transport);
    const events: string[] = [];
    mux.attach(new MessageBus(), {
      onPeerOnline: () => events.push("a-online"),
      onPeerOffline: () => events.push("a-offline"),
    });
    mux.notifyPeerOnline();
    expect(events).toEqual(["a-online"]);

    // Drill-in: a stream attached while already established never sees a
    // fresh peer-online event, so attach() must fire it immediately.
    mux.attach(new MessageBus(), { onPeerOnline: () => events.push("b-online") });
    expect(events).toEqual(["a-online", "b-online"]);

    mux.notifyPeerOffline();
    expect(events).toContain("a-offline");
  });

  test("detachAll tears every stream down", () => {
    const { transport, closed } = makeTransport();
    const mux = new StreamMux(transport);
    const a = mux.attach(new MessageBus(), {});
    const b = mux.attach(new MessageBus(), {});
    mux.detachAll();
    expect(closed.sort()).toEqual([a.streamId, b.streamId].sort());
  });

  // --- A2: projectBinding, routeTerminal, terminalHooks, projectDetached ---

  test("projectBinding returns the latest live entry for a projectId and null after detach", () => {
    const { transport } = makeTransport();
    const mux = new StreamMux(transport);
    expect(mux.projectBinding("p1")).toBeNull();

    const a = mux.attach(new MessageBus(), { projectId: "p1" });
    expect(mux.projectBinding("p1")?.streamId).toBe(a.streamId);

    // A second live entry for the same project (a reconnect race): the most
    // recently attached one wins.
    const b = mux.attach(new MessageBus(), { projectId: "p1" });
    expect(mux.projectBinding("p1")?.streamId).toBe(b.streamId);

    b.detach();
    expect(mux.projectBinding("p1")?.streamId).toBe(a.streamId);
    a.detach();
    expect(mux.projectBinding("p1")).toBeNull();
  });

  test("binding.dispatch re-runs mayAcceptFrom and reaches the bus as relay with the peerId", () => {
    const { transport, peers } = makeTransport();
    peers.set("stale", peerView("stale", false));
    peers.set("modern", peerView("modern", true));
    const mux = new StreamMux(transport);
    const bus = new MessageBus();
    const received: Array<{ msg: unknown; channel: Channel; source: string; peerId?: string }> = [];
    bus.setInboundHandler((msg, channel, source, peerId) => received.push({ msg, channel, source, peerId }));
    mux.attach(bus, { projectId: "p1", mayAcceptFrom: refuseIncapable });
    const binding = mux.projectBinding("p1")!;
    const msg = createMessage("pong", {});

    expect(binding.dispatch(msg, "stale")).toBe(false);
    expect(received).toEqual([]);

    expect(binding.dispatch(msg, "modern")).toBe(true);
    expect(received).toEqual([{ msg, channel: "control", source: "relay", peerId: "modern" }]);
  });

  test("routeTerminal runs only after mayDeliver, mayDeliverTo and unboundAtPeer allow the send", async () => {
    const { transport, routedCalls, peers } = makeTerminalTransport();
    peers.set("peer1", peerView("peer1", true));
    const mux = new StreamMux(transport);
    const bus = new MessageBus();
    let deliverAllowed = false;
    let deliverToAllowed = false;
    const handle = mux.attach(bus, {
      mayDeliver: () => deliverAllowed,
      mayDeliverTo: () => deliverToAllowed,
    });
    const msg = createMessage("pong", {});
    const attempt = () => bus.deliverTo(msg, "control", "relay", new AbortController().signal, "peer1");

    await expect(attempt()).rejects.toThrow("gated"); // mayDeliver refuses
    expect(routedCalls).toEqual([]);

    deliverAllowed = true;
    await expect(attempt()).rejects.toThrow("gated"); // mayDeliverTo refuses
    expect(routedCalls).toEqual([]);

    deliverToAllowed = true;
    mux.markUnbound(handle.streamId);
    await expect(attempt()).rejects.toThrow("gated"); // unboundAtPeer mute
    expect(routedCalls).toEqual([]);

    mux.markBound(handle.streamId);
    await attempt();
    expect(routedCalls.length).toBe(1);
    expect(routedCalls[0]!.peerId).toBe("peer1");
  });

  test("a routed send replaces sendEnvelope, and an undefined route falls back to it", () => {
    const { transport, routedCalls, sent, setRouter } = makeTerminalTransport();
    const mux = new StreamMux(transport);
    const bus = new MessageBus();
    const handle = mux.attach(bus, {});

    setRouter(() => Promise.resolve("sent"));
    const routedMsg = createMessage("pong", {});
    bus.publishOnly(routedMsg, "control", "relay", "peer1");
    expect(routedCalls.map((c) => c.msg)).toEqual([routedMsg]);
    expect(sent).toEqual([]); // routeTerminal replaced sendEnvelope entirely

    setRouter(() => undefined);
    const fallbackMsg = createMessage("pong", {});
    bus.publishOnly(fallbackMsg, "control", "relay", "peer1");
    expect(sent).toEqual([{ streamId: handle.streamId, msg: fallbackMsg, channel: "control" }]);
  });

  test("a routed non-sent outcome rejects a signalled delivery", async () => {
    const { transport, setRouter } = makeTerminalTransport();
    const mux = new StreamMux(transport);
    const bus = new MessageBus();
    mux.attach(bus, {});
    setRouter(() => Promise.resolve("dropped"));
    const msg = createMessage("pong", {});
    await expect(
      bus.deliverTo(msg, "control", "relay", new AbortController().signal, "peer1"),
    ).rejects.toThrow("Terminal delivery dropped");
  });

  test("detach calls projectDetached only when no other entry holds the project", () => {
    const { transport, projectDetachedCalls } = makeTerminalTransport();
    const mux = new StreamMux(transport);
    const a = mux.attach(new MessageBus(), { projectId: "p1" });
    const b = mux.attach(new MessageBus(), { projectId: "p1" });
    const c = mux.attach(new MessageBus(), { projectId: "p2" });

    a.detach();
    expect(projectDetachedCalls).toEqual([]); // b still holds p1

    b.detach();
    expect(projectDetachedCalls).toEqual(["p1"]);

    c.detach();
    expect(projectDetachedCalls).toEqual(["p1", "p2"]);
  });

  test("attach returns the transport's terminalHooks on the handle", () => {
    const { transport, hooks } = makeTerminalTransport();
    const mux = new StreamMux(transport);
    const handle = mux.attach(new MessageBus(), {});
    expect(handle.terminalHooks).toBe(hooks);
  });
});

// --- Integration: the real TestPeerSessionOwner driving the envelope over the wire ---

const AGENT_DEVICE_ID = "agent-1";
const PHONE_ID = "phone-1";

let clients: TestPeerSessionOwner[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

/** Establish a real session on a REAL (non-forTest) TestPeerSessionOwner.
 *  Unlike forTest() — which stubs the mux to a no-op for hello-only tests —
 *  this needs the real StreamMux wired to real sendJson/sendAppEnvelope, so it
 *  constructs the client normally and overrides `sendPayload` (same shadowing
 *  trick forTest uses) plus a stubbed OPEN socket so `sendJson`'s
 *  stream-open/close land in the same observable `sent` array as application
 *  traffic. */
function establish(): { client: TestPeerSessionOwner; sent: Array<string | Buffer> } {
  const sent: Array<string | Buffer> = [];
  const client = new TestPeerSessionOwner({
    identity: {
      deviceId: AGENT_DEVICE_ID, deviceName: "agent", createdAt: new Date().toISOString(),
      ed25519PublicKey: "unused", ed25519PrivateKey: ed25519Pair().seedB64,
    },
  });
  clients.push(client);
  client.setNativeWriter((p) => { sent.push(p); return true; });
  (client as any).ws = { readyState: WebSocket.OPEN, send: (d: string) => sent.push(d), close: () => {} };

  client.establish(PHONE_ID, { attemptId: "a1" });
  return { client, sent };
}

function parse(frame: string | Buffer): any {
  return JSON.parse(typeof frame === "string" ? frame : frame.toString("utf8"));
}

describe("StreamMux over a live TestPeerSessionOwner (wire-level envelope tagging)", () => {
  test("attach admits the host-local binding immediately", () => {
    const { client } = establish();
    const admitted: string[] = [];
    const handle = client.attachStream(new MessageBus(), {
      onAdmitted: (id) => admitted.push(id),
    });
    expect(admitted).toEqual([handle.streamId]);
  });

  test("outbound: a bus publish on an attached stream is sent as {s: streamId, m: msg}", () => {
    const { client, sent } = establish();
    const bus = new MessageBus();
    const handle = client.attachStream(bus, {});
    const sentBefore = sent.length;

    const msg = createMessage("pong", {});
    bus.publish(msg, "control");

    expect(sent.length).toBe(sentBefore + 1);
    const envelope = parse(sent[sent.length - 1]!);
    expect(envelope.s).toBe(handle.streamId);
    expect(envelope.m).toEqual(msg);
  });

  test("inbound: a {s: streamId, m} envelope is routed to the matching stream's bus", () => {
    const { client } = establish();
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((m) => received.push(m));
    const handle = client.attachStream(bus, {});

    const msg = createMessage("pong", {});
    client.sendFromPeer(PHONE_ID, { s: handle.streamId, m: msg });

    expect(received).toEqual([msg]);
  });

  test("inbound envelope for an unknown streamId is dropped (no stream sees it) and answered with a control-plane stream-invalid", () => {
    const { client, sent } = establish();
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((m) => received.push(m));
    client.attachStream(bus, {});
    sent.length = 0;

    client.sendFromPeer(PHONE_ID, { s: "deadbeefdeadbeef", m: createMessage("pong", {}) });

    expect(received).toEqual([]);
    // The notice rides the control plane (`s` omitted), so the phone reads it
    // without a stream binding â€” which is the whole point: it has none.
    const replies = sent.filter((s): s is Buffer => Buffer.isBuffer(s));
    expect(replies).toHaveLength(1);
    const envelope = parse(replies[0]!);
    expect(envelope.s).toBeUndefined();
    expect(envelope.m).toMatchObject({ type: "stream-invalid", streamId: "deadbeefdeadbeef" });
  });

  test("a fragmented inbound envelope reassembles with `s` intact", () => {
    const { client } = establish();
    const bus = new MessageBus();
    const received: unknown[] = [];
    bus.setInboundHandler((m) => received.push(m));
    const handle = client.attachStream(bus, {});

    const bigMsg = createMessage("file:content", {
      projectId: "p1", path: "a.txt", content: "x".repeat(5000), size: 5000, encoding: "utf8",
    });
    const envelopeJson = JSON.stringify({ s: handle.streamId, m: bigMsg });
    // A tiny budget forces multiple fragments even for this modest payload.
    const frames = buildFragments(envelopeJson, "rx-1", undefined, 500);
    expect(frames.length).toBeGreaterThan(1);

    for (const frame of frames) {
      client.sendFromPeer(PHONE_ID, frame);
    }

    expect(received).toEqual([bigMsg]);
  });


});
