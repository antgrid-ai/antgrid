// The five-step checklist for a new inbound message type fails SILENTLY when a
// step is missed: the frame parses, reaches nothing, and the sender sees no
// error. Only a test that drives a real core proves the last step — the arm in
// agent-core's switch — is wired at all.
import { test, expect, beforeEach, afterEach, afterAll } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../../src/agent-core";
import { MessageBus } from "../../src/message-bus";
import { createMessage, type AbMessage } from "../../src/protocol";

let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-undo-wire-"));
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
  const f = mkdtempSync(join(tmpdir(), "antgrid-undo-wire-proj-"));
  writeFileSync(join(f, "antgrid.yaml"), "name: test-undo-wire\nagent:\n  tool: claude-code\n");
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

interface StatusFrame { sessions: Array<{ terminalId: string }>; snapshots: Array<{ snapshotId: string }> }
const statuses = (sent: AbMessage[]) =>
  sent.filter((m) => m.type === "handler:status") as never as StatusFrame[];
const snapshotFrames = (sent: AbMessage[]) =>
  sent.filter((m) => m.type === "handler:snapshot") as never as Array<{ snapshotId: string; state: string }>;

test("handler:undo reaches the engine, and a malformed one resyncs without disarming", async () => {
  const folder = tempFolder();
  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
  });

  // Planted before the first status emit: the engine reads the store lazily and
  // caches it, and the handshake emit is the first read.
  mkdirSync(join(core.abDir, "agents", core.projectId), { recursive: true });
  writeFileSync(join(core.abDir, "agents", core.projectId, "handler-snapshots.json"), JSON.stringify({
    version: 1,
    entries: [{
      // An earlier session's offer: arming t1 below retires t1's own leftovers,
      // and an offer outliving the session that took it is the point of §5.2.
      terminalId: "t0",
      action: "reset_hard",
      entry: {
        id: "s1", at: 5, sessionId: "t0", projectPath: folder, trigger: "git reset --hard HEAD~1",
        kind: "git_stash", headSha: "abc1234567", backupRef: "refs/antgrid/handler-snapshot/s1",
      },
    }],
  }));

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
  expect(statuses(sent).at(-1)!.snapshots.map((s) => s.snapshotId)).toEqual(["s1"]);

  // A malformed payload must not tear down the armed session it names nothing in.
  // Its resync emit is invisible here (the bus drops a byte-identical replay
  // frame), so the disarm is ruled out by the next state change instead: arming a
  // second slot must still report the first.
  sent.length = 0;
  bus.dispatchInbound({
    ...createMessage("handler:undo", { projectId: core.projectId, snapshotId: "s1" }),
    snapshotId: 7,
  } as never, "control", "loopback");
  bus.dispatchInbound(createMessage("handler:configure", {
    projectId: core.projectId, terminalId: "t2", armed: true,
  }), "control", "loopback");
  expect(await waitFor(() => statuses(sent).some((s) => s.sessions.length === 2))).toBe(true);
  expect(statuses(sent).at(-1)!.sessions.map((x) => x.terminalId).sort()).toEqual(["t1", "t2"]);
  expect(snapshotFrames(sent)).toHaveLength(0);

  // The well-formed one reaches the engine: the folder is no git repo, so the
  // undo fails honestly and says so rather than claiming the entry is spent.
  sent.length = 0;
  bus.dispatchInbound(createMessage("handler:undo", {
    projectId: core.projectId, snapshotId: "s1",
  }), "control", "loopback");
  expect(await waitFor(() => snapshotFrames(sent).length > 0)).toBe(true);
  expect(snapshotFrames(sent).at(-1)).toMatchObject({ snapshotId: "s1", state: "failed" });
  expect(statuses(sent).every((s) => s.sessions.length === 2)).toBe(true);
});
