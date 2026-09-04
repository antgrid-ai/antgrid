import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage, type SessionEntry } from "../src/protocol";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-core-membership-"));
  process.env.ANTGRID_DIR = join(root, "state");
  writeFileSync(join(root, "antgrid.yaml"), "name: membership\nagent:\n  tool: claude-code\n");
});

// Same 30s budget and same bind-before-await discipline as
// agent-core-checkout-routing.test.ts — the reasons are documented there.
afterEach(async () => {
  const dying = core;
  const dir = root;
  const restore = previousAbDir;
  core = null;
  if (restore === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = restore;
  try {
    await dying?.shutdown();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}, 30_000);

const lead = { machineId: "lead-machine", projectId: "lead-project", sessionId: "lead-session" };
const peer = { machineId: "peer-machine", projectId: "peer-project", sessionId: "peer-session" };

async function attached(): Promise<{ sent: AbMessage[]; bus: MessageBus }> {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (message) => sent.push(message) });
  core.attachTransport(bus);
  // The session manager is bound at handshake; without this every verb below
  // is answered "agent not ready".
  core.onHandshakeComplete();
  return { sent, bus };
}

async function resultFor(sent: AbMessage[], requestId: string) {
  for (let i = 0; i < 200; i++) {
    const hit = sent.find((m) => m.type === "session:result" && m.requestId === requestId);
    if (hit && hit.type === "session:result") return hit;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`no session:result for ${requestId}`);
}

test("records and releases a member over the wire", async () => {
  const { sent, bus } = await attached();
  bus.dispatchInbound(createMessage("session:create", { requestId: "c1", name: "Lead" }), "control", "loopback");
  const created = await resultFor(sent, "c1");
  const leadId = (created.session as SessionEntry).id;

  bus.dispatchInbound(createMessage("session:member-record", {
    requestId: "r1", sessionId: leadId, member: { ...peer, machineLabel: "Server" }, role: "peer",
  }), "control", "loopback");
  const recorded = await resultFor(sent, "r1");
  expect(recorded.ok).toBe(true);
  expect(recorded.session?.members).toMatchObject([{ machineId: "peer-machine", state: "active" }]);

  bus.dispatchInbound(createMessage("session:member-release", {
    requestId: "r2", sessionId: leadId, member: peer, deleteRefused: true, reason: "WORKTREE_DIRTY",
  }), "control", "loopback");
  const released = await resultFor(sent, "r2");
  expect(released.ok).toBe(true);
  expect(released.session?.members).toMatchObject([
    { state: "released-delete-refused", releaseReason: "WORKTREE_DIRTY" },
  ]);
}, 30_000);

test("creates a peer session and marks it orphaned", async () => {
  const { sent, bus } = await attached();
  bus.dispatchInbound(createMessage("session:create", {
    requestId: "c1", name: "Peer", memberOf: lead, brief: "Own the backend.",
  }), "control", "loopback");
  const created = await resultFor(sent, "c1");
  expect(created.ok).toBe(true);
  const peerId = (created.session as SessionEntry).id;
  expect(created.session?.memberOf).toMatchObject({ machineId: "lead-machine", state: "active" });

  bus.dispatchInbound(createMessage("session:member-orphan", {
    requestId: "o1", sessionId: peerId, orphaned: true,
  }), "control", "loopback");
  const orphaned = await resultFor(sent, "o1");
  expect(orphaned.session?.memberOf).toMatchObject({ state: "orphaned" });
}, 30_000);

test("a create carrying a brief is answered exactly once", async () => {
  // The brief hand-off runs after the reply and outside its try, so whatever it
  // does it cannot author a second answer for this requestId: a carrier that
  // read one would take it for a failed create, retry, and end up with two peer
  // sessions on this machine.
  const { sent, bus } = await attached();
  bus.dispatchInbound(createMessage("session:create", {
    requestId: "c1", name: "Peer", memberOf: lead, brief: "Own the backend.",
  }), "control", "loopback");
  expect((await resultFor(sent, "c1")).ok).toBe(true);

  await new Promise((resolve) => setTimeout(resolve, 200));
  expect(sent.filter((m) => m.type === "session:result" && m.requestId === "c1")).toHaveLength(1);
}, 30_000);

test("refuses an isolated peer session with the schema's own reason", async () => {
  const { sent, bus } = await attached();
  bus.dispatchInbound(createMessage("session:create", {
    requestId: "c1", name: "Peer", memberOf: lead, isolation: "worktree",
  }), "control", "loopback");
  const created = await resultFor(sent, "c1");
  expect(created.ok).toBe(false);
  expect(created.error).toContain("worktree isolation");
}, 30_000);

test("refuses a member payload the union would reject", async () => {
  const { sent, bus } = await attached();
  bus.dispatchInbound(createMessage("session:create", { requestId: "c1", name: "Lead" }), "control", "loopback");
  const leadId = ((await resultFor(sent, "c1")).session as SessionEntry).id;

  // parseMessageFast admitted this frame on the type alone; the switch's own
  // re-parse is the only thing between an over-long label and a persisted row.
  bus.dispatchInbound({
    ...createMessage("session:member-record", { requestId: "r1", sessionId: leadId, member: peer, role: "peer" }),
    member: { ...peer, sessionName: "x".repeat(400) },
  } as AbMessage, "control", "loopback");
  const refused = await resultFor(sent, "r1");
  expect(refused.ok).toBe(false);
  expect(refused.error).toContain("Malformed member payload");
}, 30_000);
