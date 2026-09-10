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
import { SessionDirectory } from "../src/session-bus/directory";
import { SessionBusCoordinator } from "../src/session-bus/coordinator";
import type { AbConfig } from "../src/config";
import type { AbMessage } from "../src/protocol";

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

/** One machine's half of the pair: its own coordinator, the API over it, and a
 *  loopback API server. Nothing here stands up a relay — a frame is handed
 *  straight to the other coordinator, which is the carrier's job, and the routes
 *  cannot tell the difference. */
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
  if (terminalId === LEAD_SESSION) return { sessionId: LEAD_SESSION, sessionName: "lead session" };
  if (terminalId === PEER_SESSION) return { sessionId: PEER_SESSION, sessionName: "peer session" };
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
  /** Omitted is a bus with no host above it, which is what most of this file
   *  exercises; supplied is the machine-level directory a real host injects. */
  directory?: SessionDirectory;
}): Machine {
  const outbound: AbMessage[] = [];
  const routes: { contextId: string; role: string }[] = [];
  const coordinator = new SessionBusCoordinator({
    abDir: opts.abDir,
    projectIdFor: () => opts.projectId,
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
    ...(opts.directory ? { directory: opts.directory } : {}),
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

describe("session-bus routes", () => {
  test("a body carrying a bridge-owned field is refused 400, not silently ignored", async () => {
    const { peer, stop } = pair();
    try {
      const res = await post(peer, "artifacts", PEER_SESSION, {
        name: "diff.txt",
        summary: "the codec diff",
        content: "0123456789",
        // Resolved by the bridge, never named by the caller (spec 3.4).
        artifactId: "a-forged",
      });
      expect(res.status).toBe(400);
      expect(res.body.error).toBe("Invalid body");
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

// A session this bridge holds but cannot stamp an address for was refused
// NOT_MEMBER, which sends the reader hunting for a session that is sitting right
// there. The two nulls are different answers and the caller has to be able to
// tell them apart.
describe("a self with no address is not a session this bridge does not hold", () => {
  function coordinatorWith(addressable?: () => boolean): SessionBusCoordinator {
    return new SessionBusCoordinator({
      abDir: tempDir("antgrid-bus-selfnull-"),
      projectIdFor: () => "proj",
      // Null for the same reason in both cases; only `addressable` says which.
      self: () => null,
      send: () => true,
      ...(addressable ? { addressable } : {}),
    });
  }

  const post = (c: SessionBusCoordinator) =>
    c.message({
      sessionId: LEAD_SESSION,
      taskId: null,
      to: { machineId: "m2", projectId: "p2", sessionId: PEER_SESSION },
      summary: "go",
      parts: [{ kind: "text", text: "go" }],
    }) as { code?: string };

  test("an unaddressable machine is AGENT_NOT_READY", () => {
    expect(post(coordinatorWith(() => false)).code).toBe("AGENT_NOT_READY");
  });

  test("an addressable machine keeps NOT_MEMBER", () => {
    expect(post(coordinatorWith(() => true)).code).toBe("NOT_MEMBER");
  });

  // A core that never wires it — every test harness and any older build — must
  // keep the answer it has always given.
  test("an unwired addressable keeps NOT_MEMBER", () => {
    expect(post(coordinatorWith()).code).toBe("NOT_MEMBER");
  });
});

// A managed worktree opened in its own right hashes to a project id of its own,
// so the id one bridge recorded for the other need not be the one that bridge
// holds. Relaxing that match must not relax the session id with it.
describe("the two machines may know the session by different projects", () => {
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

describe("GET /session-bus/sessions", () => {
  /** A directory over one repo key holding `sessions`, all in `projectId`. */
  function directoryOf(projectId: string, key: string | null, sessions: { id: string; name: string }[]) {
    return new SessionDirectory({
      repoKeys: {
        keyFor: (id) => (id === projectId ? key : null),
        probed: () => true,
        projectsSharing: (k) => (k !== null && k === key ? [projectId] : []),
      },
      sessionIndex: {
        *sessionsIn(id) {
          if (id !== projectId) return;
          for (const s of sessions) yield { entry: { ...s, running: true, archived: false, deleting: false, lastUsedAt: 1, tool: "claude-code" } as any };
        },
      },
      projectPath: () => "/repo",
      machineId: () => "m1",
      readBranch: async () => "main",
    });
  }

  test("a caller that names no session is refused, like every other route", async () => {
    const { peer, stop } = pair();
    try {
      const res = await get(peer, "sessions");
      expect(res.status).toBe(403);
      expect(res.body.code).toBe("NOT_MEMBER");
    } finally { stop(); }
  });

  test("a bus with no host refuses rather than answering with its own project", async () => {
    // The dangerous failure is a plausible one: narrowing to this core's
    // sessions would look like a correct empty directory and would silently
    // undo the reach the machine-level bus exists to give.
    const { peer, stop } = pair();
    try {
      const res = await get(peer, "sessions", PEER_SESSION);
      expect(res.status).toBe(503);
      expect(res.body.code).toBe("AGENT_NOT_READY");
    } finally { stop(); }
  });

  test("a project with no git remote is refused 409, not served an empty list", async () => {
    const m = machine({
      abDir: tempDir("bus-keyless-"),
      machineId: "m1",
      projectId: "p1",
      sessionIds: [PEER_SESSION],
      directory: directoryOf("p1", null, [{ id: "other", name: "Other" }]),
    });
    try {
      const res = await get(m, "sessions", PEER_SESSION);
      expect(res.status).toBe(409);
      expect(res.body.code).toBe("NOT_ADDRESSABLE");
      expect(res.body.error).toContain("git remote");
    } finally { m.stop(); }
  });

  test("the directory answers a judgeable row and excludes the caller", async () => {
    const m = machine({
      abDir: tempDir("bus-dir-"),
      machineId: "m1",
      projectId: "p1",
      sessionIds: [PEER_SESSION],
      directory: directoryOf("p1", "github.com/owner/repo", [
        { id: PEER_SESSION, name: "the caller" },
        { id: "other-1", name: "Refresh expired OAuth tokens" },
      ]),
    });
    try {
      const res = await get(m, "sessions", PEER_SESSION);
      expect(res.status).toBe(200);
      expect(res.body.truncated).toBe(0);
      expect(res.body.sessions).toHaveLength(1);
      // 5.5's whole point: the row names the work, not the directory it is in.
      expect(res.body.sessions[0]).toMatchObject({
        sessionId: "other-1",
        title: "Refresh expired OAuth tokens",
        branch: "main",
        canReply: true,
      });
    } finally { m.stop(); }
  });
});

