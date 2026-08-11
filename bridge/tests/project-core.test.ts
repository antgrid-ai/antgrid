import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { ProjectCore, type ProjectCoreRemoteDeps } from "../src/project-core";
import { computeProjectId } from "../src/project-id";
import { MessageBus } from "../src/message-bus";
import type { AttachStreamOpts, StreamHandle } from "../src/stream-mux";
import type { ConnState } from "../src/conn-state";

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
      const handle: StreamHandle = { streamId: "stream-1", detach: () => {}, sendTunnel: () => {} };
      return handle;
    },
    currentPeerPubkey: () => null,
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
  // and firstRegister must track that stream's onAdmitted/onRejected outcome.
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
  calls[0].opts.onAdmitted?.("stream-1");

  expect(core.isRelayRegistered()).toBe(true);
  await expect(handle.firstRegister).resolves.toEqual({ ok: true });

  handle.stop();
  expect(core.isRelayRegistered()).toBe(false);
});

test("a rejected stream-open (e.g. SESSION_LIMIT_EXCEEDED) resolves firstRegister with the typed rejection", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-promo-reject-"));
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
  const handle = core.promote(deps);
  calls[0].opts.onRejected?.("SESSION_LIMIT_EXCEEDED", "cap reached");

  expect(core.isRelayRegistered()).toBe(false);
  await expect(handle.firstRegister).resolves.toEqual({ ok: false, code: "SESSION_LIMIT_EXCEEDED", message: "cap reached" });
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

  calls[0].opts.onAdmitted?.("stream-1");
  expect(core.isRelayRegistered()).toBe(true);
});
