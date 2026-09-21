// A terminal session's turn is opened by keystroke inference and was closed by
// exactly one thing: a turn-end NOTIFICATION. codex's other turn-end channel —
// the `notify` argv, which posts /handler-event turn_end and fires
// independently of its Stop hook — reached the Handler engine and nothing else,
// so an enter that dismissed a TUI menu rather than starting a model turn opened
// a turn nothing would ever close and the session read "working" until it
// stopped. Every unit around this passes against a stubbed callback; only a real
// core proves the api-server's event reaches the work reduction at all.
// Modelled on agent-core-question-latch.test.ts.
import { test, expect, beforeEach, afterEach, afterAll } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import type { AbMessage } from "../src/protocol";

let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-hook-turn-end-"));
  process.env.ANTGRID_DIR = abDir;
});

async function rmWithRetry(path: string): Promise<void> {
  for (let i = 0; i < 20; i++) {
    try { rmSync(path, { recursive: true, force: true }); return; }
    catch { await new Promise((r) => setTimeout(r, 25)); }
  }
}

// Same teardown artifact the other core-driving suites swallow: the chokidar
// watcher can emit a late EPERM/ENOENT once its temp dir goes away.
function ignoreWatcherEperm(err: unknown): void {
  const code = (err as { code?: string } | null)?.code;
  if (code === "EPERM" || code === "ENOENT") return;
  throw err;
}
process.on("uncaughtException", ignoreWatcherEperm);

let core: AgentCore | null = null;
afterEach(async () => {
  try { await core?.shutdown(); } catch { /* teardown only */ }
  core = null;
  await new Promise((r) => setTimeout(r, 50));
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  await rmWithRetry(abDir);
});

afterAll(async () => {
  while (folders.length) await rmWithRetry(folders.pop()!);
  process.off("uncaughtException", ignoreWatcherEperm);
});

async function waitFor(pred: () => boolean, timeoutMs = 3000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pred()) return true;
    await new Promise((r) => setTimeout(r, 15));
  }
  return pred();
}

/** Every `onHookTurnEnd` / `onHookChannelLost` the core raised. Recorded rather
 *  than asserted through a work status because the callbacks ARE the wiring
 *  under test; a fake slot has no `session:updated` to read a status off. */
async function wire(): Promise<{ turnEnds: string[]; lost: string[]; port: number }> {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-hook-turn-end-proj-"));
  writeFileSync(join(folder, "antgrid.yaml"), "name: test-hook-turn-end\nagent:\n  tool: codex\n");
  folders.push(folder);
  const turnEnds: string[] = [];
  const lost: string[] = [];
  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    onHookTurnEnd: (sessionId) => turnEnds.push(sessionId),
    onHookChannelLost: (sessionId) => lost.push(sessionId),
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"));
  // AgentCore exposes no port, so this reads the api server's own discovery
  // file — the fallback a hook without ANTGRID_API_PORT already takes.
  return { turnEnds, lost, port: Number(readFileSync(join(abDir, "api.port"), "utf8").trim()) };
}

async function post(port: number, body: unknown): Promise<Response> {
  return fetch(`http://127.0.0.1:${port}/handler-event`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

test("a turn_end hook event reaches the work reduction, not just the Handler", async () => {
  const { turnEnds, port } = await wire();
  expect((await post(port, { terminalId: "t1", agent: "codex", event: "turn_end" })).status).toBe(200);
  expect(await waitFor(() => turnEnds.includes("t1"))).toBe(true);
});

test("turn_failed does NOT close the turn", async () => {
  // A transient StopFailure is claude parking for the Handler to nudge it, and
  // it withholds its notification for exactly that reason (claudeStopFailureEvent).
  // Closing here would take the dot down on a session still being managed.
  const { turnEnds, port } = await wire();
  expect((await post(port, { terminalId: "t1", agent: "claude", event: "turn_failed" })).status).toBe(200);
  // Ordered behind a turn_end for the same slot, so this cannot pass merely by
  // asserting before the post was folded.
  expect((await post(port, { terminalId: "t2", agent: "claude", event: "turn_end" })).status).toBe(200);
  expect(await waitFor(() => turnEnds.includes("t2"))).toBe(true);
  expect(turnEnds).not.toContain("t1");
});

test("a runId-less post from an UNKNOWN slot is not a channel loss", async () => {
  // `acceptsHookRun` refuses a runId-less post only from a slot the manager
  // holds; an unknown one never had an identity (a service PTY, a config
  // `terminals:` entry). Writing its hooks off would mark a session blind on
  // the strength of a post that was never about a session.
  const { lost, turnEnds, port } = await wire();
  expect((await post(port, { terminalId: "t1", agent: "codex", event: "turn_end" })).status).toBe(200);
  expect(await waitFor(() => turnEnds.includes("t1"))).toBe(true);
  expect(lost).not.toContain("t1");
});
