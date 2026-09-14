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

for (const history of [false, true]) {
  test(`retired snapshot request requires an upgrade (history=${history})`, async () => {
    const { bus, sent } = await bootWithTerminal();
    sent.length = 0;
    bus.dispatchInbound(createMessage("terminal:snapshot:request", {
      terminalId: "adhoc", history,
    }), "control", "loopback");
    const reply = await waitFor(sent, (m) => m.type === "terminal:display:status", "upgrade status");
    expect(reply).toMatchObject({ code: "UPGRADE_REQUIRED", terminalId: "adhoc" });
    expect(sent.filter((m) => m.type === "terminal:snapshot")).toEqual([]);
  });
}
