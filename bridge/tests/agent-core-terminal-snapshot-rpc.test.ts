// The correlated RPC twin of terminal:snapshot:request (see
// agent-core-terminal-snapshot.test.ts for the message-path fixtures this
// mirrors, and agent-core-transcript-snapshot.test.ts for the
// findResponse/mobile-access-drop shape reused below).
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { loadPairedPhones } from "../src/paired-phones";
import { createMessage, type AbMessage } from "../src/protocol";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-terminal-snapshot-rpc-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: terminal-snapshot-rpc\nagent:\n  tool: claude-code\n");
});

// Same 30s / read-before-await shape as agent-core-checkout-routing.test.ts —
// `shutdown()` waits out a graceful PTY kill (5s) plus the git drain behind
// it, and a hook that overruns resumes inside the NEXT test's already-
// reassigned module slots if these aren't captured first.
afterEach(async () => {
  const dying = core;
  const dir = root;
  const restore = previousAbDir;
  core = null;
  if (restore === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = restore;
  try {
    await dying?.shutdown();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}, 30_000);

async function waitFor(
  sent: AbMessage[],
  predicate: (message: AbMessage) => boolean,
  what: string,
  timeoutMs = 5000,
): Promise<AbMessage> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = sent.find(predicate);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

function findResponse(frames: AbMessage[], requestId: string): AbMessage | undefined {
  return frames.find((m) => m.type === "response" && (m as { requestId?: string }).requestId === requestId);
}

async function waitForResponse(sent: AbMessage[], requestId: string, timeoutMs = 5000): Promise<AbMessage> {
  return waitFor(sent, (m) => m.type === "response" && (m as { requestId?: string }).requestId === requestId, `response ${requestId}`, timeoutMs);
}

function requestSnapshot(
  bus: MessageBus,
  requestId: string,
  params: { terminalId?: string; checkoutId?: string; history?: boolean },
  source: "loopback" | "relay" = "loopback",
): void {
  bus.dispatchInbound(
    createMessage("request", { requestId, method: "terminal.snapshot", params }),
    "control",
    source,
  );
}

async function bootWithTerminal(opts: { worktreeSessionsSupported?: boolean } = {}): Promise<{ bus: MessageBus; sent: AbMessage[] }> {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    worktreeSessionsSupported: opts.worktreeSessionsSupported,
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (message) => sent.push(message) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(sent, (m) => m.type === "agent:status", "agent:status");

  // cwd deliberately outside the project: on Windows a live PTY holds its own
  // cwd open and the fixture's teardown rm would hit EBUSY.
  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: "adhoc", cwd: tmpdir() }),
    "control",
    "loopback",
  );
  await waitFor(
    sent,
    (m) => m.type === "terminal:started" && m.terminalId === "adhoc",
    "terminal:started",
  );
  return { bus, sent };
}

test("warm RPC snapshot answers ok:true with a composed, non-empty blob", async () => {
  const { bus, sent } = await bootWithTerminal();
  sent.length = 0;

  requestSnapshot(bus, "r1", { terminalId: "adhoc" });
  const res = await waitForResponse(sent, "r1");
  if (res.type !== "response") throw new Error("unreachable");
  expect(res.ok).toBe(true);
  const snapshot = (res.result as { snapshot?: Record<string, unknown> }).snapshot;
  expect(snapshot).not.toBeNull();
  expect(snapshot?.composed).toBe(true);
  expect(typeof snapshot?.scrollback).toBe("string");
  expect((snapshot?.scrollback as string).length).toBeGreaterThan(0);
  expect(typeof snapshot?.seq).toBe("number");
  expect(snapshot?.seq as number).toBeGreaterThanOrEqual(0);
  expect(snapshot?.terminalId).toBe("adhoc");
});

test("cold RPC snapshot carries the erasing history preamble a warm one must not", async () => {
  const { bus, sent } = await bootWithTerminal();
  sent.length = 0;

  requestSnapshot(bus, "r-cold", { terminalId: "adhoc", history: true });
  const cold = await waitForResponse(sent, "r-cold");
  if (cold.type !== "response") throw new Error("unreachable");
  const coldSnap = (cold.result as { snapshot?: { scrollback?: string } }).snapshot;
  expect(coldSnap?.scrollback).toContain("\x1b[3J");

  sent.length = 0;
  requestSnapshot(bus, "r-warm", { terminalId: "adhoc" });
  const warm = await waitForResponse(sent, "r-warm");
  if (warm.type !== "response") throw new Error("unreachable");
  const warmSnap = (warm.result as { snapshot?: { scrollback?: string } }).snapshot;
  expect(warmSnap?.scrollback).not.toContain("\x1b[3J");
});

test("unknown terminalId answers ok:true with a null snapshot, not a timeout", async () => {
  const { bus, sent } = await bootWithTerminal();
  sent.length = 0;

  requestSnapshot(bus, "r-unknown", { terminalId: "never-existed" });
  const res = await waitForResponse(sent, "r-unknown");
  if (res.type !== "response") throw new Error("unreachable");
  expect(res.ok).toBe(true);
  expect((res.result as { snapshot: unknown }).snapshot).toBeNull();
});

test("missing terminalId is E_BAD_PARAMS", async () => {
  const { bus, sent } = await bootWithTerminal();
  sent.length = 0;

  requestSnapshot(bus, "r-badparams", {});
  const res = await waitForResponse(sent, "r-badparams");
  if (res.type !== "response") throw new Error("unreachable");
  expect(res.ok).toBe(false);
  expect(res.error?.code).toBe("E_BAD_PARAMS");
});

test("unknown checkoutId is UNKNOWN_CHECKOUT and no snapshot frame is emitted", async () => {
  const { bus, sent } = await bootWithTerminal();
  sent.length = 0;

  requestSnapshot(bus, "r-unknown-checkout", { terminalId: "adhoc", checkoutId: "does-not-exist" });
  const res = await waitForResponse(sent, "r-unknown-checkout");
  if (res.type !== "response") throw new Error("unreachable");
  expect(res.ok).toBe(false);
  expect(res.error?.code).toBe("UNKNOWN_CHECKOUT");
  // The one that must fail if `?? mainRuntime` creeps back in: a fallback
  // would answer out of main's runtime instead of refusing.
  expect(sent.filter((m) => m.type === "terminal:snapshot")).toEqual([]);
});

async function git(args: string[]): Promise<void> {
  const proc = Bun.spawn(["git", ...args], { cwd: root, stdout: "ignore", stderr: "pipe" });
  const code = await proc.exited;
  if (code !== 0) throw new Error(await new Response(proc.stderr).text());
}

async function initRepo(): Promise<void> {
  await git(["init"]);
  await git(["config", "user.email", "test@antgrid.local"]);
  await git(["config", "user.name", "Antgrid Test"]);
  await git(["add", "."]);
  await git(["commit", "-m", "initial"]);
}

interface SessionResult {
  id: string;
  checkoutId: string;
}

async function createIsolatedSession(bus: MessageBus, sent: AbMessage[]): Promise<SessionResult> {
  const requestId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("session:create", {
    requestId, name: "Isolated", isolation: "worktree",
  }), "control", "loopback");
  const result = await waitFor(sent, (message) =>
    message.type === "session:result" && message.requestId === requestId,
    "session:result",
    20000,
  );
  if (result.type !== "session:result" || !result.session) throw new Error("session missing");
  return { id: result.session.id, checkoutId: result.session.checkoutId };
}

async function bootIsolated(): Promise<{ bus: MessageBus; sent: AbMessage[]; session: SessionResult }> {
  writeFileSync(join(root, "same.txt"), "main\n");
  await initRepo();
  const { bus, sent } = await bootWithTerminal({ worktreeSessionsSupported: true });
  const session = await createIsolatedSession(bus, sent);
  return { bus, sent, session };
}

test("a checkout whose delete is in flight answers CHECKOUT_DELETING", async () => {
  const { bus, sent, session } = await bootIsolated();
  const { checkoutId } = session;

  // Same in-flight-delete race as agent-core-checkout-routing.test.ts's
  // `duringIsolatedDelete`: fire the RPC from inside the delivery of the
  // first `session:updated` carrying `deleting: true`, which removes the
  // scheduler gap so the window is hit deterministically.
  let fired = false;
  const unsubscribe = bus.subscribe({
    deliver: (message) => {
      if (fired) return;
      if (message.type !== "session:updated") return;
      if (!message.sessions.some((s) => s.checkoutId === checkoutId && s.deleting)) return;
      fired = true;
      requestSnapshot(bus, "r-deleting", { terminalId: "adhoc", checkoutId });
    },
  });
  try {
    const deleteRequestId = crypto.randomUUID();
    bus.dispatchInbound(createMessage("session:delete", { requestId: deleteRequestId, sessionId: session.id }), "control", "loopback");
    const deleteResult = await waitFor(sent, (m) =>
      m.type === "session:result" && m.requestId === deleteRequestId,
      "session:result (delete)",
      20000,
    );
    expect(deleteResult).toMatchObject({ type: "session:result", ok: true });
    expect(fired).toBe(true);

    const res = await waitForResponse(sent, "r-deleting");
    if (res.type !== "response") throw new Error("unreachable");
    expect(res.ok).toBe(false);
    expect(res.error?.code).toBe("CHECKOUT_DELETING");
  } finally {
    unsubscribe();
  }
}, 30_000);

test("an RPC naming an isolated checkout answers that checkout's screen, never main's", async () => {
  const { bus, sent, session } = await bootIsolated();
  const { checkoutId } = session;

  // A second terminal, same external id "adhoc", but living in the isolated
  // checkout's own namespace.
  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: "adhoc", cwd: tmpdir(), checkoutId }),
    "control",
    "loopback",
  );
  await waitFor(sent, (m) =>
    m.type === "terminal:started" && m.terminalId === "adhoc" && "checkoutId" in m && m.checkoutId === checkoutId,
    "isolated terminal:started",
  );

  // Distinguish the two screens by writing distinct bytes into each PTY.
  bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data: "echo main-only\r" }), "control", "loopback");
  bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data: "echo isolated-only\r", checkoutId }), "control", "loopback");
  await new Promise((resolve) => setTimeout(resolve, 500));

  sent.length = 0;
  requestSnapshot(bus, "r-isolated-screen", { terminalId: "adhoc", checkoutId });
  const res = await waitForResponse(sent, "r-isolated-screen");
  if (res.type !== "response") throw new Error("unreachable");
  expect(res.ok).toBe(true);
  const scrollback = (res.result as { snapshot?: { scrollback?: string } }).snapshot?.scrollback ?? "";
  expect(scrollback).toContain("isolated-only");
  expect(scrollback).not.toContain("main-only");
});

test("dropped from a remote phone while mobile access is off — no response at all", async () => {
  const store = loadPairedPhones(join(root, "state"));
  const pk1 = "phone-pubkey-terminal-snap-rpc";
  store.upsert({
    phonePubkey: pk1,
    phoneDeviceId: "phone-dev-terminal-snap-rpc",
    pairedAt: new Date().toISOString(),
    lastSeenAt: new Date().toISOString(),
  });
  let mobileAccess = false;

  core = await buildAgentCore({
    folder: root,
    mode: "remote",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    pairedPhones: store,
    remoteAccessEnabled: () => mobileAccess,
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.setPeerPubkeyProvider(() => pk1);
  core.onHandshakeComplete();
  await waitFor(sent, (m) => m.type === "agent:status", "agent:status");

  sent.length = 0;
  requestSnapshot(bus, "r-gated", { terminalId: "adhoc" }, "relay");
  await new Promise((resolve) => setTimeout(resolve, 200));
  // Proves the app's timeout-≠-old-bridge rule: a fully new bridge produces
  // an unanswered request here too, so `E_UNKNOWN_METHOD` must stay the ONLY
  // signal the app reads as "old bridge".
  expect(findResponse(sent, "r-gated")).toBeUndefined();

  // Positive control, same shape as agent-core-transcript-snapshot.test.ts:
  // flip the switch and prove the method DOES reach the handler once allowed.
  mobileAccess = true;
  sent.length = 0;
  requestSnapshot(bus, "r-gated-on", { terminalId: "adhoc" }, "relay");
  const res = await waitForResponse(sent, "r-gated-on");
  if (res.type !== "response") throw new Error("unreachable");
  expect(res.ok).toBe(true);
});

test("transport equivalence: the RPC scrollback is byte-identical to the message path's, for the same history flag", async () => {
  const { bus, sent } = await bootWithTerminal();
  // Let the shell's own startup finish emitting mode sequences (git-bash's
  // profile toggles focus reporting on launch) before comparing two snapshots
  // taken moments apart — otherwise the two calls can straddle a real mode
  // change and differ for a reason that has nothing to do with the transport.
  await new Promise((resolve) => setTimeout(resolve, 600));

  sent.length = 0;
  requestSnapshot(bus, "r-equiv", { terminalId: "adhoc", history: true });
  const res = await waitForResponse(sent, "r-equiv");
  if (res.type !== "response") throw new Error("unreachable");
  const rpcScrollback = (res.result as { snapshot?: { scrollback?: string } }).snapshot?.scrollback;

  sent.length = 0;
  bus.dispatchInbound(
    createMessage("terminal:snapshot:request", { terminalId: "adhoc", history: true }),
    "control",
    "loopback",
  );
  const broadcast = await waitFor(sent, (m) => m.type === "terminal:snapshot" && m.terminalId === "adhoc", "terminal:snapshot");
  if (broadcast.type !== "terminal:snapshot") throw new Error("unreachable");

  expect(rpcScrollback).toBe(broadcast.scrollback);
});

test("the legacy terminal:snapshot:request message path still answers after the RPC exists", async () => {
  const { bus, sent } = await bootWithTerminal();
  sent.length = 0;

  bus.dispatchInbound(
    createMessage("terminal:snapshot:request", { terminalId: "adhoc" }),
    "control",
    "loopback",
  );
  const reply = await waitFor(sent, (m) => m.type === "terminal:snapshot" && m.terminalId === "adhoc", "terminal:snapshot");
  if (reply.type !== "terminal:snapshot") throw new Error("unreachable");
  expect(reply.composed).toBe(true);
});
