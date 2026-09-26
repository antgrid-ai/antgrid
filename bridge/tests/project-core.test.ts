import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { ProjectCore, type ProjectCoreRemoteDeps } from "../src/project-core";
import { computeProjectId } from "../src/project-id";
import { MessageBus } from "../src/message-bus";
import type { AttachStreamOpts, StreamHandle, TerminalStreamHooks } from "../src/project-streams";
import type { ConnState } from "../src/conn-state";
import { createMessage, type AbMessage } from "../src/protocol";
import { SessionDirectory } from "../src/session-bus/directory";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";
import type { WorkStatusState } from "../src/work-status";

let cleanup: Array<() => void | Promise<unknown>> = [];
// LIFO + awaited: cores shut down (stopping their file watchers) before the
// project folder they watch is rm'd — FIFO deleted the folder under a live
// chokidar watcher, which throws asynchronously between tests.
afterEach(async () => { for (const fn of cleanup.splice(0).reverse()) try { await fn(); } catch {} });

/** A ProjectCoreRemoteDeps stub whose `attachStream` captures the bus + opts
 *  it was called with (instead of a live machine socket) — the seam v3 uses
 *  in place of the deleted per-core `makeRelayClient`/RelayClientOptions hook. */
function fakeRemoteDeps(): { deps: ProjectCoreRemoteDeps; calls: Array<{ bus: MessageBus; opts: AttachStreamOpts }> } {
  const calls: Array<{ bus: MessageBus; opts: AttachStreamOpts }> = [];
  const deps: ProjectCoreRemoteDeps = {
    attachStream: (bus, opts) => {
      calls.push({ bus, opts });
      const handle: StreamHandle = {
        detach: () => {},
        sendTo: async () => "sent" as const,
        deliverableTo: () => true,
      };
      return handle;
    },
    establishedPeers: () => [],
    peerSession: () => null,
    machineDeviceId: () => "machine-uuid",
    sendPushDeliver: () => {},
  };
  return { deps, calls };
}

test("local ProjectCore.start binds a listener and exposes connect info", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  const projectId = computeProjectId(folder);

  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
  });
  cleanup.push(() => core.shutdown());

  await core.start();

  expect(core.projectId).toBe(projectId);
  expect(core.localConnectInfo?.port).toBeGreaterThan(0);
  expect(core.localConnectInfo?.token).toBeTruthy();
});

test("remote ProjectCore.start throws without remote deps", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-r-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  const core = new ProjectCore({
    folder,
    mode: "remote",
    identity: {
      deviceId: randomUUID(), deviceName: "d", createdAt: new Date().toISOString(),
      ed25519PublicKey: "AAAA", ed25519PrivateKey: "AAAA",
    },
    // remote deps deliberately omitted
  });
  await expect(core.start()).rejects.toThrow(/remote deps/i);
});

test("local ProjectCore.shutdown tears down the listener", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-sd-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  const core = new ProjectCore({
    folder, mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
  });
  await core.start();
  expect(core.localConnectInfo?.port).toBeGreaterThan(0);
  await expect(core.shutdown()).resolves.toBeUndefined();
});

test("promoting a LOCAL core attaches its bus as a stream and reflects the admission outcome", async () => {
  // v3: promote() no longer builds its own RelayClient with a machine identity
  // — it attaches the core's EXISTING bus as a stream on the host's
  // one machine socket via ProjectCoreRemoteDeps.attachStream. isRelayRegistered()
  // and firstRegister tracks host-local admission.
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-promo-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");

  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
  });
  cleanup.push(() => core.shutdown());
  await core.start();
  expect(core.isRelayRegistered()).toBe(false);

  const { deps, calls } = fakeRemoteDeps();
  const handle = core.promote(deps);

  expect(calls.length).toBe(1); // attached exactly once, on THIS core's bus
  calls[0].opts.onAdmitted?.();

  expect(core.isRelayRegistered()).toBe(true);
  await expect(handle.firstRegister).resolves.toBeUndefined();

  handle.stop();
  expect(core.isRelayRegistered()).toBe(false);
});

test("the project stream a core attaches refuses a sender with no session and fails delivery closed", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-gate-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");

  let remoteOn = false;
  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
    remoteAccessEnabled: () => remoteOn,
  });
  cleanup.push(() => core.shutdown());
  await core.start();

  const { deps, calls } = fakeRemoteDeps();
  const handle = core.promote(deps);
  cleanup.push(() => handle.stop());
  const { opts } = calls[0];

  // A stream open (or inbound record) whose peer resolves to no session must
  // be refused, never admitted with nothing to route by.
  expect(opts.mayAcceptFrom?.(null)).toEqual({ code: "NOT_ALLOWED", message: "no session for this peer" });
  expect(opts.mayAcceptFrom?.({ peerId: "app#machine", peerPubkey: "pk" })).toBeNull();

  // Outbound is gated live on the machine switch, per send.
  expect(opts.mayDeliver?.()).toBe(false);
  remoteOn = true;
  expect(opts.mayDeliver?.()).toBe(true);
});

test("promote() throws for a remote-mode core (its relay slot is already the primary session)", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-promo-remote-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");

  const { deps } = fakeRemoteDeps();
  const core = new ProjectCore({
    folder,
    mode: "remote",
    identity: {
      deviceId: randomUUID(), deviceName: "d", createdAt: new Date().toISOString(),
      ed25519PublicKey: "AAAA", ed25519PrivateKey: "AAAA",
    },
    remote: deps,
  });
  cleanup.push(() => core.shutdown());
  await core.start();

  expect(() => core.promote(deps)).toThrow(/cannot promote a remote-mode core/i);
});

test("peer-offline suppresses the shared stream ONLY when no loopback owner is attached", async () => {
  // Regression: connState gates every bus subscriber at the source, so flipping
  // peerOnline=false on a phone disconnect while a desktop owner shares it over
  // loopback would freeze the local session. onPeerOffline must guard on hasOwner.
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-peeroff-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");

  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
  });
  cleanup.push(() => core.shutdown());
  await core.start();
  const { deps, calls } = fakeRemoteDeps();
  core.promote(deps);

  const opts = calls[0].opts;
  // White-box: connState isn't public and hasOwner needs a live socket — fake both.
  const connState = (core as unknown as { core: { connState: ConnState } }).core.connState;
  const listener = (core as unknown as { listener: { ownerSocket: unknown } }).listener;

  // No owner → phone is sole consumer → suppress on offline, restore on online.
  listener.ownerSocket = null;
  opts.onPeerOffline?.();
  expect(connState.peerOnline).toBe(false);
  opts.onPeerOnline?.();
  expect(connState.peerOnline).toBe(true);

  // Owner attached over loopback → a phone drop must NOT suppress the shared bus.
  listener.ownerSocket = {};
  opts.onPeerOffline?.();
  expect(connState.peerOnline).toBe(true);
});

test("deleteSession returns false before start (no live core)", () => {
  const pc = new ProjectCore({
    folder: ".", mode: "local",
    identity: { deviceId: "d", deviceName: "d", createdAt: "2026-01-01T00:00:00.000Z" },
  } as any);
  expect(pc.deleteSession("any")).toBe(false);
});

test("remote-mode core also binds loopback (connect is non-null) and attaches its bus as the primary stream", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-rem-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  // Remote mode skips the interactive setup wizard only when a config file exists.
  // An empty yaml is valid (loadConfig returns DEFAULT_CONFIG = {}).
  writeFileSync(join(folder, "antgrid.yaml"), "");
  const { deps, calls } = fakeRemoteDeps();
  const core = new ProjectCore({
    folder,
    mode: "remote",
    identity: {
      deviceId: randomUUID(), deviceName: "d", createdAt: new Date().toISOString(),
      ed25519PublicKey: "AAAA", ed25519PrivateKey: "AAAA",
    },
    remote: deps,
  });
  cleanup.push(() => core.shutdown());

  await core.start();

  expect(core.localConnectInfo).not.toBeNull();
  expect(core.localConnectInfo?.port).toBeGreaterThan(0);
  expect(core.localConnectInfo?.token).toBeTruthy();
  expect(calls.length).toBe(1); // the primary remote stream attached at start()

  calls[0].opts.onAdmitted?.();
  expect(core.isRelayRegistered()).toBe(true);
});

const WAIT_MS = 20_000;

async function waitFor(predicate: () => boolean, what: string, timeoutMs = WAIT_MS): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

test("onSessionsChange fires on a rename but not on the create that established the baseline", async () => {
  // Regression for the cross-device sync gap: a rename moves neither
  // workStatus, workRunningCount nor sessionWorkStatuses, so onWorkStatusChange
  // alone never tells a cold peeker (a device with this project's drawer
  // collapsed) that a session's NAME changed. onSessionsChange exists
  // specifically to catch that, via a content diff on `session:updated` — see
  // ProjectCore.observeSessionsIdentity.
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-sess-change-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");
  const { deps, calls } = fakeRemoteDeps();
  const core = new ProjectCore({
    folder,
    mode: "remote",
    identity: {
      deviceId: randomUUID(), deviceName: "d", createdAt: new Date().toISOString(),
      ed25519PublicKey: "AAAA", ed25519PrivateKey: "AAAA",
    },
    remote: deps,
  });
  cleanup.push(() => core.shutdown());
  await core.start();

  const bus = calls[0].bus;
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  let sessionsChanges = 0;
  core.onSessionsChange(() => { sessionsChanges++; });

  const createId = randomUUID();
  bus.dispatchInbound(createMessage("session:create", {
    requestId: createId, name: "Original name", command: "node keepalive.js",
  }) as any, "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "session:result" && (m as any).requestId === createId),
    "the session:create result",
  );
  const created = sent.find((m) => m.type === "session:result" && (m as any).requestId === createId) as any;
  expect(created.ok).toBe(true);
  const sessionId = created.session.id as string;

  // The create's own session:updated seeds observeSessionsIdentity's baseline
  // (never having seen this project's list before), so it must not count as a
  // "change" in the sense onSessionsChange exists for — a fresh project's
  // first advert already goes out unconditionally on open (host-server.ts).
  const changesAfterCreate = sessionsChanges;

  const renameId = randomUUID();
  bus.dispatchInbound(createMessage("session:rename", {
    requestId: renameId, sessionId, name: "Renamed",
  }) as any, "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "session:result" && (m as any).requestId === renameId),
    "the session:rename result",
  );

  expect(sessionsChanges).toBeGreaterThan(changesAfterCreate);
});

test("a core built with sessionDirectory deps answers session-bus:directory instead of refusing AGENT_NOT_READY", async () => {
  // api-server-session-bus.test.ts injects a SessionDirectory straight into
  // createSessionBusApi, which skips the exact wiring this pins: ProjectCore
  // must forward its sessionDirectory dep into buildAgentCore for the bus to
  // ever see one. Going through a real ProjectCore is the only way to catch a
  // dropped forward — a directory injected below the core would stay green
  // even with the forward deleted.
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-bus-dir-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");
  const { deps, calls } = fakeRemoteDeps();

  const projectId = computeProjectId(folder);
  const siblingId = randomUUID();
  const directory = new SessionDirectory({
    repoKeys: {
      keyFor: (id) => (id === projectId ? "github.com/owner/repo" : null),
      probed: () => true,
      projectsSharing: (key) => (key === "github.com/owner/repo" ? [projectId] : []),
    },
    sessionIndex: {
      *sessionsIn(id) {
        if (id !== projectId) return;
        yield {
          entry: {
            id: siblingId,
            name: "Sibling session",
            running: true,
            archived: false,
            deleting: false,
            lastUsedAt: Date.now(),
            tool: "claude-code",
          } as any,
        };
      },
    },
    projectPath: () => undefined,
    machineId: () => "machine-uuid",
  });

  const core = new ProjectCore({
    folder,
    mode: "remote",
    identity: {
      deviceId: randomUUID(), deviceName: "d", createdAt: new Date().toISOString(),
      ed25519PublicKey: "AAAA", ed25519PrivateKey: "AAAA",
    },
    remote: deps,
    sessionDirectory: directory,
  });
  cleanup.push(() => core.shutdown());
  await core.start();

  const bus = calls[0].bus;
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });

  const createId = randomUUID();
  bus.dispatchInbound(createMessage("session:create", {
    requestId: createId, name: "Asking session", command: "node keepalive.js",
  }) as any, "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "session:result" && (m as any).requestId === createId),
    "the session:create result",
  );
  const created = sent.find((m) => m.type === "session:result" && (m as any).requestId === createId) as any;
  expect(created.ok).toBe(true);
  const sessionId = created.session.id as string;

  const dirRequestId = randomUUID();
  bus.dispatchInbound(createMessage("session-bus:directory", {
    requestId: dirRequestId, sessionId,
  }) as any, "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "session-bus:directory:result" && (m as any).requestId === dirRequestId),
    "the session-bus:directory:result",
  );
  const result = sent.find((m) => m.type === "session-bus:directory:result" && (m as any).requestId === dirRequestId) as any;

  // Not just "not AGENT_NOT_READY" — a directory that fails closed for an
  // unrelated reason (e.g. a repo key that never probed) would pass that
  // weaker check while still proving nothing about the forward under test.
  expect(result.code).toBeUndefined();
  expect(result.sessions).toEqual([expect.objectContaining({ sessionId: siblingId })]);
});

test("attachRelayStream wires handle.terminalHooks into the core, and every teardown clears them", async () => {
  // Both of attachRelayStream's callers (startRemote, promote) share this one
  // wiring — promote() is used here only because it is the one whose handle
  // stays reachable after its own teardown, to prove the clear actually took.
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-term-hooks-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");

  const retired: Array<{ peerId: string; attachmentId: string }> = [];
  const settled: Array<{ peerId: string; requestId: string; attachmentId: string | undefined }> = [];
  const hooks: TerminalStreamHooks = {
    retired: (peerId, attachmentId) => retired.push({ peerId, attachmentId }),
    subscribeSettled: (peerId, requestId, attachmentId) => settled.push({ peerId, requestId, attachmentId }),
  };
  const calls: Array<{ bus: MessageBus; opts: AttachStreamOpts }> = [];
  const deps: ProjectCoreRemoteDeps = {
    attachStream: (bus, opts) => {
      calls.push({ bus, opts });
      const handle: StreamHandle = {
        detach: () => {},
        sendTo: async () => "sent" as const,
        deliverableTo: () => true,
        terminalHooks: hooks,
      };
      return handle;
    },
    establishedPeers: () => [],
    peerSession: () => null,
    machineDeviceId: () => "machine-uuid",
    sendPushDeliver: () => {},
  };

  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
    remoteAccessEnabled: () => true,
  });
  cleanup.push(() => core.shutdown());
  await core.start();

  const bus = (core as unknown as { bus: MessageBus }).bus;
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  bus.dispatchInbound(createMessage("terminal:start", { terminalId: "adhoc", cwd: tmpdir() }) as any, "control", "loopback");
  await waitFor(() => sent.some((m) => m.type === "terminal:started" && (m as any).terminalId === "adhoc"), "terminal:started");

  const promoted = core.promote(deps);
  expect(calls.length).toBe(1);
  calls[0].opts.onAdmitted?.();

  // A promoted LOCAL core's inbound handler is startLocal()'s promotion
  // wrapper; the hooks are keyed by peerId, so the wrapper must pass it on.
  const requestId = randomUUID();
  bus.dispatchInbound(
    createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId }) as any,
    "control", "relay", "phone-1",
  );
  await waitFor(() => settled.some((s) => s.requestId === requestId), "subscribeSettled after promotion");
  expect(settled).toEqual([{ peerId: "phone-1", requestId, attachmentId: expect.any(String) }]);
  const attachmentId = settled[0].attachmentId!;

  // Teardown: promote()'s stop() must clear the hooks it wired, same as
  // ProjectCore.shutdown does for startRemote's binding.
  promoted.stop();

  bus.dispatchInbound(
    createMessage("terminal:unsubscribe", { terminalId: "adhoc", runId: "adhoc", attachmentId }) as any,
    "control", "relay", "phone-1",
  );
  await new Promise((resolve) => setTimeout(resolve, 150));
  expect(retired).toEqual([]);

  const secondRequestId = randomUUID();
  bus.dispatchInbound(
    createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId: secondRequestId }) as any,
    "control", "relay", "phone-2",
  );
  await new Promise((resolve) => setTimeout(resolve, 150));
  expect(settled.some((s) => s.requestId === secondRequestId)).toBe(false);
});

test("sendToAppSession returns false and sends nothing when deliverableTo(peer) is false", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-deliverable-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");

  const sendCalls: Array<{ peerId: string }> = [];
  let deliverable = false;
  const deps: ProjectCoreRemoteDeps = {
    attachStream: (_bus, _opts) => ({
      detach: () => {},
      sendTo: async (_msg, _channel, target) => {
        sendCalls.push({ peerId: (target as { peerId: string }).peerId });
        return "sent" as const;
      },
      deliverableTo: () => deliverable,
    }),
    establishedPeers: () => [],
    peerSession: () => null,
    machineDeviceId: () => "machine-uuid",
    sendPushDeliver: () => {},
  };

  const core = new ProjectCore({
    folder,
    mode: "remote",
    identity: {
      deviceId: randomUUID(), deviceName: "d", createdAt: new Date().toISOString(),
      ed25519PublicKey: "AAAA", ed25519PrivateKey: "AAAA",
    },
    remote: deps,
  });
  cleanup.push(() => core.shutdown());
  await core.start();

  const msg = createMessage("terminal:display:status", {
    terminalId: "t", code: "ACK_TIMEOUT", message: "Reconnect",
  }) as AbMessage;

  // Not deliverable: the strongest fact available synchronously says the
  // session isn't live, so no queue is spent on a frame the writer would drop.
  expect(core.sendToAppSession("peer-x", msg)).toBe(false);
  expect(sendCalls).toEqual([]);

  // Deliverable: the same call now reaches the stream's sendTo.
  deliverable = true;
  expect(core.sendToAppSession("peer-x", msg)).toBe(true);
  expect(sendCalls).toEqual([{ peerId: "peer-x" }]);
});

test("onPeerStreamClosed(peer) clears that peer's focus claim", async () => {
  // A device that closed its project stream stops vouching for whatever it had
  // on screen — same effect as clientGone, just triggered by the stream rather
  // than the whole peer session ending.
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-streamclosed-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");

  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
  });
  cleanup.push(() => core.shutdown());
  await core.start();
  const { deps, calls } = fakeRemoteDeps();
  core.promote(deps);
  const opts = calls[0].opts;

  core.noteSessionFocus("session-1", "phone-1");
  const work = () => (core as unknown as { _work: WorkStatusState })._work;
  expect(work().focusedSessions.get("phone-1")).toBe("session-1");

  opts.onPeerStreamClosed?.("phone-1");
  expect(work().focusedSessions.get("phone-1")).toBeUndefined();
});

test("tunnel aborts follow the peer's session: another phone coming online aborts nothing, and a session going aborts only its own runs", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-tunnelabort-"));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");

  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
  });
  cleanup.push(() => core.shutdown());
  await core.start();
  const { deps, calls } = fakeRemoteDeps();
  core.promote(deps);
  const opts = calls[0].opts;

  const agent = (core as unknown as { core: { abortTunnelStreams(peerId: string): void } }).core;
  const aborted: string[] = [];
  agent.abortTunnelStreams = (peerId) => { aborted.push(peerId); };

  opts.onPeerOnline?.();
  opts.onPeerOnline?.();
  expect(aborted).toEqual([]);

  opts.onPeerSessionGone?.("phone-a");
  expect(aborted).toEqual(["phone-a"]);

  opts.onPeerOffline?.();
  expect(aborted).toEqual(["phone-a"]);
});
