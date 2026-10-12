// The `/scheduler/*` routes through a real core. The hazard is invisible below
// this level: agent-core's `acceptsHookRun` wrapper treats a post with no run
// id as a lost hook channel and fails the session's scheduled run, and neither
// `SessionManager` nor a stubbed api-server context has that wrapper. Only a
// real core shows that a run-id-less scheduler call refuses without it.
import { test, expect, beforeEach, afterEach, afterAll, spyOn } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { StructuredAgentManager } from "../src/structured/structured-manager";
import type { AgentCallerIdentity, SchedulerAgentMethod } from "../src/scheduler/agent";

let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-sched-route-"));
  process.env.ANTGRID_DIR = abDir;
});

async function rmWithRetry(path: string): Promise<void> {
  for (let i = 0; i < 20; i++) {
    try { rmSync(path, { recursive: true, force: true }); return; }
    catch { await new Promise((r) => setTimeout(r, 25)); }
  }
}

// The chokidar watcher can emit a late EPERM/ENOENT once its temp dir goes away.
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

interface Wired {
  bus: MessageBus;
  sent: AbMessage[];
  lost: string[];
  calls: { caller: AgentCallerIdentity; method: SchedulerAgentMethod; params: Record<string, unknown> }[];
  port: number;
}

async function wire(): Promise<Wired> {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-sched-route-proj-"));
  writeFileSync(join(folder, "antgrid.yaml"), "name: test-sched-route\nagent:\n  tool: codex\n");
  folders.push(folder);
  const lost: string[] = [];
  const calls: Wired["calls"] = [];
  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    onHookChannelLost: (sessionId) => lost.push(sessionId),
    schedulerForAgent: async (caller, method, params) => {
      calls.push({ caller, method, params });
      return { ok: true };
    },
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"));
  return { bus, sent, lost, calls, port: Number(readFileSync(join(abDir, "api.port"), "utf8").trim()) };
}

async function createChat(w: Wired, requestId: string): Promise<string> {
  w.bus.dispatchInbound(createMessage("session:create", { requestId, name: requestId, mode: "chat" }), "control", "loopback");
  expect(await waitFor(() => w.sent.some((m) => m.type === "session:result" && (m as any).requestId === requestId))).toBe(true);
  const created = w.sent.find((m) => m.type === "session:result" && (m as any).requestId === requestId) as any;
  expect(created.ok).toBe(true);
  return created.session.id as string;
}

function list(port: number, terminalId: string, body: Record<string, unknown>): Promise<Response> {
  return fetch(`http://127.0.0.1:${port}/scheduler/list?terminalId=${encodeURIComponent(terminalId)}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function expectNotASession(res: Response): Promise<void> {
  expect(res.status).toBe(403);
  expect((await res.json()).code).toBe("NOT_A_SESSION");
}

test("a run-id-less call from a stopped session or a service slot is refused without losing the hook channel", async () => {
  const w = await wire();
  const stopped = await createChat(w, "stopped");

  await expectNotASession(await list(w.port, stopped, {}));
  await expectNotASession(await list(w.port, stopped, { runId: "" }));
  await expectNotASession(await list(w.port, stopped, { runId: "guessed" }));
  // A service PTY's slot has no session entry and no run id.
  await expectNotASession(await list(w.port, "service-dev", {}));
  expect(w.calls).toEqual([]);
  expect(w.lost).toEqual([]);

  // The same slot through a hook route DOES trip the wrapper, so the empty
  // list above is the scheduler route staying clear of it, not a deaf harness.
  await fetch(`http://127.0.0.1:${w.port}/handler-event`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ terminalId: stopped, agent: "codex", event: "turn_end" }),
  });
  expect(await waitFor(() => w.lost.includes(stopped))).toBe(true);
});

test("a live session is refused without its run id, and answered with it", async () => {
  const w = await wire();
  const slot = await createChat(w, "live");
  let runId: string | undefined;
  const start = spyOn(StructuredAgentManager.prototype, "startChat").mockImplementation(async (options) => {
    runId = options.runId;
    return "ready";
  });
  try {
    w.bus.dispatchInbound(createMessage("session:start", { requestId: "start-live", sessionId: slot }), "control", "loopback");
    expect(await waitFor(() => !!runId)).toBe(true);

    await expectNotASession(await list(w.port, slot, {}));
    await expectNotASession(await list(w.port, slot, { runId: "wrong" }));
    expect(w.calls).toEqual([]);
    expect(w.lost).toEqual([]);

    const res = await list(w.port, slot, { runId });
    expect(res.status).toBe(200);
    expect(w.calls).toHaveLength(1);
    expect(w.calls[0]!.method).toBe("list");
    expect(w.calls[0]!.caller).toEqual({
      sessionId: slot, sessionName: "live", agentId: "codex", mode: "chat", approvalLevel: "gated", scheduled: false,
    });
    expect(w.lost).toEqual([]);
  } finally {
    start.mockRestore();
  }
});
