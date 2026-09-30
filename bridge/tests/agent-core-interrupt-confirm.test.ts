// interrupt-confirm.test.ts pins the confirmer's own polling/window mechanics
// in isolation. Nothing there proves agent-core actually arms it off a real
// terminal:input frame, with the SESSION's own tool (not the project default)
// and its recorded transcript path — this file drives that wiring through a
// real buildAgentCore, with the confirmer's clock/timer/file-read deps
// swapped for an in-memory fake (interruptConfirmDeps) so nothing here sleeps
// for real or touches disk for the transcript itself.
//
// The session is seeded straight into sessions.json before the core boots,
// rather than created live and reported via the /session-title hook: a hook
// post for a real session id is gated on acceptsHookRun (an active run id
// from a genuine PTY spawn), which this file deliberately never starts — the
// session's own tool decides its launch binary, so starting one for real here
// would spawn the actual claude/codex CLI. A persisted transcript path is the
// realistic case anyway: it survives restarts and is exactly what a resumed
// session already carries before its first turn of this run.
import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { computeProjectId } from "../src/project-id";
import type { InterruptConfirmDeps } from "../src/interrupt-confirm";

let abDir: string;
let prevAbDir: string | undefined;
let core: AgentCore | null;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-interrupt-confirm-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(async () => {
  try { await core?.shutdown(); } catch { /* teardown only */ }
  core = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  rmSync(abDir, { recursive: true, force: true });
});

afterAll(() => {
  while (folders.length) rmSync(folders.pop()!, { recursive: true, force: true });
});

async function waitFor(pred: () => boolean, what: string, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pred()) return;
    await new Promise((r) => setTimeout(r, 15));
  }
  if (!pred()) throw new Error(`timed out waiting for ${what}`);
}

/** An in-memory transcript store plus a manually-driven poll — see
 *  interrupt-confirm.test.ts's fakeDeps for the same shape in isolation.
 *  `sizes`/`reads` record every path the confirmer actually touched, which is
 *  what proves opencode (no predicate) never reaches the filesystem at all. */
function fakeInterruptDeps() {
  const clock = { now: 0 };
  const files = new Map<string, string>();
  const ticks: Array<() => void> = [];
  const sizes: string[] = [];
  const reads: string[] = [];
  const deps: InterruptConfirmDeps = {
    now: () => clock.now,
    setRepeating: (fn) => { ticks.push(fn); return {}; },
    clearRepeating: () => {},
    fileSize: (path) => {
      sizes.push(path);
      const content = files.get(path);
      return content === undefined ? undefined : Buffer.byteLength(content, "utf8");
    },
    readAppended: async (path, from) => {
      reads.push(path);
      const content = files.get(path);
      if (content === undefined) return "";
      const buf = Buffer.from(content, "utf8");
      if (from >= buf.length) return "";
      return buf.subarray(from).toString("utf8");
    },
  };
  return { deps, clock, files, ticks, sizes, reads };
}

/** Writes a single session straight into this project's sessions.json before
 *  the core is built, so SessionManager's constructor load() picks it up with
 *  no live create/start/hook round trip. Shape matches PersistedEntrySchema's
 *  required fields; the rest default sanely (see session-manager.ts). */
function seedSession(
  abDir: string,
  folder: string,
  entry: { id: string; tool: string; agentTranscriptPath?: string },
): void {
  const projectId = computeProjectId(folder);
  const dir = join(abDir, "agents", projectId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "sessions.json"), JSON.stringify({
    version: 1,
    sessions: [{
      id: entry.id,
      name: "seeded",
      archived: false,
      tool: entry.tool,
      mode: "terminal",
      agentTranscriptPath: entry.agentTranscriptPath,
    }],
  }));
}

async function boot(fake: ReturnType<typeof fakeInterruptDeps>, folder: string) {
  const interrupted: string[] = [];
  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
    onInterrupt: (sessionId) => interrupted.push(sessionId),
    // Always open: this file is about the confirm/arm wiring, not about
    // work-status's own open-turn fold (project-core.test.ts and
    // work-status.test.ts already cover that half).
    isTurnOpenFor: () => true,
    interruptConfirmDeps: fake.deps,
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (message) => sent.push(message) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"), "the first agent:status");
  return { bus, interrupted };
}

function makeFolder(): string {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-interrupt-confirm-proj-"));
  writeFileSync(join(folder, "antgrid.yaml"), "name: interrupt-confirm-wiring\n");
  folders.push(folder);
  return folder;
}

function keystroke(bus: MessageBus, terminalId: string, data: string): void {
  bus.dispatchInbound(createMessage("terminal:input", { terminalId, data }), "control", "loopback");
}

/** terminal:input is a CHECKOUT_VARIABLE_MESSAGE_TYPES frame, so the core
 *  resolves the checkout (an async lookup, cached but never synchronous)
 *  before dispatchAbMessage ever runs — dispatchInbound itself returns long
 *  before arm() does. Every assertion on the confirmer's own state after a
 *  keystroke has to wait for that hop rather than read it inline. */
async function waitForTicks(fake: { ticks: unknown[] }, length: number): Promise<void> {
  await waitFor(() => fake.ticks.length >= length, `${length} armed confirmation(s)`);
}

test("Esc on claude with a marker appended after the key closes the turn", async () => {
  const fake = fakeInterruptDeps();
  const folder = makeFolder();
  const id = crypto.randomUUID();
  fake.files.set("/t.jsonl", "");
  seedSession(abDir, folder, { id, tool: "claude-code", agentTranscriptPath: "/t.jsonl" });
  const { bus, interrupted } = await boot(fake, folder);
  keystroke(bus, id, "\x1b");
  await waitForTicks(fake, 1);
  expect(fake.ticks).toHaveLength(1);
  fake.files.set("/t.jsonl", `${JSON.stringify({
    type: "user",
    message: { role: "user", content: [{ type: "text", text: "[Request interrupted by user]" }] },
  })}\n`);
  await fake.ticks[0]!();
  expect(interrupted).toContain(id);
});

test("Esc with nothing appended (a picker/dialog Esc) leaves the turn open after the window", async () => {
  const fake = fakeInterruptDeps();
  const folder = makeFolder();
  const id = crypto.randomUUID();
  fake.files.set("/t.jsonl", "");
  seedSession(abDir, folder, { id, tool: "claude-code", agentTranscriptPath: "/t.jsonl" });
  const { bus, interrupted } = await boot(fake, folder);
  keystroke(bus, id, "\x1b");
  await waitForTicks(fake, 1);
  expect(fake.ticks).toHaveLength(1);
  await fake.ticks[0]!(); // nothing appended
  expect(interrupted).not.toContain(id);
  fake.clock.now += 10_000; // past the confirmation window
  await fake.ticks[0]!();
  expect(interrupted).not.toContain(id);
});

test("a marker already in the file BEFORE the key does not close the turn", async () => {
  const fake = fakeInterruptDeps();
  const folder = makeFolder();
  const id = crypto.randomUUID();
  fake.files.set("/t.jsonl", `${JSON.stringify({
    type: "user",
    message: { role: "user", content: [{ type: "text", text: "[Request interrupted by user]" }] },
  })}\n`);
  seedSession(abDir, folder, { id, tool: "claude-code", agentTranscriptPath: "/t.jsonl" });
  const { bus, interrupted } = await boot(fake, folder);
  keystroke(bus, id, "\x1b");
  await waitForTicks(fake, 1);
  await fake.ticks[0]!();
  expect(interrupted).not.toContain(id);
});

test("Ctrl+C on codex with a turn_aborted line closes the turn", async () => {
  const fake = fakeInterruptDeps();
  const folder = makeFolder();
  const id = crypto.randomUUID();
  fake.files.set("/rollout.jsonl", "");
  seedSession(abDir, folder, { id, tool: "codex", agentTranscriptPath: "/rollout.jsonl" });
  const { bus, interrupted } = await boot(fake, folder);
  keystroke(bus, id, "\x03");
  await waitForTicks(fake, 1);
  expect(fake.ticks).toHaveLength(1);
  fake.files.set("/rollout.jsonl", `${JSON.stringify({
    type: "event_msg",
    payload: { type: "turn_aborted", reason: "interrupted" },
  })}\n`);
  await fake.ticks[0]!();
  expect(interrupted).toContain(id);
});

test("Esc on opencode does nothing and never reaches the filesystem", async () => {
  const fake = fakeInterruptDeps();
  const folder = makeFolder();
  const id = crypto.randomUUID();
  fake.files.set("/t.jsonl", "");
  seedSession(abDir, folder, { id, tool: "opencode", agentTranscriptPath: "/t.jsonl" });
  const { bus, interrupted } = await boot(fake, folder);
  keystroke(bus, id, "\x1b");
  await new Promise((r) => setTimeout(r, 50));
  expect(fake.ticks).toHaveLength(0);
  expect(fake.sizes).toHaveLength(0);
  expect(fake.reads).toHaveLength(0);
  expect(interrupted).not.toContain(id);
});

test("a missing transcript file is a no-op, not a throw", async () => {
  const fake = fakeInterruptDeps();
  const folder = makeFolder();
  const id = crypto.randomUUID();
  // Reported, but never added to `fake.files` — fileSize answers undefined.
  seedSession(abDir, folder, { id, tool: "claude-code", agentTranscriptPath: "/does/not/exist.jsonl" });
  const { bus, interrupted } = await boot(fake, folder);
  keystroke(bus, id, "\x1b");
  await new Promise((r) => setTimeout(r, 50));
  expect(fake.ticks).toHaveLength(0);
  expect(interrupted).not.toContain(id);
});

test("two keys in a row is one reader", async () => {
  const fake = fakeInterruptDeps();
  const folder = makeFolder();
  const id = crypto.randomUUID();
  fake.files.set("/t.jsonl", "");
  seedSession(abDir, folder, { id, tool: "claude-code", agentTranscriptPath: "/t.jsonl" });
  const { bus } = await boot(fake, folder);
  keystroke(bus, id, "\x1b");
  keystroke(bus, id, "\x1b");
  await waitForTicks(fake, 1);
  // A second reader would show up as a second scheduled poll — give it a beat
  // to (not) appear rather than asserting the instant the first one does.
  await new Promise((r) => setTimeout(r, 50));
  expect(fake.ticks).toHaveLength(1);
});
