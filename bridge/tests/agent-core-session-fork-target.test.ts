// `targetTool` only matters if the core hands it to SessionManager.fork; a
// dropped argument would fork into the source's own agent while the bridge
// still advertises handoff support.
import { test, expect, afterAll, afterEach, beforeEach, spyOn } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { SessionManager } from "../src/session-manager";

let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];
let core: AgentCore | null = null;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-fork-target-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(async () => {
  try { await core?.shutdown(); } catch { /* teardown only */ }
  core = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  rmSync(abDir, { recursive: true, force: true });
});

afterAll(() => {
  while (folders.length) rmSync(folders.pop()!, { recursive: true, force: true });
});

async function waitFor(pred: () => boolean, timeoutMs = 3000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pred()) return true;
    await new Promise((r) => setTimeout(r, 15));
  }
  return pred();
}

test("session:fork passes targetTool through to the session manager, and omits it when absent", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-fork-target-proj-"));
  folders.push(folder);
  writeFileSync(join(folder, "antgrid.yaml"), "name: fork-target\nagent:\n  tool: codex\n");
  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  expect(await waitFor(() => sent.some((m) => m.type === "agent:status"))).toBe(true);

  const fork = spyOn(SessionManager.prototype, "fork").mockRejectedValue(new Error("stubbed"));
  try {
    bus.dispatchInbound(createMessage("session:fork", { requestId: "with", sourceSessionId: "src", workspace: "current", targetTool: "claude-code" }), "control", "loopback");
    bus.dispatchInbound(createMessage("session:fork", { requestId: "without", sourceSessionId: "src", workspace: "current" }), "control", "loopback");
    expect(await waitFor(() => fork.mock.calls.length === 2)).toBe(true);
    expect(fork.mock.calls[0]).toEqual(["src", "current", "claude-code"]);
    expect(fork.mock.calls[1]![2]).toBeUndefined();
  } finally {
    fork.mockRestore();
  }
});
