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

test("retired snapshot RPC always requires a coordinated upgrade", async () => {
  const { bus, sent } = await bootWithTerminal();
  for (const params of [{ terminalId: "adhoc" }, { terminalId: "adhoc", history: true }, {}, { terminalId: "missing", checkoutId: "missing" }]) {
    const requestId = crypto.randomUUID();
    requestSnapshot(bus, requestId, params);
    const reply = await waitForResponse(sent, requestId);
    expect(reply).toMatchObject({ ok: false, error: { code: "UPGRADE_REQUIRED" } });
  }
  expect(sent.filter((m) => m.type === "terminal:snapshot")).toEqual([]);
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
  expect(findResponse(sent, "r-gated")).toBeUndefined();

  // Positive control, same shape as agent-core-transcript-snapshot.test.ts:
  // flip the switch and prove the method DOES reach the handler once allowed.
  mobileAccess = true;
  sent.length = 0;
  requestSnapshot(bus, "r-gated-on", { terminalId: "adhoc" }, "relay");
  const res = await waitForResponse(sent, "r-gated-on");
  if (res.type !== "response") throw new Error("unreachable");
  expect(res.ok).toBe(false);
  expect(res.error?.code).toBe("UPGRADE_REQUIRED");
});
