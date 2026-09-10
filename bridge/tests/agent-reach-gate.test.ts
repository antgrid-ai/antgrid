// E12's two halves at the bridge: the "reachable by agents" bit gates
// DISCLOSURE (a peer's agent reading this machine's session titles and work
// status) and INTERRUPTION (a peer's agent posting into a session here)
// together, and gates neither when remote access has already said no.
//
// The disclosure half is exercised against `handleCapabilityCardRpc` directly;
// the interruption half through the core's own bus inbound handler, because the
// carve-outs that matter (a loopback frame, a core with no relay wired, an
// answer on a context this machine leads) live in that handler and not in the
// coordinator underneath it.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { loadAgentReachPolicy, AGENT_REACH_DEFAULT } from "../src/agent-reach-policy";
import { HostServer, type HostRemoteConfig, type RemoteRuntime } from "../src/host-server";
import { MessageBus } from "../src/message-bus";
import { setLogLevel } from "../src/logger";
import { createMessage, type AbMessage, type SessionEntry, type SessionMemberRef } from "../src/protocol";
import { SessionBusCoordinator } from "../src/session-bus/coordinator";
import { SessionBusSessionIndex } from "../src/session-bus/session-index";
import type { PeerSessionView } from "../src/stream-mux";

setLogLevel("error");

let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];
let cores: AgentCore[] = [];
let coordinator: SessionBusCoordinator | null = null;
let host: HostServer | null = null;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-agent-reach-"));
  process.env.ANTGRID_DIR = abDir;
  cores = [];
  coordinator = null;
});

afterEach(async () => {
  for (const core of cores) {
    try { await core.shutdown(); } catch { /* best effort */ }
  }
  // An injected coordinator outlives every core by design, so the harness stops
  // it the way HostServer's own shutdown does.
  coordinator?.stop();
  try { await host?.shutdown(); } catch { /* best effort */ }
  host = null;
  for (const f of folders.splice(0)) {
    try { rmSync(f, { recursive: true, force: true }); } catch { /* Windows watcher handle */ }
  }
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  try { rmSync(abDir, { recursive: true, force: true }); } catch { /* Windows watcher handle */ }
}, 30_000);

// --- the store ------------------------------------------------------------

test("the bit is ON before anyone has set it", () => {
  // The whole answer to the discovery objection: turning remote access on still
  // works end to end, with nothing else to find first.
  expect(loadAgentReachPolicy(abDir).isEnabled()).toBe(AGENT_REACH_DEFAULT);
  expect(AGENT_REACH_DEFAULT).toBe(true);
});

test("an off survives a reload", () => {
  expect(loadAgentReachPolicy(abDir).setEnabled(false)).toBe(true);
  expect(loadAgentReachPolicy(abDir).isEnabled()).toBe(false);
});

test("a no-op set reports no change", () => {
  const store = loadAgentReachPolicy(abDir);
  expect(store.setEnabled(true)).toBe(false);
  expect(store.setEnabled(false)).toBe(true);
  expect(store.setEnabled(false)).toBe(false);
});

test("a file we cannot read reads OFF, and is not overwritten with the guess", () => {
  // Absent and unreadable are different answers: absent is "never set", where
  // the default is what the user was promised, while unreadable is a value that
  // exists and cannot be seen -- guessing "on" there would re-grant something
  // that may have been turned off.
  const path = join(abDir, "agents", "agent-reach-policy.json");
  loadAgentReachPolicy(abDir).setEnabled(false);
  writeFileSync(path, "{ not json");

  expect(loadAgentReachPolicy(abDir).isEnabled()).toBe(false);
  // Untouched, so a clean read later still recovers the real value.
  writeFileSync(path, JSON.stringify({ version: 1, enabled: true }));
  expect(loadAgentReachPolicy(abDir).isEnabled()).toBe(true);
});

test("a version this build does not know is unreadable, not older", () => {
  // A newer build's file under a rollback: its `enabled` may not mean what this
  // build thinks it does.
  loadAgentReachPolicy(abDir).setEnabled(false);
  writeFileSync(
    join(abDir, "agents", "agent-reach-policy.json"),
    JSON.stringify({ version: 99, enabled: true }),
  );
  expect(loadAgentReachPolicy(abDir).isEnabled()).toBe(false);
});

// --- disclosure -----------------------------------------------------------

function fakeRemoteConfig(): HostRemoteConfig {
  return {
    relayUrl: "ws://127.0.0.1:1",
    licenseApiUrl: "http://127.0.0.1:1",
    identity: { deviceId: "dev-1", deviceName: "dev-1", createdAt: "2026-01-01T00:00:00.000Z" },
    auth: { clientId: "cid", clientSecret: "secret", deviceUuid: "uuid-1" },
    onAuthRevoked: () => {},
  };
}

function fakeRuntime(): RemoteRuntime {
  return { maint: { getToken: () => "tok", stop: () => {} } };
}

function cardRequest(params: unknown) {
  return { id: "m", timestamp: 0, type: "request", requestId: "r1", method: "machine.capability-card", params } as any;
}

async function hostWithReach(enabled: boolean): Promise<HostServer> {
  // Written before the host loads it: the store is read once at construction.
  if (!enabled) loadAgentReachPolicy(abDir).setEnabled(false);
  const h = new HostServer({ remote: fakeRemoteConfig(), remoteRuntimeFactory: () => Promise.resolve(fakeRuntime()) });
  await h.handleRemoteAccessVerb({ id: "t", type: "mobile-access:set", enabled: true });
  return h;
}

test("a session-bearing card is refused while agent reach is off", async () => {
  host = await hostWithReach(false);

  const res = (await host.handleCapabilityCardRpc(cardRequest({ includeSessions: true }))) as any;

  // NOT_ALLOWED, not a card with the key omitted: omitting is already how a
  // bridge too old to know the flag degrades, and reusing it here would say
  // "that machine cannot" where the truth is "that machine will not".
  expect(res.ok).toBe(false);
  expect(res.error.code).toBe("NOT_ALLOWED");
});

test("the repo half of the card still answers while agent reach is off", async () => {
  host = await hostWithReach(false);

  const res = (await host.handleCapabilityCardRpc(cardRequest({}))) as any;

  // That half answers a device the user is holding, where remote access is the
  // whole question.
  expect(res.ok).toBe(true);
  expect(res.result.os.name.length).toBeGreaterThan(0);
});

test("the same ask is answered once agent reach is turned back on", async () => {
  host = await hostWithReach(false);
  await host.handleAgentReachVerb({ id: "t", type: "agent-reach:set", enabled: true });

  const res = (await host.handleCapabilityCardRpc(cardRequest({ includeSessions: true }))) as any;

  expect(res.ok).toBe(true);
  expect(res.result.sessions).toEqual([]);
});

test("agent-reach:get reports what the machine actually holds", async () => {
  host = await hostWithReach(true);
  expect(await host.handleAgentReachVerb({ id: "g", type: "agent-reach:get" })).toMatchObject({ enabled: true });
  await host.handleAgentReachVerb({ id: "s", type: "agent-reach:set", enabled: false });
  expect(await host.handleAgentReachVerb({ id: "g", type: "agent-reach:get" })).toMatchObject({ enabled: false });
});

// --- interruption ---------------------------------------------------------

const REMOTE: SessionMemberRef = { machineId: "m-remote", projectId: "p-remote", sessionId: "s-remote" };

function peerSession(): PeerSessionView {
  return { peerId: "app-1", peerPubkey: "pub", checkoutRouting: true, reachable: true, pullsTree: true };
}

async function waitFor(predicate: () => boolean, what: string, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** One remote-mode core sharing an injected coordinator, with one session on
 *  it -- the smallest thing that can receive a bus frame addressed somewhere
 *  real. `setPeerSessionProvider` is what makes the core relay-wired, which is
 *  the carve-out both gates skip when it is absent. */
async function bootReachable(reach: () => boolean): Promise<{
  bus: MessageBus;
  sessionId: string;
  sessionBus: SessionBusCoordinator;
}> {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-agent-reach-proj-"));
  writeFileSync(join(folder, "antgrid.yaml"), "name: reach\nagent:\n  tool: claude-code\n");
  folders.push(folder);

  const sessionIndex = new SessionBusSessionIndex({
    liveSessions: (projectId) => cores.find((c) => c.projectId === projectId)?.listSessions(true) ?? null,
  });
  const sessionBus = new SessionBusCoordinator({
    abDir,
    projectIdFor: (sessionId) => sessionIndex.lookup(sessionId)?.projectId ?? null,
    self: (sessionId) => {
      const entry = sessionIndex.lookup(sessionId);
      if (!entry) return null;
      return {
        key: { machineId: "m1", projectId: entry.projectId, sessionId },
        ref: { machineId: "m1", projectId: entry.projectId, sessionId, sessionName: entry.sessionName },
      };
    },
    addressable: () => true,
    send: () => true,
  });
  coordinator = sessionBus;

  const core = await buildAgentCore({
    folder,
    mode: "remote",
    identity: { deviceId: "agent-reach", deviceName: "agent-reach", createdAt: new Date().toISOString() },
    machineId: () => "m1",
    sessionBus,
    agentReachEnabled: reach,
    remoteAccessEnabled: () => true,
  });
  cores.push(core);

  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.setPeerSessionProvider(() => peerSession());
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"), "first agent:status");

  const requestId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("session:create", { requestId, name: "s" }), "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "session:result" && (m as { requestId?: string }).requestId === requestId),
    "session:create result",
  );
  const result = sent.find((m) => m.type === "session:result" && (m as { requestId?: string }).requestId === requestId);
  if (result?.type !== "session:result" || !result.ok || !result.session) {
    throw new Error(`session:create failed: ${JSON.stringify(result)}`);
  }
  const sessionId = result.session.id;
  sessionIndex.noteProject(core.projectId, "reach", core.listSessions(true) as SessionEntry[]);
  return { bus, sessionId, sessionBus };
}

function inbound(sessionId: string, contextId: string, text: string) {
  return createMessage("session-bus:message", {
    from: REMOTE,
    to: { machineId: "m1", projectId: "label-only", sessionId },
    contextId,
    taskId: null,
    envelope: {
      messageId: `msg-${text}`,
      taskId: null,
      contextId,
      parts: [{ kind: "text", text }],
      metadata: { peer: REMOTE, summary: text, timestamp: 1 },
    },
  });
}

test("a peer opening an exchange is dropped while agent reach is off, and lands once on", async () => {
  let reach = false;
  const { bus, sessionId, sessionBus } = await bootReachable(() => reach);

  // contextId is the SENDER's session, so this is a context nobody here opened.
  bus.dispatchInbound(inbound(sessionId, REMOTE.sessionId, "while-off"), "control", "relay", "app-1");
  await new Promise((r) => setTimeout(r, 100));
  expect(sessionBus.messages(sessionId).entries).toHaveLength(0);

  reach = true;
  bus.dispatchInbound(inbound(sessionId, REMOTE.sessionId, "while-on"), "control", "relay", "app-1");
  await waitFor(() => sessionBus.messages(sessionId).entries.length === 1, "the frame sent once reach was on");
}, 30_000);

test("an answer on a context this machine LEADS still lands while agent reach is off", async () => {
  const { bus, sessionId, sessionBus } = await bootReachable(() => false);

  // contextId === this machine's own session: something here opened the
  // exchange, so this is the reply to it. Refusing it would not be "nobody may
  // interrupt me", it would be "my own agents may not finish a sentence".
  bus.dispatchInbound(inbound(sessionId, sessionId, "reply"), "control", "relay", "app-1");

  await waitFor(() => sessionBus.messages(sessionId).entries.length === 1, "the reply on our own context");
}, 30_000);

test("the desktop's own loopback frames are never gated", async () => {
  const { bus, sessionId, sessionBus } = await bootReachable(() => false);

  bus.dispatchInbound(inbound(sessionId, REMOTE.sessionId, "local"), "control", "loopback");

  await waitFor(() => sessionBus.messages(sessionId).entries.length === 1, "the loopback frame");
}, 30_000);
