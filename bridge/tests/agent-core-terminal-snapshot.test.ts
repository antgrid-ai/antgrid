// A returning app rebuilds its VT engine from this one reply, so what it
// carries — the composed flag above all — is the whole contract between the
// bridge's emulator and the app's.
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
  root = mkdtempSync(join(tmpdir(), "antgrid-terminal-snapshot-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: terminal-snapshot\n");
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

async function bootWithTerminal(): Promise<{ bus: MessageBus; sent: AbMessage[] }> {
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

test("a snapshot request is answered once, with a composed attach sequence", async () => {
  const { bus, sent } = await bootWithTerminal();
  sent.length = 0;

  bus.dispatchInbound(
    createMessage("terminal:snapshot:request", { terminalId: "adhoc" }),
    "control",
    "loopback",
  );
  const reply = await waitFor(
    sent,
    (m) => m.type === "terminal:snapshot" && m.terminalId === "adhoc",
    "terminal:snapshot",
  );
  if (reply.type !== "terminal:snapshot") throw new Error("unreachable");

  // Without the flag the app places its own erase and lands it on whichever
  // buffer its engine happens to be on.
  expect(reply.composed).toBe(true);
  // Only the leading buffer-select is pinned here. The preamble's full byte
  // order is `terminal-screen.test.ts`'s subject, and duplicating the literal
  // makes every mode added to it a two-file edit for no extra coverage.
  expect(reply.scrollback.startsWith("\x1b[?1049l\x1b[r")).toBe(true);
  expect(typeof reply.seq).toBe("number");

  // The serialization is asynchronous now, so a second reply would be a second
  // whole screen applied over the first.
  await new Promise((resolve) => setTimeout(resolve, 300));
  expect(sent.filter((m) => m.type === "terminal:snapshot").length).toBe(1);
});

test("a cold snapshot request is answered with an erasing, history-bearing blob", async () => {
  const { bus, sent } = await bootWithTerminal();
  sent.length = 0;

  bus.dispatchInbound(
    createMessage("terminal:snapshot:request", { terminalId: "adhoc", history: true }),
    "control",
    "loopback",
  );
  const reply = await waitFor(
    sent,
    (m) => m.type === "terminal:snapshot" && m.terminalId === "adhoc",
    "terminal:snapshot",
  );
  if (reply.type !== "terminal:snapshot") throw new Error("unreachable");

  expect(reply.composed).toBe(true);
  // The flag has to survive the whole way to the serializer, and the erase is
  // the observable that says it did: the warm preamble never carries `3J`, on
  // pain of destroying the app's own history.
  expect(reply.scrollback).toContain("\x1b[3J");
  // Echoed on the REPLY as well, and that is not redundant: the frame is
  // published on the project bus, so a client that asked for nothing receives
  // it too and needs to know the body erases before it paints.
  expect(reply.history).toBe(true);
});

test("a warm snapshot request is answered with no history claim", async () => {
  const { bus, sent } = await bootWithTerminal();
  sent.length = 0;

  bus.dispatchInbound(
    createMessage("terminal:snapshot:request", { terminalId: "adhoc" }),
    "control",
    "loopback",
  );
  const reply = await waitFor(
    sent,
    (m) => m.type === "terminal:snapshot" && m.terminalId === "adhoc",
    "terminal:snapshot",
  );
  if (reply.type !== "terminal:snapshot") throw new Error("unreachable");

  // Never truthy for a warm attach: a peer applying this must keep its own
  // scrollback, and the body carries no `3J` to justify dropping it.
  expect(reply.history ?? false).toBe(false);
  expect(reply.scrollback).not.toContain("\x1b[3J");
});

test("a snapshot request for an unknown terminal sends nothing", async () => {
  const { bus, sent } = await bootWithTerminal();
  sent.length = 0;

  bus.dispatchInbound(
    createMessage("terminal:snapshot:request", { terminalId: "never-existed" }),
    "control",
    "loopback",
  );
  await new Promise((resolve) => setTimeout(resolve, 400));
  expect(sent.filter((m) => m.type === "terminal:snapshot")).toEqual([]);
});
