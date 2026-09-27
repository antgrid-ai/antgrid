// The five-step checklist for a new inbound message type fails SILENTLY when a
// step is missed: the frame parses, reaches nothing, and the sender sees no
// error. Only a test that drives a real core proves the last step — the arm in
// agent-core's switch — is wired at all. Modelled on dismiss-wire.test.ts.
import { test, expect, beforeEach, afterEach, afterAll } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../../src/agent-core";
import { MessageBus } from "../../src/message-bus";
import { createMessage, type AbMessage } from "../../src/protocol";
import type { ActivityRecord } from "../../src/handler/config";

let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-history-wire-"));
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
  const f = mkdtempSync(join(tmpdir(), "antgrid-history-wire-proj-"));
  writeFileSync(join(f, "antgrid.yaml"), "name: test-history-wire\nagent:\n  tool: claude-code\n");
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

interface PageFrame {
  projectId: string;
  requestId: string;
  records: Array<{ recordId: string; decision: string; reason: string }>;
  truncated: boolean;
}
const pages = (sent: AbMessage[]) =>
  sent.filter((m) => m.type === "handler:history:page") as never as PageFrame[];

const record = (n: number): ActivityRecord => (
  { recordId: `r${n}`, at: n, terminalId: "t1", decision: "handle", reason: `reason ${n}` }
);

/** Plant rows the way a past session left them, under an arbitrary project id. */
function plant(core: AgentCore, projectId: string, count: number): void {
  const dir = join(core.abDir, "agents", projectId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "handler-activity.jsonl"),
    Array.from({ length: count }, (_, i) => JSON.stringify(record(i + 1))).join("\n") + "\n",
    "utf8",
  );
}

async function attach(folder: string): Promise<{ bus: MessageBus; sent: AbMessage[] }> {
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core!.attachTransport(bus);
  core!.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"));
  sent.length = 0;
  return { bus, sent };
}

test("handler:history:request answers with the log, newest first", async () => {
  const folder = tempFolder();
  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
  });
  plant(core, core.projectId, 3);
  const { bus, sent } = await attach(folder);

  const requestId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("handler:history:request", {
    projectId: core.projectId, requestId,
  }), "control", "loopback");

  expect(await waitFor(() => pages(sent).length === 1)).toBe(true);
  const page = pages(sent)[0]!;
  expect(page.requestId).toBe(requestId);
  expect(page.projectId).toBe(core.projectId);
  expect(page.records.map((r) => r.recordId)).toEqual(["r3", "r2", "r1"]);
  expect(page.truncated).toBe(false);
});

test("a project whose handler was never armed answers an empty page rather than nothing", async () => {
  // The app is waiting on this answer. Silence is indistinguishable from a
  // stalled request, and would spend the caller's whole deadline.
  const folder = tempFolder();
  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
  });
  const { bus, sent } = await attach(folder);

  bus.dispatchInbound(createMessage("handler:history:request", {
    projectId: core.projectId, requestId: crypto.randomUUID(),
  }), "control", "loopback");

  expect(await waitFor(() => pages(sent).length === 1)).toBe(true);
  expect(pages(sent)[0]!.records).toEqual([]);
  expect(pages(sent)[0]!.truncated).toBe(false);
});

test("the log is read under the receiving core's own project id, never the frame's", async () => {
  // A frame naming another project must not read that project's log. The stream
  // already settled which project this peer reached.
  const folder = tempFolder();
  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
  });
  plant(core, core.projectId, 1);
  plant(core, "someone-elses-project", 5);
  const { bus, sent } = await attach(folder);

  bus.dispatchInbound(createMessage("handler:history:request", {
    projectId: "someone-elses-project", requestId: crypto.randomUUID(),
  }), "control", "loopback");

  expect(await waitFor(() => pages(sent).length === 1)).toBe(true);
  const page = pages(sent)[0]!;
  expect(page.projectId).toBe(core.projectId);
  expect(page.records.map((r) => r.recordId)).toEqual(["r1"]);
});

test("a malformed request is dropped without an answer", async () => {
  const folder = tempFolder();
  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
  });
  plant(core, core.projectId, 2);
  const { bus, sent } = await attach(folder);

  bus.dispatchInbound({
    ...createMessage("handler:history:request", {
      projectId: core.projectId, requestId: crypto.randomUUID(),
    }),
    requestId: "not-a-uuid",
  } as never, "control", "loopback");

  // A well-formed request behind it proves the dispatch is still live, so the
  // absence above is the refusal and not a dead arm.
  const good = crypto.randomUUID();
  bus.dispatchInbound(createMessage("handler:history:request", {
    projectId: core.projectId, requestId: good,
  }), "control", "loopback");

  expect(await waitFor(() => pages(sent).length === 1)).toBe(true);
  expect(pages(sent)[0]!.requestId).toBe(good);
});
