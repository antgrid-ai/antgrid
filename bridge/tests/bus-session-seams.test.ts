// The core seams a bus request drives, against a real core. A session a person
// made with elevated settings must not be woken by another machine, and a bus
// create must never carry settings that bypass an approval prompt.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { setLogLevel } from "../src/logger";
import { createMessage, type AbMessage } from "../src/protocol";
import { peerView } from "./relay-stubs";

setLogLevel("error");

let prevAbDir: string | undefined;
let abDir: string;
let folder: string;
let core: AgentCore | null = null;

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-bus-seams-"));
  folder = mkdtempSync(join(tmpdir(), "antgrid-bus-seams-proj-"));
  process.env.ANTGRID_DIR = abDir;
  writeFileSync(join(folder, "antgrid.yaml"), "name: seams\nagent:\n  tool: claude-code\n");
});

afterEach(async () => {
  try { await core?.shutdown(); } catch { /* best effort */ }
  core = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  for (const p of [abDir, folder]) {
    try { rmSync(p, { recursive: true, force: true }); } catch { /* Windows watcher handle */ }
  }
}, 30_000);

async function waitFor(predicate: () => boolean, what: string): Promise<void> {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

async function boot(): Promise<{ core: AgentCore; createFromApp: (extra: Record<string, unknown>) => Promise<string> }> {
  const c = await buildAgentCore({
    folder,
    mode: "remote",
    identity: { deviceId: "seams", deviceName: "seams", createdAt: new Date().toISOString() },
    machineId: () => "m1",
    remoteAccessEnabled: () => true,
  });
  core = c;
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  c.attachTransport(bus);
  c.setPeerSessionProvider(() => peerView({ peerId: "app-1" }));
  c.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"), "first agent:status");
  const createFromApp = async (extra: Record<string, unknown>): Promise<string> => {
    const requestId = crypto.randomUUID();
    bus.dispatchInbound(createMessage("session:create", { requestId, name: "app", ...extra }), "control", "loopback");
    await waitFor(() => sent.some((m) => m.type === "session:result" && (m as { requestId?: string }).requestId === requestId), "session:result");
    const result = sent.find((m) => m.type === "session:result" && (m as { requestId?: string }).requestId === requestId);
    if (result?.type !== "session:result" || !result.ok || !result.session) throw new Error(`create failed: ${JSON.stringify(result)}`);
    return result.session.id;
  };
  return { core: c, createFromApp };
}

test("a bus create makes a default-policy session with no command or args", async () => {
  const { core: c } = await boot();
  const made = await c.createSessionForBus({ name: "from-bus", mode: "terminal" });
  if (!made.ok) throw new Error(`create refused: ${made.code}`);
  expect(made.session).toMatchObject({ name: "from-bus", approvalPolicy: "default", mode: "terminal" });
  expect(made.session.command).toBeUndefined();
  expect(made.session.args).toBeUndefined();
});

test("a bus create naming an unknown tool fails without throwing", async () => {
  const { core: c } = await boot();
  expect(await c.createSessionForBus({ tool: "no-such-agent" })).toEqual({ ok: false, code: "REQUEST_FAILED" });
});

test("a bus start refuses a session a person made with bypass or a custom command, and it does not start", async () => {
  const { core: c, createFromApp } = await boot();
  const bypass = await createFromApp({ approvalPolicy: "bypass" });
  const custom = await createFromApp({ command: "node", args: "-e 0" });
  for (const id of [bypass, custom]) {
    expect(await c.startSessionForBus(id, "do it")).toEqual({ ok: false, code: "SESSION_NOT_BUS_ELIGIBLE" });
    expect(c.listSessions(true)?.find((s) => s.id === id)?.running).toBe(false);
  }
});

test("a bus stop on an elevated session still succeeds", async () => {
  const { core: c, createFromApp } = await boot();
  const bypass = await createFromApp({ approvalPolicy: "bypass" });
  expect(await c.stopSessionForBus(bypass)).toEqual({ ok: true });
});

test("a bus start or stop of a session this project does not hold is UNKNOWN_SESSION", async () => {
  const { core: c } = await boot();
  expect(await c.startSessionForBus("nope")).toEqual({ ok: false, code: "UNKNOWN_SESSION" });
  expect(await c.stopSessionForBus("nope")).toEqual({ ok: false, code: "UNKNOWN_SESSION" });
});

test("a bus start of an eligible session passes the eligibility check", async () => {
  const { core: c } = await boot();
  const made = await c.createSessionForBus({ name: "eligible" });
  if (!made.ok) throw new Error("create refused");
  // Whether the agent binary exists here is not what this pins, only that the
  // eligibility check did not refuse it.
  const started = await c.startSessionForBus(made.session.id);
  expect(started.ok === true || started.code === "REQUEST_FAILED").toBe(true);
  await c.stopSessionForBus(made.session.id);
}, 30_000);

type PersistedSessions = { sessions: { id: string; config?: Record<string, string> }[] };

function sessionsFile(): string {
  const [projectDir] = readdirSync(join(abDir, "agents"));
  return join(abDir, "agents", projectDir!, "sessions.json");
}

test("a chat mode that does not prompt is neither inherited by a bus create nor woken by a bus start", async () => {
  const first = await boot();
  const person = await first.createFromApp({ tool: "claude-code", mode: "chat" });
  await first.core.shutdown();
  core = null;
  // The person's last-used chat config, as the chat driver would have persisted it.
  const file = sessionsFile();
  const persisted = JSON.parse(readFileSync(file, "utf8")) as PersistedSessions;
  persisted.sessions.find((s) => s.id === person)!.config = { mode: "auto", model: "big" };
  writeFileSync(file, JSON.stringify(persisted));

  const { core: c } = await boot();
  expect(await c.startSessionForBus(person, "do it")).toEqual({ ok: false, code: "SESSION_NOT_BUS_ELIGIBLE" });
  expect(c.listSessions(true)?.find((s) => s.id === person)?.running).toBe(false);

  const made = await c.createSessionForBus({ name: "from-bus", tool: "claude-code", mode: "chat" });
  if (!made.ok) throw new Error(`create refused: ${made.code}`);
  await c.shutdown();
  core = null;
  const after = JSON.parse(readFileSync(file, "utf8")) as PersistedSessions;
  expect(after.sessions.find((s) => s.id === made.session.id)?.config).toEqual({ model: "big" });
}, 60_000);
