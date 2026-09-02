// bridge/tests/agent-core-entitlement.test.ts
//
// The wiring, end to end inside the bridge: a `handler:configure {armed:true}`
// arriving on the bus reaches the engine's gate carrying the tier the HOST
// supplied. The engine's own gate logic is covered in
// handler/entitlement-gate.test.ts; what this proves is that `tierClaim`
// survives the buildAgentCore → HandlerEngine hop at all, which no unit test on
// either side can see.
import { test, expect, beforeEach, afterEach, afterAll } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage } from "../src/protocol";
import type { TierClaim } from "../src/entitlement";

let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-entitlement-"));
  process.env.ANTGRID_DIR = abDir;
});

async function rmWithRetry(path: string): Promise<void> {
  for (let i = 0; i < 20; i++) {
    try { rmSync(path, { recursive: true, force: true }); return; }
    catch { await new Promise((r) => setTimeout(r, 25)); }
  }
}

// Same benign teardown artifact remote-access-gate.test.ts documents: the raw
// fs.watch under chokidar can emit a late EPERM/ENOENT after a watched temp dir
// is removed, uncatchable through chokidar's own error channel.
function ignoreWatcherEperm(err: unknown): void {
  const code = (err as { code?: string } | null)?.code;
  if (code === "EPERM" || code === "ENOENT") return;
  throw err;
}
process.on("uncaughtException", ignoreWatcherEperm);

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
  process.off("uncaughtException", ignoreWatcherEperm);
});

function tempFolder(): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-entitlement-proj-"));
  writeFileSync(join(f, "antgrid.yaml"), "name: test-entitlement\nagent:\n  tool: claude-code\n");
  folders.push(f);
  return f;
}

interface HandlerStatus { sessions: Array<{ terminalId: string }> }
function armedTerminals(frames: AbMessage[]): string[] {
  const last = frames.filter((m) => m.type === "handler:status").at(-1) as never as HandlerStatus | undefined;
  return (last?.sessions ?? []).map((s) => s.terminalId);
}

/** Wait for a frame of `type` to appear, so the arm is dispatched against a
 *  core whose services exist — every inbound verb is dropped until they do
 *  (`if (!manager) return`), which would make a drop look like a refusal. */
async function waitFor(frames: AbMessage[], type: string, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (frames.some((m) => m.type === type)) return;
    await new Promise((r) => setTimeout(r, 15));
  }
}

interface ArmResult {
  terminalId: string;
  armed: string[];
  /** handler:status frames published AFTER the connect seeded one. */
  extraStatusFrames: number;
}

async function armThrough(tierClaim: (() => TierClaim) | undefined): Promise<ArmResult> {
  const folder = tempFolder();
  core = await buildAgentCore({
    folder,
    mode: "local",
    identity: { deviceId: "agent-dev", deviceName: "agent-dev", createdAt: new Date().toISOString() },
    ...(tierClaim ? { tierClaim } : {}),
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  // Services are built lazily off the handshake; the same call seeds the app's
  // Handler defaults, which is the not-armed status every refusal below is
  // measured against.
  core.onHandshakeComplete();
  await waitFor(sent, "agent:status");
  await waitFor(sent, "handler:status");
  const seeded = sent.filter((m) => m.type === "handler:status").length;

  const terminalId = `t-${randomUUID()}`;
  bus.dispatchInbound(
    createMessage("handler:configure", { projectId: core.projectId, terminalId, armed: true }),
    "control",
  );
  // The honored path publishes a new status synchronously; the refused path
  // publishes nothing new at all (see below), so this bounded poll settles fast
  // when it arms and spends its budget when it does not.
  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && !armedTerminals(sent).includes(terminalId)) {
    await new Promise((r) => setTimeout(r, 15));
  }
  return {
    terminalId,
    armed: armedTerminals(sent),
    extraStatusFrames: sent.filter((m) => m.type === "handler:status").length - seeded,
  };
}

test("a pro tier claim reaches the engine and the arm is honored", async () => {
  const { terminalId, armed } = await armThrough(() => ({ credentialed: true, tier: "pro" }));
  expect(armed).toContain(terminalId);
});

test("a free tier claim reaches the engine and the arm is refused", async () => {
  // Refused on a LOCAL core, deliberately: local is the desktop default, so
  // gating only remote cores would let a signed-in Free user open the same
  // project locally and arm anyway.
  const { terminalId, armed, extraStatusFrames } = await armThrough(() => ({ credentialed: true, tier: "free" }));
  expect(armed).not.toContain(terminalId);
  // The strongest available statement of "refused via the Handler-off path":
  // the status the refusal emits is byte-identical to the not-armed one already
  // cached, so MessageBus's payload-equality dedup drops it and the app is
  // handed nothing new to render. A refusal that invented its own state — a new
  // field, a new session row, an error frame — could not be dedup'd here.
  expect(extraStatusFrames).toBe(0);
});

test("a credentialed machine with an unreadable claim is refused", async () => {
  const { terminalId, armed, extraStatusFrames } = await armThrough(() => ({ credentialed: true, tier: null }));
  expect(armed).not.toContain(terminalId);
  expect(extraStatusFrames).toBe(0);
});

test("a core with no tierClaim at all still arms — the local/offline flow", async () => {
  // A bare `antgrid agent`, or any host that never held device credentials.
  // Fail-closed applies to a machine that HAS a credential and cannot read its
  // tier; it must never apply to a runtime that never had one.
  const { terminalId, armed } = await armThrough(undefined);
  expect(armed).toContain(terminalId);
});

test("a signed-out host arms even though it supplies a claim source", async () => {
  // HostServer always supplies `tierClaim`; `credentialed:false` is how it says
  // "this machine holds no device token", and that is the same carve-out.
  const { terminalId, armed } = await armThrough(() => ({ credentialed: false, tier: null }));
  expect(armed).toContain(terminalId);
});
