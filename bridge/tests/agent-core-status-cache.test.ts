// A relay app rebuilds its per-checkout terminal tabs from ONE thing: the
// frames its `state.snapshot` request is answered with. `terminal:started` is
// not a replay type and a stream attach runs no `resyncState` — only a loopback
// owner connect does — so nothing else ever tells it a PTY exists. Every test
// here therefore asserts through a real snapshot request rather than reading
// the bus cache behind its back: the gap between the two IS the bug. Served
// verbatim, the cached agent:status can be arbitrarily older than the pull, and
// a replayed terminal-less status DELETES the tabs the app already has. All of
// this is invisible to a loopback app, which resyncState feeds regardless.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage, type SessionEntry } from "../src/protocol";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-status-cache-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: status-cache\n");
  // Outlives the test; the PTY is reaped by core.shutdown().
  writeFileSync(join(root, "keepalive.js"), "setTimeout(() => {}, 600000);\n");
});

afterEach(async () => {
  await core?.shutdown();
  core = null;
  if (previousAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = previousAbDir;
  rmSync(root, { recursive: true, force: true });
});

// Every test below raises its budget to TEST_MS, because bun's 5s per-test
// default is not enough for a cold `git worktree add` plus an agent-core boot
// on a Windows CI runner. WAIT_MS stays under it so a hang reports WHICH wait
// timed out instead of an anonymous "test timed out after 5000ms".
const WAIT_MS = 20_000;
const TEST_MS = 30_000;

async function waitFor(
  predicate: () => boolean,
  what: string,
  timeoutMs = WAIT_MS,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

async function git(args: string[]): Promise<void> {
  const proc = Bun.spawn(["git", ...args], { cwd: root, stdout: "ignore", stderr: "pipe" });
  if (await proc.exited !== 0) throw new Error(await new Response(proc.stderr).text());
}

async function initRepo(): Promise<void> {
  await git(["init"]);
  await git(["config", "user.email", "test@antgrid.local"]);
  await git(["config", "user.name", "Antgrid Test"]);
  await git(["add", "."]);
  await git(["commit", "-m", "initial"]);
}

async function bootCore(): Promise<{ bus: MessageBus; sent: AbMessage[] }> {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    worktreeSessionsSupported: true,
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (message) => sent.push(message) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"), "the first agent:status");
  return { bus, sent };
}

/** Exactly what a (re)connecting app is handed for [checkoutId] — the frames a
 *  real `state.snapshot` request answers with, never a peek at the cache behind
 *  it, which is precisely the difference between a loopback app and a relay
 *  one. Null when the answer names no status for that checkout at all: an
 *  assertion that some id is ABSENT would pass just as happily against an empty
 *  answer, so the negative cases below have to tell the two apart.
 *
 *  Dispatched as loopback only to clear the mobile-access gate, which stands in
 *  front of the whole inbound handler; the recompute under test sits behind it
 *  and reads no source. */
async function pullStatus(
  bus: MessageBus,
  sent: AbMessage[],
  checkoutId: string,
): Promise<{ terminalId: string; running: boolean }[] | null> {
  const requestId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("request", {
    requestId, method: "state.snapshot", params: { types: ["*"] },
  }), "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "response" && m.requestId === requestId),
    `the state.snapshot response for ${checkoutId}`,
  );
  const res = sent.find((m) => m.type === "response" && m.requestId === requestId);
  if (res?.type !== "response" || !res.ok) {
    throw new Error(`state.snapshot failed: ${JSON.stringify(res)}`);
  }
  const { frames } = res.result as { frames: AbMessage[] };
  for (const frame of frames) {
    if (frame.type !== "agent:status" || frame.checkoutId !== checkoutId) continue;
    return frame.terminals.map((t) => ({ terminalId: t.terminalId, running: t.running }));
  }
  return null;
}

async function pullRunning(
  bus: MessageBus,
  sent: AbMessage[],
  checkoutId: string,
): Promise<string[]> {
  return ((await pullStatus(bus, sent, checkoutId)) ?? [])
    .filter((t) => t.running)
    .map((t) => t.terminalId);
}

/** The negative half of the per-checkout contract, with the "no status at all"
 *  escape hatch closed. */
async function expectPulledWithout(
  bus: MessageBus,
  sent: AbMessage[],
  checkoutId: string,
  terminalId: string,
): Promise<void> {
  const pulled = await pullStatus(bus, sent, checkoutId);
  expect(pulled).not.toBeNull();
  expect(pulled!.map((t) => t.terminalId)).not.toContain(terminalId);
}

async function startSession(
  bus: MessageBus,
  sent: AbMessage[],
  name: string,
  isolation?: "worktree",
): Promise<SessionEntry> {
  const createId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("session:create", {
    requestId: createId, name, command: "node keepalive.js",
    ...(isolation ? { isolation } : {}),
  }), "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "session:result" && m.requestId === createId),
    "the session:create result",
  );
  const created = sent.find(
    (m) => m.type === "session:result" && m.requestId === createId,
  );
  if (created?.type !== "session:result" || !created.ok || !created.session) {
    throw new Error(`session:create failed: ${JSON.stringify(created)}`);
  }
  const session = created.session;

  const startId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("session:start", {
    requestId: startId, sessionId: session.id,
  }), "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "terminal:started" && m.terminalId === session.id),
    "the session PTY to start",
  );
  return session;
}

// The whole bug in one line: nothing republishes a checkout's status when a PTY
// spawns — `session:start` never calls it, `startCheckoutRuntime`'s call runs
// BEFORE the spawn, the git poll fires only on a branch change — so a pull that
// does not recompute is answered with a status that predates the terminal.
test("a PTY started after connect is named by the next snapshot pull", async () => {
  const { bus, sent } = await bootCore();
  const session = await startSession(bus, sent, "Main");

  expect(await pullRunning(bus, sent, "main")).toContain(session.id);
}, TEST_MS);

test("an isolated session's PTY is pulled for ITS checkout, never for main", async () => {
  await initRepo();
  const { bus, sent } = await bootCore();
  const session = await startSession(bus, sent, "Isolated", "worktree");
  expect(session.checkoutId).not.toBe("main");

  expect(await pullRunning(bus, sent, session.checkoutId)).toContain(session.id);
  await expectPulledWithout(bus, sent, "main", session.id);
}, TEST_MS);

test("an ad-hoc terminal is pulled for its own checkout", async () => {
  await initRepo();
  const { bus, sent } = await bootCore();
  const session = await startSession(bus, sent, "Isolated", "worktree");
  const terminalId = "adhoc-1";

  bus.dispatchInbound(createMessage("terminal:start", {
    terminalId, command: "node", args: ["keepalive.js"], checkoutId: session.checkoutId,
  }), "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "terminal:started" && m.terminalId === terminalId),
    "the ad-hoc terminal to start",
  );

  expect(await pullRunning(bus, sent, session.checkoutId)).toContain(terminalId);
  await expectPulledWithout(bus, sent, "main", terminalId);
}, TEST_MS);

// Two neighbouring defects are deliberately NOT pinned here, because this
// change does not fix them and a test that asserts today's behaviour would
// cement them. Both are about ATTRIBUTION rather than freshness, so the pull
// recomputing changes nothing for either:
//
//   - An exited ad-hoc terminal leaves its own checkout. `onTerminalExited`
//     drops the `terminalOwners` row, so the namespaced id then resolves
//     through `terminalOwner`'s "main" default: the stopped tab disappears
//     from the checkout the user is looking at and reappears in main's status
//     under `<checkoutId>:<name>`.
//   - A deleted session's PTY is never forgotten. `manager.forget()` is called
//     only from `teardownCheckoutRuntime`, over `configuredTerminalIds` —
//     which `internalTerminalId` returns early for a session id, so it never
//     holds one. The row survives in `stoppedTerminals` for the life of the
//     process with both its session entry and its owner row gone, and lands in
//     main's status as a tab nothing can close.

test("a stopped session stops being pulled as running", async () => {
  const { bus, sent } = await bootCore();
  const session = await startSession(bus, sent, "Main");
  expect(await pullRunning(bus, sent, "main")).toContain(session.id);

  bus.dispatchInbound(createMessage("session:stop", {
    requestId: crypto.randomUUID(), sessionId: session.id,
  }), "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "terminal:exited" && m.terminalId === session.id),
    "the session PTY to exit",
  );

  expect(await pullRunning(bus, sent, "main")).not.toContain(session.id);
}, TEST_MS);
