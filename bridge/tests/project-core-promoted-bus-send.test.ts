import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { ProjectCore, type ProjectCoreRemoteDeps } from "../src/project-core";
import { MessageBus } from "../src/message-bus";
import type { AttachStreamOpts, PeerSessionView, SendTarget, StreamHandle } from "../src/stream-mux";
import { createMessage } from "../src/protocol";

let cleanup: Array<() => void | Promise<unknown>> = [];
afterEach(async () => { for (const fn of cleanup.splice(0).reverse()) try { await fn(); } catch {} });

const PEER = "app-device#machine-uuid";

function viewFor(peerId: string): PeerSessionView {
  return { peerId, peerPubkey: "pub", checkoutRouting: true, reachable: true, pullsTree: true };
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
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");

  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
  });
  cleanup.push(() => core.shutdown());
  await core.start();

  const { deps, calls, sent } = remoteDepsWithPeer();
  core.promote(deps);
  calls[0].opts.onAdmitted?.("stream-1");
  expect(core.isRelayRegistered()).toBe(true);

  const frame = createMessage("session-bus:notify", {
    from: { machineId: "machine-uuid", projectId: "p1", sessionId: "s1" },
    to: { machineId: "other-machine", projectId: "p2", sessionId: "s2" },
    contextId: "s2",
    threadId: "t1",
    envelope: { messageId: "m1", threadId: "t1", contextId: "s2", parts: [{ kind: "text", text: "hi" }] },
  } as never);

  expect(core.sendToAppSession(PEER, frame)).toBe(true);
  expect(sent).toHaveLength(1);
  expect(sent[0].target).toEqual({ kind: "peer", peerId: PEER });
});
