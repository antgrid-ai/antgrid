import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { ProjectCore, type ProjectCoreDeps, type ProjectCoreRemoteDeps } from "../src/project-core";
import type { AttachStreamOpts, SendTarget } from "../src/project-streams";
import type { MessageBus } from "../src/message-bus";
import { fakeStreamHandle, peerView } from "./relay-stubs";
import { createMessage } from "../src/protocol";

let cleanup: Array<() => void | Promise<unknown>> = [];
afterEach(async () => { for (const fn of cleanup.splice(0).reverse()) try { await fn(); } catch {} });

const PEER = "app-device#machine-uuid";

/** Fully typed, no cast: `envelope.metadata` is mandatory on the wire, so a
 *  fixture that elides it is a frame this bridge would refuse. */
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

/** A live peer session and a recording `sendTo` — what a bus reply needs to
 *  leave. */
function peerStreamStub() {
  const sent: Array<SendTarget | undefined> = [];
  const deps: ProjectCoreRemoteDeps = {
    attachStream: (_bus: MessageBus, opts: AttachStreamOpts) => {
      const handle = fakeStreamHandle({
        sendTo: async (_msg, _channel, target) => { sent.push(target); return "sent" as const; },
        deliverableTo: (peerId) => peerId === PEER,
      });
      // The registry's admission, which is what flips `isRelayRegistered`.
      opts.onAdmitted?.();
      return handle;
    },
    establishedPeers: () => [peerView({ peerId: PEER })],
    peerSession: (peerId: string) => (peerId === PEER ? peerView({ peerId }) : null),
    sendPushDeliver: () => {},
    accountDisowns: () => false,
    machineDeviceId: () => "machine-uuid",
  };
  return { deps, sent };
}

function localCore(prefix: string, deps: Partial<ProjectCoreDeps> = {}): ProjectCore {
  const folder = mkdtempSync(join(tmpdir(), prefix));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");
  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
    ...deps,
  });
  cleanup.push(() => core.shutdown());
  return core;
}

test("a promoted local-mode core can answer a session-bus message addressed at the app session that carried it in", async () => {
  const core = localCore("antgrid-pc-busreply-");
  await core.start();

  const { deps, sent } = peerStreamStub();
  core.promote(deps);

  expect(core.sendToAppSession(PEER, busReplyFrame())).toBe(true);
  expect(sent).toEqual([{ kind: "peer", peerId: PEER }]);
});

test("tearing down a slot a second attach has taken over leaves the live one answering", async () => {
  const core = localCore("antgrid-pc-staleslot-");
  await core.start();

  // A second promote without a stop in between attaches twice.
  const first = peerStreamStub();
  const stale = core.promote(first.deps);
  const second = peerStreamStub();
  core.promote(second.deps);

  stale.stop();

  expect(core.sendToAppSession(PEER, busReplyFrame())).toBe(true);
  expect(second.sent).toEqual([{ kind: "peer", peerId: PEER }]);
  expect(first.sent).toEqual([]);
  // The surviving stream is still admitted, so the advert must not read
  // not-running.
  expect(core.isRelayRegistered()).toBe(true);
});
