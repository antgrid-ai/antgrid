// The prompt latch and the armed-slot mirror are built in agent-core and read
// from other modules — the api-server's notification suppression and the push
// dispatcher's question/escalation pairing — so every unit around them passes
// against a stubbed predicate while the wiring itself is absent. Only a real
// core proves those edges exist, and the latch is a mechanism that SILENCES
// notifications: a missed clear costs a genuinely blocked agent every push for
// the rest of its run. Modelled on handler/dismiss-wire.test.ts.
import { test, expect, beforeEach, afterEach, afterAll, spyOn } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { StructuredAgentManager } from "../src/structured/structured-manager";

let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-question-latch-"));
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
  const f = mkdtempSync(join(tmpdir(), "antgrid-question-latch-proj-"));
  writeFileSync(join(f, "antgrid.yaml"), "name: test-question-latch\nagent:\n  tool: claude-code\n");
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

interface Wired {
  bus: MessageBus;
  sent: AbMessage[];
  /** Every `onUserReply` the core raised. ProjectCore's real one feeds
   *  work-status, whose `question` entry is a call-to-action nothing else
   *  deletes — a terminal session's next signal is its Stop hook, minutes of
   *  work later. Recorded here rather than asserted through a work status
   *  because the callback IS the wiring under test; a fake slot has no
   *  `session:updated` to read it off. */
  replies: Array<[string, { submitted: boolean; typed: boolean }]>;
  /** The port a hook posts to. AgentCore exposes none, so this reads the api
   *  server's own discovery file — the fallback a hook without ANTGRID_API_PORT
   *  in its env already takes. */
  port: number;
}

async function wire(): Promise<Wired> {
  const replies: Wired["replies"] = [];
  core = await buildAgentCore({
    folder: tempFolder(),
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    onUserReply: (sessionId, replyOpts) => replies.push([sessionId, replyOpts]),
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"));
  return { bus, sent, replies, port: Number(readFileSync(join(abDir, "api.port"), "utf8").trim()) };
}

async function post(port: number, path: string, body: unknown): Promise<Response> {
  return fetch(`http://127.0.0.1:${port}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

const question = (terminalId: string, promptId: string) => ({
  terminalId, agent: "claude", event: "question", promptId,
  promptTool: "AskUserQuestion", detail: "Which env?",
});

// The CLI's own second announcement of that block. `message` varies per call
// because /notify dedups on the whole body inside its window, and what is under
// test here is whether the LATCH dropped it.
const permission = (terminalId: string, promptTool: string, nth: number) => ({
  type: "permission_request", terminalId, promptTool, message: `Permission needed ${nth}`,
});

type Frame<T extends AbMessage["type"]> = Extract<AbMessage, { type: T }>;
const framesOf = <T extends AbMessage["type"]>(sent: AbMessage[], type: T): Frame<T>[] =>
  sent.filter((m): m is Frame<T> => m.type === type);

const pushes = (sent: AbMessage[]) => framesOf(sent, "notification:push");

/** The escalations the newest status frame reports for [terminalId], or null
 *  before the slot has appeared in one. `handler:status` is a REPLAY_TYPE that
 *  drops unchanged republishes, so the newest frame is always the newest STATE. */
function escalationsOf(sent: AbMessage[], terminalId: string) {
  const last = framesOf(sent, "handler:status").at(-1);
  return last?.sessions.find((x) => x.terminalId === terminalId)?.escalations ?? null;
}

async function arm(bus: MessageBus, sent: AbMessage[], terminalId: string): Promise<void> {
  bus.dispatchInbound(createMessage("handler:configure", {
    projectId: core!.projectId, terminalId, armed: true,
  }), "control", "loopback");
  expect(await waitFor(() => armedSlots(sent)?.includes(terminalId) === true)).toBe(true);
}

// The slots the latest status frame reports as armed. Asserted on rather than on
// a frame's mere arrival: the core emits status of its own, so "a status landed"
// can pass before the configure it is meant to observe.
function armedSlots(sent: AbMessage[]): string[] | null {
  const last = framesOf(sent, "handler:status").at(-1);
  return last ? last.sessions.map((x) => x.terminalId) : null;
}

test("a question latches the slot, and only the tool it belongs to is silenced", async () => {
  const { sent, port } = await wire();

  expect((await post(port, "/handler-event", question("t1", "toolu_1"))).status).toBe(200);
  sent.length = 0;

  const dropped = await post(port, "/notify", permission("t1", "AskUserQuestion", 1));
  expect(await dropped.json()).toEqual({ ok: true, suppressed: true });
  expect(pushes(sent)).toHaveLength(0);

  // A parallel batch's Bash approval is a block nobody has been told about, so
  // it must land while the question is still on screen.
  expect((await post(port, "/notify", permission("t1", "Bash", 2))).status).toBe(200);
  expect(await waitFor(() => pushes(sent).length === 1)).toBe(true);
  expect(pushes(sent)[0]!.message).toBe("Permission needed 2");
});

test("prompt_answered retires the prompt it names", async () => {
  const { sent, port } = await wire();
  await post(port, "/handler-event", question("t1", "toolu_1"));
  await post(port, "/handler-event", {
    terminalId: "t1", agent: "claude", event: "prompt_answered", promptId: "toolu_1",
  });
  sent.length = 0;

  expect((await post(port, "/notify", permission("t1", "AskUserQuestion", 1))).status).toBe(200);
  expect(await waitFor(() => pushes(sent).length === 1)).toBe(true);
});

test("a turn boundary releases a latch no completion hook reported", async () => {
  // A turn that ended without a PostToolUse leaves an entry nothing else clears,
  // and a slot id is reused by a same-id restart — so a stale one silences the
  // next run's every block.
  const { sent, port } = await wire();
  const releases: Array<[string, (slot: string) => Promise<Response>]> = [
    ["t1", (slot) => post(port, "/handler-event", { terminalId: slot, agent: "claude", event: "turn_end" })],
    ["t2", (slot) => post(port, "/handler-event", { terminalId: slot, agent: "claude", event: "turn_failed" })],
    ["t3", (slot) => post(port, "/turn-start", { terminalId: slot })],
  ];
  for (const [slot, release] of releases) {
    await post(port, "/handler-event", question(slot, "toolu_1"));
    expect(await (await post(port, "/notify", permission(slot, "AskUserQuestion", 1))).json())
      .toEqual({ ok: true, suppressed: true });

    await release(slot);
    sent.length = 0;
    expect((await post(port, "/notify", permission(slot, "AskUserQuestion", 2))).status).toBe(200);
    expect(await waitFor(() => pushes(sent).length === 1)).toBe(true);
  }
});

test("a chat slot latches too — the hooks reporting the prompt are the same ones", async () => {
  // buildChatSpawnAugment reuses the terminal-mode injection, so a chat spawn
  // posts this pair as well. The engine ignores a chat slot (its driver tap
  // feeds it instead), but what the AGENT is displaying is not a fact about
  // supervision — un-latched, the CLI's "Permission needed" lands beside the
  // question push it re-announces.
  const { bus, sent, port } = await wire();
  bus.dispatchInbound(createMessage("session:create", {
    requestId: "c1", name: "Chat", mode: "chat",
  }), "control", "loopback");
  expect(await waitFor(() => sent.some((m) => m.type === "session:result"))).toBe(true);
  const created = framesOf(sent, "session:result")[0]!;
  expect(created.ok).toBe(true);
  const slot = created.session!.id;

  // Admit a real session run without allocating a provider backend: callbacks
  // from a created-but-stopped slot must be rejected before the latch sees them.
  let runId: string | undefined;
  const start = spyOn(StructuredAgentManager.prototype, "startChat").mockImplementation(async (options) => {
    runId = options.runId;
    return "ready";
  });
  try {
    bus.dispatchInbound(createMessage("session:start", { requestId: "start-chat", sessionId: slot }), "control", "loopback");
    expect(await waitFor(() => !!runId)).toBe(true);
    expect((await post(port, "/handler-event", { ...question(slot, "toolu_1"), runId })).status).toBe(200);
    sent.length = 0;
    expect(await (await post(port, "/notify", { ...permission(slot, "AskUserQuestion", 1), runId })).json())
      .toEqual({ ok: true, suppressed: true });
    expect(pushes(sent)).toHaveLength(0);
  } finally {
    start.mockRestore();
  }
});

test("the armed-slot mirror follows every handler:status the engine emits", async () => {
  // Read by the push dispatcher to drop the question notification an armed
  // session's escalation already carries. Over-inclusive, it drops the only
  // thing that ever says what an UNARMED agent asked.
  const { bus, sent } = await wire();
  expect(core!.isHandlerArmed("t1")).toBe(false);

  bus.dispatchInbound(createMessage("handler:configure", {
    projectId: core!.projectId, terminalId: "t1", armed: true,
  }), "control", "loopback");
  expect(await waitFor(() => armedSlots(sent)?.includes("t1") === true)).toBe(true);
  expect(core!.isHandlerArmed("t1")).toBe(true);
  expect(core!.isHandlerArmed("t2")).toBe(false);

  bus.dispatchInbound(createMessage("handler:configure", {
    projectId: core!.projectId, terminalId: "t1", armed: false,
  }), "control", "loopback");
  expect(await waitFor(() => armedSlots(sent)?.includes("t1") === false)).toBe(true);
  expect(core!.isHandlerArmed("t1")).toBe(false);
});

test("owning a session's completion needs a backlog, not just an arm", async () => {
  // The turn-end drop needs a wrap-up to be coming, and `allTerminal` is false
  // for an EMPTY backlog — so a 1-tap arm must not answer true.
  const { bus, sent } = await wire();
  await arm(bus, sent, "t1");
  expect(core!.isHandlerArmed("t1")).toBe(true);
  expect(core!.handlerOwnsCompletion("t1")).toBe(false);

  bus.dispatchInbound(createMessage("handler:configure", {
    projectId: core!.projectId, terminalId: "t1", armed: true,
    backlog: [{ id: "i1", text: "ship it", status: "queued", createdAt: 1 }],
  }), "control", "loopback");
  expect(await waitFor(() => core!.handlerOwnsCompletion("t1"))).toBe(true);
});

test("prompt_answered retires the escalation its id names, and says the block is over", async () => {
  // The two halves of the branch below the chat guard. Neither is reachable from
  // the latch tests above — those assert only that a later push lands — so
  // deleting either line leaves this file, the engine suite and the api-server
  // suite all green while a terminal user who answered stays dotted "needs you"
  // (no onUserReply) or keeps a card for a question that is gone (no retraction).
  const { bus, sent, replies, port } = await wire();
  await arm(bus, sent, "t1");

  await post(port, "/handler-event", question("t1", "toolu_1"));
  expect(await waitFor(() => escalationsOf(sent, "t1")?.length === 1)).toBe(true);
  expect(escalationsOf(sent, "t1")![0]!.kind).toBe("resolve_in_session");

  replies.length = 0;
  await post(port, "/handler-event", {
    terminalId: "t1", agent: "claude", event: "prompt_answered", promptId: "toolu_1",
  });
  expect(await waitFor(() => escalationsOf(sent, "t1")?.length === 0)).toBe(true);
  expect(replies).toEqual([["t1", { submitted: false, typed: false }]]);
});

test("an id-less prompt_answered clears the block but retracts nothing", async () => {
  // One tool call reporting its own completion always names itself. An id-less
  // retraction means "every prompt on this session is gone" — true of a driver's
  // synchronous turn-end sweep, never of this hook — so dropping the `promptId`
  // guard takes an outstanding ask the user has not answered with it.
  const { bus, sent, replies, port } = await wire();
  await arm(bus, sent, "t1");

  await post(port, "/handler-event", question("t1", "toolu_1"));
  expect(await waitFor(() => escalationsOf(sent, "t1")?.length === 1)).toBe(true);

  replies.length = 0;
  await post(port, "/handler-event", {
    terminalId: "t1", agent: "claude", event: "prompt_answered",
  });
  // The unguarded half runs for both shapes, so it is the signal that the post
  // was handled — no sleep needed to prove the retraction did NOT happen.
  expect(await waitFor(() => replies.length === 1)).toBe(true);
  expect(escalationsOf(sent, "t1")?.length).toBe(1);
});
