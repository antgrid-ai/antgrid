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
import { SessionDirectory, type SessionDirectoryRow } from "../src/session-bus/directory";
import { SessionBusCoordinator, type SessionBusEvent } from "../src/session-bus/coordinator";
import { pairKey, upsertPairBudget, type PairBudgetState } from "../src/session-bus/pair-budget";
import { MAX_NOTIFIES_PER_PAIR_HOUR, NO_PROGRESS_EXCHANGES } from "../src/session-bus/constants";
import { busDbPath } from "../src/session-bus/bus-db";
import { Database } from "bun:sqlite";
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
  abDir: string;
  port: number;
  stop(): void;
  outbound: AbMessage[];
  /** The routing decision behind each frame this machine tried to send. The
   *  frame itself does not carry it — `role` chooses between the carrier and the
   *  loopback owner, which is a difference only the sender can see. */
  routes: { contextId: string; role: string }[];
  /** The per-pair budget this machine's coordinator answers to, when one was
   *  wired. Exposed so a case can seed a halt: §7.4 makes a halt durable state
   *  a human clears, which is not something a send can set up for itself. */
  budget: BudgetStore | null;
  /** Every bus event this machine's coordinator handed its project's consumer.
   *  That consumer is `deliverBusEvent` in production, which renders the line
   *  and queues it for the next turn boundary — so an event here is the nearest
   *  witness a route-level test has that an arrival became a line rather than
   *  mail. */
  busEvents: SessionBusEvent[];
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
  /** Off refuses every off-machine leg at the verb layer (§6.3). */
  remoteAccessEnabled?: boolean;
  /** The host's per-pair ceilings (§7.4). Absent is an unbudgeted bus, which is
   *  what a core with no host above it is. */
  pairBudget?: BudgetStore;
  /** The other machine's coordinator, handed every frame this one sends — the
   *  whole of what a carrier does. Absent records the frame and delivers it
   *  nowhere, which is the shape the artifact cases rely on. */
  link?: () => SessionBusCoordinator | null;
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
      // Handed on inside this very call, exactly as a local delivery and a live
      // carrier both are: the coordinator writes its log before it sends for
      // that reason, and a receipt arriving back here has to find the entry.
      opts.link?.()?.handleInbound(frame);
      return true;
    },
    ...(opts.pairBudget ? { pairBudget: opts.pairBudget } : {}),
  });
  const busEvents: SessionBusEvent[] = [];
  coordinator.setListener(opts.projectId, (event) => busEvents.push(event));
  const api = createSessionBusApi({
    coordinator,
    abDir: opts.abDir,
    projectId: opts.projectId,
    projectName: "proj",
    machineId: () => opts.machineId,
    membership: membershipOf,
    carrierPresent: () => opts.carrierPresent !== false,
    remoteAccessEnabled: () => opts.remoteAccessEnabled !== false,
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
    abDir: opts.abDir,
    port: server.port,
    outbound,
    routes,
    busEvents,
    budget: opts.pairBudget ?? null,
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

/** The pair-budget store the HOST owns in production — `pair-budget.ts` is pure
 *  and holds none, and the coordinator only reads and writes through this. In
 *  memory here because a test process is one run; what has to be faithful is
 *  the shape, one record list per session keyed by pair, so a halt tripped
 *  through a route reads back on the next call exactly as the host's would. */
interface BudgetStore {
  recordsFor(sessionId: string): readonly PairBudgetState[];
  write(sessionId: string, next: PairBudgetState): void;
}

function budgetStore(): BudgetStore {
  const rows = new Map<string, PairBudgetState[]>();
  return {
    recordsFor: (sessionId) => rows.get(sessionId) ?? [],
    write(sessionId, next) {
      rows.set(sessionId, upsertPairBudget(rows.get(sessionId) ?? [], next));
    },
  };
}

const REPO_KEY = "github.com/owner/repo";

/** A peer's row as this machine's mirror holds it. Every address the linked
 *  pair below sends to is off-machine, so this — not the session index — is
 *  what `rowFor` resolves, and `activity` is the peer's own report rather than
 *  anything this machine could re-derive. */
function mirroredRow(machineId: string, projectId: string, sessionId: string): SessionDirectoryRow {
  return {
    machineId,
    projectId,
    sessionId,
    title: "Refresh expired OAuth tokens",
    branch: "main",
    activity: "running",
    lastActiveAt: 1,
    canReply: true,
  };
}

/** A directory whose only peers are mirrored ones. `rows` is handed back by
 *  reference on every read, so a case that needs the target to stop writes to
 *  the row it was given — which is what the peer's own next push would do. */
function mirrorDirectory(machineId: string, projectId: string, rows: SessionDirectoryRow[]): SessionDirectory {
  return new SessionDirectory({
    repoKeys: {
      keyFor: (id) => (id === projectId ? REPO_KEY : null),
      probed: () => true,
      projectsSharing: (key) => (key === REPO_KEY ? [projectId] : []),
    },
    sessionIndex: { *sessionsIn() {} },
    projectPath: () => "/repo",
    machineId: () => machineId,
    readBranch: async () => "main",
    remoteDirectory: {
      view: (_key, _selfMachineId, now) => ({
        rows,
        truncated: 0,
        machines: [],
        staleMachines: 0,
        notConnected: 0,
        lastPushAt: now,
      }),
    },
  });
}

const TO_PEER = { machineId: "m2", projectId: "p2", sessionId: PEER_SESSION };
const TO_LEAD = { machineId: "m1", projectId: "p1", sessionId: LEAD_SESSION };

/** The pair with the link closed: each machine's carrier hands the frame
 *  straight to the other's coordinator, each holds the host's pair budget, and
 *  each directory mirrors the other's one session. Everything a send consults
 *  is the real thing — only the wire between the two is short — so a refusal
 *  here is the one an agent would read, and a success went out and came back
 *  acked. {@link pair} stays as it was: no directory, no link, no budget, which
 *  is what the artifact and `sessions` cases above are about. */
function linkedPair(opts: { carrier?: boolean; remoteAccess?: boolean } = {}): {
  lead: Machine;
  peer: Machine;
  peerRow: SessionDirectoryRow;
  leadRow: SessionDirectoryRow;
  /** The rows the LEAD's mirror holds, by reference. Emptying it is how a case
   *  reaches the state a real machine is in whenever its remote access is off or
   *  its desktop app is gone: both are what keep a mirror empty, so a seeded row
   *  beside either of them exists only for the seconds after the flip. */
  leadMirror: SessionDirectoryRow[];
  stop(): void;
} {
  const peerRow = mirroredRow("m2", "p2", PEER_SESSION);
  const leadRow = mirroredRow("m1", "p1", LEAD_SESSION);
  const leadMirror = [peerRow];
  let peerMachine: Machine | undefined;
  const lead = machine({
    abDir: tempDir("bus-lead-"),
    machineId: "m1",
    projectId: "p1",
    sessionIds: [LEAD_SESSION],
    directory: mirrorDirectory("m1", "p1", leadMirror),
    pairBudget: budgetStore(),
    carrierPresent: opts.carrier !== false,
    remoteAccessEnabled: opts.remoteAccess !== false,
    link: () => peerMachine?.coordinator ?? null,
  });
  const peer = machine({
    abDir: tempDir("bus-peer-"),
    machineId: "m2",
    projectId: "p2",
    sessionIds: [PEER_SESSION],
    directory: mirrorDirectory("m2", "p2", [leadRow]),
    pairBudget: budgetStore(),
    link: () => lead.coordinator,
  });
  peerMachine = peer;
  return { lead, peer, peerRow, leadRow, leadMirror, stop: () => { lead.stop(); peer.stop(); } };
}

/** The pair key `pair-budget.ts` files a lead↔peer record under. Machine and
 *  session only: the project id is a label, and the two machines can hold
 *  different ones for the same session. */
function leadPeerKey(): string {
  return pairKey({ machineId: "m1", sessionId: LEAD_SESSION }, { machineId: "m2", sessionId: PEER_SESSION });
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

  test("an artifact whose handle could not be written is refused, never reported as published", async () => {
    // The bytes land before the handle on purpose, so the failure this covers
    // leaves them unreferenced rather than leaving an id that resolves to
    // nothing. What must not happen is the agent being handed that id anyway:
    // it would carry it into a message the other machine then cannot fetch.
    const { peer, stop } = pair();
    const first = await post(peer, "artifacts", PEER_SESSION, { name: "a.txt", summary: "s", content: "aaa" });
    expect(first.status).toBe(200);

    const blocker = new Database(busDbPath(peer.abDir));
    try {
      blocker.exec("BEGIN EXCLUSIVE");
      const res = await post(peer, "artifacts", PEER_SESSION, {
        name: "diff.txt", summary: "the codec diff", content: "0123456789",
      });
      expect(res.status).toBe(503);
      expect(res.body.code).toBe("STORE_UNAVAILABLE");
    } finally {
      blocker.exec("ROLLBACK");
      blocker.close();
    }
    try {
      const list = await get(peer, "artifacts", PEER_SESSION);
      expect(list.body.artifacts.map((a: { name: string }) => a.name)).toEqual(["a.txt"]);
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
      verb: "post",
      threadId: null,
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
        messageId: "msg-1",
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

  test("a directory that covers only this machine says so instead of narrowing silently", async () => {
    // `directoryOf` wires no remote deps at all — the same shape a bare core
    // has today. The reach must name that rather than omit the field, or an
    // agent reading `sessions` alone cannot tell "nobody else on this repo"
    // from "nobody else THIS MACHINE COULD ASK".
    const m = machine({
      abDir: tempDir("bus-reach-"),
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
      expect(res.body.reach).toEqual({ scope: "machine", why: "no-carrier" });
    } finally { m.stop(); }
  });
});

// Every refusal a send can answer with, and every success, driven over the real
// loopback route: the tool layer above these routes decides nothing, so a
// decision that is not provable here is not enforced anywhere.
describe("the send verbs over the loopback route", () => {
  test("a send body carrying a bridge-owned field is refused 400, not silently ignored", async () => {
    const { lead, stop } = linkedPair();
    try {
      // The coordinator mints the message id (§4.3). A caller able to author one
      // could author the id of a message it never sent.
      const forgedId = await post(lead, "post", LEAD_SESSION, {
        to: TO_PEER, summary: "the codec diff", text: "look", messageId: "m-forged",
      });
      expect(forgedId.status).toBe(400);
      expect(forgedId.body.error).toBe("Invalid body");
      // A schema refusal carries no bus code, which is what tells the two kinds
      // of 4xx apart on the wire: this one never reached a bus decision.
      expect(forgedId.body.code).toBeUndefined();

      // The sender is resolved from the terminal id and nothing else (§4.3), so
      // a `from` in the body is an agent naming itself.
      const forgedFrom = await post(lead, "post", LEAD_SESSION, {
        to: TO_PEER, summary: "the codec diff", text: "look",
        from: { machineId: "m2", projectId: "p2", sessionId: PEER_SESSION },
      });
      expect(forgedFrom.status).toBe(400);
      expect(forgedFrom.body.error).toBe("Invalid body");
      expect(lead.outbound).toHaveLength(0);
    } finally { stop(); }
  });

  test("a send with neither text nor an artifact is refused 400 rather than crossing empty", async () => {
    const { lead, stop } = linkedPair();
    try {
      const res = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "nothing to say" });
      expect(res.status).toBe(400);
      expect(res.body.error).toBe("Invalid body");
      expect(lead.outbound).toHaveLength(0);
    } finally { stop(); }
  });

  test("a target the directory does not offer is UNKNOWN_PEER, and no send is attempted", async () => {
    const { lead, stop } = linkedPair();
    try {
      // The control: this machine can deliver, so the refusal below is the
      // DIRECTORY's answer and not a transport failure wearing its name.
      const known = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "s", text: "t" });
      expect(known.status).toBe(200);
      const attempted = lead.routes.length;

      const res = await post(lead, "post", LEAD_SESSION, {
        to: { machineId: "m2", projectId: "p2", sessionId: "no-such-session" },
        summary: "s", text: "t",
      });
      expect(res.status).toBe(404);
      expect(res.body.code).toBe("UNKNOWN_PEER");
      expect(lead.routes).toHaveLength(attempted);
    } finally { stop(); }
  });

  test("a halted pair is refused NO_PROGRESS on post, not only on notify", async () => {
    const { lead, peerRow, stop } = linkedPair();
    try {
      // Seeded rather than tripped, because a halt survives a restart and is
      // cleared only by a human (§7.4): this case is about a halt already
      // standing refusing EVERY verb. Reaching one through the routes at all is
      // the next case, and neither proves the other.
      lead.budget!.write(LEAD_SESSION, {
        pairKey: leadPeerKey(), notifiesAtMs: [], exchangesSinceProgress: NO_PROGRESS_EXCHANGES, haltedAt: 1,
      });

      const posted = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "s", text: "t" });
      expect(posted.status).toBe(429);
      expect(posted.body.code).toBe("NO_PROGRESS");

      const notified = await post(lead, "notify", LEAD_SESSION, { to: TO_PEER, summary: "s", text: "t" });
      expect(notified.status).toBe(429);
      expect(notified.body.code).toBe("NO_PROGRESS");

      // Ordering, not merely presence. A halted pair aimed at a stopped session
      // must be told the thing a human can act on: "that session is not
      // running" sends it to wait for something that could not free it.
      peerRow.activity = "stopped";
      const stopped = await post(lead, "notify", LEAD_SESSION, { to: TO_PEER, summary: "s", text: "t" });
      expect(stopped.status).toBe(429);
      expect(stopped.body.code).toBe("NO_PROGRESS");
      expect(lead.outbound).toHaveLength(0);
    } finally { stop(); }
  });

  test("a notify at a session that is not running is NOT_RUNNING and names the verb that reaches", async () => {
    const { lead, peerRow, stop } = linkedPair();
    try {
      peerRow.activity = "stopped";
      const res = await post(lead, "notify", LEAD_SESSION, { to: TO_PEER, summary: "s", text: "t" });
      expect(res.status).toBe(409);
      expect(res.body.code).toBe("NOT_RUNNING");
      // §7.3: refuse, and name the verb that reaches — as the tool it is called
      // by, since an agent reads this refusal and then calls something.
      expect(res.body.error).toContain("antgrid_post");
      expect(lead.outbound).toHaveLength(0);

      // And the verb it names does reach: a post lands in the mailbox whether
      // or not anything is running to read it yet.
      const posted = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "s", text: "t" });
      expect(posted.status).toBe(200);
    } finally { stop(); }
  });

  test("an over-ceiling notify is NOTIFY_RATE while a post to the same pair still lands", async () => {
    const { lead, peer, stop } = linkedPair();
    try {
      const now = Date.now();
      lead.budget!.write(LEAD_SESSION, {
        pairKey: leadPeerKey(),
        notifiesAtMs: Array.from({ length: MAX_NOTIFIES_PER_PAIR_HOUR }, () => now),
        exchangesSinceProgress: 0,
        haltedAt: null,
      });

      const notified = await post(lead, "notify", LEAD_SESSION, { to: TO_PEER, summary: "s", text: "t" });
      expect(notified.status).toBe(429);
      expect(notified.body.code).toBe("NOTIFY_RATE");
      // Names the verb still open to it (§7.4), which is the whole reason this
      // is a separate code from the halt: one is waited out, the other is not.
      expect(notified.body.error).toContain("post");

      // At the same moment, on the same pair: post is unbudgeted, so a spent
      // notify ceiling must not read as the pair being silenced.
      const posted = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "s", text: "t" });
      expect(posted.status).toBe(200);
      expect(posted.body.sent).toBe(true);
      const inbox = await get(peer, "inbox", PEER_SESSION);
      expect(inbox.body.posts).toHaveLength(1);
    } finally { stop(); }
  });

  test("an off-machine target with remote access off is REMOTE_ACCESS_OFF while a row is still mirrored", async () => {
    const { lead, stop } = linkedPair({ remoteAccess: false });
    try {
      const res = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "s", text: "t" });
      expect(res.status).toBe(403);
      expect(res.body.code).toBe("REMOTE_ACCESS_OFF");
      // §6.3's send half is refused where the agent can read it, never queued
      // behind a switch only a human at this machine can flip.
      expect(lead.outbound).toHaveLength(0);
    } finally { stop(); }
  });

  test("an off-machine target with no carrier is PEER_UNREACHABLE while a row is still mirrored", async () => {
    const { lead, stop } = linkedPair({ carrier: false });
    try {
      const res = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "s", text: "t" });
      expect(res.status).toBe(503);
      expect(res.body.code).toBe("PEER_UNREACHABLE");
      // The failure this rung exists to prevent: `{ok:true, held:true}` is what
      // every surface renders as "on its way", with nothing carrying it.
      expect(res.body.ok).toBeUndefined();
      expect(res.body.held).toBeUndefined();
      expect(lead.outbound).toHaveLength(0);
    } finally { stop(); }
  });

  test("every send verb answers with a thread id, and the minted one is what a reply names", async () => {
    const { lead, peer, stop } = linkedPair();
    try {
      const posted = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "asking", text: "one" });
      expect(posted.status).toBe(200);
      expect(posted.body).toMatchObject({ ok: true, sent: true, opensThread: true });
      expect(typeof posted.body.threadId).toBe("string");

      const notified = await post(lead, "notify", LEAD_SESSION, { to: TO_PEER, summary: "urgent", text: "two" });
      expect(notified.status).toBe(200);
      expect(typeof notified.body.threadId).toBe("string");
      expect(notified.body.threadId).not.toBe(posted.body.threadId);

      // §4.3 makes the id bridge-owned, so an agent never told it cannot answer
      // on the thread it was just handed.
      const replied = await post(peer, "reply", PEER_SESSION, {
        threadId: posted.body.threadId, summary: "answering", text: "three",
      });
      expect(replied.status).toBe(200);
      expect(replied.body.threadId).toBe(posted.body.threadId);
      expect(replied.body.opensThread).toBe(false);
    } finally { stop(); }
  });

  test("a terminal that names no session is NOT_MEMBER on every one of the five routes", async () => {
    const { lead, stop } = linkedPair();
    const SERVICE_PTY = "service-pty";
    try {
      for (const verb of ["post", "notify"]) {
        const res = await post(lead, verb, SERVICE_PTY, { to: TO_PEER, summary: "s", text: "t" });
        expect(res.status).toBe(403);
        expect(res.body.code).toBe("NOT_MEMBER");
      }
      const replied = await post(lead, "reply", SERVICE_PTY, { threadId: "t-1", summary: "s", text: "t" });
      expect(replied.status).toBe(403);
      expect(replied.body.code).toBe("NOT_MEMBER");

      for (const path of ["inbox", "thread?threadId=t-1"]) {
        const res = await get(lead, path, SERVICE_PTY);
        expect(res.status).toBe(403);
        expect(res.body.code).toBe("NOT_MEMBER");
      }
      expect(lead.outbound).toHaveLength(0);
    } finally { stop(); }
  });
});

// §7.4's counter has to be fed by the send path itself. Hand-built budget state
// proves a ceiling refuses; it cannot prove anything ever reaches the ceiling,
// which is the failure that reads as enforced and bounds nothing.
describe("the no-progress halt as the verbs actually charge it", () => {
  /** A thread the PEER opened, so none of the sends under test is the opener:
   *  opening one is progress and would reset the very counter being watched. */
  async function peerOpenedThread(lead: Machine, peer: Machine): Promise<string> {
    const opened = await post(peer, "post", PEER_SESSION, { to: TO_LEAD, summary: "opening", text: "one" });
    expect(opened.status).toBe(200);
    const read = await get(lead, "inbox", LEAD_SESSION);
    expect(read.body.posts).toHaveLength(1);
    return opened.body.threadId as string;
  }

  test("the halt trips through the route, on the send after the ceiling", async () => {
    const { lead, peer, stop } = linkedPair();
    try {
      const threadId = await peerOpenedThread(lead, peer);
      for (let i = 0; i < NO_PROGRESS_EXCHANGES; i += 1) {
        const res = await post(lead, "post", LEAD_SESSION, {
          to: TO_PEER, threadId, summary: "still going", text: `round ${i}`,
        });
        expect(res.status).toBe(200);
      }
      const halted = await post(lead, "post", LEAD_SESSION, {
        to: TO_PEER, threadId, summary: "one too many", text: "round n",
      });
      expect(halted.status).toBe(429);
      expect(halted.body.code).toBe("NO_PROGRESS");
      // §7.4 puts the remedy in the text, because time is not one: only a human
      // working in either session lifts it.
      expect(halted.body.error).toContain("human");
    } finally { stop(); }
  });

  test("a send carrying an artifact does not trip the halt at that count", async () => {
    const { lead, peer, stop } = linkedPair();
    try {
      const published = await post(lead, "artifacts", LEAD_SESSION, {
        name: "diff.txt", summary: "the codec diff", content: "0123456789",
      });
      expect(published.status).toBe(200);
      const artifactId = published.body.artifact.artifactId as string;
      const threadId = await peerOpenedThread(lead, peer);

      // One past the ceiling: an artifact is half of §7.4's own definition of
      // progress, so the counter resets on every one of these.
      for (let i = 0; i <= NO_PROGRESS_EXCHANGES; i += 1) {
        const res = await post(lead, "post", LEAD_SESSION, {
          to: TO_PEER, threadId, summary: "with evidence", text: `round ${i}`, artifactIds: [artifactId],
        });
        expect(res.status).toBe(200);
      }
    } finally { stop(); }
  });

  test("a send that opens a new thread does not trip the halt at that count", async () => {
    const { lead, stop } = linkedPair();
    try {
      for (let i = 0; i <= NO_PROGRESS_EXCHANGES; i += 1) {
        const res = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "a new one", text: `round ${i}` });
        expect(res.status).toBe(200);
        expect(res.body.opensThread).toBe(true);
      }
    } finally { stop(); }
  });
});

// The reads nothing else in the tree exercises, plus the routing fact none of
// them type-checks: which exchange a reply goes back out on.
describe("threads, replies and the mailbox over the loopback route", () => {
  test("a reply rides the contextId the peer opened the thread on", async () => {
    const { lead, peer, stop } = linkedPair();
    try {
      // A NOTIFY on purpose: it leaves the lead no mailbox row at all, so the
      // thread store is the only thing on this machine that still remembers
      // which exchange the answer belongs to.
      const notified = await post(peer, "notify", PEER_SESSION, {
        to: TO_LEAD, summary: "look at this", text: "one",
      });
      expect(notified.status).toBe(200);
      const threadId = notified.body.threadId as string;

      const before = lead.routes.length;
      const replied = await post(lead, "reply", LEAD_SESSION, { threadId, summary: "answering", text: "two" });
      expect(replied.status).toBe(200);

      // The misroute nothing type-checks: the replier's own session id as the
      // context reads as "lead", which hands the answer to THIS machine's own
      // desktop app — which accepts it and reports it sent.
      expect(lead.routes.slice(before)).toEqual([{ contextId: PEER_SESSION, role: "peer" }]);
      const frame = lead.outbound.at(-1) as Extract<AbMessage, { type: "session-bus:notify" }>;
      expect(frame.contextId).toBe(PEER_SESSION);
      expect(frame.contextId).not.toBe(LEAD_SESSION);
    } finally { stop(); }
  });

  test("a reply that names no address is aimed by the thread row", async () => {
    const { lead, peer, stop } = linkedPair();
    try {
      const opened = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "asking", text: "one" });
      expect(opened.status).toBe(200);

      const before = peer.outbound.length;
      const replied = await post(peer, "reply", PEER_SESSION, {
        threadId: opened.body.threadId, summary: "answering", text: "two",
      });
      expect(replied.status).toBe(200);
      const sent = peer.outbound
        .slice(before)
        .find((f): f is Extract<AbMessage, { type: "session-bus:notify" }> => f.type === "session-bus:notify");
      // Never respelled by the agent: an address it was not given is one it
      // would have to guess at.
      expect(sent?.to).toEqual({ machineId: "m1", projectId: "p1", sessionId: LEAD_SESSION });
    } finally { stop(); }
  });

  test("a reply naming a thread that does not exist is refused, not defaulted", async () => {
    const { lead, stop } = linkedPair();
    try {
      const res = await post(lead, "reply", LEAD_SESSION, {
        threadId: "no-such-thread", summary: "answering", text: "two",
      });
      expect(res.status).toBe(404);
      expect(res.body.code).toBe("UNKNOWN_PEER");
      expect(lead.outbound).toHaveLength(0);
    } finally { stop(); }
  });

  test("the inbox hands over unread posts with the drop count, and reading marks them read", async () => {
    const { lead, peer, stop } = linkedPair();
    try {
      const first = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "first", text: "one" });
      expect(first.status).toBe(200);
      const second = await post(lead, "post", LEAD_SESSION, {
        to: TO_PEER, summary: "second", text: "two", unexpected: "the codec is also wrong",
      });
      expect(second.status).toBe(200);

      const read = await get(peer, "inbox", PEER_SESSION);
      expect(read.status).toBe(200);
      expect(read.body.posts.map((p: { summary: string }) => p.summary)).toEqual(["first", "second"]);
      expect(read.body.posts[0].text).toEqual(["one"]);
      expect(read.body.posts[0].from).toMatchObject({ machineId: "m1", sessionId: LEAD_SESSION });
      expect(read.body.posts[1].unexpected).toBe("the codec is also wrong");
      // Zero rides every answer (§7.4): an empty inbox and an emptied one are
      // different facts, and a reader told only the posts cannot tell them apart.
      expect(read.body.dropped).toBe(0);

      const again = await get(peer, "inbox", PEER_SESSION);
      expect(again.status).toBe(200);
      expect(again.body.posts).toEqual([]);
      expect(again.body.dropped).toBe(0);
    } finally { stop(); }
  });

  test("a thread reads both directions, and the receipt lands on the outbound entry", async () => {
    const { lead, peer, stop } = linkedPair();
    try {
      const opened = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "asking", text: "one" });
      expect(opened.status).toBe(200);
      const threadId = opened.body.threadId as string;
      const replied = await post(peer, "reply", PEER_SESSION, { threadId, summary: "answering", text: "two" });
      expect(replied.status).toBe(200);

      const res = await get(lead, `thread?threadId=${threadId}`, LEAD_SESSION);
      expect(res.status).toBe(200);
      expect(res.body.threadId).toBe(threadId);
      expect(res.body.contextId).toBe(LEAD_SESSION);
      expect(res.body.entries.map((e: { direction: string }) => e.direction)).toEqual(["out", "in"]);
      expect(res.body.entries.map((e: { summary: string }) => e.summary)).toEqual(["asking", "answering"]);
      // The other end's receipt is the only honest witness that anything
      // arrived (E6), and this read is the only place the stamp is visible.
      expect(typeof res.body.entries[0].deliveredAt).toBe("number");
      // An inbound entry carries none: this machine sends no receipt to itself.
      expect(res.body.entries[1].deliveredAt).toBeUndefined();
    } finally { stop(); }
  });

  test("an unknown thread id is refused on the read, the same way it is on a send", async () => {
    const { lead, stop } = linkedPair();
    try {
      const res = await get(lead, "thread?threadId=no-such-thread", LEAD_SESSION);
      expect(res.status).toBe(404);
      expect(res.body.code).toBe("UNKNOWN_PEER");
    } finally { stop(); }
  });
});

// The rungs above are proved in a state a machine is in for seconds. These are
// the same decisions in the state it is in the rest of the time: a peer at rest
// between turns, a mirror emptied by the very fact being reported, a session
// index that spans every repository this machine has open, and an agent
// answering an exchange it can name but cannot respell.
describe("the send rungs in the state a machine is usually in", () => {
  /** Every session on THIS machine, one repo key per project. The index a host
   *  injects is machine-wide, so a project on another key enumerates here just
   *  as it would in production — which is the whole reason `rowFor` scopes its
   *  local branch to the caller's own key. */
  function localDirectory(
    machineId: string,
    projects: Record<string, { key: string | null; sessions: string[] }>,
  ): SessionDirectory {
    return new SessionDirectory({
      repoKeys: {
        keyFor: (id) => projects[id]?.key ?? null,
        probed: () => true,
        projectsSharing: (key) =>
          key === null ? [] : Object.keys(projects).filter((id) => projects[id]!.key === key),
      },
      sessionIndex: {
        *sessionsIn(projectId) {
          for (const id of projects[projectId]?.sessions ?? []) {
            yield {
              entry: {
                id, name: `title ${id}`, running: true, archived: false, deleting: false,
                lastUsedAt: 1, tool: "claude-code",
              } as any,
            };
          }
        },
      },
      projectPath: () => "/repo",
      machineId: () => machineId,
      readBranch: async () => "main",
    });
  }

  test("a notify at a live session between turns is delivered, not refused as not running", async () => {
    // A live session with no turn in flight ranks "idle", which is what every
    // session is between turns — and the state the delivery queue hands a line
    // to at once (§7.2). A gate on anything wider than "stopped" refuses the
    // common case and sends the agent to a verb that deliberately does not
    // interrupt, when interrupting is what it asked for.
    const { lead, peer, peerRow, stop } = linkedPair();
    try {
      peerRow.activity = "idle";
      const res = await post(lead, "notify", LEAD_SESSION, { to: TO_PEER, summary: "urgent", text: "look" });
      expect(res.status).toBe(200);
      expect(res.body).toMatchObject({ ok: true, sent: true });
      // The receiving half, since a 200 alone would also be true of a frame that
      // went nowhere: the arrival reached the consumer that queues the line, and
      // left no mailbox row for the agent to read the same thing twice.
      expect(peer.busEvents.map((e) => e.kind)).toEqual(["notify"]);
      const inbox = await get(peer, "inbox", PEER_SESSION);
      expect(inbox.body.posts).toEqual([]);
    } finally { stop(); }
  });

  test("a session on this machine in an unrelated repository is UNKNOWN_PEER", async () => {
    // §8.2's first bound, and E5 puts it on the bridge rather than on the
    // agent's judgment. The session index is host-wide, so a caller able to
    // resolve a row outside its own repo key would be messaging — and taking
    // answers from — work it shares no remote with.
    const m = machine({
      abDir: tempDir("bus-local-scope-"),
      machineId: "m1",
      projectId: "p1",
      sessionIds: [LEAD_SESSION],
      directory: localDirectory("m1", {
        p1: { key: REPO_KEY, sessions: [LEAD_SESSION] },
        sibling: { key: REPO_KEY, sessions: ["s-sibling"] },
        unrelated: { key: "github.com/other/thing", sessions: ["s-elsewhere"] },
      }),
    });
    try {
      const res = await post(m, "post", LEAD_SESSION, {
        to: { machineId: null, projectId: "unrelated", sessionId: "s-elsewhere" },
        summary: "s", text: "t",
      });
      expect(res.status).toBe(404);
      expect(res.body.code).toBe("UNKNOWN_PEER");
      expect(m.outbound).toHaveLength(0);

      // The control: another project on the SAME key is a peer, so what the
      // refusal above names is the repo key and not the local path itself.
      const sibling = await post(m, "post", LEAD_SESSION, {
        to: { machineId: null, projectId: "sibling", sessionId: "s-sibling" },
        summary: "s", text: "t",
      });
      expect(sibling.status).toBe(200);
    } finally { m.stop(); }
  });

  test("remote access off is REMOTE_ACCESS_OFF once the mirror has emptied", async () => {
    // The switch is itself what empties the mirror, so this is the state every
    // send but the first few is in. Decided after the row read, the agent is
    // told "no session with that address" instead: it re-reads the directory,
    // finds nobody, and concludes the peer does not exist rather than naming the
    // one switch a human at this machine can flip (§6.3).
    const { lead, leadMirror, stop } = linkedPair({ remoteAccess: false });
    try {
      leadMirror.length = 0;
      const res = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "s", text: "t" });
      expect(res.status).toBe(403);
      expect(res.body.code).toBe("REMOTE_ACCESS_OFF");
      expect(lead.outbound).toHaveLength(0);
    } finally { stop(); }
  });

  test("a missing carrier is PEER_UNREACHABLE once the mirror has emptied", async () => {
    // Same shape as the switch: the desktop app is what pushes the mirror, so a
    // machine without one has an empty mirror by definition. "No session with
    // that address" sends its human hunting for a peer that is there and becomes
    // reachable the moment the app opens.
    const { lead, leadMirror, stop } = linkedPair({ carrier: false });
    try {
      leadMirror.length = 0;
      const res = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "s", text: "t" });
      expect(res.status).toBe(503);
      expect(res.body.code).toBe("PEER_UNREACHABLE");
      expect(lead.outbound).toHaveLength(0);
    } finally { stop(); }
  });

  test("a thread and a `to` that disagree are refused, and nothing leaves", async () => {
    // The context travels from the THREAD whichever address wins, so a send that
    // followed the caller's target instead would reach a session that does not
    // hold that exchange, and be filed there under a peer nobody recognises. The
    // outbound count is the half that matters: a refusal that still sent is
    // exactly the failure this guards.
    const { lead, leadMirror, stop } = linkedPair();
    try {
      // A REAL row for the session the caller misaddresses, so the refusal below
      // is the thread's answer and not a row lookup missing: an address that
      // resolves is exactly the case where following the caller instead sends
      // the frame somewhere it will be accepted.
      leadMirror.push(mirroredRow("m2", "p2", "another-session"));
      const opened = await post(lead, "post", LEAD_SESSION, { to: TO_PEER, summary: "asking", text: "one" });
      expect(opened.status).toBe(200);
      const threadId = opened.body.threadId as string;

      const before = lead.outbound.length;
      const res = await post(lead, "post", LEAD_SESSION, {
        threadId,
        to: { machineId: "m2", projectId: "p2", sessionId: "another-session" },
        summary: "s", text: "t",
      });
      expect(res.status).toBe(404);
      expect(res.body.code).toBe("UNKNOWN_PEER");
      // The remedy rides the text, because only the caller knows which of the
      // two exchanges it meant.
      expect(res.body.error).toContain("omit");
      expect(lead.outbound).toHaveLength(before);

      const agreeing = await post(lead, "post", LEAD_SESSION, {
        threadId, to: TO_PEER, summary: "s", text: "t",
      });
      expect(agreeing.status).toBe(200);
      expect(agreeing.body.threadId).toBe(threadId);
      expect(lead.outbound).toHaveLength(before + 1);
    } finally { stop(); }
  });

  test("a post naming only a thread is aimed by the peer that thread recorded", async () => {
    // The non-interrupting way to answer an exchange, and why `to` is optional
    // beside a thread id: the only rendering an agent could copy that address
    // out of is a joined string, and an address it has to respell is one it can
    // spell wrong.
    const { lead, peer, stop } = linkedPair();
    try {
      const opened = await post(peer, "post", PEER_SESSION, { to: TO_LEAD, summary: "asking", text: "one" });
      expect(opened.status).toBe(200);
      const threadId = opened.body.threadId as string;

      const before = lead.outbound.length;
      const answered = await post(lead, "post", LEAD_SESSION, { threadId, summary: "answering", text: "two" });
      expect(answered.status).toBe(200);
      expect(answered.body.threadId).toBe(threadId);
      const sent = lead.outbound
        .slice(before)
        .find((f): f is Extract<AbMessage, { type: "session-bus:post" }> => f.type === "session-bus:post");
      expect(sent?.to).toEqual({ machineId: "m2", projectId: "p2", sessionId: PEER_SESSION });
    } finally { stop(); }
  });

  test("a send naming neither an address nor a thread is refused 400", async () => {
    // The other half of an optional `to`: with both absent there is nothing to
    // resolve, and a body that got past the schema would have the bus inventing
    // a target for it.
    const { lead, stop } = linkedPair();
    try {
      const res = await post(lead, "post", LEAD_SESSION, { summary: "s", text: "t" });
      expect(res.status).toBe(400);
      expect(res.body.error).toBe("Invalid body");
      expect(res.body.code).toBeUndefined();
      expect(lead.outbound).toHaveLength(0);
    } finally { stop(); }
  });
});
