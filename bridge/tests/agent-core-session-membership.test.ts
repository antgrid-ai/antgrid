import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage, type SessionEntry } from "../src/protocol";
import type { QueuedLine } from "../src/session-bus/delivery-queue";
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

async function attached(
  opts?: {
    queueBusLine?: (line: Omit<QueuedLine, "queuedAt">) => void;
    renderBriefInstruction?: (d: { lead: unknown; brief: string }) => string;
    machineId?: string;
    sendToAppSession?: (peerId: string, msg: AbMessage) => boolean;
    sendToOwner?: (msg: AbMessage) => boolean;
  },
): Promise<{ sent: AbMessage[]; bus: MessageBus }> {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
    ...(opts?.queueBusLine ? { queueBusLine: opts.queueBusLine } : {}),
    ...(opts?.renderBriefInstruction
      ? { renderBriefInstruction: opts.renderBriefInstruction as never }
      : {}),
    ...(opts?.machineId ? { machineId: () => opts.machineId ?? null } : {}),
    ...(opts?.sendToAppSession ? { sendToAppSession: opts.sendToAppSession } : {}),
    ...(opts?.sendToOwner ? { sendToOwner: opts.sendToOwner } : {}),
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

/** A member as the carrier records it once the peer's bridge has answered with
 *  its Capability Card (spec 3.3). */
const cardedPeer = {
  ...peer,
  machineLabel: "Server",
  card: {
    os: { name: "Linux", version: "6.8.0", arch: "arm64" },
    repo: { label: "ingest", remote: "github.com/acme/ingest", branch: "main" },
  },
};

test("a join reaches the lead's agent carrying the card and the human's brief", async () => {
  const queued: Omit<QueuedLine, "queuedAt">[] = [];
  const { sent, bus } = await attached({ queueBusLine: (line) => queued.push(line) });
  bus.dispatchInbound(createMessage("session:create", { requestId: "c1", name: "Lead" }), "control", "loopback");
  const leadId = ((await resultFor(sent, "c1")).session as SessionEntry).id;

  bus.dispatchInbound(createMessage("session:member-record", {
    requestId: "r1", sessionId: leadId, member: cardedPeer, role: "peer",
    brief: "Own the ingest service.",
  }), "control", "loopback");
  const recorded = await resultFor(sent, "r1");
  expect(recorded.ok).toBe(true);
  // The card is on the persisted row, which is what lets antgrid_list_peers
  // answer for a machine this bridge can never reach again.
  expect(recorded.session?.members?.[0]?.card).toEqual(cardedPeer.card);

  // The brief lives on the PEER's disk, so this notice is the only thing on the
  // lead machine that ever states the mandate its own agent is working under.
  expect(queued).toHaveLength(1);
  expect(queued[0]).toMatchObject({ kind: "joined", sessionId: leadId });
  expect(queued[0]!.text).toContain("github.com/acme/ingest");
  expect(queued[0]!.text).toContain("Own the ingest service.");
  expect(queued[0]!.text).toContain('on machine "Server"');
}, 30_000);

test("re-recording an active member refreshes it without announcing a second join", async () => {
  const queued: Omit<QueuedLine, "queuedAt">[] = [];
  const { sent, bus } = await attached({ queueBusLine: (line) => queued.push(line) });
  bus.dispatchInbound(createMessage("session:create", { requestId: "c1", name: "Lead" }), "control", "loopback");
  const leadId = ((await resultFor(sent, "c1")).session as SessionEntry).id;

  bus.dispatchInbound(createMessage("session:member-record", {
    requestId: "r1", sessionId: leadId, member: cardedPeer, role: "peer", brief: "Own the ingest service.",
  }), "control", "loopback");
  expect((await resultFor(sent, "r1")).ok).toBe(true);

  // A carrier refreshes labels through the same verb, and a lead that is woken
  // to re-read a mandate it already holds pays a turn for nothing.
  bus.dispatchInbound(createMessage("session:member-record", {
    requestId: "r2", sessionId: leadId, member: { ...cardedPeer, machineLabel: "Server 2" }, role: "peer",
    brief: "Own the ingest service.",
  }), "control", "loopback");
  const refreshed = await resultFor(sent, "r2");
  expect(refreshed.session?.members?.[0]?.machineLabel).toBe("Server 2");
  expect(queued).toHaveLength(1);
}, 30_000);

test("a member with no card is recorded and announced without one", async () => {
  const queued: Omit<QueuedLine, "queuedAt">[] = [];
  const { sent, bus } = await attached({ queueBusLine: (line) => queued.push(line) });
  bus.dispatchInbound(createMessage("session:create", { requestId: "c1", name: "Lead" }), "control", "loopback");
  const leadId = ((await resultFor(sent, "c1")).session as SessionEntry).id;

  // What an older app sends: a membership and nothing else. It must still join.
  bus.dispatchInbound(createMessage("session:member-record", {
    requestId: "r1", sessionId: leadId, member: peer, role: "peer",
  }), "control", "loopback");
  expect((await resultFor(sent, "r1")).ok).toBe(true);
  expect(queued).toHaveLength(1);
  expect(queued[0]!.text).toContain("no capability card and no brief");
}, 30_000);

test("refuses a card whose fields outrun their bounds", async () => {
  const { sent, bus } = await attached();
  bus.dispatchInbound(createMessage("session:create", { requestId: "c1", name: "Lead" }), "control", "loopback");
  const leadId = ((await resultFor(sent, "c1")).session as SessionEntry).id;

  // The card's values are rendered into an agent's prompt, so the bound on them
  // is the same defence the labels beside them get — and it is enforced by the
  // switch's re-parse, since parseMessageFast reads the discriminator alone.
  bus.dispatchInbound({
    ...createMessage("session:member-record", { requestId: "r1", sessionId: leadId, member: peer, role: "peer" }),
    member: { ...peer, card: { repo: { remote: "x".repeat(400) } } },
  } as AbMessage, "control", "loopback");
  const refused = await resultFor(sent, "r1");
  expect(refused.ok).toBe(false);
  expect(refused.error).toContain("Malformed member payload");
}, 30_000);

// The Handler is the brief's other route and it is the RARE one: an added
// machine starts its agent in terminal mode, so nothing ever arms and the queue
// is what has to carry the mandate. Before this was wired the brief sat on disk
// forever while the dialog that collected it reported success.
test("a peer's brief is queued for its agent when no Handler arms", async () => {
  const queued: Omit<QueuedLine, "queuedAt">[] = [];
  const { sent, bus } = await attached({
    queueBusLine: (line) => queued.push(line),
    renderBriefInstruction: ({ brief }) => `WRAPPED<${brief}>`,
  });

  bus.dispatchInbound(createMessage("session:create", {
    requestId: "c1", name: "Peer", memberOf: lead, brief: "Own the ingest service.",
  }), "control", "loopback");
  const created = await resultFor(sent, "c1");
  expect(created.ok).toBe(true);
  const peerId = (created.session as SessionEntry).id;

  const brief = queued.find((l) => l.kind === "brief");
  expect(brief).toBeDefined();
  expect(brief).toMatchObject({ id: `brief:${peerId}`, sessionId: peerId });
  // Wrapped by the renderer, never the human's text raw: a brief injected
  // unwrapped is a mandate with no provenance.
  expect(brief!.text).toBe("WRAPPED<Own the ingest service.>");
}, 30_000);

// Handing the brief over is what clears it, so a second create-time flush (a
// carrier retrying, a restart replaying) must not queue the same mandate twice.
test("a queued brief is handed over once", async () => {
  const queued: Omit<QueuedLine, "queuedAt">[] = [];
  const { sent, bus } = await attached({
    queueBusLine: (line) => queued.push(line),
    renderBriefInstruction: ({ brief }) => `WRAPPED<${brief}>`,
  });

  bus.dispatchInbound(createMessage("session:create", {
    requestId: "c1", name: "Peer", memberOf: lead, brief: "Own the ingest service.",
  }), "control", "loopback");
  const peerId = ((await resultFor(sent, "c1")).session as SessionEntry).id;
  await new Promise((resolve) => setTimeout(resolve, 50));

  expect(queued.filter((l) => l.kind === "brief")).toHaveLength(1);
  expect(peerId).toBeTruthy();
}, 30_000);

// A build with no renderer holds the brief rather than queueing it raw, and a
// held brief is still on disk for the next attempt.
test("a brief is held, not queued unwrapped, when no renderer is wired", async () => {
  const queued: Omit<QueuedLine, "queuedAt">[] = [];
  const { sent, bus } = await attached({ queueBusLine: (line) => queued.push(line) });

  bus.dispatchInbound(createMessage("session:create", {
    requestId: "c1", name: "Peer", memberOf: lead, brief: "Own the ingest service.",
  }), "control", "loopback");
  expect((await resultFor(sent, "c1")).ok).toBe(true);
  await new Promise((resolve) => setTimeout(resolve, 50));

  expect(queued.filter((l) => l.kind === "brief")).toHaveLength(0);
}, 30_000);

// A peer bridge cannot dial the lead's machine (D7), so the app session that
// carried a frame in is its only way back. Membership is created by
// `session:create`, not by a bus frame, so before this the route was recorded
// only once the LEAD had sent something — leaving a machine that had just been
// added, briefed, and told to report unable to answer its own brief.
describe("the carrier that creates a membership is the peer's route home", () => {
  test("a peer's first outbound follows the app session that created it", async () => {
    const routed: { peerId: string; type: string }[] = [];
    const toOwner: AbMessage[] = [];
    const { sent, bus } = await attached({
      machineId: "peer-machine",
      sendToAppSession: (peerId, msg) => {
        routed.push({ peerId, type: msg.type });
        return true;
      },
      sendToOwner: (msg) => {
        toOwner.push(msg);
        return true;
      },
    });
    bus.dispatchInbound(createMessage("session:create", {
      requestId: "c1", name: "Peer", memberOf: lead, brief: "Own the backend.",
    }), "control", "relay", "carrier-1");
    const created = await resultFor(sent, "c1");
    const peerId = (created.session as SessionEntry).id;

    // Taskless on purpose: a finding before any assignment is exactly what a
    // brief saying "report what you find" asks for, and it is the case that had
    // nowhere to go.
    const note = core!.sessionBus.message({
      sessionId: peerId,
      taskId: null,
      to: lead,
      summary: "found it",
      parts: [{ kind: "text", text: "the codec is little-endian" }],
      contextId: lead.sessionId,
    });
    expect(note).toMatchObject({ ok: true, sent: true });
    expect(routed).toEqual([{ peerId: "carrier-1", type: "session-bus:message" }]);
    // Never the loopback owner: on a peer bridge that is the peer's OWN desktop
    // app, which accepts the frame and books a delivery that never happened.
    expect(toOwner).toEqual([]);
  }, 30_000);

  test("a peer with no carrier holds the frame instead of posting it to its own app", async () => {
    const toOwner: AbMessage[] = [];
    const { sent, bus } = await attached({
      machineId: "peer-machine",
      sendToAppSession: () => true,
      sendToOwner: (msg) => {
        toOwner.push(msg);
        return true;
      },
    });
    // No peerId: the loopback owner, which `noteBusOrigin` refuses to record
    // because on THIS bridge it is not the lead's carrier.
    bus.dispatchInbound(createMessage("session:create", {
      requestId: "c1", name: "Peer", memberOf: lead,
    }), "control", "loopback");
    const created = await resultFor(sent, "c1");

    const note = core!.sessionBus.message({
      sessionId: (created.session as SessionEntry).id,
      taskId: null,
      to: lead,
      summary: "found it",
      parts: [{ kind: "text", text: "x" }],
      contextId: lead.sessionId,
    });
    expect(note).toMatchObject({ ok: true, sent: false });
    expect(toOwner).toEqual([]);
  }, 30_000);

  // A route is learned from inbound traffic, and a restarted bridge has received
  // none. The task store beside it comes back off disk and re-arms its retries,
  // so every one of them would refuse; and on a task the peer has already acked,
  // the lead has no reason to send the frame that would teach it a route.
  test("a remembered carrier route survives a restart of the peer bridge", async () => {
    const first = await attached({
      machineId: "peer-machine",
      sendToAppSession: () => true,
      sendToOwner: () => true,
    });
    first.bus.dispatchInbound(createMessage("session:create", {
      requestId: "c1", name: "Peer", memberOf: lead,
    }), "control", "relay", "carrier-1");
    const peerSessionId = ((await resultFor(first.sent, "c1")).session as SessionEntry).id;

    const dying = core;
    core = null;
    await dying?.shutdown();

    const routed: { peerId: string; type: string }[] = [];
    await attached({
      machineId: "peer-machine",
      sendToAppSession: (peerId, msg) => {
        routed.push({ peerId, type: msg.type });
        return true;
      },
      sendToOwner: () => true,
    });

    // Nothing is dispatched into this core: the only thing that can name the
    // carrier is what the dead process wrote down.
    const note = core!.sessionBus.message({
      sessionId: peerSessionId,
      taskId: null,
      to: lead,
      summary: "found it",
      parts: [{ kind: "text", text: "the codec is little-endian" }],
      contextId: lead.sessionId,
    });
    expect(note).toMatchObject({ ok: true, sent: true });
    expect(routed).toEqual([{ peerId: "carrier-1", type: "session-bus:message" }]);
  }, 30_000);
});
