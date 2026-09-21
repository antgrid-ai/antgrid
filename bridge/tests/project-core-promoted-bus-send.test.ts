import { test, expect, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { ProjectCore, type ProjectCoreDeps, type ProjectCoreRemoteDeps } from "../src/project-core";
import type { SendTarget } from "../src/stream-mux";
import type { MachineRelaySession } from "../src/relay-promotion";
import { fakeStreamHandle, peerView } from "./relay-stubs";
import { createMessage } from "../src/protocol";

let cleanup: Array<() => void | Promise<unknown>> = [];
afterEach(async () => { for (const fn of cleanup.splice(0).reverse()) try { await fn(); } catch {} });

const PEER = "app-device#machine-uuid";

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

/** A live peer session and a `sendTo` that records — the two things a bus reply
 *  needs to actually leave. One object serves both doors onto the same slot:
 *  `ProjectCoreRemoteDeps` for `promote`, `MachineRelaySession` for the wizard,
 *  which differ only in how they name this machine's device id. */
function peerStreamStub() {
  const sent: Array<SendTarget | undefined> = [];
  const stub = {
    attachStream: () => fakeStreamHandle({
      sendTo: async (_msg, _channel, target) => { sent.push(target); return "sent" as const; },
    }),
    establishedPeers: () => [peerView({ peerId: PEER })],
    peerSession: (peerId: string) => (peerId === PEER ? peerView({ peerId }) : null),
    sendPushDeliver: () => {},
    machineDeviceId: () => "machine-uuid",
    agentDeviceId: "machine-uuid",
  };
  return {
    deps: stub satisfies ProjectCoreRemoteDeps,
    session: stub satisfies MachineRelaySession,
    sent,
  };
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

test("a core promoted by the desktop enable-relay wizard can answer one too", async () => {
  const { session, sent } = peerStreamStub();
  const core = localCore("antgrid-pc-wizreply-", { ensureMachineRelay: async () => session });
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
  expect(sent).toEqual([{ kind: "peer", peerId: PEER }]);

  // The owner goes away before the core does, in that order: closing the socket
  // after shutdown would race the listener's own teardown.
  await new Promise<void>((resolve) => { ws.addEventListener("close", () => resolve()); ws.close(); });
});
