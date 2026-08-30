// The re-sync paths exist because a client just told us it has nothing — so an
// UNCHANGED payload is precisely the one that still has to reach the wire. The
// bus's payload-equality dedup is what silently swallowed them: an idle
// project's status, git and tree are byte-identical to the cached frames, so
// nothing was delivered and the client had no second way to ask.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-resync-pushes-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: resync-pushes\n");
});

// 30s, not the 5s Bun gives a hook by default: `shutdown()` waits out a graceful
// PTY kill whose own budget IS 5s (`killAllGracefully`) and then drains the
// in-flight `git` children. `test(..., 30000)` does not raise it — a hook budget
// is separate from the test's. Same shape and same reason as
// `agent-core-checkout-routing.test.ts`; keep them in step.
afterEach(async () => {
  // Bound before the await, never read after it. Bun does not CANCEL a hook that
  // overruns, it just stops waiting: the body resumes inside the NEXT test, where
  // these module-level slots have already been reassigned, and the late rmSync
  // then deletes the running test's directory.
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

async function waitFor(predicate: () => boolean, what: string, timeoutMs = 4000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

async function bootCore(): Promise<{ bus: MessageBus; sent: AbMessage[] }> {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (message) => sent.push(message) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"), "agent:status");
  return { bus, sent };
}

const countOf = (sent: AbMessage[], type: string) => sent.filter((m) => m.type === type).length;

test("a resync re-sends the file tree even when nothing about it changed", async () => {
  const { sent } = await bootCore();
  await waitFor(() => sent.some((m) => m.type === "tree:full"), "the first tree:full");
  const before = countOf(sent, "tree:full");

  // A second handshake is a reconnected app: its whole point is that the app
  // believes it has nothing, while the project sat idle and every frame it
  // needs is identical to what the replay cache holds.
  core!.onHandshakeComplete();

  await waitFor(() => countOf(sent, "tree:full") > before, "the re-synced tree:full");
  await waitFor(() => countOf(sent, "agent:status") > 1, "the re-synced agent:status");
});

test("a tree snapshot request re-sends an UNCHANGED git status", async () => {
  const { bus, sent } = await bootCore();
  await waitFor(() => sent.some((m) => m.type === "git:status"), "the first git:status");
  // Let the boot-time refreshes settle, so the request below is the only thing
  // left that could move the count.
  await new Promise((resolve) => setTimeout(resolve, 800));
  const before = countOf(sent, "git:status");

  bus.dispatchInbound(createMessage("file:tree:snapshot:request", {}), "control", "loopback");

  await waitFor(() => sent.some((m) => m.type === "file:tree:snapshot"), "the tree snapshot");
  await waitFor(() => countOf(sent, "git:status") > before, "git:status after the request");
});

test("a preview snapshot request re-emits the detected ports alongside it", async () => {
  const { bus, sent } = await bootCore();
  await new Promise((resolve) => setTimeout(resolve, 200));
  const before = countOf(sent, "ports:update");

  // The snapshot carries config-declared proxies only; ad-hoc detections ride
  // ports:update, which is pushed on change alone — so without this pairing a
  // caller that asks for the preview picture cannot learn about a port found
  // before it was listening.
  bus.dispatchInbound(createMessage("preview:snapshot:request", {}), "control", "loopback");

  await waitFor(() => sent.some((m) => m.type === "preview:snapshot"), "the preview snapshot");
  await waitFor(() => countOf(sent, "ports:update") > before, "ports:update after the request");
});

test("a resync re-sends each terminal as a composed snapshot, never as output", async () => {
  const { bus, sent } = await bootCore();
  // cwd deliberately outside the project: on Windows a live PTY holds its own
  // cwd open and the fixture's teardown rm would hit EBUSY.
  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: "adhoc", cwd: tmpdir() }),
    "control",
    "loopback",
  );
  await waitFor(
    () => sent.some((m) => m.type === "terminal:started" && m.terminalId === "adhoc"),
    "terminal:started",
  );
  sent.length = 0;

  core!.onHandshakeComplete();

  await waitFor(() => sent.some((m) => m.type === "terminal:snapshot"), "the re-synced screen");
  const snapshot = sent.find((m) => m.type === "terminal:snapshot");
  if (snapshot?.type !== "terminal:snapshot") throw new Error("unreachable");
  // A whole screen delivered as ordinary output would stack a second copy into
  // a live tab, and with no seq the app's cutoff could not filter it out.
  expect(snapshot.composed).toBe(true);
  expect(typeof snapshot.seq).toBe("number");
});
