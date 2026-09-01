// The five-step checklist for a new inbound message type fails SILENTLY when a
// step is missed: the frame parses, reaches nothing, and the sender sees no
// error. Only a test that drives a real core proves the last step — the arm in
// agent-core's switch — is wired at all. Modelled on undo-wire.test.ts.
import { test, expect, beforeEach, afterEach, afterAll } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../../src/agent-core";
import { MessageBus } from "../../src/message-bus";
import { createMessage, type AbMessage } from "../../src/protocol";
import type { HandlerSessionRecord } from "../../src/handler/session-store";

let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-dismiss-wire-"));
  process.env.ANTGRID_DIR = abDir;
});

async function rmWithRetry(path: string): Promise<void> {
  for (let i = 0; i < 20; i++) {
    try { rmSync(path, { recursive: true, force: true }); return; }
    catch { await new Promise((r) => setTimeout(r, 25)); }
  }
}

// The core's chokidar watcher can emit a late EPERM/ENOENT from the raw fs.watch
// when its temp dir goes away, asynchronously enough to land in the next test.
// Same teardown artifact the other core-driving suites swallow.
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

function tempFolder(): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-dismiss-wire-proj-"));
  writeFileSync(join(f, "antgrid.yaml"), "name: test-dismiss-wire\nagent:\n  tool: claude-code\n");
  folders.push(f);
  return f;
}

async function waitFor(pred: () => boolean, timeoutMs = 3000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pred()) return true;
    await new Promise((r) => setTimeout(r, 15));
  }
  return pred();
}

interface StatusFrame {
  sessions: Array<{ terminalId: string; state: string; escalations: Array<{ escalationId: string }> }>;
}
const statuses = (sent: AbMessage[]) =>
  sent.filter((m) => m.type === "handler:status") as never as StatusFrame[];

test("handler:dismiss reaches the engine, and a malformed one resyncs without disarming", async () => {
  const folder = tempFolder();
  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
  });

  // Raising a real report needs a judge spawn, so the row is planted on disk and
  // rehydrated by the arm below — the same path a bridge restart takes, and the
  // one that carries a report across it.
  const rec: HandlerSessionRecord = {
    version: 2, terminalId: "t1", armed: false, suspended: true,
    goal: "migrate auth", backlog: [], armedAt: 1,
    escalations: [{
      escalationId: "b1", question: "Handler did not send its reply",
      reasoning: "reply contains control characters", draftReply: "yes[B",
      urgency: "normal", kind: "guard_blocked", at: 2,
    }],
  };
  mkdirSync(join(core.abDir, "agents", core.projectId), { recursive: true });
  writeFileSync(
    join(core.abDir, "agents", core.projectId, "handler-session-t1.json"),
    JSON.stringify(rec),
  );

  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"));

  bus.dispatchInbound(createMessage("handler:configure", {
    projectId: core.projectId, terminalId: "t1", armed: true,
  }), "control", "loopback");
  expect(await waitFor(() => statuses(sent).some((s) => s.sessions.length === 1))).toBe(true);
  // A report survives the suspend→re-arm gap intact: it names nothing in the
  // runtime that went away.
  expect(statuses(sent).at(-1)!.sessions[0]!.escalations.map((e) => e.escalationId)).toEqual(["b1"]);
  expect(statuses(sent).at(-1)!.sessions[0]!.state).toBe("needs_you");

  // A malformed payload must not tear down the armed session it names a row on.
  // Its resync emit is invisible here (the bus drops a byte-identical replay
  // frame), so the disarm is ruled out by the next state change instead: arming a
  // second slot must still report the first, with its row.
  sent.length = 0;
  bus.dispatchInbound({
    ...createMessage("handler:dismiss", {
      projectId: core.projectId, terminalId: "t1", escalationId: "b1",
    }),
    escalationId: 7,
  } as never, "control", "loopback");
  bus.dispatchInbound(createMessage("handler:configure", {
    projectId: core.projectId, terminalId: "t2", armed: true,
  }), "control", "loopback");
  expect(await waitFor(() => statuses(sent).some((s) => s.sessions.length === 2))).toBe(true);
  const armed = statuses(sent).at(-1)!.sessions;
  expect(armed.map((x) => x.terminalId).sort()).toEqual(["t1", "t2"]);
  expect(armed.find((x) => x.terminalId === "t1")!.escalations).toHaveLength(1);

  // The well-formed one reaches the engine, retires the row, and rests the slot.
  sent.length = 0;
  bus.dispatchInbound(createMessage("handler:dismiss", {
    projectId: core.projectId, terminalId: "t1", escalationId: "b1",
  }), "control", "loopback");
  expect(await waitFor(() => statuses(sent).some(
    (s) => s.sessions.find((x) => x.terminalId === "t1")?.escalations.length === 0,
  ))).toBe(true);
  const after = statuses(sent).at(-1)!.sessions.find((x) => x.terminalId === "t1")!;
  expect(after.state).toBe("watching");
  expect(statuses(sent).every((s) => s.sessions.length === 2)).toBe(true);
});
