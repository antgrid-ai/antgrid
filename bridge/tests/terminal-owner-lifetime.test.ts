// `sendStatus` routes every row `manager.getStatus()` reports through
// `terminalOwner`, and a STOPPED terminal is reported until it is forgotten —
// not until it exits. So the owner row has to outlive the PTY by exactly as
// long as the manager's memory of it does. Released any earlier, the corpse
// resolves through `terminalOwner`'s "main" default and is advertised in the
// primary workspace instead of the checkout it belongs to.
//
// Every assertion below reads the CACHED status — the frame `state.snapshot`
// serves a reconnecting app — after forcing a fresh publish, rather than the
// live frames the test happened to see. Attribution is only observable in what
// a later client is handed.
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
  root = mkdtempSync(join(tmpdir(), "antgrid-owner-lifetime-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: owner-lifetime\n");
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

// A cold `git worktree add` plus an agent-core boot does not fit bun's 5s
// per-test default on a Windows CI runner. WAIT_MS stays under TEST_MS so a
// hang names the wait that timed out.
const WAIT_MS = 20_000;
const SETTLE_MS = 5_000;
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

/** The terminals a reconnecting app would be handed for [checkoutId]. Null when
 *  the checkout has no cached status at all — an assertion that some id is
 *  ABSENT would pass just as happily against an empty answer, so the negative
 *  cases have to tell the two apart. */
function cachedStatus(
  bus: MessageBus,
  checkoutId: string,
): { terminalId: string; running: boolean }[] | null {
  for (const frame of bus.getSnapshot(["agent:status"])) {
    if (frame.type !== "agent:status" || frame.checkoutId !== checkoutId) continue;
    return frame.terminals.map((t) => ({ terminalId: t.terminalId, running: t.running }));
  }
  return null;
}

function statusCount(sent: AbMessage[], checkoutId: string): number {
  return sent.filter((m) => m.type === "agent:status" && m.checkoutId === checkoutId).length;
}

/** Re-drive the owner connect and wait for every named checkout to publish a
 *  fresh status — which is literally the scenario under test: what a client
 *  arriving AFTER the exit or the delete is told. `resyncState` forces its
 *  sends past the bus's payload dedup, so a new frame is proof of a new
 *  publish and not of a changed payload. */
async function reconnectApp(
  sent: AbMessage[],
  ...checkoutIds: string[]
): Promise<void> {
  const before = checkoutIds.map((id) => statusCount(sent, id));
  core!.onHandshakeComplete();
  await Promise.all(checkoutIds.map((id, i) => waitFor(
    () => statusCount(sent, id) > before[i]!,
    `a fresh agent:status for ${id}`,
  )));
}

/** A delete kills the PTY but cannot reap it: `forget` TOMBSTONES a still-live
 *  session rather than evicting it, so the row leaves `getStatus()` only once
 *  the exit lands, and the exit itself is then suppressed — there is no frame
 *  to wait on. So reconnect until the phantom is gone, and leave the verdict to
 *  the caller's assertion: a row that is still there when this gives up is the
 *  regression, and naming it beats a timeout message. */
async function settleDelete(
  bus: MessageBus,
  sent: AbMessage[],
  checkoutId: string,
  terminalId: string,
): Promise<void> {
  const deadline = Date.now() + SETTLE_MS;
  do {
    await reconnectApp(sent, checkoutId);
    const cached = cachedStatus(bus, checkoutId) ?? [];
    if (!cached.some((t) => t.terminalId === terminalId)) return;
  } while (Date.now() < deadline);
}

function expectCachedWithout(bus: MessageBus, checkoutId: string, terminalId: string): void {
  const cached = cachedStatus(bus, checkoutId);
  expect(cached).not.toBeNull();
  expect(cached!.map((t) => t.terminalId)).not.toContain(terminalId);
}

async function startSession(
  bus: MessageBus,
  sent: AbMessage[],
  name: string,
  opts: { isolation?: "worktree"; command?: string } = {},
): Promise<SessionEntry> {
  const createId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("session:create", {
    requestId: createId, name, command: opts.command ?? "node keepalive.js",
    ...(opts.isolation ? { isolation: opts.isolation } : {}),
  }), "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "session:result" && m.requestId === createId),
    "the session:create result",
  );
  const created = sent.find((m) => m.type === "session:result" && m.requestId === createId);
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

async function deleteSession(
  bus: MessageBus,
  sent: AbMessage[],
  sessionId: string,
  removeCheckout: boolean,
): Promise<void> {
  const deleteId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("session:delete", {
    requestId: deleteId, sessionId, force: true, ...(removeCheckout ? { removeCheckout } : {}),
  }), "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "session:result" && m.requestId === deleteId),
    "the session:delete result",
  );
  const res = sent.find((m) => m.type === "session:result" && m.requestId === deleteId);
  if (res?.type !== "session:result" || !res.ok) {
    throw new Error(`session:delete failed: ${JSON.stringify(res)}`);
  }
}

// The row's whole job. An ad-hoc terminal in a non-main checkout runs under a
// namespaced `<checkoutId>:<name>` id, so nothing but the owner row can say
// which checkout it belongs to: the session store has never heard of it, and
// the id itself is not consulted.
test("an exited terminal stays in ITS checkout's status and never lands in main's", async () => {
  await initRepo();
  const { bus, sent } = await bootCore();
  const session = await startSession(bus, sent, "Isolated", { isolation: "worktree" });
  const terminalId = "adhoc-exits";

  bus.dispatchInbound(createMessage("terminal:start", {
    terminalId, command: "node", args: ["-e", "0"], checkoutId: session.checkoutId,
  }), "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "terminal:exited" && m.terminalId === terminalId),
    "the ad-hoc terminal to exit",
  );
  await reconnectApp(sent, "main", session.checkoutId);

  const isolated = cachedStatus(bus, session.checkoutId);
  expect(isolated).not.toBeNull();
  expect(isolated!.find((t) => t.terminalId === terminalId)).toEqual({
    terminalId,
    running: false,
  });
  expectCachedWithout(bus, "main", terminalId);
  // The namespaced internal id is what a released row actually surfaces, so it
  // is the shape worth naming: `terminalOwner`'s fallback answers main for the
  // runtime AND hands back the raw id as the external one.
  expectCachedWithout(bus, "main", `${session.checkoutId}:${terminalId}`);
}, TEST_MS);

// A session PTY is namespaced by nothing — `internalTerminalId` returns early
// on a session id — so `forget` is the only thing that can end its life in
// `getStatus()`. Left there with its entry gone, it resolves through the same
// "main" default and renders as an agent-typed stopped tab in the primary
// workspace that no surface can close.
test("a deleted isolated session leaves no phantom tab in main's status", async () => {
  await initRepo();
  const { bus, sent } = await bootCore();
  const session = await startSession(bus, sent, "Isolated", { isolation: "worktree" });
  expect(session.checkoutId).not.toBe("main");

  await deleteSession(bus, sent, session.id, true);
  await settleDelete(bus, sent, "main", session.id);

  expectCachedWithout(bus, "main", session.id);
}, TEST_MS);

// The same defect with no isolation involved at all, on the OTHER delete path:
// `delete`'s shared branch, not `deleteManaged`. The session PTY exits on its
// own here rather than being killed — `tm.kill` only signals, and a conpty child
// can outlive the whole test — so the row under test is unambiguously the
// stopped-terminal corpse the delete has to release, not a live session.
test("a deleted MAIN session leaves no phantom tab either", async () => {
  const { bus, sent } = await bootCore();
  const session = await startSession(bus, sent, "Main", { command: "node -e 0" });
  await waitFor(
    () => sent.some((m) => m.type === "terminal:exited" && m.terminalId === session.id),
    "the session PTY to exit on its own",
  );
  await reconnectApp(sent, "main");
  expect((cachedStatus(bus, "main") ?? []).map((t) => t.terminalId)).toContain(session.id);

  await deleteSession(bus, sent, session.id, false);
  await settleDelete(bus, sent, "main", session.id);

  expectCachedWithout(bus, "main", session.id);
}, TEST_MS);
