import { test, expect, beforeEach, afterEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { TestPeerSessionOwner } from "./test-peer-session-owner";
import { createRelayPromotion, type MachineRelaySession } from "../src/relay-promotion";
import type { PeerSessionView } from "../src/project-streams";

/** One established app session, as the relay transport would report it. */
function session(peerPubkey: string, peerId = "app-dev#machine-dev"): PeerSessionView {
  return { peerId, peerPubkey, checkoutRouting: true, pullsTree: true };
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

// CRITICAL #2: a localâ†’relay-promoted connection must be gated too. In v3
// relay-promotion.ts no longer builds its own TestPeerSessionOwner â€” it asks the host
// to bring the ONE machine socket up (ensureMachineRelay) and hands the result
// to ProjectCore's `attach` (which owns the real setPeerSessionProvider wiring;
// see project-core.ts's attachRelayStream). This test stubs `attach` the same
// way ProjectCore really implements it, so the load-bearing assertion â€”
// enabling relay wires the gate to the promoted session's attached devices, and
// disabling clears it â€” still holds under the new dependency split.
test("promotion wires (and clears) the gate's session provider", async () => {
  const bus = new MessageBus();
  bus.setInboundHandler(() => {});

  type Provider = (peerId: string) => PeerSessionView | null;
  let provider: Provider | null | undefined = undefined;
  const setCalls: Array<Provider | null> = [];

  const setPeerSessionProvider = (fn: Provider | null) => {
    setCalls.push(fn);
    provider = fn;
  };

  // Stub machine relay session whose attached device is observable through the
  // wired provider â€” mirrors what HostServer.ensureMachineRelay() returns.
  const promoted = session("promoted-phone-pk", "promoted-phone#machine-dev");
  const machineSession: MachineRelaySession = {
    attachStream: () => ({ detach: () => {}, sendTo: async () => "sent" as const, deliverableTo: () => true }),
    establishedPeers: () => [promoted],
    peerSession: (peerId) => (peerId === promoted.peerId ? promoted : null),
    sendPushDeliver: () => {},
    agentDeviceId: "0bbd1111-2222-3333-4444-555566667777",
  };

  const ctrl = createRelayPromotion({
    bus,
    ensureMachineRelay: async () => machineSession,
    // Reproduces ProjectCore.attachLocalStreamForWizard's real wiring: wire
    // the gate's provider to the attached stream's peer, clear it on detach.
    attach: (remote) => {
      setPeerSessionProvider((peerId) => remote.peerSession(peerId));
      return {
        handle: { detach: () => {}, sendTo: async () => "sent" as const, deliverableTo: () => true },
        detach: () => { setPeerSessionProvider(null); },
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

  // Provider was wired and resolves the promoted session's attached device.
  expect(typeof provider).toBe("function");
  const wired = provider as unknown as Provider;
  expect(wired(promoted.peerId)?.peerPubkey).toBe("promoted-phone-pk");
  // ...and only that device: an address it holds no session for resolves null,
  // which is what makes every per-device answer fail closed.
  expect(wired("someone-else#machine-dev")).toBe(null);

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

/** Tracks a fake `TunnelHttpExchange`'s calls in arrival order, so a test can
 *  assert `serveHttp` never reaches `end()` without a real app on the other
 *  end of the stream. The signal is never aborted by the test itself —
 *  `abortTunnelStreams()` fires `serveHttp`'s own per-run controller, which is
 *  combined with (not replaced by) this one, and a run aborted that way must
 *  `fail()` its exchange: the app is still attached and would otherwise wait
 *  on a stream that neither ends nor resets. */
function fakeExchange(calls: string[], peerId = "app-dev#machine-dev") {
  return {
    peerId,
    signal: new AbortController().signal,
    head: async () => { calls.push("head"); return "sent" as const; },
    body: async () => { calls.push("body"); return "sent" as const; },
    end: async () => { calls.push("end"); return "sent" as const; },
    fail: (_reason: string) => { calls.push("fail"); },
  };
}

test("abortTunnelStreams aborts the core's in-flight tunnel exchange: the upstream is cancelled and end() never runs", async () => {
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
    core.setPeerSessionProvider(() => session("phone-pubkey-abort-base64"));

    core.onHandshakeComplete();
    await waitForServices(sent);

    const admission = core.tunnelStreams.admit("app-dev#machine-dev", "main");
    if (!admission.ok) throw new Error("expected admission");

    const calls: string[] = [];
    const req = {
      type: "tunnel:http-request" as const,
      requestId: "abort-me",
      port: route.port!,
      method: "GET",
      path: "/big",
      bodyLength: 0,
      checkoutId: "main",
    };
    const run = admission.manager.serveHttp(req, null, fakeExchange(calls));

    const headBy = Date.now() + 5000;
    while (!calls.includes("head") && Date.now() < headBy) await new Promise((r) => setTimeout(r, 15));
    expect(calls).toContain("head");

    core.abortTunnelStreams("app-dev#machine-dev");
    await run;

    const cancelledBy = Date.now() + 2000;
    while (!upstream.cancelled && Date.now() < cancelledBy) await new Promise((r) => setTimeout(r, 15));
    expect(upstream.cancelled).toBe(true);
    expect(calls).not.toContain("end");
    expect(calls).toContain("fail");
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
    core.setPeerSessionProvider(() => session("phone-pubkey-abort-checkout-base64"));

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

    const mainCalls: string[] = [];
    const checkoutCalls: string[] = [];
    const mainReq = {
      type: "tunnel:http-request" as const, requestId: "abort-main", port: route.port!,
      method: "GET", path: "/main", bodyLength: 0, checkoutId: "main",
    };
    const checkoutReq = {
      type: "tunnel:http-request" as const, requestId: "abort-checkout", port: route.port!,
      method: "GET", path: "/checkout", bodyLength: 0, checkoutId: checkoutId!,
    };
    const mainRun = mainAdmission.manager.serveHttp(mainReq, null, fakeExchange(mainCalls));
    const checkoutRun = checkoutAdmission.manager.serveHttp(checkoutReq, null, fakeExchange(checkoutCalls));

    const headBy = Date.now() + 15_000;
    while ((!mainCalls.includes("head") || !checkoutCalls.includes("head")) && Date.now() < headBy) {
      await new Promise((r) => setTimeout(r, 15));
    }
    expect(mainCalls).toContain("head");
    expect(checkoutCalls).toContain("head");

    core.abortTunnelStreams("app-dev#machine-dev");
    await Promise.all([mainRun, checkoutRun]);

    const cancelledBy = Date.now() + 5000;
    while (cancelled.size < 2 && Date.now() < cancelledBy) await new Promise((r) => setTimeout(r, 15));
    expect([...cancelled].sort()).toEqual(["/checkout", "/main"]);

    expect(mainCalls).not.toContain("end");
    expect(checkoutCalls).not.toContain("end");
    expect(mainCalls).toContain("fail");
    expect(checkoutCalls).toContain("fail");
  } finally {
    route.stop(true);
  }
}, 60_000);
