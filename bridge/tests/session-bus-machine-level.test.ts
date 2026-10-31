// bridge/tests/session-bus-machine-level.test.ts
//
// E9/§5.4: one SessionBusCoordinator now answers for every project a host has
// open, not one project's own — HostServer builds it as a single class field
// and injects it into every `ProjectCore` it starts (`opts.sessionBus`,
// agent-core.ts). session-bus-wire.test.ts's harness is deliberately
// single-project (its own `projectId:` closure), so the property that widens
// here — `self()` and `resume()` both spanning a project boundary —
// gets its own suite rather than living as an implicit case there.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage, type SessionMemberKey, type SessionMemberRef } from "../src/protocol";
import { setLogLevel } from "../src/logger";
import { SessionBusCoordinator, type SessionBusSelf } from "../src/session-bus/coordinator";
import { SessionBusSessionIndex } from "../src/session-bus/session-index";
import { removeSessionBusProject, sessionBusSessionDir } from "../src/session-bus/store-fs";
import { loadHeld } from "../src/session-bus/held-store";
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
// SessionBusCoordinator({ ... })` self-reference relies on `send` never running
// during construction.
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
async function setUpMachine(sent: { frame: AbMessage; contextId: string }[]): Promise<{
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
    // Records every dispatch rather than deciding delivery, so what a test
    // checks is exactly what a real `send` was handed.
    send: (frame, ctx) => {
      sent.push({ frame, contextId: ctx.contextId });
      return { sent: true };
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
    const sent: { frame: AbMessage; contextId: string }[] = [];
    const { sessionA, sessionB } = await setUpMachine(sent);
    const sessionBus = sharedCoordinator();

    const resA = sessionBus.message({
      sessionId: sessionA, verb: "post", threadId: null, to: REMOTE, summary: "hi from A", parts: [{ kind: "text", text: "hi" }],
    });
    const resB = sessionBus.message({
      sessionId: sessionB, verb: "post", threadId: null, to: REMOTE, summary: "hi from B", parts: [{ kind: "text", text: "hi" }],
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
    const sent: { frame: AbMessage; contextId: string }[] = [];
    const { sessionB } = await setUpMachine(sent);
    const sessionBus = sharedCoordinator();

    // Addressed by machine + session alone — the project id on the wire is a
    // LABEL (bridge/AGENTS.md's existing address invariant) and deliberately
    // wrong here, to prove that label is not what admits the frame.
    const inbound = createMessage("session-bus:post", {
      from: REMOTE,
      to: { machineId: "m1", projectId: "not-really-project-b", sessionId: sessionB },
      contextId: sessionB,
      threadId: null,
      envelope: {
        messageId: "msg-cross-project",
        threadId: null,
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
  "a thread is minted once per session and reused, and no two sessions share one",
  async () => {
    const sent: { frame: AbMessage; contextId: string }[] = [];
    const { sessionA, sessionB } = await setUpMachine(sent);
    const sessionBus = sharedCoordinator();

    const opened = sessionBus.message({
      sessionId: sessionA, verb: "post", threadId: null, to: REMOTE, summary: "open", parts: [{ kind: "text", text: "open" }],
    });
    if (!opened.ok) throw new Error(`message refused: ${JSON.stringify(opened)}`);
    // Nothing minted one before this wave, so every message carried null and a
    // reply had no thread to name.
    expect(opened.threadId).toBeTruthy();
    expect(opened.opensThread).toBe(true);

    const again = sessionBus.message({
      sessionId: sessionA, verb: "post", threadId: opened.threadId, to: REMOTE, summary: "more", parts: [{ kind: "text", text: "more" }],
    });
    if (!again.ok) throw new Error(`message refused: ${JSON.stringify(again)}`);
    expect(again.threadId).toBe(opened.threadId);
    expect(again.opensThread).toBe(false);

    // The thread store is per SESSION even though one coordinator answers for
    // the whole machine, so a second project's first send opens its own thread
    // rather than joining the one already on the machine.
    const other = sessionBus.message({
      sessionId: sessionB, verb: "post", threadId: null, to: REMOTE, summary: "elsewhere", parts: [{ kind: "text", text: "elsewhere" }],
    });
    if (!other.ok) throw new Error(`message refused: ${JSON.stringify(other)}`);
    expect(other.opensThread).toBe(true);
    expect(other.threadId).not.toBe(opened.threadId);
  },
  30_000,
);

test(
  "one resume() after a rebuild hydrates both projects' held state",
  async () => {
    const sent: { frame: AbMessage; contextId: string }[] = [];
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
      send: () => ({ sent: false, reason: "no-transport" }), // no transport yet — everything is held to disk
    });
    const { core: coreA, bus: busA, sent: sentA } = await bootProject("a");
    const { core: coreB, bus: busB, sent: sentB } = await bootProject("b");
    sessionIndex.noteProject(coreA.projectId, "Project A", null);
    sessionIndex.noteProject(coreB.projectId, "Project B", null);
    const sessionA = await createSession(busA, sentA, "session-a");
    const sessionB = await createSession(busB, sentB, "session-b");

    const warm = sharedCoordinator();
    const resA = warm.message({ sessionId: sessionA, verb: "post", threadId: null, to: REMOTE, summary: "a", parts: [{ kind: "text", text: "a" }] });
    const resB = warm.message({ sessionId: sessionB, verb: "post", threadId: null, to: REMOTE, summary: "b", parts: [{ kind: "text", text: "b" }] });
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
      send: (frame) => { delivered.push(frame); return { sent: true }; }, // the transport is back
    });
    resumed.resume();
    resumed.retryNow();
    resumed.stop();

    expect(delivered).toHaveLength(2);
    const toIds = delivered.map((f) => (f as { to: SessionMemberKey }).to.sessionId).sort();
    expect(toIds).toEqual([REMOTE.sessionId, REMOTE.sessionId]);
    const fromSessions = delivered.map((f) => (f as { from: SessionMemberKey }).from.sessionId).sort();
    expect(fromSessions).toEqual([sessionA, sessionB].sort());
  },
  30_000,
);

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
    send: () => ({ sent: false, reason: "no-transport" }), // both messages land in held-store on disk
    now: () => now,
  });
  const resOwn = setup.message({ sessionId: "session-own", verb: "post", threadId: null, to: REMOTE, summary: "own", parts: [{ kind: "text", text: "own" }] });
  const resForeign = setup.message({ sessionId: "session-foreign", verb: "post", threadId: null, to: REMOTE, summary: "foreign", parts: [{ kind: "text", text: "foreign" }] });
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
    send: (frame) => { delivered.push(frame); return { sent: true }; }, // the transport is back
    now: () => now,
  });
  fallback.resume();
  fallback.retryNow();
  fallback.stop();

  // Only the session this fallback actually owns gets retried. Session
  // "foreign" must be skipped outright, never loaded and pinned as "p-own" —
  // if it were, its held message would flush straight through THIS transport,
  // which is a different project's bus content reaching this one's transport.
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
      if (!deliver) return { sent: false, reason: "no-transport" };
      delivered.push(ctx.contextId);
      return { sent: true };
    },
  });

  const resA = coordinator.message({ sessionId: "session-a", verb: "post", threadId: null, to: REMOTE, summary: "a", parts: [{ kind: "text", text: "a" }] });
  const resB = coordinator.message({ sessionId: "session-b", verb: "post", threadId: null, to: REMOTE, summary: "b", parts: [{ kind: "text", text: "b" }] });
  if (!resA.ok || !resB.ok) throw new Error("message refused");
  expect(resA.held).toBe(true);
  expect(resB.held).toBe(true);
  const heldFor = (projectId: string, sessionId: string) => loadHeld(abDir, projectId, sessionId).held.length;
  expect(heldFor("p-forgotten", "session-a")).toBe(1);

  // Mirrors HostServer.forget()'s own order: the durable reclaim has already
  // run and the session index no longer resolves session-a at all by the time
  // the coordinator's own drop runs — proving forgetProjectStates reads the
  // state's PINNED projectId rather than re-querying a resolver that would now
  // answer null for it.
  removeSessionBusProject(abDir, "p-forgotten");
  // Checked before the flush below, which legitimately empties session-b's own
  // held rows by delivering them: a project reclaim must not be a machine wipe,
  // and after a successful send the two answers are indistinguishable.
  expect(heldFor("p-kept", "session-b")).toBe(1);
  owners.delete("session-a");
  coordinator.forgetProjectStates("p-forgotten");

  // The transport comes back and the retry timer fires. Without the drop above,
  // session-a's still-cached state would flush its held message straight
  // through this `send` — a project this bridge has otherwise fully forgotten
  // — and `commit()` would write its rows straight back behind the reclaim.
  deliver = true;
  coordinator.retryNow();

  expect(delivered).toEqual(["session-b"]);
  expect(heldFor("p-forgotten", "session-a")).toBe(0);

  coordinator.stop();
});
