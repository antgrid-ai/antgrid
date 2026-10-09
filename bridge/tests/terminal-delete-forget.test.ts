import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { closeTerminalHistoryStore } from "../src/terminal-manager";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

type StatusMessage = Extract<AbMessage, { type: "agent:status" }>;

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-terminal-delete-"));
  process.env.ANTGRID_DIR = join(root, "state");
  process.env.ANTGRID_TERMINAL_HISTORY_TEST = "1";
  writeFileSync(join(root, "antgrid.yaml"), "name: terminal-delete\n");
});

afterEach(async () => {
  const dying = core;
  core = null;
  if (previousAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = previousAbDir;
  delete process.env.ANTGRID_TERMINAL_HISTORY_TEST;
  try {
    await dying?.shutdown();
  } finally {
    closeTerminalHistoryStore();
    rmSync(root, { recursive: true, force: true });
  }
}, 30_000);

async function waitFor(sent: AbMessage[], predicate: (m: AbMessage) => boolean, what: string): Promise<AbMessage> {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const found = sent.find(predicate);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

async function boot(): Promise<{ bus: MessageBus; sent: AbMessage[]; status: StatusMessage }> {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ audience: "loopback", deliver: (message) => sent.push(message) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  const status = await waitFor(sent, (m) => m.type === "agent:status", "agent:status");
  return { bus, sent, status: status as StatusMessage };
}

/** Shuts the core down and boots a fresh one over the same state dir — what
 *  closing and reopening the app does to the bridge. */
async function restart(): ReturnType<typeof boot> {
  await core?.shutdown();
  core = null;
  closeTerminalHistoryStore();
  return boot();
}

async function runTerminal(bus: MessageBus, sent: AbMessage[], terminalId: string): Promise<void> {
  bus.dispatchInbound(createMessage("terminal:start", {
    terminalId,
    cwd: root,
    command: process.execPath,
    args: ["-e", "console.log('hello'); setTimeout(() => {}, 60000)"],
  }), "control", "loopback");
  await waitFor(sent, (m) => m.type === "terminal:started" && m.terminalId === terminalId, "terminal:started");
  await new Promise((resolve) => setTimeout(resolve, 300));
}

const listed = (status: StatusMessage, terminalId: string): boolean =>
  status.terminals.some((t) => t.terminalId === terminalId);

describe("deleting a user terminal", () => {
  test("a plain stop keeps the terminal listed as stopped across a restart", async () => {
    const { bus, sent } = await boot();
    await runTerminal(bus, sent, "kept");
    bus.dispatchInbound(createMessage("terminal:stop", { terminalId: "kept" }), "control", "loopback");
    await waitFor(sent, (m) => m.type === "terminal:exited" && m.terminalId === "kept", "terminal:exited");

    const { status: after } = await restart();

    expect(listed(after, "kept")).toBe(true);
  }, 30_000);

  test("a forgetting stop of a running terminal is not resurrected by a restart", async () => {
    const { bus, sent } = await boot();
    await runTerminal(bus, sent, "gone");
    bus.dispatchInbound(createMessage("terminal:stop", { terminalId: "gone", forget: true }), "control", "loopback");
    await new Promise((resolve) => setTimeout(resolve, 500));

    const { status: after } = await restart();

    expect(listed(after, "gone")).toBe(false);
  }, 30_000);

  test("deleting an already-exited terminal drops it, which is the delete after a restart", async () => {
    const { bus, sent } = await boot();
    await runTerminal(bus, sent, "stale");
    bus.dispatchInbound(createMessage("terminal:stop", { terminalId: "stale" }), "control", "loopback");
    await waitFor(sent, (m) => m.type === "terminal:exited" && m.terminalId === "stale", "terminal:exited");
    const reopened = await restart();
    expect(listed(reopened.status, "stale")).toBe(true);

    reopened.bus.dispatchInbound(createMessage("terminal:stop", { terminalId: "stale", forget: true }), "control", "loopback");
    await new Promise((resolve) => setTimeout(resolve, 200));

    const { status: after } = await restart();

    expect(listed(after, "stale")).toBe(false);
  }, 30_000);
});
