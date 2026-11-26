import { test, expect, beforeEach, afterEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import net from "node:net";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import type { SessionDirectory, SessionDirectoryRow } from "../src/session-bus/directory";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { TestPeerSessionOwner } from "./test-peer-session-owner";
import type { PeerSessionView } from "../src/project-streams";

function session(peerPubkey: string, peerId = "app-dev#machine-dev"): PeerSessionView {
  return { peerId, peerPubkey };
}

// Isolate ANTGRID_DIR so the core writes its session/catalog state into a temp
// dir rather than the real ~/.antgrid (mirrors host-server.test.ts).
let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-mobile-gate-"));
  process.env.ANTGRID_DIR = abDir;
});

// On Windows the file watcher can hold a transient handle on the temp folder for
// a few ms after shutdown(); retry the cleanup and never fail teardown.
async function rmWithRetry(path: string): Promise<void> {
  for (let i = 0; i < 20; i++) {
    try { rmSync(path, { recursive: true, force: true }); return; }
    catch { await new Promise((r) => setTimeout(r, 25)); }
  }
}

// The core's file watcher (chokidar over a raw fs.watch) can emit a late EPERM
// `error` event on Windows when a watched temp dir is removed. That raw event
// is delivered asynchronously (often during the *next* test, after the prior
// test's temp dir was cleaned up) and is NOT catchable via chokidar's
// `.on("error")`, so it would otherwise surface as an uncaught error and fail
// the run. Swallow only that benign teardown artifact for the lifetime of this
// suite; re-throw anything else. Mirrors the Windows watcher teardown race
// documented elsewhere in the bridge tests.
function ignoreWatcherEperm(err: unknown): void {
  const code = (err as { code?: string } | null)?.code;
  if (code === "EPERM" || code === "ENOENT") return;
  throw err;
}
process.on("uncaughtException", ignoreWatcherEperm);

let core: AgentCore | null = null;
afterEach(async () => {
  try { await core?.shutdown(); } catch {}
  core = null;
  // Let the watcher's teardown + any pending fs.watch events drain.
  await new Promise((r) => setTimeout(r, 50));
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  await rmWithRetry(abDir);
  // NOTE: the per-project temp folders (under `folders`) are intentionally NOT
  // removed here. The core's chokidar watcher watches them; deleting a watched
  // dir on Windows fires a late, uncatchable EPERM `error` event from the raw
  // fs.watch that lands during the *next* test and would be reported as an
  // unhandled error. The OS reclaims the OS temp dir; leaking a couple of empty
  // temp folders per run is the lesser evil. They are tracked in `folders` and
  // cleaned once at the end of the suite (afterAll), after all watchers are gone.
  // 30s, not the 5s Bun gives a hook by default: a core holding a managed
  // worktree drains git children that still have the checkout as their cwd
  // before shutdown() returns, and an overrun hook is not cancelled â€” its body
  // would resume inside the NEXT test, against the already-reassigned abDir.
}, 30_000);

afterAll(async () => {
  while (folders.length) await rmWithRetry(folders.pop()!);
  process.off("uncaughtException", ignoreWatcherEperm);
});

function tempFolder(): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-mobile-gate-proj-"));
  // Minimal config so buildAgentCore loads non-interactively.
  writeFileSync(join(f, "antgrid.yaml"), "name: test-mobile-gate\nagent:\n  tool: claude-code\n");
  folders.push(f);
  return f;
}

function statusListsTerminal(frames: AbMessage[], terminalId: string): boolean {
  return frames.some(
    (m) =>
      m.type === "agent:status" &&
      !!(m as { terminals?: Array<{ terminalId: string }> }).terminals?.some(
        (t) => t.terminalId === terminalId,
      ),
  );
}

/** Wait until the bus has emitted an agent:status frame listing `terminalId`,
 *  or the timeout elapses. Used for the honored path, where spawn â†’ sendStatus
 *  is async relative to the inbound dispatch (local-mode setupServices defers
 *  manager creation). */
async function waitForTerminal(frames: AbMessage[], terminalId: string, timeoutMs = 2000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (statusListsTerminal(frames, terminalId)) return true;
    await new Promise((r) => setTimeout(r, 15));
  }
  return statusListsTerminal(frames, terminalId);
}

/** Wait until the core's services are up (an agent:status frame has been
 *  published at least once), so an inbound verb is dispatched against a live
 *  manager rather than dropped by the `if (!manager) return` guard. */
async function waitForServices(frames: AbMessage[], timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (frames.some((m) => m.type === "agent:status")) return;
    await new Promise((r) => setTimeout(r, 15));
  }
}

test("drops project verbs from an account-trusted phone while mobile access is off, honors them once on", async () => {
  const folder = tempFolder();
  let mobileAccess = false;

  core = await buildAgentCore({
    folder,
    mode: "remote",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    remoteAccessEnabled: () => mobileAccess,
  });

  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  // Wire the attached-session lookup exactly as the remote transport does.
  core.setPeerSessionProvider(() => session("phone-pubkey-1-base64"));

  // Spin up managers (the relay does this once the peer session is established).
  core.onHandshakeComplete();
  await waitForServices(sent);

  // --- Mobile access off: terminal:start must be dropped (no terminal spawned). ---
  const t1 = `t-${randomUUID()}`;
  sent.length = 0;
  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: t1, command: "node", args: ["-e", "0"] }),
    "control",
  );
  // Give it the same budget the honored path gets; it must still NOT appear.
  await new Promise((r) => setTimeout(r, 200));
  expect(statusListsTerminal(sent, t1)).toBe(false);

  // --- Turn the machine on, and the same verb must be honored. ---
  mobileAccess = true;

  const t2 = `t-${randomUUID()}`;
  sent.length = 0;
  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: t2, command: "node", args: ["-e", "0"] }),
    "control",
  );
  expect(await waitForTerminal(sent, t2)).toBe(true);
});

test("a core with no host-supplied switch fails closed for a remote phone", async () => {
  // A bare agent (no HostServer) omits `remoteAccessEnabled`; the default must
  // be "disabled", never "unset means allow".
  const folder = tempFolder();
  core = await buildAgentCore({
    folder,
    mode: "remote",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
  });

  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.setPeerSessionProvider(() => session("phone-pubkey-unwired"));

  core.onHandshakeComplete();
  await waitForServices(sent);

  const t1 = `t-${randomUUID()}`;
  sent.length = 0;
  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: t1, command: "node", args: ["-e", "0"] }),
    "control",
  );
  await new Promise((r) => setTimeout(r, 200));
  expect(statusListsTerminal(sent, t1)).toBe(false);
});

test("clearing the peer-session provider does not hand relay frames the local-core carve-out", async () => {
  // A promotion's stop() and a shutdown both null the provider while the core
  // stays warm on its bus. The core must keep answering to the switch: it has
  // faced remote peers, so a relay-origin frame is still one.
  const folder = tempFolder();
  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    remoteAccessEnabled: () => false,
  });

  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.setPeerSessionProvider(() => session("phone-pubkey-demoted"));
  core.setPeerSessionProvider(null);

  core.onHandshakeComplete();
  await waitForServices(sent);

  const t1 = `t-${randomUUID()}`;
  sent.length = 0;
  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: t1, command: "node", args: ["-e", "0"] }),
    "control", "relay", "app-dev#machine-dev",
  );
  await new Promise((r) => setTimeout(r, 200));
  expect(statusListsTerminal(sent, t1)).toBe(false);

  // The desktop's own loopback frames are still honoured with the switch off.
  const t2 = `t-${randomUUID()}`;
  sent.length = 0;
  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: t2, command: "node", args: ["-e", "0"] }),
    "control", "loopback",
  );
  expect(await waitForTerminal(sent, t2)).toBe(true);
});

test("does NOT gate when no relay transport is wired (local/loopback transport)", async () => {
  const folder = tempFolder();

  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    // Mobile access is OFF for the machine; the desktop must still drive it.
    remoteAccessEnabled: () => false,
  });

  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  // Local transport never sets a provider â†’ no relay transport â†’ not gated.

  core.onHandshakeComplete();
  await waitForServices(sent);

  const t1 = `t-${randomUUID()}`;
  sent.length = 0;
  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: t1, command: "node", args: ["-e", "0"] }),
    "control",
  );
  expect(await waitForTerminal(sent, t1)).toBe(true);
});

/** A directory row, minimal but complete: only `machineId` is under test. */
function localRow(): SessionDirectoryRow {
  return {
    machineId: null,
    projectId: "project-self",
    sessionId: "session-local",
    title: "local",
    branch: null,
    activity: "idle",
    lastActiveAt: 0,
    canReply: true,
  };
}

function peerRow(): SessionDirectoryRow {
  return { ...localRow(), machineId: "machine-peer", projectId: "project-peer", sessionId: "session-peer", title: "peer" };
}

async function waitForDirectoryResult(
  frames: AbMessage[],
  requestId: string,
  timeoutMs = 2000,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const hit = frames.find(
      (m) => m.type === "session-bus:directory:result" && (m as { requestId?: string }).requestId === requestId,
    );
    if (hit) return hit as unknown as Record<string, unknown>;
    await new Promise((r) => setTimeout(r, 15));
  }
  throw new Error("session-bus:directory never answered");
}

/** Create a session and hand back its id, so a bus verb has a member to name. */
async function createSession(bus: MessageBus, frames: AbMessage[], name: string): Promise<string> {
  const requestId = randomUUID();
  bus.dispatchInbound(createMessage("session:create", { requestId, name }), "control", "loopback");
  const deadline = Date.now() + 2000;
  while (Date.now() < deadline) {
    const hit = frames.find(
      (m) => m.type === "session:result" && (m as { requestId?: string }).requestId === requestId,
    );
    if (hit?.type === "session:result" && hit.ok && hit.session) return hit.session.id;
    await new Promise((r) => setTimeout(r, 15));
  }
  throw new Error(`session:create never answered for ${name}`);
}

// REGRESSION: the switch's OUTBOUND half must NOT inherit the inbound gate's
// "never faced the relay" carve-out. A session reaches a peer MACHINE through
// rows the app pushes into this core's directory, so no relay of its own need
// ever have attached — which is the configuration a desktop runs in whenever
// the app sits on the loopback listener. Reading the switch as "on" there made
// every surface lie at once: the directory offered off-machine rows, `post`
// accepted a send, and the `dispatch` gate — which reads the policy directly and
// was therefore right — held the frame while the caller was told "it goes when
// the link is back" about a link the switch itself was keeping down.
//
// The directory is asserted rather than the send because it is the surface an
// agent consults FIRST: a peer it is never offered is one it cannot try to
// reach. Caught on two real machines, not by this suite — the eval covering
// this switch always has a relay attached, so the carve-out is unreachable
// there and load-bearing in production.
test("narrows the directory to this machine while the switch is off, with no relay ever attached", async () => {
  const folder = tempFolder();

  // One row on this machine and one on another, so the assertion below can tell
  // "narrowed" from "empty". `list` is all `listSessions` asks of a directory.
  const directory = {
    list: async () => ({
      ok: true as const,
      rows: [localRow(), peerRow()],
      truncated: 0,
      reach: { scope: "network" as const, lastPushAgoMs: 0, machines: [], staleMachines: 0, notConnected: 0 },
    }),
  } as unknown as SessionDirectory;

  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    machineId: () => "machine-self",
    remoteAccessEnabled: () => false,
    sessionDirectory: directory,
  });

  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  // Local transport sets no peer-session provider, so `relayEverAttached` stays
  // false for the life of this core. That is the whole point of the fixture.
  core.onHandshakeComplete();
  await waitForServices(sent);

  const sessionId = await createSession(bus, sent, "s1");

  const requestId = randomUUID();
  sent.length = 0;
  bus.dispatchInbound(
    createMessage("session-bus:directory", { requestId, sessionId }),
    "control",
    "loopback",
  );
  const result = await waitForDirectoryResult(sent, requestId);

  // Narrowed to this machine, and it says which fact did it rather than blaming
  // the carrier. Before the fix the peer row was offered as addressable and the
  // reach report described the network read the switch should have prevented.
  expect(result.reach).toEqual({ scope: "machine", why: "remote-access-off" });
  expect((result.sessions as { machineId: string | null }[]).map((r) => r.machineId)).toEqual([null]);
});

// REGRESSION: after a local core is promoted onto the relay, the loopback
// session and the relay slot share ONE bus + inbound handler. The desktop's own
// loopback frames (source "loopback") must NEVER be gated by the machine switch
// â€” even with mobile access off â€” or the user's local typing would be silently
// dropped. Relay-origin frames must still be gated.
test("loopback frames bypass the gate even when mobile access is off", async () => {
  const folder = tempFolder();

  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    remoteAccessEnabled: () => false,
  });

  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  // Simulate promotion: a relay slot wired the gate's session provider to the
  // attached app devices.
  core.setPeerSessionProvider(() => session("phone-pubkey-loopback-base64"));

  core.onHandshakeComplete();
  await waitForServices(sent);

  // A relay-origin verb must be DROPPED.
  const tRelay = `t-${randomUUID()}`;
  sent.length = 0;
  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: tRelay, command: "node", args: ["-e", "0"] }),
    "control",
    "relay",
  );
  await new Promise((r) => setTimeout(r, 200));
  expect(statusListsTerminal(sent, tRelay)).toBe(false);

  // A loopback-origin verb (the desktop owner) must still be HONORED.
  const tLoop = `t-${randomUUID()}`;
  sent.length = 0;
  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: tLoop, command: "node", args: ["-e", "0"] }),
    "control",
    "loopback",
  );
  expect(await waitForTerminal(sent, tLoop)).toBe(true);
});

// CRITICAL #1: tunnel streams bypass the bus (they admit via
// core.tunnelStreams.admit onto their own QUIC stream, A3). A phone must NOT be
// able to read a project's dev-server data through them with the machine
// switch off.
test("core.tunnelStreams.admit refuses NOT_ALLOWED while mobile access is off, and admits once it is on", async () => {
  const folder = tempFolder();
  let mobileAccess = false;

  core = await buildAgentCore({
    folder,
    mode: "remote",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    remoteAccessEnabled: () => mobileAccess,
  });

  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.setPeerSessionProvider(() => session("phone-pubkey-tunnel-base64"));

  core.onHandshakeComplete();
  await waitForServices(sent);

  // --- Off: refused in-band, never parked. ---
  const refused = core.tunnelStreams.admit("phone-pubkey-tunnel-base64", "main");
  expect(refused).toMatchObject({ ok: false, refusal: { code: "NOT_ALLOWED" } });

  // --- On: the same peer/checkout is admitted with a live manager. ---
  mobileAccess = true;
  const admitted = core.tunnelStreams.admit("phone-pubkey-tunnel-base64", "main");
  expect(admitted.ok).toBe(true);
});

async function gitIn(folder: string, args: string[]): Promise<void> {
  const proc = Bun.spawn(["git", ...args], { cwd: folder, stdout: "ignore", stderr: "pipe" });
  const code = await proc.exited;
  if (code !== 0) throw new Error(await new Response(proc.stderr).text());
}

/** A managed-worktree session can only be created inside a repository, so the
 *  checkout half of the fan-out needs a real one to branch from. */
async function initRepo(folder: string): Promise<void> {
  await gitIn(folder, ["init"]);
  await gitIn(folder, ["config", "user.email", "test@antgrid.local"]);
  await gitIn(folder, ["config", "user.name", "Antgrid Test"]);
  await gitIn(folder, ["add", "."]);
  await gitIn(folder, ["commit", "-m", "initial"]);
}

/** A local TCP server that echoes every byte back, standing in for a dev
 *  server: the tunnel manager under test dials it exactly as it would a real
 *  one. */
function echoServer() {
  return net.createServer((socket) => {
    socket.on("error", () => {});
    socket.on("data", (chunk) => socket.write(chunk));
  });
}

async function listen(server: net.Server): Promise<number> {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return (server.address() as net.AddressInfo).port;
}

/** A tunnel peer that records what a run reports, so a test can wait on the
 *  echo without a real stream. */
function recordingPeer() {
  const events: string[] = [];
  const received: number[] = [];
  return {
    events,
    received,
    peer: {
      ready: async () => { events.push("ready"); return "sent" as const; },
      unreachable: (message: string) => { events.push(`unreachable:${message}`); },
      data: async (bytes: Uint8Array) => { received.push(...bytes); return "sent" as const; },
      end: () => { events.push("end"); },
    },
  };
}

async function eventually(condition: () => boolean, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition() && Date.now() < deadline) await new Promise((r) => setTimeout(r, 15));
  expect(condition()).toBe(true);
}

// The manager a core hands out is the only thing that dials a dev server on a
// phone's behalf, so this proves the admitted manager really forwards bytes.
test("core.tunnelStreams.admit hands out a manager that pipes raw TCP to a local port and back", async () => {
  const folder = tempFolder();
  const server = echoServer();
  const port = await listen(server);

  try {
    core = await buildAgentCore({
      folder,
      mode: "remote",
      identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
      remoteAccessEnabled: () => true,
    });

    const bus = new MessageBus();
    const sent: AbMessage[] = [];
    bus.subscribe({ deliver: (m) => sent.push(m) });
    core.attachTransport(bus);
    core.setPeerSessionProvider(() => session("phone-pubkey-tcp-base64"));

    core.onHandshakeComplete();
    await waitForServices(sent);

    const admission = core.tunnelStreams.admit("app-dev#machine-dev", "main");
    if (!admission.ok) throw new Error("expected admission");

    const rec = recordingPeer();
    const sink = admission.manager.serveTcp(
      { type: "tunnel:tcp-open", connId: "c1", port, checkoutId: "main" },
      rec.peer,
    );
    await eventually(() => rec.events.includes("ready"));
    await sink.write(Uint8Array.from([1, 2, 3, 4]));
    await eventually(() => rec.received.length === 4);
    expect(rec.received).toEqual([1, 2, 3, 4]);

    sink.end();
    await eventually(() => rec.events.includes("end"));
  } finally {
    server.close();
  }
});

// An isolated session runs its own TunnelManager, so a preview stream that
// names a checkout must be handed that checkout's manager, not main's.
test("core.tunnelStreams.admit hands a checkout its own manager, which also forwards", async () => {
  const folder = tempFolder();
  await initRepo(folder);
  const server = echoServer();
  const port = await listen(server);

  try {
    core = await buildAgentCore({
      folder,
      mode: "remote",
      worktreeSessionsSupported: true,
      identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
      remoteAccessEnabled: () => true,
    });

    const bus = new MessageBus();
    const sent: AbMessage[] = [];
    bus.subscribe({ deliver: (m) => sent.push(m) });
    core.attachTransport(bus);
    core.setPeerSessionProvider(() => session("phone-pubkey-tcp-checkout-base64"));

    core.onHandshakeComplete();
    await waitForServices(sent);

    // Loopback, so the isolated session is created before anything depends on a
    // remote app advertising checkout routing.
    const requestId = randomUUID();
    bus.dispatchInbound(
      createMessage("session:create", { requestId, name: "Isolated", isolation: "worktree" }),
      "control",
      "loopback",
    );
    const createdBy = Date.now() + 30_000;
    let checkoutId: string | undefined;
    while (Date.now() < createdBy && checkoutId === undefined) {
      const result = sent.find(
        (m) => m.type === "session:result" && (m as { requestId?: string }).requestId === requestId,
      );
      if (result) {
        checkoutId = (result as { session?: { checkoutId?: string } }).session?.checkoutId;
        break;
      }
      await new Promise((r) => setTimeout(r, 20));
    }
    expect(typeof checkoutId).toBe("string");
    expect(checkoutId).not.toBe("main");

    const mainAdmission = core.tunnelStreams.admit("app-dev#machine-dev", "main");
    const checkoutAdmission = core.tunnelStreams.admit("app-dev#machine-dev", checkoutId!);
    if (!mainAdmission.ok || !checkoutAdmission.ok) throw new Error("expected both admissions to succeed");
    expect(checkoutAdmission.manager).not.toBe(mainAdmission.manager);

    const rec = recordingPeer();
    const sink = checkoutAdmission.manager.serveTcp(
      { type: "tunnel:tcp-open", connId: "c-checkout", port, checkoutId: checkoutId! },
      rec.peer,
    );
    await eventually(() => rec.events.includes("ready"));
    await sink.write(Uint8Array.from([9]));
    await eventually(() => rec.received.length === 1);
    sink.end();
    await eventually(() => rec.events.includes("end"));
  } finally {
    server.close();
  }
}, 60_000);
