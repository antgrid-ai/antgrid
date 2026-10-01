import { test, expect, describe, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { MessageBus } from "../src/message-bus";
import { ProjectCore } from "../src/project-core";
import { REVOKE_NOTICE_BUDGET_MS, ScreenRelay, type ScreenRelayDeps } from "../src/screen-relay";
import { createMessage, type AbMessage } from "../src/protocol";
import type { AgentCore } from "../src/agent-core";
import { fakeRemoteDeps, fakeStreamHandle } from "./relay-stubs";

const PHONE_A = "phone-a#machine";
const PHONE_B = "phone-b#machine";

interface Switches {
  remoteAccess: boolean;
  screenControl: boolean;
  hasOwner: boolean;
}

/** A real bus with the two kinds of wire a promoted core carries. The host is
 *  the loopback owner. The viewers share ONE relay-audience subscriber, keyed
 *  by the `peerId` a publish names, because that is how project-streams.ts
 *  subscribes a project stream: a targeted publish reaches that peer's binding
 *  alone, an untargeted one every bound peer. */
function harness(over: Partial<Switches> = {}, wired = true) {
  const switches: Switches = { remoteAccess: true, screenControl: true, hasOwner: true, ...over };
  const bus = new MessageBus();
  const host: AbMessage[] = [];
  const viewers = new Map<string, AbMessage[]>([[PHONE_A, []], [PHONE_B, []]]);
  bus.subscribe({ audience: "loopback", deliver: (msg) => { host.push(msg); } });
  bus.subscribe({
    audience: "relay",
    deliver: (msg, _channel, _signal, peerId) => {
      for (const [id, inbox] of viewers) if (peerId === undefined || peerId === id) inbox.push(msg);
    },
  });
  const deps: ScreenRelayDeps = { bus, hasOwner: () => switches.hasOwner };
  if (wired) {
    deps.remoteAccessEnabled = () => switches.remoteAccess;
    deps.screenControlEnabled = () => switches.screenControl;
  }
  const relay = new ScreenRelay(deps);
  return {
    relay,
    switches,
    host,
    viewer: (id: string) => viewers.get(id)!,
    fromViewer: (msg: AbMessage, peerId?: string) => relay.handleInbound(msg, "control", "relay", peerId),
    fromHost: (msg: AbMessage) => relay.handleInbound(msg, "control", "loopback"),
  };
}

const request = (extra: Record<string, unknown> = {}) =>
  createMessage("screen:request", { projectId: "proj", ...extra });
const offerTo = (viewerId?: string) =>
  createMessage("screen:offer", {
    sdp: "v=0", dtlsFingerprint: "sha-256 AA", width: 100, height: 100,
    ...(viewerId ? { viewerId } : {}),
  });

describe("ScreenRelay", () => {
  test("a viewer's frame reaches the host alone, stamped with the viewer's peer id over any it forged", () => {
    const h = harness();
    expect(h.fromViewer(request({ viewerId: PHONE_B }), PHONE_A)).toBe(true);

    expect(h.host).toHaveLength(1);
    expect(h.host[0]).toMatchObject({ type: "screen:request", viewerId: PHONE_A });
    // No echo to the sender, and nothing for a sibling viewer.
    expect(h.viewer(PHONE_A)).toHaveLength(0);
    expect(h.viewer(PHONE_B)).toHaveLength(0);
  });

  test("a relay frame with no peer id has nowhere to be answered and is dropped", () => {
    const h = harness();
    expect(h.fromViewer(request())).toBe(true);
    expect(h.host).toHaveLength(0);
    expect(h.viewer(PHONE_A)).toHaveLength(0);
  });

  test("a host frame with no viewerId is dropped rather than broadcast", () => {
    const h = harness();
    h.fromViewer(request(), PHONE_A);
    h.host.length = 0;

    expect(h.fromHost(offerTo())).toBe(true);
    expect(h.viewer(PHONE_A)).toHaveLength(0);
    expect(h.viewer(PHONE_B)).toHaveLength(0);
    expect(h.host).toHaveLength(0);
  });

  test("a host frame reaches only the viewer it names", () => {
    const h = harness();
    h.fromViewer(request(), PHONE_A);
    h.fromViewer(request(), PHONE_B);
    h.host.length = 0;

    h.fromHost(offerTo(PHONE_A));
    expect(h.viewer(PHONE_A)).toHaveLength(1);
    expect(h.viewer(PHONE_A)[0]).toMatchObject({ type: "screen:offer", viewerId: PHONE_A });
    // The session description is PHONE_A's; PHONE_B must never see it.
    expect(h.viewer(PHONE_B)).toHaveLength(0);
    expect(h.host).toHaveLength(0);
  });

  const closedCases: Array<[string, Partial<Switches>, boolean]> = [
    ["remote access off", { remoteAccess: false }, true],
    ["screen control off", { screenControl: false }, true],
    ["switches unwired", {}, false],
  ];
  for (const [label, switches, wired] of closedCases) {
    test(`${label}: both directions drop, except the host's ended state`, () => {
      const h = harness(switches, wired);

      h.fromViewer(request(), PHONE_A);
      expect(h.host).toHaveLength(0);
      // Not even a no-host answer: a closed switch discloses nothing.
      expect(h.viewer(PHONE_A)).toHaveLength(0);

      h.fromHost(offerTo(PHONE_A));
      h.fromHost(createMessage("screen:state", { status: "live", viewerId: PHONE_A }));
      expect(h.viewer(PHONE_A)).toHaveLength(0);

      h.fromHost(createMessage("screen:state", { status: "ended", reason: "off", viewerId: PHONE_A }));
      expect(h.viewer(PHONE_A)).toHaveLength(1);
      expect(h.viewer(PHONE_A)[0]).toMatchObject({ type: "screen:state", status: "ended" });
      expect(h.viewer(PHONE_B)).toHaveLength(0);
    });
  }

  test("a switch flipped on an already-built relay takes effect on the next frame", () => {
    const h = harness();
    h.fromViewer(request(), PHONE_A);
    expect(h.host).toHaveLength(1);

    h.switches.screenControl = false;
    h.fromViewer(request(), PHONE_A);
    expect(h.host).toHaveLength(1);
  });

  test("with no host connected the viewer is told no-host, and only that viewer", () => {
    const h = harness({ hasOwner: false });
    h.fromViewer(request(), PHONE_A);

    expect(h.host).toHaveLength(0);
    expect(h.viewer(PHONE_A)).toHaveLength(1);
    expect(h.viewer(PHONE_A)[0]).toMatchObject({ type: "screen:state", status: "no-host", viewerId: PHONE_A });
    expect(h.viewer(PHONE_B)).toHaveLength(0);
    // It never reached a host, so its later departure is nothing to report.
    h.relay.clientGone(PHONE_A);
    expect(h.host).toHaveLength(0);
  });

  test("a viewer whose session closed is reported to the host once", () => {
    const h = harness();
    h.fromViewer(request(), PHONE_A);
    h.host.length = 0;

    h.relay.clientGone(PHONE_A);
    expect(h.host).toHaveLength(1);
    expect(h.host[0]).toMatchObject({ type: "screen:stop", reason: "viewer-gone", viewerId: PHONE_A });
    expect(h.viewer(PHONE_A)).toHaveLength(0);

    h.relay.clientGone(PHONE_A);
    expect(h.host).toHaveLength(1);
  });

  test("a peer that never reached the host leaves without a word", () => {
    const h = harness();
    h.fromViewer(request(), PHONE_A);
    h.host.length = 0;

    h.relay.clientGone(PHONE_B);
    expect(h.host).toHaveLength(0);
    expect(h.viewer(PHONE_B)).toHaveLength(0);
  });

  test("a viewer the host already stopped is not reported gone", () => {
    const h = harness();
    h.fromViewer(request(), PHONE_A);
    h.fromHost(createMessage("screen:stop", { reason: "window closed", viewerId: PHONE_A }));
    h.host.length = 0;

    h.relay.clientGone(PHONE_A);
    expect(h.host).toHaveLength(0);
  });

  test("the host leaving tells every known viewer no-host, once", () => {
    const h = harness();
    h.fromViewer(request(), PHONE_A);
    h.fromViewer(request(), PHONE_B);
    h.host.length = 0;

    h.relay.clientGone("loopback");
    for (const id of [PHONE_A, PHONE_B]) {
      expect(h.viewer(id)).toHaveLength(1);
      expect(h.viewer(id)[0]).toMatchObject({ type: "screen:state", status: "no-host", viewerId: id });
    }
    expect(h.host).toHaveLength(0);

    h.relay.clientGone("loopback");
    expect(h.viewer(PHONE_A)).toHaveLength(1);
    expect(h.viewer(PHONE_B)).toHaveLength(1);
  });

  test("revokeAll stops the host's capture and ends each viewer's picture, then forgets them", async () => {
    const h = harness();
    h.fromViewer(request(), PHONE_A);
    h.fromViewer(request(), PHONE_B);
    h.host.length = 0;

    await h.relay.revokeAll("screen control turned off");
    // One stop naming no viewer: the host ends whatever it runs.
    expect(h.host).toHaveLength(1);
    expect(h.host[0]).toMatchObject({ type: "screen:stop", reason: "screen control turned off" });
    expect(h.host[0]).not.toHaveProperty("viewerId");
    for (const id of [PHONE_A, PHONE_B]) {
      expect(h.viewer(id)).toHaveLength(1);
      expect(h.viewer(id)[0]).toMatchObject({
        type: "screen:state", status: "ended", reason: "screen control turned off", viewerId: id,
      });
    }

    h.relay.clientGone(PHONE_A);
    expect(h.host).toHaveLength(1);
    await h.relay.revokeAll("again");
    expect(h.viewer(PHONE_A)).toHaveLength(1);
  });

  test("revokeAll reaches a capture whose viewer the relay forgot when the host reconnected", async () => {
    const h = harness();
    h.fromViewer(request(), PHONE_A);
    // The host's socket drops and comes back; its peer connection, and the
    // input channel riding it, never went through the bridge and survive.
    h.relay.clientGone("loopback");
    h.host.length = 0;

    await h.relay.revokeAll("remote access turned off");
    expect(h.host).toHaveLength(1);
    expect(h.host[0]).toMatchObject({ type: "screen:stop", reason: "remote access turned off" });
  });

  test("revokeAll gives up on a stalled viewer stream after its budget", async () => {
    const bus = new MessageBus();
    bus.subscribe({ audience: "loopback", deliver: () => {} });
    bus.subscribe({ audience: "relay", deliver: () => new Promise<void>(() => {}) });
    const relay = new ScreenRelay({
      bus, hasOwner: () => true, remoteAccessEnabled: () => true, screenControlEnabled: () => true,
    });
    relay.handleInbound(request(), "control", "relay", PHONE_A);

    const started = Date.now();
    await relay.revokeAll("screen control turned off");
    expect(Date.now() - started).toBeGreaterThanOrEqual(REVOKE_NOTICE_BUDGET_MS - 10);
  });

  test("a viewer that stopped its own session is not told when the host goes away", () => {
    const h = harness();
    h.fromViewer(request(), PHONE_A);
    h.fromViewer(createMessage("screen:stop", { reason: "closed" }), PHONE_A);
    expect(h.host.at(-1)).toMatchObject({ type: "screen:stop", viewerId: PHONE_A });

    h.relay.clientGone("loopback");
    expect(h.viewer(PHONE_A)).toHaveLength(0);
  });

  test("a non-screen frame is left to the caller's dispatch", () => {
    const h = harness();
    const focus = createMessage("client:focus-state", { paused: true });
    expect(h.fromViewer(focus, PHONE_A)).toBe(false);
    expect(h.fromHost(focus)).toBe(false);
    expect(h.host).toHaveLength(0);
    expect(h.viewer(PHONE_A)).toHaveLength(0);
  });
});

describe("ProjectCore screen routing", () => {
  let cleanup: Array<() => void | Promise<unknown>> = [];
  // LIFO + awaited, matching project-core.test.ts: cores stop their file
  // watchers before the folder they watch is rm'd.
  afterEach(async () => { for (const fn of cleanup.splice(0).reverse()) try { await fn(); } catch {} });

  /** A local core promoted onto a project stream whose relay-audience subscriber
   *  records every frame with the peer it was addressed to. */
  async function promotedCore() {
    const folder = mkdtempSync(join(tmpdir(), "antgrid-screen-"));
    cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
    writeFileSync(join(folder, "antgrid.yaml"), "");

    const core = new ProjectCore({
      folder,
      mode: "local",
      identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
      remoteAccessEnabled: () => true,
      screenControlEnabled: () => true,
    });
    cleanup.push(() => core.shutdown());
    await core.start();

    const outbound: Array<{ msg: AbMessage; peerId?: string }> = [];
    const { deps, calls } = fakeRemoteDeps({
      attachStream: (bus, opts) => {
        calls.push({ bus, opts });
        const unsub = bus.subscribe({
          audience: "relay",
          deliver: (msg, _channel, _signal, peerId) => { outbound.push({ msg, peerId }); },
        });
        return fakeStreamHandle({ detach: unsub });
      },
    });
    const promotion = core.promote(deps);
    cleanup.push(() => promotion.stop());
    return { core, bus: calls[0].bus, opts: calls[0].opts, outbound };
  }

  /** Connect the desktop capture host over the core's real loopback socket. */
  async function connectOwner(core: ProjectCore) {
    const info = core.localConnectInfo!;
    const received: any[] = [];
    const ws = new WebSocket(`ws://127.0.0.1:${info.port}`);
    await new Promise<void>((resolve, reject) => {
      ws.onopen = () => resolve();
      ws.onerror = (e) => reject(e);
    });
    let ready!: () => void;
    const readied = new Promise<void>((r) => { ready = r; });
    ws.onmessage = (ev) => {
      const frame = JSON.parse(String(ev.data));
      if (frame.type === "ready") { ready(); return; }
      received.push(frame);
    };
    ws.send(JSON.stringify({ type: "hello", token: info.token, appPid: 1, appVersion: "test" }));
    await readied;
    cleanup.push(() => ws.close());
    return { ws, screen: () => received.filter((f) => String(f.type).startsWith("screen:")) };
  }

  const screenOut = (outbound: Array<{ msg: AbMessage; peerId?: string }>) =>
    outbound.filter((o) => o.msg.type.startsWith("screen:"));

  /** Bus delivery is synchronous; the loopback hop is a real socket. */
  const settle = () => new Promise((r) => setTimeout(r, 50));

  test("a viewer's request reaches the owner stamped, and the owner's answer goes back to that peer", async () => {
    const { core, bus, outbound } = await promotedCore();
    const owner = await connectOwner(core);

    bus.dispatchInbound(request({ projectId: core.projectId }), "control", "relay", PHONE_A);
    await settle();
    expect(owner.screen()).toHaveLength(1);
    expect(owner.screen()[0]).toMatchObject({ type: "screen:request", viewerId: PHONE_A });
    expect(screenOut(outbound)).toHaveLength(0);

    owner.ws.send(JSON.stringify({ channel: "control", ...offerTo(PHONE_A) }));
    await settle();
    const sent = screenOut(outbound);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({ msg: { type: "screen:offer", viewerId: PHONE_A }, peerId: PHONE_A });
    // The owner's own frame does not come back to it.
    expect(owner.screen()).toHaveLength(1);
  });

  test("a closed project stream reaches the relay through noteClientGone", async () => {
    const { core, bus, opts } = await promotedCore();
    const owner = await connectOwner(core);
    bus.dispatchInbound(request({ projectId: core.projectId }), "control", "relay", PHONE_A);
    await settle();

    opts.onPeerStreamClosed?.(PHONE_A);
    await settle();
    expect(owner.screen().at(-1)).toMatchObject({ type: "screen:stop", reason: "viewer-gone", viewerId: PHONE_A });
  });

  test("revokeScreenSharing stops the owner's capture and ends the viewer's picture", async () => {
    const { core, bus, outbound } = await promotedCore();
    const owner = await connectOwner(core);
    bus.dispatchInbound(request({ projectId: core.projectId }), "control", "relay", PHONE_A);
    await settle();

    await core.revokeScreenSharing("screen control turned off");
    await settle();
    expect(owner.screen().at(-1)).toMatchObject({ type: "screen:stop", reason: "screen control turned off" });
    expect(owner.screen().at(-1)).not.toHaveProperty("viewerId");
    expect(screenOut(outbound)).toEqual([
      { msg: expect.objectContaining({ type: "screen:state", status: "ended", viewerId: PHONE_A }), peerId: PHONE_A },
    ]);
  });

  test("a non-screen frame from a relay peer reaches the core's dispatch under that peer's id", async () => {
    const { core, bus } = await promotedCore();
    await connectOwner(core);

    bus.dispatchInbound(createMessage("client:focus-state", { paused: true }), "control", "relay", PHONE_A);
    await settle();

    // Read state is keyed per client: a peer id lost in the wrapped handler
    // would file this under the anonymous "relay" key instead.
    const agent = (core as unknown as { core: AgentCore }).core;
    expect(agent.clientFocusPaused(PHONE_A)).toBe(true);
    expect(agent.clientFocusPaused("relay")).toBeUndefined();
  });
});
