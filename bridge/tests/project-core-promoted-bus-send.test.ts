import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { ProjectCore, type ProjectCoreRemoteDeps } from "../src/project-core";
import { MessageBus } from "../src/message-bus";
import type { AttachStreamOpts, PeerSessionView, SendTarget, StreamHandle } from "../src/stream-mux";
import type { MachineRelaySession } from "../src/relay-promotion";
import { createMessage } from "../src/protocol";

let cleanup: Array<() => void | Promise<unknown>> = [];
afterEach(async () => { for (const fn of cleanup.splice(0).reverse()) try { await fn(); } catch {} });

const PEER = "app-device#machine-uuid";

// Neither test removes its temp folder, on purpose. Deleting it is itself what
// arms the last git refresh: the watcher sees the tree vanish and schedules a
// debounced `rev-parse`, which outlives `shutdown`'s drain and then spawns with
// a cwd that is gone. That rejection surfaces against whatever test is running
// 250ms later — in another file — so the folder is left for the OS to reap.

function viewFor(peerId: string): PeerSessionView {
  return { peerId, peerPubkey: "pub", checkoutRouting: true, reachable: true, pullsTree: true };
}

/** Fully typed, no cast: `envelope.metadata` is mandatory on the wire, so a
 *  fixture that elides it is a frame this bridge would refuse — and the cast
 *  that let it compile would hide the next schema change too. */
function busReplyFrame() {
  const from = { machineId: "machine-uuid", projectId: "p1", sessionId: "s1" };
  return createMessage("session-bus:notify", {
    from,
    to: { machineId: "other-machine", projectId: "p2", sessionId: "s2" },
    contextId: "s2",
    threadId: "t1",
    envelope: {
      messageId: "m1",
      threadId: "t1",
      contextId: "s2",
      parts: [{ kind: "text", text: "hi" }],
      metadata: { peer: from, summary: "hi", timestamp: 1 },
    },
  });
}

/** Like project-core.test.ts's stub, but with a LIVE peer session and a sendTo
 *  that records — the two things a bus reply needs to actually leave. */
function remoteDepsWithPeer(): {
  deps: ProjectCoreRemoteDeps;
  calls: Array<{ bus: MessageBus; opts: AttachStreamOpts }>;
  sent: Array<{ target?: SendTarget }>;
} {
  const calls: Array<{ bus: MessageBus; opts: AttachStreamOpts }> = [];
  const sent: Array<{ target?: SendTarget }> = [];
  const deps: ProjectCoreRemoteDeps = {
    attachStream: (bus, opts) => {
      calls.push({ bus, opts });
      const handle: StreamHandle = {
        streamId: "stream-1",
        detach: () => {},
        sendTunnel: async () => "sent" as const,
        sendTo: async (_msg, _channel, target) => { sent.push({ target }); return "sent" as const; },
      };
      return handle;
    },
    establishedPeers: () => [viewFor(PEER)],
    peerSession: (peerId) => (peerId === PEER ? viewFor(peerId) : null),
    machineDeviceId: () => "machine-uuid",
    sendPushDeliver: () => {},
  };
  return { deps, calls, sent };
}

test("a promoted local-mode core can answer a session-bus message addressed at the app session that carried it in", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-busreply-"));
  writeFileSync(join(folder, "antgrid.yaml"), "");

  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
  });
  cleanup.push(() => core.shutdown());
  await core.start();

  const { deps, calls, sent } = remoteDepsWithPeer();
  const promoted = core.promote(deps);
  calls[0].opts.onAdmitted?.("stream-1");
  expect(core.isRelayRegistered()).toBe(true);

  expect(core.sendToAppSession(PEER, busReplyFrame())).toBe(true);
  expect(sent).toHaveLength(1);
  expect(sent[0].target).toEqual({ kind: "peer", peerId: PEER });

  // Torn down here rather than only in `cleanup`, so the slot and the core are
  // both gone before the next test in this file starts.
  promoted.stop();
  await core.shutdown();
});

/** The wizard promotion path (`agent:enableRelay` over loopback) attaches the
 *  same relay slot through a different door, so it needs the same bookkeeping:
 *  without it the reply is refused against a null handle and held, exactly as
 *  the promote() path did. */
function machineSessionWithPeer(): { session: MachineRelaySession; sent: Array<{ target?: SendTarget }> } {
  const sent: Array<{ target?: SendTarget }> = [];
  const session: MachineRelaySession = {
    attachStream: () => ({
      streamId: "wizard-stream",
      detach: () => {},
      sendTunnel: async () => "sent" as const,
      sendTo: async (_msg, _channel, target) => { sent.push({ target }); return "sent" as const; },
    }),
    establishedPeers: () => [viewFor(PEER)],
    peerSession: (peerId) => (peerId === PEER ? viewFor(peerId) : null),
    sendPushDeliver: () => {},
    agentDeviceId: "machine-uuid",
  };
  return { session, sent };
}

test("a core promoted by the desktop enable-relay wizard can answer one too", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-wizreply-"));
  writeFileSync(join(folder, "antgrid.yaml"), "");

  const { session, sent } = machineSessionWithPeer();
  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
    ensureMachineRelay: async () => session,
  });
  cleanup.push(() => core.shutdown());
  await core.start();

  const connect = core.localConnectInfo!;
  const ws = new WebSocket(`ws://127.0.0.1:${connect.port}`);
  await new Promise<void>((resolve, reject) => {
    ws.addEventListener("open", () => resolve());
    ws.addEventListener("error", () => reject(new Error("loopback connect failed")));
  });

  // `agent:relayReady` is this path's one success signal, and the attach happens
  // inside an async start() — awaiting the signal is what makes it deterministic
  // rather than a poll. `agent:relayError` is awaited too so a refusal fails
  // here with its own message instead of timing out.
  const attached = new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("no agent:relayReady within 5s")), 5000);
    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(String(ev.data)) as { type?: string; message?: string };
      if (msg.type === "agent:relayReady") { clearTimeout(timer); resolve(); }
      if (msg.type === "agent:relayError") { clearTimeout(timer); reject(new Error(msg.message ?? "relayError")); }
    });
  });

  ws.send(JSON.stringify({ type: "hello", token: connect.token }));
  ws.send(JSON.stringify(createMessage("agent:enableRelay", {
    auth: {
      deviceUuid: "11111111-1111-4111-8111-111111111111",
      ed25519Pub: "cHVi",
      ed25519Priv: "cHJpdg",
    },
  })));
  await attached;

  expect(core.sendToAppSession(PEER, busReplyFrame())).toBe(true);
  expect(sent).toHaveLength(1);
  expect(sent[0].target).toEqual({ kind: "peer", peerId: PEER });

  // The owner goes away before the core does, in that order: closing the socket
  // after shutdown would race the listener's own teardown.
  await new Promise<void>((resolve) => { ws.addEventListener("close", () => resolve()); ws.close(); });
  await core.shutdown();
});
