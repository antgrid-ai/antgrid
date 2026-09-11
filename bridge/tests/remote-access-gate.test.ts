import { test, expect, beforeEach, afterEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { loadPairedPhones } from "../src/paired-phones";
import { createMessage, type AbMessage } from "../src/protocol";
import { RelayClient } from "../src/relay-client";
import { createRelayPromotion, type MachineRelaySession } from "../src/relay-promotion";
import { generateEphemeralKeypair } from "../src/key-exchange";

function tunnelResponses(frames: object[]): object[] {
  return frames.filter((f) => (f as { type?: string }).type === "tunnel:http-start");
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
  // before shutdown() returns, and an overrun hook is not cancelled — its body
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
 *  or the timeout elapses. Used for the honored path, where spawn → sendStatus
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
  // Wire the connected-phone identity exactly as the remote transport does.
  core.setPeerPubkeyProvider(() => "phone-pubkey-1-base64");

  // Spin up managers (the relay does this after the E2E handshake confirms).
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
  core.setPeerPubkeyProvider(() => "phone-pubkey-unwired");

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

test("does NOT gate when no phone pubkey is present (local/loopback transport)", async () => {
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
  // Local transport never sets a provider → gate sees null → not gated.

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

// REGRESSION: after a local core is promoted onto the relay, the loopback
// session and the relay slot share ONE bus + inbound handler. The desktop's own
// loopback frames (source "loopback") must NEVER be gated by the machine switch
// — even with mobile access off — or the user's local typing would be silently
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
  // Simulate promotion: a relay slot wired the gate's peer provider to the
  // connected phone.
  core.setPeerPubkeyProvider(() => "phone-pubkey-loopback-base64");

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

// CRITICAL #1: tunnel:* frames bypass the bus (they route via onTunnelMessage →
// core.handleTunnelMessage → TunnelManager's localhost HTTP proxy). A phone must
// NOT be able to read a project's dev-server data through them with the machine
// switch off.
test("drops tunnel:http-request while mobile access is off, honors it once on", async () => {
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
  core.setPeerPubkeyProvider(() => "phone-pubkey-tunnel-base64");

  // The tunnel response frames are emitted via the plaintext hook (they bypass
  // the bus); capture them to detect whether the proxy actually ran.
  const plain: object[] = [];
  core.setPlainHook(async (d) => { plain.push(d); return "sent"; });

  core.onHandshakeComplete();
  await waitForServices(sent);

  // --- Off: the proxy must NOT run → no tunnel:http-start. ---
  plain.length = 0;
  core.handleTunnelMessage({
    type: "tunnel:http-request",
    requestId: "req-1",
    port: 65500, // nothing listening; an admitted request would still emit a 502
    method: "GET",
    path: "/secret",
  });
  await new Promise((r) => setTimeout(r, 300));
  expect(tunnelResponses(plain).length).toBe(0);

  // --- On: the same request now reaches the proxy (a 502 from the dead port is
  //     still proof the gate let it through). ---
  mobileAccess = true;
  plain.length = 0;
  core.handleTunnelMessage({
    type: "tunnel:http-request",
    requestId: "req-2",
    port: 65500,
    method: "GET",
    path: "/secret",
  });
  // Poll for the async fetch → response.
  const deadline = Date.now() + 2000;
  while (Date.now() < deadline && tunnelResponses(plain).length === 0) {
    await new Promise((r) => setTimeout(r, 15));
  }
  expect(tunnelResponses(plain).length).toBe(1);
  expect((tunnelResponses(plain)[0] as { requestId?: string }).requestId).toBe("req-2");
});

// SOFT CONCERN (real bypass): on a trusted reconnect the relay sends peer-online
// (NOT a fresh pair-request), so onApproved never repopulates the pubkey map.
// After an agent RESTART the map starts empty, so currentPeerPubkey() would
// return null — and a null peer reads as "local", which skips the gate. The
// peer-online handler must backfill the pubkey from the persistent pairedPhones
// store so a remote phone is still recognised as remote.
test("currentPeerPubkey backfills from the phone store on trusted reconnect (empty map)", async () => {
  const store = loadPairedPhones(abDir);
  const pk1 = "phone-pubkey-reconnect-base64";
  const phoneDeviceId = "phone-dev-reconnect";
  store.upsert({
    phonePubkey: pk1,
    phoneDeviceId,
    pairedAt: new Date().toISOString(),
    lastSeenAt: new Date().toISOString(),
  });

  // A fresh RelayClient simulates the post-restart state: phoneEd25519ByDeviceId
  // starts empty (it's in-memory, never persisted).
  const client = new RelayClient({
    url: "ws://127.0.0.1:1",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    generateKeypair: () => generateEphemeralKeypair(),
    getLicenseToken: () => "tok",
    pairedPhones: store,
  });

  // Before reconnect there is no peer → null.
  expect(client.currentPeerPubkey()).toBe(null);

  // Drive the real peer-online server message (the reconnect-restore path).
  (client as unknown as { handleTextMessage(raw: string): void }).handleTextMessage(
    JSON.stringify({ type: "peer-online", peerId: phoneDeviceId }),
  );

  // The gate can now identify the reconnected phone even though no fresh
  // pair-request (and thus no onApproved) ran this process.
  expect(client.currentPeerPubkey()).toBe(pk1);

  client.close();
});

// CRITICAL #2: a local→relay-promoted connection must be gated too. In v3
// relay-promotion.ts no longer builds its own RelayClient — it asks the host
// to bring the ONE machine socket up (ensureMachineRelay) and hands the result
// to ProjectCore's `attach` (which owns the real setPeerPubkeyProvider wiring;
// see project-core.ts's attachRelayStream). This test stubs `attach` the same
// way ProjectCore really implements it, so the load-bearing assertion —
// enabling relay wires the gate to the promoted session's connected phone, and
// disabling clears it — still holds under the new dependency split.
test("promotion wires (and clears) the gate's peer provider", async () => {
  const bus = new MessageBus();
  bus.setInboundHandler(() => {});

  let provider: (() => string | null) | null | undefined = undefined;
  const setCalls: Array<(() => string | null) | null> = [];

  const setPeerPubkeyProvider = (fn: (() => string | null) | null) => {
    setCalls.push(fn);
    provider = fn;
  };

  // Stub machine relay session whose currentPeerPubkey is observable through
  // the wired provider — mirrors what HostServer.ensureMachineRelay() returns.
  const machineSession: MachineRelaySession = {
    attachStream: () => ({ streamId: "s1", detach: () => {}, sendTunnel: async () => "sent" as const, sendFrame: () => {} }),
    currentPeerPubkey: () => "promoted-phone-pk",
    sendPushDeliver: () => {},
    agentDeviceId: "0bbd1111-2222-3333-4444-555566667777",
  };

  const ctrl = createRelayPromotion({
    bus,
    ensureMachineRelay: async () => machineSession,
    // Reproduces ProjectCore.attachLocalStreamForWizard's real wiring: wire
    // the gate's provider to the attached stream's peer, clear it on detach.
    attach: (remote) => {
      setPeerPubkeyProvider(() => remote.currentPeerPubkey());
      return {
        handle: { streamId: "s1", detach: () => {}, sendTunnel: async () => "sent" as const, sendFrame: () => {} },
        detach: () => { setPeerPubkeyProvider(null); },
      };
    },
  });

  ctrl.handleInbound(
    createMessage("agent:enableRelay", {
      relayUrl: "https://relay.example.com",
      auth: {
        deviceUuid: "0bbd1111-2222-3333-4444-555566667777",
        ed25519Pub: Buffer.from("edpub").toString("base64url"),
        ed25519Priv: Buffer.from("edpriv").toString("base64url"),
        licenseToken: "static-token",
      },
    }) as AbMessage,
  );
  await new Promise((r) => setTimeout(r, 20));

  // Provider was wired and reflects the promoted session's connected phone.
  expect(typeof provider).toBe("function");
  const wired = provider as unknown as () => string | null;
  expect(wired()).toBe("promoted-phone-pk");

  // Teardown clears it (so the demoted local session is ungated again).
  ctrl.stop();
  expect(setCalls[setCalls.length - 1]).toBe(null);
});

// The core-level half of the abort: `project-core`'s peer hooks reach every
// checkout runtime's TunnelManager only through this one call, and a body left
// streaming past a peer loss burns the whole credit window on frames nobody
// will read. (It lives here because this file is the only place that builds a
// real core with a plaintext hook.)
/** A dev server whose body trickles, so the flush window turns a response into
 *  a start plus chunks rather than one whole-body frame. `onCancel` is handed
 *  the request path, which is how a caller with two concurrent runs tells which
 *  upstream the bridge let go of. */
function trickleServer(onCancel: (path: string) => void) {
  return Bun.serve({
    port: 0,
    fetch(req) {
      const path = new URL(req.url).pathname;
      return new Response(
        new ReadableStream<Uint8Array>({
          start(c) {
            let n = 0;
            const timer = setInterval(() => {
              try {
                if (n++ >= 200) { clearInterval(timer); c.close(); return; }
                c.enqueue(new Uint8Array(4096).fill(0x61));
              } catch { clearInterval(timer); }
            }, 20);
          },
          cancel() { onCancel(path); },
        }),
        { headers: { "content-type": "application/octet-stream" } },
      );
    },
  });
}

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

test("abortTunnelStreams aborts the core's in-flight tunnel streams", async () => {
  const folder = tempFolder();
  const upstream = { cancelled: false };
  const route = trickleServer(() => { upstream.cancelled = true; });

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
    core.setPeerPubkeyProvider(() => "phone-pubkey-abort-base64");

    const plain: object[] = [];
    const held: Array<(o: "sent") => void> = [];
    core.setPlainHook(async (d) => {
      plain.push(d);
      // Park on the first chunk so the run is mid-body when the abort lands.
      if ((d as { type?: string }).type === "tunnel:http-chunk" && held.length === 0) {
        return new Promise<"sent">((resolve) => held.push(resolve));
      }
      return "sent";
    });

    core.onHandshakeComplete();
    await waitForServices(sent);

    core.handleTunnelMessage({
      type: "tunnel:http-request",
      requestId: "abort-me",
      port: route.port!,
      method: "GET",
      path: "/big",
    });

    const heldBy = Date.now() + 5000;
    while (held.length === 0 && Date.now() < heldBy) await new Promise((r) => setTimeout(r, 15));
    expect(held.length).toBe(1);

    core.abortTunnelStreams();
    for (const resolve of held.splice(0)) resolve("sent");

    const cancelledBy = Date.now() + 2000;
    while (!upstream.cancelled && Date.now() < cancelledBy) await new Promise((r) => setTimeout(r, 15));
    expect(upstream.cancelled).toBe(true);

    const before = plain.length;
    await new Promise((r) => setTimeout(r, 200));
    expect(plain.length).toBe(before);
    expect(plain.some((f) => (f as { type?: string }).type === "tunnel:http-end")).toBe(false);
  } finally {
    route.stop(true);
  }
});

// The other half of the same call: an isolated session runs its own
// TunnelManager, so a core that aborted only the main one would leave a managed
// checkout streaming a dead body past the peer loss. Nothing but this fan-out
// reaches those managers.
test("abortTunnelStreams reaches a checkout runtime's manager, not only main", async () => {
  const folder = tempFolder();
  await initRepo(folder);
  const cancelled = new Set<string>();
  const route = trickleServer((path) => cancelled.add(path));

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
    core.setPeerPubkeyProvider(() => "phone-pubkey-abort-checkout-base64");

    const plain: object[] = [];
    const held = new Map<string, (o: "sent") => void>();
    const parked = new Set<string>();
    core.setPlainHook(async (d) => {
      plain.push(d);
      const frame = d as { type?: string; requestId?: string };
      // Park each run on ITS first chunk, so both are mid-body when the abort
      // lands and neither can finish while the other is still climbing.
      if (frame.type === "tunnel:http-chunk" && frame.requestId && !parked.has(frame.requestId)) {
        parked.add(frame.requestId);
        const requestId = frame.requestId;
        return new Promise<"sent">((resolve) => held.set(requestId, resolve));
      }
      return "sent";
    });

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

    core.handleTunnelMessage({
      type: "tunnel:http-request",
      requestId: "abort-main",
      port: route.port!,
      method: "GET",
      path: "/main",
      checkoutId: "main",
    });
    core.handleTunnelMessage({
      type: "tunnel:http-request",
      requestId: "abort-checkout",
      port: route.port!,
      method: "GET",
      path: "/checkout",
      checkoutId,
    });

    const heldBy = Date.now() + 15_000;
    while (held.size < 2 && Date.now() < heldBy) await new Promise((r) => setTimeout(r, 15));
    expect(held.size).toBe(2);

    core.abortTunnelStreams();
    for (const resolve of held.values()) resolve("sent");
    held.clear();

    const cancelledBy = Date.now() + 5000;
    while (cancelled.size < 2 && Date.now() < cancelledBy) await new Promise((r) => setTimeout(r, 15));
    expect([...cancelled].sort()).toEqual(["/checkout", "/main"]);

    const before = plain.length;
    await new Promise((r) => setTimeout(r, 300));
    expect(plain.length).toBe(before);
    expect(plain.some((f) => (f as { type?: string }).type === "tunnel:http-end")).toBe(false);
  } finally {
    route.stop(true);
  }
}, 60_000);
