// The loopback bus routes are the ONLY thing an MCP tool talks to, so every
// decision they make has to be provable here: who the caller is (derived from
// its terminal id, never declared), what each verb does to the stores, and what
// a refusal looks like on the wire. A tool that could answer differently from
// its route would be a second, unbounded authority.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startApiServer, type AgentContext } from "../src/api-server";
import { createSessionBusApi, type SessionMembership } from "../src/session-bus/api";
import { SessionBusCoordinator } from "../src/session-bus/coordinator";
import { MAX_TASKS_PER_HOUR } from "../src/session-bus/task-guard";
import { saveBrief } from "../src/session-bus/brief-store";
import type { AbConfig } from "../src/config";
import type { AbMessage, SessionMember, SessionMemberOf } from "../src/protocol";

const dirs: string[] = [];
function tempDir(prefix: string): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  dirs.push(dir);
  return dir;
}

afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

const LEAD_SESSION = "lead-1";
const PEER_SESSION = "peer-1";

const PEER_MEMBER: SessionMember = {
  machineId: "m2",
  projectId: "p2",
  sessionId: PEER_SESSION,
  sessionName: "peer session",
  role: "peer",
  // The Capability Card the peer's own bridge observed (spec 3.3). It is on the
  // member row and nowhere else, so the peers route is the only thing that can
  // ever answer a lead's "what is this machine".
  card: {
    os: { name: "Linux", version: "6.8.0", arch: "arm64" },
    repo: { label: "ingest", remote: "github.com/acme/ingest", branch: "main" },
  },
  joinedAt: 1_000,
  state: "active",
};

const LEAD_OF_PEER: SessionMemberOf = {
  machineId: "m1",
  projectId: "p1",
  sessionId: LEAD_SESSION,
  sessionName: "lead session",
  role: "lead",
  joinedAt: 1_000,
  state: "active",
};

/** One machine's half of the pair: its own coordinator, the API over it, and a
 *  loopback API server. The two machines are wired to each other through
 *  `deliver` below rather than through a relay — this is the carrier's job, and
 *  the routes cannot tell the difference. */
interface Machine {
  coordinator: SessionBusCoordinator;
  port: number;
  stop(): void;
  outbound: AbMessage[];
  /** The routing decision behind each frame this machine tried to send. The
   *  frame itself does not carry it — `role` chooses between the carrier and the
   *  loopback owner, which is a difference only the sender can see. */
  routes: { contextId: string; role: string }[];
}

function membershipOf(terminalId: string): SessionMembership | null {
  if (terminalId === LEAD_SESSION) {
    return { sessionId: LEAD_SESSION, sessionName: "lead session", members: [PEER_MEMBER] };
  }
  if (terminalId === PEER_SESSION) {
    return { sessionId: PEER_SESSION, sessionName: "peer session", members: [], memberOf: LEAD_OF_PEER };
  }
  // A session that exists and joined no bus, which is every ordinary session.
  if (terminalId === "solo-1") return { sessionId: "solo-1", members: [] };
  // Anything else names no session at all (a service PTY, or a bad id).
  return null;
}

function machine(opts: {
  abDir: string;
  machineId: string;
  projectId: string;
  sessionIds: string[];
  carrierPresent?: boolean;
  /** False makes every send fail, which is what a machine with no carrier route
   *  looks like from inside the coordinator. */
  deliverable?: boolean;
}): Machine {
  const outbound: AbMessage[] = [];
  const routes: { contextId: string; role: string }[] = [];
  const coordinator = new SessionBusCoordinator({
    abDir: opts.abDir,
    projectId: opts.projectId,
    self: (sessionId) =>
      opts.sessionIds.includes(sessionId)
        ? {
          key: { machineId: opts.machineId, projectId: opts.projectId, sessionId },
          ref: { machineId: opts.machineId, projectId: opts.projectId, sessionId },
        }
        : null,
    send: (frame, ctx) => {
      routes.push({ contextId: ctx.contextId, role: ctx.role });
      if (opts.deliverable === false) return false;
      outbound.push(frame);
      return true;
    },
  });
  const api = createSessionBusApi({
    coordinator,
    abDir: opts.abDir,
    projectId: opts.projectId,
    projectName: "proj",
    machineId: () => opts.machineId,
    membership: membershipOf,
    carrierPresent: () => opts.carrierPresent !== false,
  });
  const ctx: AgentContext = {
    manager: () => null,
    config: () => ({} as AbConfig),
    project: () => ({ id: opts.projectId, path: opts.abDir } as any),
    sendAb: () => {},
    sessionBus: api,
  };
  const server = startApiServer(ctx);
  return {
    coordinator,
    port: server.port,
    outbound,
    routes,
    stop() {
      coordinator.stop();
      server.stop();
    },
  };
}

/** Move every queued frame between the two machines until neither has more. The
 *  carrier is synchronous here so a test reads as one exchange; the coordinator
 *  is what makes the real one eventual. */
function deliver(a: Machine, b: Machine): void {
  for (let i = 0; i < 20; i += 1) {
    const from = a.outbound.length ? a : b.outbound.length ? b : null;
    if (!from) return;
    const to = from === a ? b : a;
    const frame = from.outbound.shift()!;
    to.coordinator.handleInbound(frame);
  }
}

async function get(m: Machine, path: string, terminalId?: string): Promise<{ status: number; body: any }> {
  const sep = path.includes("?") ? "&" : "?";
  const url = `http://127.0.0.1:${m.port}/session-bus/${path}${terminalId ? `${sep}terminalId=${terminalId}` : ""}`;
  const res = await fetch(url);
  return { status: res.status, body: await res.json() };
}

async function post(
  m: Machine,
  path: string,
  terminalId: string | undefined,
  body: unknown,
): Promise<{ status: number; body: any }> {
  const url = `http://127.0.0.1:${m.port}/session-bus/${path}${terminalId ? `?terminalId=${terminalId}` : ""}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return { status: res.status, body: await res.json() };
}

function pair(): { lead: Machine; peer: Machine; stop(): void } {
  const lead = machine({ abDir: tempDir("bus-lead-"), machineId: "m1", projectId: "p1", sessionIds: [LEAD_SESSION] });
  const peer = machine({ abDir: tempDir("bus-peer-"), machineId: "m2", projectId: "p2", sessionIds: [PEER_SESSION] });
  return { lead, peer, stop: () => { lead.stop(); peer.stop(); } };
}

describe("session-bus role resolution", () => {
  test("a terminal naming no session is a non-member, and says so without an error", async () => {
    const { lead, stop } = pair();
    try {
      const role = await get(lead, "role", "some-service-pty");
      expect(role.status).toBe(200);
      expect(role.body).toEqual({ role: null, lead: false, peer: false, sessionId: null });

      // The other routes refuse it: a non-member has no session to answer for.
      const session = await get(lead, "session", "some-service-pty");
      expect(session.status).toBe(403);
      expect(session.body.code).toBe("NOT_MEMBER");
    } finally {
      stop();
    }
  });

  test("a session that joined no bus is a non-member too", async () => {
    const { lead, stop } = pair();
    try {
      const role = await get(lead, "role", "solo-1");
      expect(role.body.role).toBeNull();
      expect((await get(lead, "peers", "solo-1")).status).toBe(403);
    } finally {
      stop();
    }
  });

  test("a request with no terminal id at all is a non-member", async () => {
    const { lead, stop } = pair();
    try {
      const role = await get(lead, "role");
      expect(role.body.role).toBeNull();
    } finally {
      stop();
    }
  });

  test("the role comes from the membership row, not from anything the caller sends", async () => {
    const { lead, peer, stop } = pair();
    try {
      const asLead = await get(lead, "role", LEAD_SESSION);
      expect(asLead.body).toMatchObject({ role: "lead", lead: true, peer: false, sessionId: LEAD_SESSION });
      const asPeer = await get(peer, "role", PEER_SESSION);
      expect(asPeer.body).toMatchObject({ role: "peer", lead: false, peer: true, sessionId: PEER_SESSION });
    } finally {
      stop();
    }
  });

  test("a core with no bus answers every route 503 rather than reporting a non-member", async () => {
    const server = startApiServer({
      manager: () => null,
      config: () => ({} as AbConfig),
      project: () => ({ id: "p1", path: tempDir("bus-none-") } as any),
      sendAb: () => {},
    });
    try {
      const res = await fetch(`http://127.0.0.1:${server.port}/session-bus/role?terminalId=${LEAD_SESSION}`);
      expect(res.status).toBe(503);
      expect((await res.json()).code).toBe("AGENT_NOT_READY");
    } finally {
      server.stop();
    }
  });
});

describe("session-bus routes", () => {
  test("a lead lists its peers, and the carrier's presence is reported", async () => {
    const withCarrier = machine({
      abDir: tempDir("bus-carrier-"), machineId: "m1", projectId: "p1", sessionIds: [LEAD_SESSION],
    });
    const without = machine({
      abDir: tempDir("bus-nocarrier-"), machineId: "m1", projectId: "p1", sessionIds: [LEAD_SESSION],
      carrierPresent: false,
    });
    try {
      const on = await get(withCarrier, "peers", LEAD_SESSION);
      expect(on.status).toBe(200);
      expect(on.body.peers).toHaveLength(1);
      expect(on.body.peers[0]).toMatchObject({
        sessionId: PEER_SESSION,
        carrierAttached: true,
      });
      // The card reaches the lead's tools intact: an OS or a repo dropped here
      // leaves antgrid_list_peers unable to say what a machine IS, which is the
      // half of spec 3.3 the lead decides "what to ask" from.
      expect(on.body.peers[0].card).toEqual({
        os: { name: "Linux", version: "6.8.0", arch: "arm64" },
        repo: { label: "ingest", remote: "github.com/acme/ingest", branch: "main" },
      });

      const off = await get(without, "peers", LEAD_SESSION);
      expect(off.body.peers[0].carrierAttached).toBe(false);
    } finally {
      withCarrier.stop();
      without.stop();
    }
  });

  test("a peer cannot list peers and a lead cannot read a brief", async () => {
    const { lead, peer, stop } = pair();
    try {
      const peers = await get(peer, "peers", PEER_SESSION);
      expect(peers.status).toBe(403);
      expect(peers.body.code).toBe("NOT_LEAD");

      const brief = await get(lead, "brief", LEAD_SESSION);
      expect(brief.status).toBe(403);
      expect(brief.body.code).toBe("NOT_PEER");
    } finally {
      stop();
    }
  });

  test("a stored brief is served with the scope it was stored with", async () => {
    const abDir = tempDir("bus-brief-");
    const m = machine({ abDir, machineId: "m2", projectId: "p2", sessionIds: [PEER_SESSION] });
    try {
      saveBrief(abDir, "p2", PEER_SESSION, {
        lead: LEAD_OF_PEER,
        brief: "Owns: the relay.\nMay not: touch the app.",
        now: 1_000,
      });
      const res = await get(m, "brief", PEER_SESSION);
      expect(res.status).toBe(200);
      expect(res.body.brief).toContain("Owns: the relay.");
      expect(res.body.scope.map((s: { label: string }) => s.label)).toEqual(["Owns", "May not"]);
      expect(res.body.lead.sessionId).toBe(LEAD_SESSION);
    } finally {
      m.stop();
    }
  });

  test("a peer with no stored brief is refused rather than given an empty one", async () => {
    const { peer, stop } = pair();
    try {
      const res = await get(peer, "brief", PEER_SESSION);
      expect(res.status).toBe(404);
      expect(res.body.code).toBe("UNKNOWN_TASK");
    } finally {
      stop();
    }
  });

  test("an assign opens a task on both machines, and each side sees its own role", async () => {
    const { lead, peer, stop } = pair();
    try {
      const assigned = await post(lead, "tasks", LEAD_SESSION, {
        peer: PEER_SESSION,
        summary: "port the codec",
        instruction: "Port the wire codec and report the diff.",
      });
      expect(assigned.status).toBe(200);
      expect(assigned.body.ok).toBe(true);
      const taskId = assigned.body.taskId as string;

      const leadTasks = await get(lead, "tasks", LEAD_SESSION);
      expect(leadTasks.body.tasks).toHaveLength(1);
      expect(leadTasks.body.tasks[0]).toMatchObject({ taskId, role: "lead", state: "submitted" });

      deliver(lead, peer);

      const peerTask = await get(peer, `tasks/${taskId}`, PEER_SESSION);
      expect(peerTask.status).toBe(200);
      expect(peerTask.body).toMatchObject({ taskId, role: "peer" });
    } finally {
      stop();
    }
  });

  test("a peer id no active member matches is refused, and the reason names the tool that lists them", async () => {
    const { lead, stop } = pair();
    try {
      const res = await post(lead, "tasks", LEAD_SESSION, {
        peer: "no-such-session",
        summary: "s",
        instruction: "i",
      });
      expect(res.status).toBe(404);
      expect(res.body.code).toBe("UNKNOWN_PEER");
      expect(res.body.error).toContain("antgrid_list_peers");
    } finally {
      stop();
    }
  });

  test("a peer cannot assign and a lead cannot report", async () => {
    const { lead, peer, stop } = pair();
    try {
      const assign = await post(peer, "tasks", PEER_SESSION, {
        peer: LEAD_SESSION, summary: "s", instruction: "i",
      });
      expect(assign.status).toBe(403);
      expect(assign.body.code).toBe("NOT_LEAD");

      const complete = await post(lead, "tasks/whatever/complete", LEAD_SESSION, { summary: "done" });
      expect(complete.status).toBe(403);
      expect(complete.body.code).toBe("NOT_PEER");
    } finally {
      stop();
    }
  });

  test("a body carrying a bridge-owned field is refused 400, not silently ignored", async () => {
    const { lead, stop } = pair();
    try {
      const res = await post(lead, "tasks", LEAD_SESSION, {
        peer: PEER_SESSION,
        summary: "s",
        instruction: "i",
        // Every one of these is resolved by the bridge (spec 3.4).
        taskId: "t-forged",
      });
      expect(res.status).toBe(400);
      expect(res.body.error).toBe("Invalid body");
    } finally {
      stop();
    }
  });

  test("a peer opens, asks, is answered, and completes; each hop lands on the other machine", async () => {
    const { lead, peer, stop } = pair();
    try {
      const assigned = await post(lead, "tasks", LEAD_SESSION, {
        peer: PEER_SESSION, summary: "port the codec", instruction: "Port it.",
      });
      const taskId = assigned.body.taskId as string;
      deliver(lead, peer);

      expect((await post(peer, `tasks/${taskId}/open`, PEER_SESSION, undefined)).status).toBe(200);
      deliver(lead, peer);
      expect((await get(lead, `tasks/${taskId}`, LEAD_SESSION)).body.state).toBe("working");

      const asked = await post(peer, "ask", PEER_SESSION, {
        taskId, summary: "which branch", question: "Which branch should this land on?",
      });
      expect(asked.status).toBe(200);
      expect(asked.body.requestId).toBeTruthy();
      deliver(lead, peer);
      const blocked = await get(lead, `tasks/${taskId}`, LEAD_SESSION);
      expect(blocked.body).toMatchObject({ state: "input-required", waitingOn: "lead" });

      const answered = await post(lead, `tasks/${taskId}/answer`, LEAD_SESSION, {
        summary: "branch", answer: "development",
      });
      expect(answered.status).toBe(200);
      deliver(lead, peer);
      expect((await get(peer, `tasks/${taskId}`, PEER_SESSION)).body.state).toBe("working");

      const done = await post(peer, `tasks/${taskId}/complete`, PEER_SESSION, {
        summary: "ported", text: "The codec is ported.",
      });
      expect(done.status).toBe(200);
      deliver(lead, peer);
      expect((await get(lead, `tasks/${taskId}`, LEAD_SESSION)).body.state).toBe("completed");
    } finally {
      stop();
    }
  });

  test("an answer to a task nobody is blocked on is refused rather than sent as a loose message", async () => {
    const { lead, peer, stop } = pair();
    try {
      const assigned = await post(lead, "tasks", LEAD_SESSION, {
        peer: PEER_SESSION, summary: "s", instruction: "i",
      });
      const taskId = assigned.body.taskId as string;
      deliver(lead, peer);
      const res = await post(lead, `tasks/${taskId}/answer`, LEAD_SESSION, { summary: "x", answer: "y" });
      expect(res.status).toBe(409);
      expect(res.body.code).toBe("DUPLICATE_STATE");
    } finally {
      stop();
    }
  });

  test("a cancel reaches the peer and refuses once the task is terminal", async () => {
    const { lead, peer, stop } = pair();
    try {
      const assigned = await post(lead, "tasks", LEAD_SESSION, {
        peer: PEER_SESSION, summary: "s", instruction: "i",
      });
      const taskId = assigned.body.taskId as string;
      deliver(lead, peer);

      expect((await post(lead, `tasks/${taskId}/cancel`, LEAD_SESSION, { reason: "no longer needed" })).status).toBe(200);
      deliver(lead, peer);
      expect((await get(peer, `tasks/${taskId}`, PEER_SESSION)).body.state).toBe("canceled");

      const again = await post(lead, `tasks/${taskId}/cancel`, LEAD_SESSION, { reason: "again" });
      expect(again.status).toBe(409);
      expect(again.body.code).toBe("TASK_TERMINAL");
    } finally {
      stop();
    }
  });

  test("a finding travels without moving the task's state", async () => {
    const { lead, peer, stop } = pair();
    try {
      const assigned = await post(lead, "tasks", LEAD_SESSION, {
        peer: PEER_SESSION, summary: "s", instruction: "i",
      });
      const taskId = assigned.body.taskId as string;
      deliver(lead, peer);

      const finding = await post(peer, "findings", PEER_SESSION, {
        taskId, summary: "the relay pins bun 1.3.10", text: "Its APNs handshake fails.",
      });
      expect(finding.status).toBe(200);
      expect(finding.body.ok).toBe(true);
      deliver(lead, peer);
      expect((await get(lead, `tasks/${taskId}`, LEAD_SESSION)).body.state).toBe("submitted");
    } finally {
      stop();
    }
  });

  test("an artifact round-trips through publish, list and a ranged read", async () => {
    const { peer, stop } = pair();
    try {
      const published = await post(peer, "artifacts", PEER_SESSION, {
        name: "diff.txt", summary: "the codec diff", content: "0123456789",
      });
      expect(published.status).toBe(200);
      const artifactId = published.body.artifact.artifactId as string;
      expect(published.body.artifact).toMatchObject({ name: "diff.txt", bytes: 10, mediaType: "text/plain" });

      const list = await get(peer, "artifacts", PEER_SESSION);
      expect(list.body.artifacts.map((a: { artifactId: string }) => a.artifactId)).toEqual([artifactId]);

      const whole = await get(peer, `artifacts/${artifactId}`, PEER_SESSION);
      expect(whole.body).toMatchObject({ offset: 0, eof: true, text: "0123456789" });

      const slice = await get(peer, `artifacts/${artifactId}?offset=4&length=3`, PEER_SESSION);
      expect(slice.body).toMatchObject({ offset: 4, eof: false, text: "456" });
    } finally {
      stop();
    }
  });

  test("an artifact id from the other machine is refused with the reason, not a bare 404", async () => {
    const { lead, stop } = pair();
    try {
      const res = await get(lead, "artifacts/not-here", LEAD_SESSION);
      expect(res.status).toBe(404);
      expect(res.body.code).toBe("UNKNOWN_ARTIFACT");
      expect(res.body.error).toContain("where they were published");
    } finally {
      stop();
    }
  });

  test("the session route carries the budget, the scope and the open tasks", async () => {
    const { lead, peer, stop } = pair();
    try {
      const assigned = await post(lead, "tasks", LEAD_SESSION, {
        peer: PEER_SESSION, summary: "s", instruction: "i",
      });
      const view = await get(lead, "session", LEAD_SESSION);
      expect(view.status).toBe(200);
      expect(view.body).toMatchObject({ role: "lead", sessionId: LEAD_SESSION });
      expect(view.body.self).toMatchObject({ machineId: "m1", projectId: "p1", sessionId: LEAD_SESSION });
      expect(view.body.openTaskIds).toEqual([assigned.body.taskId]);
      expect(view.body.budget).toMatchObject({ halted: false });
      expect(view.body.budget.hourlyRemaining).toBe(MAX_TASKS_PER_HOUR - 1);
      expect(peer.outbound).toBeDefined();
    } finally {
      stop();
    }
  });

  test("an unknown path under the bus prefix is a 404, not a refusal", async () => {
    const { lead, stop } = pair();
    try {
      const res = await get(lead, "not-a-verb", LEAD_SESSION);
      expect(res.status).toBe(404);
      expect(res.body.code).toBeUndefined();
    } finally {
      stop();
    }
  });
});

describe("runaway caps reach the tool caller", () => {
  test("the hourly cap refuses the next assign with 429 and the guard's own reason", async () => {
    const { lead, peer, stop } = pair();
    try {
      for (let i = 0; i < MAX_TASKS_PER_HOUR; i += 1) {
        const res = await post(lead, "tasks", LEAD_SESSION, {
          peer: PEER_SESSION, summary: `task ${i}`, instruction: "work",
        });
        expect(res.status).toBe(200);
      }
      const refused = await post(lead, "tasks", LEAD_SESSION, {
        peer: PEER_SESSION, summary: "one too many", instruction: "work",
      });
      expect(refused.status).toBe(429);
      expect(refused.body.code).toBe("TASK_RATE");
      // The reason is the guard's own words, relayed rather than re-worded.
      expect(typeof refused.body.error).toBe("string");
      expect(refused.body.error.length).toBeGreaterThan(0);

      // A refusal spends nothing: the budget still reports the same exhaustion
      // rather than having counted the refused attempt.
      const view = await get(lead, "session", LEAD_SESSION);
      expect(view.body.budget.hourlyRemaining).toBe(0);
      expect(peer.outbound).toBeDefined();
    } finally {
      stop();
    }
  });
});

// A lead whose own machine has no bus address was refused NOT_MEMBER, which
// flatly contradicts /role saying `lead:true` and sends the reader hunting for a
// membership bug that isn't there. The two nulls are different answers and the
// caller has to be able to tell them apart.
describe("a self with no address is not a self with no membership", () => {
  function coordinatorWith(addressable?: () => boolean): SessionBusCoordinator {
    return new SessionBusCoordinator({
      abDir: tempDir("antgrid-bus-selfnull-"),
      projectId: "proj",
      // Null for the same reason in both cases; only `addressable` says which.
      self: () => null,
      send: () => true,
      ...(addressable ? { addressable } : {}),
    });
  }

  const assign = (c: SessionBusCoordinator) =>
    c.assign({ sessionId: LEAD_SESSION, peer: "p", instruction: "go" } as never) as {
      code?: string;
    };

  test("an unaddressable machine is AGENT_NOT_READY", () => {
    expect(assign(coordinatorWith(() => false)).code).toBe("AGENT_NOT_READY");
  });

  test("an addressable machine keeps NOT_MEMBER", () => {
    expect(assign(coordinatorWith(() => true)).code).toBe("NOT_MEMBER");
  });

  // A core that never wires it — every test harness and any older build — must
  // keep the answer it has always given.
  test("an unwired addressable keeps NOT_MEMBER", () => {
    expect(assign(coordinatorWith()).code).toBe("NOT_MEMBER");
  });
});

// The route a frame takes is chosen from the sender's ROLE in the context, and
// for an unsequenced note there is no task record to read it off. Getting that
// default wrong is silent in both directions: a misrouted finding is accepted by
// whatever it reaches and reported sent.
describe("the role behind a taskless send", () => {
  test("a peer's finding before any task is routed as a peer", async () => {
    const peer = machine({
      abDir: tempDir("bus-role-peer-"),
      machineId: "m2",
      projectId: "p2",
      sessionIds: [PEER_SESSION],
    });
    try {
      const sent = await post(peer, "findings", PEER_SESSION, {
        summary: "the codec is little-endian",
        text: "checked against the fixtures",
      });
      expect(sent.status).toBe(200);
      // The lead's session id, as a peer's context always is — and "peer", which
      // is what sends it to the carrier rather than to this machine's own app.
      expect(peer.routes).toEqual([{ contextId: LEAD_SESSION, role: "peer" }]);
    } finally {
      peer.stop();
    }
  });

  test("a lead's own context is still led", async () => {
    const lead = machine({
      abDir: tempDir("bus-role-lead-"),
      machineId: "m1",
      projectId: "p1",
      sessionIds: [LEAD_SESSION],
    });
    try {
      await post(lead, "tasks", LEAD_SESSION, {
        peer: PEER_SESSION,
        summary: "wire the codec",
        instruction: "do the thing",
      });
      expect(lead.routes).toEqual([{ contextId: LEAD_SESSION, role: "lead" }]);
    } finally {
      lead.stop();
    }
  });
});

// Nothing here reports delivery: the carrier taking a frame is not the peer
// machine receiving it, and a lead told "delivered" on that word cannot tell
// work the peer is already reading from work no machine has ever acknowledged.
// The ack is the only evidence, so the task view carries it and the assignment
// itself claims nothing.
describe("the two machines may know the session by different projects", () => {
  // A managed worktree opened in its own right hashes to a project id of its
  // own, so the id a peer recorded for its lead need not be the one the lead
  // bridge holds. Matching on it refused every frame in silence: the assign
  // reached the peer, and the ack never got home.
  test("an ack addressed by the wrong project still lands", async () => {
    const lead = machine({
      abDir: tempDir("bus-drift-lead-"),
      machineId: "m1",
      projectId: "p1",
      sessionIds: [LEAD_SESSION],
    });
    const peer = machine({
      abDir: tempDir("bus-drift-peer-"),
      machineId: "m2",
      projectId: "p2",
      sessionIds: [PEER_SESSION],
    });
    try {
      await post(lead, "tasks", LEAD_SESSION, {
        peer: PEER_SESSION,
        summary: "wire the codec",
        instruction: "do the thing",
      });

      // Everything the peer sends home is addressed by what IT recorded at join
      // time, which is the id under test.
      for (const frame of lead.outbound.splice(0)) peer.coordinator.handleInbound(frame);
      for (const frame of peer.outbound.splice(0)) {
        const drifted = { ...frame, to: { ...(frame as any).to, projectId: "p1-worktree" } };
        expect(lead.coordinator.handleInbound(drifted as AbMessage)).toBe("applied");
      }

      const tasks = await get(lead, "tasks", LEAD_SESSION);
      expect(tasks.body.tasks[0]).toMatchObject({ reachedPeer: true, unacked: 0 });
    } finally {
      peer.stop();
      lead.stop();
    }
  });

  test("a frame for a session this bridge does not hold is still dropped", () => {
    const lead = machine({
      abDir: tempDir("bus-drift-unknown-"),
      machineId: "m1",
      projectId: "p1",
      sessionIds: [LEAD_SESSION],
    });
    try {
      // Relaxing the project id must not relax the session id with it: that one
      // is the whole of what proves the sender means a session living here.
      const stray = {
        type: "session-bus:ack",
        contextId: "ctx-1",
        taskId: "t-1",
        seq: 1,
        from: { machineId: "m2", projectId: "p2", sessionId: PEER_SESSION },
        to: { machineId: "m1", projectId: "p1", sessionId: "not-a-session-here" },
      };
      expect(lead.coordinator.handleInbound(stray as unknown as AbMessage)).toBe("dropped");
    } finally {
      lead.stop();
    }
  });
});

describe("an assignment is queued, and only an ack says it arrived", () => {
  test("an assignment reports no delivery, and the task says nothing has acked it", async () => {
    const lead = machine({
      abDir: tempDir("bus-deliver-ok-"),
      machineId: "m1",
      projectId: "p1",
      sessionIds: [LEAD_SESSION],
    });
    try {
      const assigned = await post(lead, "tasks", LEAD_SESSION, {
        peer: PEER_SESSION,
        summary: "wire the codec",
        instruction: "do the thing",
      });
      expect(assigned.body).toMatchObject({ ok: true });
      expect(assigned.body.delivered).toBeUndefined();

      const tasks = await get(lead, "tasks", LEAD_SESSION);
      expect(tasks.body.tasks[0]).toMatchObject({
        reachedPeer: false,
        unacked: 1,
      });
    } finally {
      lead.stop();
    }
  });

  test("a frame that never left is not distinguished, and the task is still made", async () => {
    const lead = machine({
      abDir: tempDir("bus-deliver-held-"),
      machineId: "m1",
      projectId: "p1",
      sessionIds: [LEAD_SESSION],
      deliverable: false,
    });
    try {
      const assigned = await post(lead, "tasks", LEAD_SESSION, {
        peer: PEER_SESSION,
        summary: "wire the codec",
        instruction: "do the thing",
      });
      expect(assigned.body).toMatchObject({ ok: true });
      expect(typeof assigned.body.taskId).toBe("string");
      // Still listed, because the outbox will carry it when a carrier appears.
      const tasks = await get(lead, "tasks", LEAD_SESSION);
      expect(tasks.body.tasks).toHaveLength(1);
      expect(tasks.body.tasks[0]).toMatchObject({
        reachedPeer: false,
        unacked: 1,
      });
    } finally {
      lead.stop();
    }
  });
});
