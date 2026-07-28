import { test, expect, beforeEach, afterEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { loadPairedPhones } from "../src/paired-phones";
import { createMessage, type AbMessage } from "../src/protocol";

let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-transcript-snap-"));
  process.env.ANTGRID_DIR = abDir;
});

async function rmWithRetry(path: string): Promise<void> {
  for (let i = 0; i < 20; i++) {
    try { rmSync(path, { recursive: true, force: true }); return; }
    catch { await new Promise((r) => setTimeout(r, 25)); }
  }
}

let core: AgentCore | null = null;
afterEach(async () => {
  try { await core?.shutdown(); } catch {}
  core = null;
  await new Promise((r) => setTimeout(r, 50));
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR; else process.env.ANTGRID_DIR = prevAbDir;
  await rmWithRetry(abDir);
});

afterAll(async () => {
  while (folders.length) await rmWithRetry(folders.pop()!);
});

function tempFolder(): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-transcript-snap-proj-"));
  writeFileSync(join(f, "antgrid.yaml"), "name: test-transcript-snap\nagent:\n  tool: claude-code\n");
  folders.push(f);
  return f;
}

async function waitForServices(frames: AbMessage[], timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (frames.some((m) => m.type === "agent:status")) return;
    await new Promise((r) => setTimeout(r, 15));
  }
}

function findResponse(frames: AbMessage[], requestId: string): AbMessage | undefined {
  return frames.find((m) => m.type === "response" && (m as { requestId?: string }).requestId === requestId);
}

test("session.transcriptSnapshot returns empty frames for an unknown/not-running session", async () => {
  const folder = tempFolder();
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
  await waitForServices(sent);

  sent.length = 0;
  bus.dispatchInbound(
    createMessage("request", { requestId: "r1", method: "session.transcriptSnapshot", params: { sessionId: "ghost" } }),
    "control",
    "loopback",
  );

  const deadline = Date.now() + 2000;
  let res: AbMessage | undefined;
  while (Date.now() < deadline && !res) {
    res = findResponse(sent, "r1");
    if (!res) await new Promise((r) => setTimeout(r, 15));
  }
  expect(res).toBeDefined();
  if (res?.type === "response") {
    expect(res.ok).toBe(true);
    expect((res.result as { frames?: unknown[] })?.frames).toEqual([]);
  }
});

test("session.transcriptSnapshot with missing sessionId param returns E_BAD_PARAMS", async () => {
  const folder = tempFolder();
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
  await waitForServices(sent);

  sent.length = 0;
  bus.dispatchInbound(
    createMessage("request", { requestId: "r2", method: "session.transcriptSnapshot", params: {} }),
    "control",
    "loopback",
  );

  const deadline = Date.now() + 2000;
  let res: AbMessage | undefined;
  while (Date.now() < deadline && !res) {
    res = findResponse(sent, "r2");
    if (!res) await new Promise((r) => setTimeout(r, 15));
  }
  expect(res).toBeDefined();
  if (res?.type === "response") {
    expect(res.ok).toBe(false);
    expect(res.error?.code).toBe("E_BAD_PARAMS");
  }
});

test("drops session.transcriptSnapshot from a trusted-but-not-allowed phone", async () => {
  const folder = tempFolder();
  const store = loadPairedPhones(abDir);
  const pk1 = "phone-pubkey-transcript-snap";
  store.upsert({
    phonePubkey: pk1,
    phoneDeviceId: "phone-dev-transcript-snap",
    pairedAt: new Date().toISOString(),
    lastSeenAt: new Date().toISOString(),
    allowedProjects: [],
  });

  core = await buildAgentCore({
    folder,
    mode: "remote",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    pairedPhones: store,
  });
  const projectId = core.projectId;

  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.setPeerPubkeyProvider(() => pk1);
  core.onHandshakeComplete();
  await waitForServices(sent);

  sent.length = 0;
  bus.dispatchInbound(
    createMessage("request", { requestId: "r3", method: "session.transcriptSnapshot", params: { sessionId: "ghost" } }),
    "control",
    "relay",
  );
  await new Promise((r) => setTimeout(r, 200));
  expect(findResponse(sent, "r3")).toBeUndefined();

  // Positive control: prove the silence above was specifically the allowlist
  // gate (not a wrong channel/source or the method never reaching the
  // handler) by granting the project and re-sending the same verb.
  store.allowProject(pk1, projectId);
  sent.length = 0;
  bus.dispatchInbound(
    createMessage("request", { requestId: "r3b", method: "session.transcriptSnapshot", params: { sessionId: "ghost" } }),
    "control",
    "relay",
  );

  const deadline = Date.now() + 2000;
  let res: AbMessage | undefined;
  while (Date.now() < deadline && !res) {
    res = findResponse(sent, "r3b");
    if (!res) await new Promise((r) => setTimeout(r, 15));
  }
  expect(res).toBeDefined();
  if (res?.type === "response") {
    expect(res.ok).toBe(true);
    expect((res.result as { frames?: unknown[] })?.frames).toEqual([]);
  }
});
