// `/session-title` through a real core: whether a post belongs to the slot is
// decided from the slot's live run, which neither a stubbed api-server context
// nor SessionManager alone has.
import { test, expect, beforeEach, afterEach, afterAll, spyOn } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import { StructuredAgentManager } from "../src/structured/structured-manager";

let prevAbDir: string | undefined;
let prevCodexHome: string | undefined;
let abDir: string;
const folders: string[] = [];
let core: AgentCore | null = null;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  prevCodexHome = process.env.CODEX_HOME;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-title-agent-"));
  process.env.ANTGRID_DIR = abDir;
  process.env.CODEX_HOME = join(abDir, "codex");
});

afterEach(async () => {
  try { await core?.shutdown(); } catch { /* teardown only */ }
  core = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  if (prevCodexHome === undefined) delete process.env.CODEX_HOME; else process.env.CODEX_HOME = prevCodexHome;
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

test("a session-title post from another agent running inside the slot does not become the slot's conversation", async () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-title-agent-proj-"));
  folders.push(folder);
  writeFileSync(join(folder, "antgrid.yaml"), "name: title-agent\nagent:\n  tool: codex\n");
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
  const port = Number(readFileSync(join(abDir, "api.port"), "utf8").trim());

  bus.dispatchInbound(createMessage("session:create", { requestId: "create", name: "chat", mode: "chat" }), "control", "loopback");
  expect(await waitFor(() => sent.some((m) => m.type === "session:result" && m.requestId === "create"))).toBe(true);
  const created = sent.find((m) => m.type === "session:result" && m.requestId === "create");
  if (created?.type !== "session:result" || !created.session) throw new Error("session not created");
  const slot = created.session.id;

  let runId: string | undefined;
  const start = spyOn(StructuredAgentManager.prototype, "startChat").mockImplementation(async (options) => {
    runId = options.runId;
    return "ready";
  });
  try {
    bus.dispatchInbound(createMessage("session:start", { requestId: "start", sessionId: slot }), "control", "loopback");
    expect(await waitFor(() => !!runId)).toBe(true);
    const post = (agent: string, sessionId: string) => fetch(`http://127.0.0.1:${port}/session-title`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ terminalId: slot, runId, agent, sessionId }),
    });
    const conversations = () => sent.flatMap((m) => m.type === "session:updated"
      ? m.sessions.filter((s) => s.id === slot).map((s) => s.agentSessionId)
      : []);

    expect((await post("kimi", "nested-kimi")).status).toBe(200);
    expect((await post("codex", "codex-thread")).status).toBe(200);
    expect(await waitFor(() => conversations().includes("codex-thread"))).toBe(true);
    expect(conversations()).not.toContain("nested-kimi");
  } finally {
    start.mockRestore();
  }
});
