// The `session:restart` verb through a real core: the reply shape (`restarted`,
// `errorCode`) is decided in agent-core's grouped session arm, not in
// SessionManager, so the manager is stubbed and only the mapping is asserted.
import { test, expect, beforeEach, afterEach, afterAll, mock, spyOn } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { SessionManager, SessionRestartRefusal } from "../src/session-manager";

let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];
let core: AgentCore | null = null;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-restart-verb-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(async () => {
  mock.restore();
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

async function openCore() {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-restart-verb-proj-"));
  folders.push(folder);
  writeFileSync(join(folder, "antgrid.yaml"), "name: restart-verb\nagent:\n  tool: codex\n");
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

  bus.dispatchInbound(createMessage("session:create", { requestId: "create", name: "s" }), "control", "loopback");
  expect(await waitFor(() => sent.some((m) => m.type === "session:result" && m.requestId === "create"))).toBe(true);
  const created = sent.find((m) => m.type === "session:result" && m.requestId === "create");
  if (created?.type !== "session:result" || !created.session) throw new Error("session not created");

  const restart = async (requestId: string) => {
    bus.dispatchInbound(
      createMessage("session:restart", { requestId, sessionId: created.session!.id, reason: "memory" }),
      "control",
      "loopback",
    );
    expect(await waitFor(() => sent.some((m) => m.type === "session:result" && m.requestId === requestId))).toBe(true);
    const reply = sent.find((m) => m.type === "session:result" && m.requestId === requestId);
    if (reply?.type !== "session:result") throw new Error("no reply");
    return reply;
  };
  return { restart };
}

test("a restart reply carries restarted:true and the session", async () => {
  const { restart } = await openCore();
  spyOn(SessionManager.prototype, "restartForMemory").mockResolvedValue(true);
  const reply = await restart("r1");
  expect(reply.ok).toBe(true);
  expect(reply.restarted).toBe(true);
  expect(reply.session?.id).toBeDefined();
});

test("a no-op restart carries restarted:false", async () => {
  const { restart } = await openCore();
  const reply = await restart("r2");
  expect(reply.ok).toBe(true);
  expect(reply.restarted).toBe(false);
});

test("a refused restart carries the refusal's errorCode", async () => {
  const { restart } = await openCore();
  const spy = spyOn(SessionManager.prototype, "restartForMemory");
  spy.mockRejectedValueOnce(new SessionRestartRefusal("MEMORY_OFF", "Memory is off, so restarting would not add it."));
  const off = await restart("r3");
  expect(off).toMatchObject({ ok: false, errorCode: "MEMORY_OFF" });
  expect(off.restarted).toBeUndefined();

  spy.mockRejectedValueOnce(new SessionRestartRefusal("SCHEDULED_RUN", "A scheduled run is in progress on this session."));
  expect(await restart("r4")).toMatchObject({ ok: false, errorCode: "SCHEDULED_RUN" });
});

test("a restart failure without a code carries only the error text", async () => {
  const { restart } = await openCore();
  spyOn(SessionManager.prototype, "restartForMemory").mockRejectedValue(new Error("failed to restart session: x"));
  const reply = await restart("r5");
  expect(reply.ok).toBe(false);
  expect(reply.error).toContain("failed to restart session");
  expect(reply.errorCode).toBeUndefined();
});
