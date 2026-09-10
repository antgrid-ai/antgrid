// bridge/tests/session-bus-machine-level.test.ts
//
// E9/§5.4: one SessionBusCoordinator now answers for every project a host has
// open, not one project's own — HostServer builds it as a single class field
// and injects it into every `ProjectCore` it starts (`opts.sessionBus`,
// agent-core.ts). session-bus-wire.test.ts's harness is deliberately
// single-project (its own `projectId:` closure), so the property that widens
// here — `self()`, a route, and `resume()` all spanning a project boundary —
// gets its own suite rather than living as an implicit case there.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage, type SessionMemberKey, type SessionMemberRef } from "../src/protocol";
import { setLogLevel } from "../src/logger";
import { BUS_ROUTE_TTL_MS, MAX_BUS_ROUTES } from "../src/session-bus/constants";
import { SessionBusCoordinator, type SessionBusSelf } from "../src/session-bus/coordinator";
import { loadBusRoutes, ROUTE_STORE_VERSION, saveBusRoutes } from "../src/session-bus/route-store";
import { SessionBusSessionIndex } from "../src/session-bus/session-index";
import { sessionBusMachineDir, sessionBusSessionDir } from "../src/session-bus/store-fs";
import { SessionManager } from "../src/session-manager";

setLogLevel("error");

// process.env.ANTGRID_DIR is a process-wide override (antgrid-dir.ts) — every
// bridge test file that touches it restores the previous value in afterEach.
let prevAbDir: string | undefined;
let abDir: string;
let cores: AgentCore[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-bus-machine-"));
  process.env.ANTGRID_DIR = abDir;
  cores = [];
  _sharedCoordinator = null;
});

afterEach(async () => {
  for (const core of cores) {
    try { await core.shutdown(); } catch { /* best effort */ }
  }
  // AgentCore.shutdown() deliberately never stops an injected coordinator
  // (killing a shared timer over one project's teardown is exactly the bug
  // this commit removes) — so the harness, standing in for HostServer's own
  // shutdown(), stops it here instead.
  _sharedCoordinator?.stop();
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  try { rmSync(abDir, { recursive: true, force: true }); } catch { /* Windows watcher handle */ }
});

async function waitFor(predicate: () => boolean, what: string, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

function tempFolder(label: string): string {
  const f = mkdtempSync(join(tmpdir(), `antgrid-bus-machine-${label}-`));
  writeFileSync(join(f, "antgrid.yaml"), `name: ${label}\n`);
  return f;
}

/** One project core sharing [sessionBus] — the exact wiring HostServer gives
 *  every project it starts (`sessionBus: this.sessionBus` in host-server.ts,
 *  threaded through `ProjectCoreDeps` in project-core.ts). `machineId` is
 *  supplied deliberately: no other buildAgentCore caller in this suite does,
 *  so this is the first harness exercising it alongside an injected
 *  coordinator together, the way a real host actually wires both. */
async function bootProject(label: string): Promise<{ core: AgentCore; bus: MessageBus; sent: AbMessage[] }> {
  const core = await buildAgentCore({
    folder: tempFolder(label),
    mode: "local",
    identity: { deviceId: `agent-${label}`, deviceName: label, createdAt: new Date().toISOString() },
    machineId: () => "m1",
    sessionBus: sharedCoordinator(),
  });
  cores.push(core);
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  bus.subscribe({ deliver: (m) => sent.push(m) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(() => sent.some((m) => m.type === "agent:status"), `${label}'s first agent:status`);
  return { core, bus, sent };
}

/** A non-isolated ("shared") session: `session:create` alone is what
 *  registers a `SessionEntry` on the core's own SessionManager — no PTY spawn,
 *  no git — so this is deliberately never followed by `session:start`. */
async function createSession(bus: MessageBus, sent: AbMessage[], name: string): Promise<string> {
  const requestId = crypto.randomUUID();
  bus.dispatchInbound(createMessage("session:create", { requestId, name }), "control", "loopback");
  await waitFor(
    () => sent.some((m) => m.type === "session:result" && (m as { requestId?: string }).requestId === requestId),
    `${name}'s session:create result`,
  );
  const result = sent.find((m) => m.type === "session:result" && (m as { requestId?: string }).requestId === requestId);
  if (result?.type !== "session:result" || !result.ok || !result.session) {
    throw new Error(`session:create failed for ${name}: ${JSON.stringify(result)}`);
  }
  return result.session.id;
}

/** `session:create` only schedules SessionManager's write of `sessions.json`
 *  (a 200ms debounce — session-manager.ts's `scheduleFlush`); a cold
 *  `SessionBusSessionIndex.hydrate` reads that same file straight off disk.
 *  A real restart never races this — the dead process's own last flush is
 *  long since durable by the time a new one starts — so this polls the same
 *  peek `hydrate` itself uses rather than a blind sleep, to make that gap
 *  disappear here too. */
async function waitForPersistedSession(projectId: string, sessionId: string): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    const entries = await SessionManager.readPersisted(abDir, projectId, true);
    if (entries.some((e) => e.id === sessionId)) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`timed out waiting for ${sessionId} to persist under project ${projectId}`);
}

const REMOTE: SessionMemberRef = { machineId: "m-remote", projectId: "p-remote", sessionId: "s-remote" };

// `bootProject` needs the coordinator before it exists (it is one of
// buildAgentCore's own options), and the coordinator's `self`/`send` need the
// two cores' project ids before either core is built — so both sides close
// over a forward reference assigned once, immediately below its declaration,
// exactly as agent-core.ts's own `const sessionBus = ... ?? new
// SessionBusCoordinator({ send: (frame, ctx) => { ... sessionBus.routeFor
// ... } })` self-reference relies on `send` never running during
// construction.
let _sharedCoordinator: SessionBusCoordinator | null = null;
function sharedCoordinator(): SessionBusCoordinator {
  if (!_sharedCoordinator) throw new Error("sharedCoordinator built before use");
  return _sharedCoordinator;
}

/** Builds the machine-level trio a real HostServer owns: the session index,
 *  the one coordinator, and the two project cores registered into both — then
 *  creates one session in each project. Mirrors host-server.ts's own
 *  `sessionIndex`/`sessionBus` fields and `startCore`'s
 *  `sessionIndex.noteProject(core.projectId, ..., core.listSessions(true))`. */
async function setUpMachine(sent: { frame: AbMessage; role: string; contextId: string }[]): Promise<{
  sessionIndex: SessionBusSessionIndex;
  coreA: AgentCore; busA: MessageBus; sentA: AbMessage[]; sessionA: string;
  coreB: AgentCore; busB: MessageBus; sentB: AbMessage[]; sessionB: string;
}> {
  const sessionIndex = new SessionBusSessionIndex({
    liveSessions: (projectId) => cores.find((c) => c.projectId === projectId)?.listSessions(true) ?? null,
  });
  _sharedCoordinator = new SessionBusCoordinator({
    abDir,
    projectIdFor: (sessionId) => sessionIndex.lookup(sessionId)?.projectId ?? null,
    self: (sessionId) => {
      const entry = sessionIndex.lookup(sessionId);
      if (!entry) return null;
      return {
        key: { machineId: "m1", projectId: entry.projectId, sessionId },
        ref: { machineId: "m1", projectId: entry.projectId, sessionId, sessionName: entry.sessionName },
      };
    },
    addressable: () => true,
    // Records every dispatch rather than deciding delivery — the per-test
    // routing assertions (which project's stream a peer-role frame lands on)
    // read this list back rather than a bespoke mailbox map, so what a test
    // checks is exactly what a real `send` was handed.
    send: (frame, ctx) => {
      sent.push({ frame, role: ctx.role, contextId: ctx.contextId });
      return true;
    },
  });

  const { core: coreA, bus: busA, sent: sentA } = await bootProject("a");
  const { core: coreB, bus: busB, sent: sentB } = await bootProject("b");
  // The label registration `startCore` does on every project open — without
  // it `lookup` never iterates this project at all (SessionBusSessionIndex's
  // own doc). The snapshot argument does not matter: both cores stay in
  // `cores`, so `liveSessions` always answers live for them from here on.
  sessionIndex.noteProject(coreA.projectId, "Project A", null);
  sessionIndex.noteProject(coreB.projectId, "Project B", null);

  const sessionA = await createSession(busA, sentA, "session-a");
  const sessionB = await createSession(busB, sentB, "session-b");
  return { sessionIndex, coreA, busA, sentA, sessionA, coreB, busB, sentB, sessionB };
}

test(
  "self() resolves a session in each of two projects from one coordinator",
  async () => {
    const sent: { frame: AbMessage; role: string; contextId: string }[] = [];
    const { sessionA, sessionB } = await setUpMachine(sent);
    const sessionBus = sharedCoordinator();

    const resA = sessionBus.message({
      sessionId: sessionA, taskId: null, to: REMOTE, summary: "hi from A", parts: [{ kind: "text", text: "hi" }],
    });
    const resB = sessionBus.message({
      sessionId: sessionB, taskId: null, to: REMOTE, summary: "hi from B", parts: [{ kind: "text", text: "hi" }],
    });
    // Neither is NOT_MEMBER/AGENT_NOT_READY: a refusal there is exactly what a
    // debounce-lagged snapshot (must-fix 3) or a single-project `self` would
    // produce for the second project's session.
    expect("ok" in resA && resA.ok).toBe(true);
    expect("ok" in resB && resB.ok).toBe(true);

    const fromA = (sent.find((s) => s.contextId === sessionA)?.frame as { from: SessionMemberKey }).from;
    const fromB = (sent.find((s) => s.contextId === sessionB)?.frame as { from: SessionMemberKey }).from;
    expect(fromA).toEqual({ machineId: "m1", projectId: cores[0]!.projectId, sessionId: sessionA });
    expect(fromB).toEqual({ machineId: "m1", projectId: cores[1]!.projectId, sessionId: sessionB });
  },
  30_000,
);

test(
  "a frame naming project B's session applies on the shared machine bus",
  async () => {
    const sent: { frame: AbMessage; role: string; contextId: string }[] = [];
    const { sessionB } = await setUpMachine(sent);
    const sessionBus = sharedCoordinator();

    // Addressed by machine + session alone — the project id on the wire is a
    // LABEL (bridge/CLAUDE.md's existing address invariant) and deliberately
    // wrong here, to prove that label is not what admits the frame.
    const inbound = createMessage("session-bus:message", {
      from: REMOTE,
      to: { machineId: "m1", projectId: "not-really-project-b", sessionId: sessionB },
      contextId: sessionB,
      taskId: null,
      envelope: {
        messageId: "msg-cross-project",
        taskId: null,
        contextId: sessionB,
        parts: [{ kind: "text", text: "reached across projects" }],
        metadata: { peer: REMOTE, summary: "reached across projects", timestamp: Date.now() },
      },
    });
    expect(sessionBus.handleInbound(inbound)).toBe("applied");
    expect(sessionBus.messages(sessionB).entries).toHaveLength(1);
    expect(sessionBus.messages(sessionB).entries[0]!.direction).toBe("in");
  },
  30_000,
);

test(
  "a route learned on project A never sends on project B's stream",
  async () => {
    const sent: { frame: AbMessage; role: string; contextId: string }[] = [];
    const { coreA, coreB, sessionB } = await setUpMachine(sent);
    const sessionBus = sharedCoordinator();

    // Simulates what `handleAbMessage`'s session-bus case does on an applied
    // inbound frame: note which project's stream carried context `sessionA`
    // in (agent-core.ts's `sessionBus.noteRoute(msg.contextId, peerId,
    // project.id)`), naming project A explicitly.
    const contextId = "ctx-cross";
    sessionBus.noteRoute(contextId, "app-session-x", coreA.projectId);
    expect(sessionBus.routeFor(contextId)?.projectId).toBe(coreA.projectId);

    // Session B now answers on that SAME context — a peer-role send, since
    // `contextId !== sessionB` (roleForContext). If routing fell back to
    // whichever project is dispatching rather than the one the route names,
    // this would resolve to project B.
    const res = sessionBus.message({
      sessionId: sessionB, taskId: null, to: REMOTE, contextId, summary: "reply", parts: [{ kind: "text", text: "reply" }],
    });
    expect("ok" in res && res.ok).toBe(true);

    const dispatched = sent.filter((s) => s.contextId === contextId);
    expect(dispatched).toHaveLength(1);
    expect(dispatched[0]!.role).toBe("peer");
    // The route is the only thing a peer-role dispatcher may consult for
    // WHICH project's stream to use — never the sending session's own
    // project — and it names A.
    expect(sessionBus.routeFor(contextId)?.projectId).toBe(coreA.projectId);
    expect(sessionBus.routeFor(contextId)?.projectId).not.toBe(coreB.projectId);
  },
  30_000,
);

test(
  "a lead's own context routes home on the PEER project's stream, not its owner's",
  async () => {
    const sent: { frame: AbMessage; role: string; contextId: string }[] = [];
    const { coreA, coreB, sessionA, sessionB } = await setUpMachine(sent);
    const sessionBus = sharedCoordinator();

    // E9/§5.4's own case, end to end on one machine: session A leads, session B
    // (another project — a worktree of the same repo, in the shape that
    // motivated the move) is the peer. A lead names its context after itself,
    // so the frame that reaches B carries A's session id as contextId while
    // arriving on B's stream — the two projects disagree by construction, and
    // noteRoute must record the stream that actually carried it.
    const inbound = createMessage("session-bus:message", {
      from: { machineId: "m1", projectId: coreA.projectId, sessionId: sessionA },
      to: { machineId: "m1", projectId: coreB.projectId, sessionId: sessionB },
      contextId: sessionA,
      taskId: null,
      envelope: {
        messageId: "msg-lead-to-peer",
        taskId: null,
        contextId: sessionA,
        parts: [{ kind: "text", text: "work on this" }],
        metadata: {
          peer: { machineId: "m1", projectId: coreA.projectId, sessionId: sessionA },
          summary: "work on this",
          timestamp: Date.now(),
        },
      },
    });
    expect(sessionBus.handleInbound(inbound)).toBe("applied");
    sessionBus.noteRoute(sessionA, "app-session-carrier", coreB.projectId);

    // Refusing this pair as a project mismatch is what strands the parent's
    // replies: the reply below is peer-role, and a peer with no route holds
    // its frames until they expire rather than falling back to anything.
    expect(sessionBus.routeFor(sessionA)).toEqual(
      expect.objectContaining({ peerId: "app-session-carrier", projectId: coreB.projectId }),
    );

    const res = sessionBus.message({
      sessionId: sessionB,
      taskId: null,
      to: { machineId: "m1", projectId: coreA.projectId, sessionId: sessionA },
      contextId: sessionA,
      summary: "done",
      parts: [{ kind: "text", text: "done" }],
    });
    expect("ok" in res && res.ok).toBe(true);
    const dispatched = sent.filter((s) => s.contextId === sessionA);
    expect(dispatched).toHaveLength(1);
    expect(dispatched[0]!.role).toBe("peer");
  },
  30_000,
);

// Slow by construction, not by accident: this walks the whole MAX_BUS_ROUTES
// cap, and noteRoute forces a save on every binding CHANGE — a context seen
// for the first time always is one. Each forced save re-reads and rewrites
// the whole machine file (the merge that makes two hosts on one ANTGRID_DIR
// safe), so the loop costs O(rows) of disk per iteration and lands just under
// bun's 5 s default. A real bridge binds one context at a time; only a test
// does the entire cap back to back. The explicit timeout keeps that
// arithmetic from reading as a flake.
test(
  "a legitimate re-stamp of its own context still moves it to the back of the LRU",
  () => {
    let now = 1_000_000;
    const coordinator = new SessionBusCoordinator({
      abDir,
      projectIdFor: (sessionId) => (sessionId === "session-b" ? "project-b" : null),
      self: () => null,
      send: () => true,
      now: () => now,
    });

    coordinator.noteRoute("session-b", "peer-1", "project-b");
    // Fill the table with foreign contexts so session-b's own entry — the
    // very first one written — is the front: next in line for eviction.
    for (let i = 0; i < MAX_BUS_ROUTES - 1; i++) {
      now += 1;
      coordinator.noteRoute(`ctx-${i}`, `peer-${i}`, "project-a");
    }
    expect(coordinator.routeFor("session-b")).not.toBeNull();

    // A re-stamp must move the entry to the back: without the delete-then-set,
    // the next insertion over the cap would evict session-b as the least
    // recently carried instead of `ctx-0`, because a Map keeps FIRST-insertion
    // order and a plain set() on an existing key does not disturb it.
    now += 1;
    coordinator.noteRoute("session-b", "peer-1", "project-b");
    now += 1;
    coordinator.noteRoute("ctx-overflow", "peer-overflow", "project-a");

    expect(coordinator.routeFor("session-b")?.peerId).toBe("peer-1");
    expect(coordinator.routeFor("ctx-0")).toBeNull();

    coordinator.stop();
  },
  20_000,
);

test(
  "one resume() after a rebuild hydrates both projects' held state",
  async () => {
    const sent: { frame: AbMessage; role: string; contextId: string }[] = [];
    // Overridden below to fail every send, so both sessions' first message is
    // HELD (and persisted) rather than delivered.
    const sessionIndex = new SessionBusSessionIndex({
      liveSessions: (projectId) => cores.find((c) => c.projectId === projectId)?.listSessions(true) ?? null,
    });
    _sharedCoordinator = new SessionBusCoordinator({
      abDir,
      projectIdFor: (sessionId) => sessionIndex.lookup(sessionId)?.projectId ?? null,
      self: (sessionId) => {
        const entry = sessionIndex.lookup(sessionId);
        if (!entry) return null;
        return {
          key: { machineId: "m1", projectId: entry.projectId, sessionId },
          ref: { machineId: "m1", projectId: entry.projectId, sessionId, sessionName: entry.sessionName },
        };
      },
      addressable: () => true,
      send: () => false, // no carrier yet — everything is held to disk
    });
    const { core: coreA, bus: busA, sent: sentA } = await bootProject("a");
    const { core: coreB, bus: busB, sent: sentB } = await bootProject("b");
    sessionIndex.noteProject(coreA.projectId, "Project A", null);
    sessionIndex.noteProject(coreB.projectId, "Project B", null);
    const sessionA = await createSession(busA, sentA, "session-a");
    const sessionB = await createSession(busB, sentB, "session-b");

    const warm = sharedCoordinator();
    const resA = warm.message({ sessionId: sessionA, taskId: null, to: REMOTE, summary: "a", parts: [{ kind: "text", text: "a" }] });
    const resB = warm.message({ sessionId: sessionB, taskId: null, to: REMOTE, summary: "b", parts: [{ kind: "text", text: "b" }] });
    if (!resA.ok || !resB.ok) throw new Error(`message refused: ${JSON.stringify({ resA, resB })}`);
    expect(resA.held).toBe(true);
    expect(resB.held).toBe(true);

    // A restart: no live core answers for either project any more (the
    // process that held them is gone), so the fresh index can only ever
    // resolve through the disk-hydrated half — the exact case `resume()`
    // exists for. Waiting for each session's debounced `sessions.json` write
    // first is what makes that true here: `createSession` above only
    // schedules it, and a real restart would never race this gap.
    await waitForPersistedSession(coreA.projectId, sessionA);
    await waitForPersistedSession(coreB.projectId, sessionB);
    const coldIndex = new SessionBusSessionIndex({ liveSessions: () => null });
    await coldIndex.hydrate(abDir, [
      { id: coreA.projectId, label: "Project A" },
      { id: coreB.projectId, label: "Project B" },
    ]);
    const delivered: AbMessage[] = [];
    const resumed = new SessionBusCoordinator({
      abDir,
      projectIdFor: (sessionId) => coldIndex.lookup(sessionId)?.projectId ?? null,
      self: () => null, // resume()/pump() only replay held frames; they never call self()
      send: (frame) => { delivered.push(frame); return true; }, // the carrier is back
    });
    resumed.resume();
    resumed.pump();
    resumed.stop();

    expect(delivered).toHaveLength(2);
    const toIds = delivered.map((f) => (f as { to: SessionMemberKey }).to.sessionId).sort();
    expect(toIds).toEqual([REMOTE.sessionId, REMOTE.sessionId]);
    const fromSessions = delivered.map((f) => (f as { from: SessionMemberKey }).from.sessionId).sort();
    expect(fromSessions).toEqual([sessionA, sessionB].sort());
  },
  30_000,
);

test("forgetting a project erases its carrier routes from the machine file, not just from memory", () => {
  // No cores: `forgetProjectRoutes` touches nothing but the route table, and
  // the property under test is what survives on disk once a forgotten project
  // is the last bus-relevant thing this process saw — so the harness is two
  // learned routes, the one call `HostServer.forget` makes, and a fresh read.
  const coordinator = new SessionBusCoordinator({
    abDir,
    projectIdFor: () => null,
    self: () => null,
    send: () => true,
  });
  coordinator.noteRoute("ctx-doomed", "phone#m1", "p-forgotten");
  coordinator.noteRoute("ctx-kept", "phone#m1", "p-kept");
  coordinator.forgetProjectRoutes("p-forgotten");
  coordinator.stop();

  // The next process start hydrates whatever is here wholesale (hydrateRoutes
  // takes no project list), so a row still on disk is a row resurrected.
  const onDisk = loadBusRoutes(abDir, BUS_ROUTE_TTL_MS, Date.now());
  expect([...onDisk.keys()]).toEqual(["ctx-kept"]);
});

test("hydrating routes does not regress a fresher one already learned live", () => {
  // HostServer's own call site runs hydrateRoutes off a `.finally()` on an
  // async sessionIndex.hydrate() (host-server.ts), so an inbound frame can
  // already have called noteRoute for a context before that disk read
  // resolves. Reproduced directly, without the async indirection: the
  // coordinator learns a route live, the file it is about to hydrate from
  // holds an older one, and hydrating must not overwrite what live traffic
  // just proved.
  const now = 2_000;
  const coordinator = new SessionBusCoordinator({
    abDir,
    projectIdFor: () => null,
    self: () => null,
    send: () => true,
    now: () => now,
  });
  coordinator.noteRoute("ctx-1", "app-fresh", "p1");
  // Written AFTER noteRoute, and by hand rather than through saveBusRoutes:
  // noteRoute forces a save of its own, and the write path merges newest-`at`
  // first, so any stale row seeded before it is gone from the file by the time
  // hydrate reads it — which is exactly what made an earlier version of this
  // test pass with the freshness guard deleted.
  mkdirSync(sessionBusMachineDir(abDir), { recursive: true });
  writeFileSync(
    join(sessionBusMachineDir(abDir), "routes.json"),
    JSON.stringify({
      version: ROUTE_STORE_VERSION,
      routes: [{ contextId: "ctx-1", peerId: "app-stale", projectId: "p1", at: 1_000 }],
    }),
    "utf8",
  );

  coordinator.hydrateRoutes();
  expect(coordinator.routeFor("ctx-1")?.peerId).toBe("app-fresh");
  coordinator.stop();
});

test("an expired route's drop is written to disk, not just to the table", () => {
  // routeFor forces a save precisely so the drop outlives the process. The
  // machine file is merged into, never replaced, so a row this table simply
  // stops mentioning reads as "unknown to me" and is copied back off disk —
  // the drop only lands because it is NAMED in the save.
  let now = 1_000_000;
  saveBusRoutes(abDir, new Map([["ctx-lapsed", { peerId: "phone#m1", projectId: "p1", at: now }]]));
  const coordinator = new SessionBusCoordinator({
    abDir,
    projectIdFor: () => null,
    self: () => null,
    send: () => true,
    now: () => now,
  });
  coordinator.hydrateRoutes();
  now += BUS_ROUTE_TTL_MS + 1;
  expect(coordinator.routeFor("ctx-lapsed")).toBeNull();
  coordinator.stop();

  // Read back with an effectively infinite TTL: loadBusRoutes' own TTL filter
  // would hide the row and prove nothing about whether the save erased it.
  expect([...loadBusRoutes(abDir, Number.MAX_SAFE_INTEGER, now).keys()]).toEqual([]);
});

// Slow by construction, not by accident: this walks the whole MAX_BUS_ROUTES
// cap, and noteRoute forces a save on every binding CHANGE — a context seen
// for the first time always is one. Each forced save re-reads and rewrites
// the whole machine file (the merge that makes two hosts on one ANTGRID_DIR
// safe), so the loop costs O(rows) of disk per iteration and lands just under
// bun's 5 s default. A real bridge binds one context at a time; only a test
// does the entire cap back to back. The explicit timeout keeps that
// arithmetic from reading as a flake.
test("an evicted route does not come back on the next hydrate", () => {
  // The cap case is the one an on-read TTL cannot cover: an evicted row can
  // carry a live `at` (a successful send restamps it by reference without
  // moving its LRU position), so if the eviction is not persisted the row
  // survives the file cap AND the load filter, and the next process start
  // hydrates the very entry this one evicted for space.
  let now = 1_000_000;
  const coordinator = new SessionBusCoordinator({
    abDir,
    projectIdFor: () => null,
    self: () => null,
    send: () => true,
    now: () => now,
  });
  coordinator.noteRoute("ctx-victim", "peer-v", "p1");
  for (let i = 0; i < MAX_BUS_ROUTES - 1; i++) {
    now += 1;
    coordinator.noteRoute(`ctx-${i}`, `peer-${i}`, "p1");
  }
  now += 1;
  const live = coordinator.routeFor("ctx-victim");
  expect(live).not.toBeNull();
  live!.at = now; // what a send that actually got out does (routeFor's doc)
  now += 1;
  coordinator.noteRoute("ctx-0", "peer-0-rebound", "p1"); // forces a save carrying the restamp
  now += 1;
  coordinator.noteRoute("ctx-over", "peer-over", "p1"); // ctx-victim is the front: evicted
  expect(coordinator.routeFor("ctx-victim")).toBeNull();
  coordinator.stop();

  expect(loadBusRoutes(abDir, BUS_ROUTE_TTL_MS, now).get("ctx-victim")).toBeUndefined();
}, 20_000);

// The two eviction tests above both start from an EMPTY file, so neither can
// see the coupling this one exists for: on disk the rows carry no LRU position
// of their own, and the only thing that re-establishes it is the ORDER the
// loader hands them back in (`route-store.ts`'s write sorts freshest-first and
// then reverses, precisely so the file reads oldest-first). `noteRoute` evicts
// from the FRONT of a Map that keeps first-insertion order, so a loader that
// returns rows in any other order evicts a live route and keeps a dead one —
// silently, and only after a restart.
//
// Seeded newest-first on purpose: what the caller hands `saveBusRoutes` must
// not be what decides the answer.
test("a hydrated table evicts the least recently carried, not the first row it was handed", () => {
  const now = 1_000_000;
  const newestFirst = new Map(
    Array.from({ length: MAX_BUS_ROUTES }, (_, i) => MAX_BUS_ROUTES - 1 - i).map((i) => [
      `ctx-${i}`,
      { peerId: `peer-${i}`, projectId: "p1", at: now + i },
    ]),
  );
  saveBusRoutes(abDir, newestFirst);

  const coordinator = new SessionBusCoordinator({
    abDir,
    projectIdFor: () => null,
    self: () => null,
    send: () => true,
    now: () => now + MAX_BUS_ROUTES,
  });
  coordinator.hydrateRoutes();
  expect(coordinator.routeFor("ctx-0")).not.toBeNull();

  coordinator.noteRoute("ctx-over", "peer-over", "p1");

  expect(coordinator.routeFor("ctx-0")).toBeNull();
  expect(coordinator.routeFor(`ctx-${MAX_BUS_ROUTES - 1}`)?.peerId).toBe(`peer-${MAX_BUS_ROUTES - 1}`);
  expect(coordinator.routeFor("ctx-over")?.peerId).toBe("peer-over");

  coordinator.stop();
});


test("resume()'s fallback-style resolver does not pin a foreign project's held state under its own id", () => {
  // Two sessions, two projects, persisted the normal way (a coordinator whose
  // `projectIdFor` is genuinely session-aware, exactly like a real one before
  // any restart).
  let now = 1_000_000;
  const owners = new Map([["session-own", "p-own"], ["session-foreign", "p-foreign"]]);
  const selfFor = (sessionId: string): SessionBusSelf | null => {
    const projectId = owners.get(sessionId);
    if (!projectId) return null;
    return {
      key: { machineId: "m1", projectId, sessionId },
      ref: { machineId: "m1", projectId, sessionId, sessionName: sessionId },
    };
  };
  const setup = new SessionBusCoordinator({
    abDir,
    projectIdFor: (sessionId) => owners.get(sessionId) ?? null,
    self: selfFor,
    send: () => false, // no carrier — both messages land in held-store on disk
    now: () => now,
  });
  const resOwn = setup.message({ sessionId: "session-own", taskId: null, to: REMOTE, summary: "own", parts: [{ kind: "text", text: "own" }] });
  const resForeign = setup.message({ sessionId: "session-foreign", taskId: null, to: REMOTE, summary: "foreign", parts: [{ kind: "text", text: "foreign" }] });
  if (!resOwn.ok || !resForeign.ok) throw new Error("message refused");
  expect(resOwn.held).toBe(true);
  expect(resForeign.held).toBe(true);
  setup.stop();

  // A restart of a HOSTLESS core: `agent-core.ts`'s own fallback answers
  // `projectIdFor` with a constant closure over its own project id, regardless
  // of which session it is asked about — the exact shape that made the old
  // "no known owning project" guard vacuous, because it never returns null.
  const delivered: AbMessage[] = [];
  const fallback = new SessionBusCoordinator({
    abDir,
    projectIdFor: () => "p-own",
    self: () => null, // resume()/pump() only replay held frames; they never call self()
    send: (frame) => { delivered.push(frame); return true; }, // the carrier is back
    now: () => now,
  });
  fallback.resume();
  fallback.pump();
  fallback.stop();

  // Only the session this fallback actually owns gets retried. Session
  // "foreign" must be skipped outright, never loaded and pinned as "p-own" —
  // if it were, its held message would flush straight through THIS carrier,
  // which is a different project's bus content reaching this one's owner.
  expect(delivered).toHaveLength(1);
  expect((delivered[0] as { from: SessionMemberKey }).from.sessionId).toBe("session-own");
});

test("forgetting a project drops its pinned session state, so a later retry cannot resurrect its store", () => {
  // A map rather than a constant closure — see the resume() test above for why
  // a constant `projectIdFor` would make this test vacuously pass no matter
  // what forgetProjectStates does with the id it is handed.
  const owners = new Map([["session-a", "p-forgotten"], ["session-b", "p-kept"]]);
  let deliver = false;
  const delivered: string[] = [];
  const coordinator = new SessionBusCoordinator({
    abDir,
    projectIdFor: (sessionId) => owners.get(sessionId) ?? null,
    self: (sessionId) => {
      const projectId = owners.get(sessionId);
      if (!projectId) return null;
      return {
        key: { machineId: "m1", projectId, sessionId },
        ref: { machineId: "m1", projectId, sessionId, sessionName: sessionId },
      };
    },
    send: (frame, ctx) => {
      if (!deliver) return false;
      delivered.push(ctx.contextId);
      return true;
    },
  });

  const resA = coordinator.message({ sessionId: "session-a", taskId: null, to: REMOTE, summary: "a", parts: [{ kind: "text", text: "a" }] });
  const resB = coordinator.message({ sessionId: "session-b", taskId: null, to: REMOTE, summary: "b", parts: [{ kind: "text", text: "b" }] });
  if (!resA.ok || !resB.ok) throw new Error("message refused");
  expect(resA.held).toBe(true);
  expect(resB.held).toBe(true);
  const forgottenDir = sessionBusSessionDir(abDir, "p-forgotten", "session-a");
  expect(existsSync(forgottenDir)).toBe(true);

  // Mirrors HostServer.forget()'s own order: `deleteProjectStores` has already
  // reclaimed `agents/p-forgotten/` and the session index no longer resolves
  // session-a at all by the time the coordinator's own drop runs — proving
  // forgetProjectStates reads the state's PINNED projectId rather than
  // re-querying a resolver that would now answer null for it.
  rmSync(join(abDir, "agents", "p-forgotten"), { recursive: true, force: true });
  owners.delete("session-a");
  coordinator.forgetProjectStates("p-forgotten");

  // The carrier comes back and the retry timer fires. Without the drop above,
  // session-a's still-cached state would flush its held message straight
  // through this `send` — a project this bridge has otherwise fully forgotten
  // — and `commit()` would recreate the very directory forget() just erased.
  deliver = true;
  coordinator.pump();

  expect(delivered).toEqual(["session-b"]);
  expect(existsSync(forgottenDir)).toBe(false);

  coordinator.stop();
});
