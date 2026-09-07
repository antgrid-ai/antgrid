// evals/tests/gate-multi-machine.test.ts
//
// The multi-machine session, end to end, across TWO real bridges.
//
// What only this file can cover: every claim about the session bus that depends
// on the two halves being on different machines. `gate-session-bus.test.ts` runs
// the same round trip inside ONE bridge with a scripted peer — which proves the
// lead's own arithmetic and nothing about the other side's. Here the peer is a
// second bridge process with its own store, its own session manager and its own
// coordinator, and the only thing joining them is the carrier: a test object
// with a loopback leg on the lead and a relay app session on the peer, exactly
// the two connections the desktop app holds (D7).
//
// Every row is self-contained — two bridges, one relay, one account, torn down
// in `finally` — because a shared env would let one row's outbox retries and
// half-open turns decide another row's timing.
import { expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { existsSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setupTwoBridgeEnv, type TwoBridgeEnv } from "../helpers/two-bridge";
import {
  createMessage,
  type SessionMemberKey,
  type SessionMemberOf,
  type SessionMemberRef,
} from "../../bridge/src/protocol";
import { briefScope } from "../../bridge/src/session-bus/brief-store";
import { declaredScope, renderCancel, renderTask, renderWake } from "../../bridge/src/session-bus/delivery";
import { sessionBusSessionDir } from "../../bridge/src/session-bus/store-fs";
import {
  CANCEL_MARKER,
  SINK_SCRIPT,
  SINK_SCRIPT_NAME,
  TASK_MARKER,
  WAKE_MARKER,
  apiPort,
  countMarkers,
  getJson,
  persistedSessions,
  postJson,
  queuedLines,
  sessionVerb,
  sessionVerbResult,
  sinkText,
  sleep,
  until,
  untilAsync,
} from "../support/session-bus";

// Two bridge processes, a relay and two PTYs come up per row, and the
// single-machine row already budgets this much for half of the traffic below.
const ROW_TIMEOUT_MS = 180_000;

const LEAD_NAME = "lead";
const PEER_NAME = "peer worker";

// Scope-bearing on purpose: `declaredScope` is lexical, so these three lines are
// what makes every task delivery below carry a restated mandate (spec 5.2).
const BRIEF = [
  "Diagnose the failing web suite on your machine.",
  "Owns: the web workspace on this checkout.",
  "Must report: the first failing assertion and what caused it.",
  "May not: push, force-push, or touch the relay.",
].join("\n");

// A repo the Capability Card can normalise into a match key. The `.git` suffix
// and the default port are both dropped by `normalizeRemoteUrl`, so the expected
// value below is the whole of what §7.5 says two machines match on.
const REMOTE_URL = "https://github.com/antgrid/Eval-Fixture.git";
const REMOTE_KEY = "github.com/antgrid/eval-fixture";

interface Sinks { lead: string; peer: string }

function newSinks(): Sinks {
  const id = randomUUID();
  return {
    lead: join(tmpdir(), `antgrid-eval-sink-lead-${id}.txt`),
    peer: join(tmpdir(), `antgrid-eval-sink-peer-${id}.txt`),
  };
}

function dropSinks(sinks: Sinks): void {
  for (const path of [sinks.lead, sinks.peer]) {
    try { rmSync(path, { force: true }); } catch { /* the PTY may still hold it */ }
  }
}

/** The guest both machines run: a stdin sink, so "when did this line reach the
 *  terminal" is the only thing a row has to read. */
function writeSink(dir: string): void {
  writeFileSync(join(dir, SINK_SCRIPT_NAME), SINK_SCRIPT);
}

async function git(cwd: string, args: string[]): Promise<void> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "ignore", stderr: "pipe" });
  if (await proc.exited !== 0) throw new Error(await new Response(proc.stderr).text());
}

/** The fixture project is a plain folder; the Capability Card reports on a
 *  repository. */
async function writeSinkAndRepo(dir: string): Promise<void> {
  writeSink(dir);
  await git(dir, ["init"]);
  await git(dir, ["config", "user.email", "eval@antgrid.local"]);
  await git(dir, ["config", "user.name", "Antgrid Eval"]);
  await git(dir, ["add", "."]);
  await git(dir, ["commit", "-m", "initial"]);
  await git(dir, ["remote", "add", "origin", REMOTE_URL]);
}

interface Expanded {
  leadSessionId: string;
  peerSessionId: string;
  leadKey: SessionMemberKey;
  peerKey: SessionMemberKey;
  /** The lead as the app named it when it created the peer — the labels every
   *  peer-facing template renders its provenance from. */
  leadRef: SessionMemberRef;
  /** The peer as the app recorded it on the lead — likewise for the wake. */
  peerRef: SessionMemberRef;
  /** The lead's row as the PEER bridge stored it, read back rather than
   *  constructed: the manager stamps `role`/`joinedAt`/`state`, and the delivery
   *  templates take this exact object. */
  leadAsMemberOf: SessionMemberOf;
  leadApi: string;
  peerApi: string;
}

/**
 * One expanded session: a lead on machine A, a peer on machine B, each half
 * written by the bridge that owns it (D9).
 *
 * The order is the app's order and not a convenience: the peer names the lead in
 * its `memberOf`, so the lead session has to exist first; and the lead's role is
 * derived from its member list, so `GET /session-bus/role` answers `null` there
 * until `session:member-record` lands.
 */
async function expand(tb: TwoBridgeEnv, opts: { brief?: string } = {}): Promise<Expanded> {
  const leadApi = `http://127.0.0.1:${await apiPort(tb.lead.abDir)}`;
  const peerApi = `http://127.0.0.1:${await apiPort(tb.peer.abDir)}`;

  const createdLead = await sessionVerb(tb.lead.app, tb.leadStreamId, createMessage("session:create", {
    requestId: randomUUID(),
    name: LEAD_NAME,
    // A custom command, because the fixture declares no agent: the sink is the
    // only guest these rows need.
    command: `node ${SINK_SCRIPT_NAME}`,
    mode: "terminal",
  }));
  const leadSessionId: string = createdLead.session.id;
  // Running before any turn opens: work status only opens a turn for a session
  // it already knows is live.
  await sessionVerb(tb.lead.app, tb.leadStreamId, createMessage("session:start", {
    requestId: randomUUID(), sessionId: leadSessionId,
  }));

  const leadRef: SessionMemberRef = {
    machineId: tb.leadMachineId,
    projectId: tb.lead.projectId,
    sessionId: leadSessionId,
    machineLabel: "Lead desktop",
    projectLabel: "lead-checkout",
    sessionName: LEAD_NAME,
  };

  const createdPeer = await sessionVerb(tb.peerApp, tb.peerStreamId, createMessage("session:create", {
    requestId: randomUUID(),
    name: PEER_NAME,
    command: `node ${SINK_SCRIPT_NAME}`,
    mode: "terminal",
    memberOf: leadRef,
    ...(opts.brief === undefined ? {} : { brief: opts.brief }),
  }));
  const peerSessionId: string = createdPeer.session.id;
  await sessionVerb(tb.peerApp, tb.peerStreamId, createMessage("session:start", {
    requestId: randomUUID(), sessionId: peerSessionId,
  }));

  const peerRef: SessionMemberRef = {
    machineId: tb.peerMachineId,
    projectId: tb.peer.projectId,
    sessionId: peerSessionId,
    machineLabel: "Peer laptop",
    projectLabel: "peer-checkout",
    sessionName: PEER_NAME,
  };

  await sessionVerb(tb.lead.app, tb.leadStreamId, createMessage("session:member-record", {
    requestId: randomUUID(), sessionId: leadSessionId, member: peerRef, role: "peer",
  }));

  // Each bridge's own half of every bus address, asserted rather than assumed: a
  // frame addressed to anything else is dropped without an ack, which a row
  // would read as a silent timeout instead of a routing bug.
  const leadRole = await getJson(`${leadApi}/session-bus/role?terminalId=${encodeURIComponent(leadSessionId)}`);
  expect(leadRole.role).toBe("lead");
  expect(leadRole.machineId).toBe(tb.lead.agentDeviceId);
  const peerRole = await getJson(`${peerApi}/session-bus/role?terminalId=${encodeURIComponent(peerSessionId)}`);
  expect(peerRole.role).toBe("peer");
  expect(peerRole.machineId).toBe(tb.peer.agentDeviceId);

  return {
    leadSessionId,
    peerSessionId,
    leadKey: { machineId: tb.leadMachineId, projectId: tb.lead.projectId, sessionId: leadSessionId },
    peerKey: { machineId: tb.peerMachineId, projectId: tb.peer.projectId, sessionId: peerSessionId },
    leadRef,
    peerRef,
    leadAsMemberOf: createdPeer.session.memberOf as SessionMemberOf,
    leadApi,
    peerApi,
  };
}

/** Neither bridge may put a bus frame on the human's phone (spec 4.1). `waitFor`
 *  scans what has already arrived before it waits, so one call covers the whole
 *  run to here and not only the window that follows. */
async function expectNoBusLeak(tb: TwoBridgeEnv, timeoutMs = 3_000): Promise<void> {
  const isBus = (m: any) => typeof m?.type === "string" && m.type.startsWith("session-bus:");
  expect(await tb.lead.app.waitFor(isBus, timeoutMs).catch(() => null)).toBeNull();
  expect(await tb.peer.app.waitFor(isBus, timeoutMs).catch(() => null)).toBeNull();
}

function busFrame(tb: TwoBridgeEnv, match: (m: any) => boolean): any | undefined {
  return tb.carrier.frames.find(match);
}

/**
 * Close B's turn, which is the edge a held delivery drains on.
 *
 * [message] must differ between two closes in the same scenario: `/notify`
 * collapses byte-identical bodies inside a few seconds (a Cursor machine runs
 * two hook tiers and posts every turn-end twice), so a repeated body is dropped
 * before it ever reaches the reduction and the queue waits on an edge that never
 * comes.
 */
async function peerTurnEnd(ex: Expanded, message: string): Promise<void> {
  await postJson(`${ex.peerApi}/notify`, {
    type: "task_complete", terminalId: ex.peerSessionId, message,
  });
}

/**
 * Wait for one frame of a task to CROSS and for the far side to acknowledge it.
 *
 * Waiting on the ack is not belt-and-braces: the coordinator keeps one report in
 * flight per task, so a peer that reported again before its previous transition
 * was acked is refused AGENT_NOT_READY. The ack is also the only evidence the
 * frame was applied on the machine it was addressed to rather than merely
 * handed to the carrier.
 */
async function crossAndAck(
  tb: TwoBridgeEnv,
  taskId: string,
  match: (m: any) => boolean,
  what: string,
): Promise<any> {
  const frame = await until(
    () => busFrame(tb, (m) => m.taskId === taskId && match(m)),
    20_000, what,
  );
  await until(
    () => busFrame(tb, (m) =>
      m.type === "session-bus:ack" && m.taskId === taskId && m.seq === frame.seq
      && m.to.machineId === frame.from.machineId),
    20_000, `the ack of ${what}`,
  );
  return frame;
}

async function listSessions(app: TwoBridgeEnv["peerApp"], streamId: string): Promise<any[]> {
  const requestId = randomUUID();
  const replyP = app.waitFor(
    (m: any) => m._streamId === streamId && m.type === "session:list:result" && m.requestId === requestId,
    15_000,
  );
  app.sendOnStream(streamId, createMessage("session:list", { requestId } as never));
  return (await replyP).sessions ?? [];
}

async function taskView(api: string, terminalId: string, taskId: string): Promise<any | undefined> {
  const res = await getJson(`${api}/session-bus/tasks?terminalId=${encodeURIComponent(terminalId)}`);
  return (res.tasks ?? []).find((t: any) => t.taskId === taskId);
}

// --- S1 ---------------------------------------------------------------------

test("Expand: each bridge writes its own half, and B's Capability Card names the repo", async () => {
  const sinks = newSinks();
  let tb: TwoBridgeEnv | undefined;
  try {
    tb = await setupTwoBridgeEnv({
      prepareProject: writeSinkAndRepo,
      leadEnv: { ANTGRID_EVAL_SINK: sinks.lead },
      peerEnv: { ANTGRID_EVAL_SINK: sinks.peer },
    });
    const ex = await expand(tb);

    // The lead's half: one active member, on the machine that answered above.
    const leadSession = await getJson(
      `${ex.leadApi}/session-bus/session?terminalId=${encodeURIComponent(ex.leadSessionId)}`,
    );
    expect(leadSession.members.length).toBe(1);
    expect(leadSession.members[0].state).toBe("active");
    expect(leadSession.members[0].machineId).toBe(tb.peerMachineId);
    expect(leadSession.members[0].sessionId).toBe(ex.peerSessionId);
    expect(leadSession.memberOf).toBeUndefined();

    // The peer's half, written by the peer bridge and never by the lead's.
    const peerSession = await getJson(
      `${ex.peerApi}/session-bus/session?terminalId=${encodeURIComponent(ex.peerSessionId)}`,
    );
    expect(peerSession.memberOf.state).toBe("active");
    expect(peerSession.memberOf.machineId).toBe(tb.leadMachineId);
    expect(peerSession.memberOf.sessionId).toBe(ex.leadSessionId);
    expect(peerSession.members.length).toBe(0);

    // D10: a peer diagnoses the machine as it is, so it may not be given a
    // worktree of its own. Refused by the bridge, not by the sender — the app is
    // not the thing being trusted here.
    const refused = await sessionVerbResult(tb.peerApp, tb.peerStreamId, createMessage("session:create", {
      requestId: randomUUID(),
      name: "isolated peer",
      command: `node ${SINK_SCRIPT_NAME}`,
      mode: "terminal",
      memberOf: ex.leadRef,
      isolation: "worktree",
    }));
    expect(refused.ok).toBe(false);
    expect(String(refused.error)).toContain("worktree isolation");

    // The Capability Card over B's own loopback control socket. The relay plane
    // answers the same question as `machine.capability-card`; this is the half
    // the desktop asks about its OWN machine, and the only place the NORMALISED
    // remote is produced.
    const card = await postJson(`http://127.0.0.1:${tb.peerHost.controlPort}/control`, {
      id: randomUUID(),
      type: "machine:capability-card",
      projects: [{ projectId: tb.peer.projectId, projectPath: tb.peer.projectDir, label: "peer checkout" }],
    }, tb.peerHost.token);
    expect(card.ok).toBe(true);
    expect(typeof card.os.name).toBe("string");
    expect(typeof card.os.version).toBe("string");
    expect(typeof card.os.arch).toBe("string");
    const repo = card.projects[tb.peer.projectId];
    expect(repo.label).toBe("peer checkout");
    expect(repo.remote).toBe(REMOTE_KEY);
    expect(typeof repo.branch).toBe("string");

    await expectNoBusLeak(tb);
  } finally {
    await tb?.teardown();
    dropSinks(sinks);
  }
}, ROW_TIMEOUT_MS);

// --- S2 ---------------------------------------------------------------------

test("The brief is held for the peer's Handler and is never a delivered line", async () => {
  const sinks = newSinks();
  let tb: TwoBridgeEnv | undefined;
  try {
    tb = await setupTwoBridgeEnv({
      prepareProject: writeSink,
      leadEnv: { ANTGRID_EVAL_SINK: sinks.lead },
      peerEnv: { ANTGRID_EVAL_SINK: sinks.peer },
    });
    const ex = await expand(tb, { brief: BRIEF });

    // Held, not delivered. A peer session is created before its agent runs, so
    // the brief waits in a slot that is persisted-only and never on the wire —
    // the store is the one place this fact exists.
    const pending = persistedSessions(tb.peer.abDir, tb.peer.projectId)
      .find((s) => s.id === ex.peerSessionId);
    expect(pending?.pendingBrief).toBe(BRIEF);

    // The durable copy the peer keeps beside it. Every later task restates its
    // mandate from THIS record's scope, not from whatever the Handler was
    // handed, which is why the two are stored separately.
    const stored = await getJson(
      `${ex.peerApi}/session-bus/brief?terminalId=${encodeURIComponent(ex.peerSessionId)}`,
    );
    expect(stored.brief).toBe(BRIEF);
    expect(stored.lead.sessionId).toBe(ex.leadSessionId);
    expect(stored.lead.machineId).toBe(tb.leadMachineId);
    expect(stored.scope).toEqual(declaredScope(BRIEF));

    // The claim this row exists for: a brief is NOT one of the four delivery
    // kinds. Its only route into the agent is `flushPendingBrief` ->
    // `handlerEngine.instruct` at arm time, so nothing was queued for the
    // terminal and nothing was typed into it — an agent that has not been armed
    // must never find another machine's words on its stdin.
    expect(queuedLines(tb.peer.abDir, tb.peer.projectId, ex.peerSessionId).length).toBe(0);
    expect(sinkText(sinks.peer)).toBe("");
    await sleep(1_000);
    expect(sinkText(sinks.peer)).toBe("");

    // The lead's side of the same claim: creating a peer sends nothing.
    expect(queuedLines(tb.lead.abDir, tb.lead.projectId, ex.leadSessionId).length).toBe(0);
    expect(sinkText(sinks.lead)).toBe("");

    await expectNoBusLeak(tb);
  } finally {
    await tb?.teardown();
    dropSinks(sinks);
  }
}, ROW_TIMEOUT_MS);

// --- S3 ---------------------------------------------------------------------

test("Assign, ack and report cross two bridges, each delivered at its own turn boundary", async () => {
  const sinks = newSinks();
  let tb: TwoBridgeEnv | undefined;
  try {
    tb = await setupTwoBridgeEnv({
      prepareProject: writeSink,
      leadEnv: { ANTGRID_EVAL_SINK: sinks.lead },
      peerEnv: { ANTGRID_EVAL_SINK: sinks.peer },
    });
    const ex = await expand(tb, { brief: BRIEF });

    const TASK_SUMMARY = "Reproduce the suite failure on your machine";
    // The canary proves the raw instruction only ever reaches the terminal
    // INSIDE the fence — it is never submitted on its own.
    const CANARY = "canary-a3f19c";
    const INSTRUCTION = `Run the web suite and report the first failing assertion. ${CANARY}`;
    const REPORT_SUMMARY = "The failing suite is a stale generated client, not the migration.";

    // Both turns are opened before any bus traffic, so no window exists in which
    // a delivery could be submitted for a reason other than the boundary under
    // test.
    await postJson(`${ex.peerApi}/turn-start`, { terminalId: ex.peerSessionId });
    await postJson(`${ex.leadApi}/turn-start`, { terminalId: ex.leadSessionId });

    const assigned = await postJson(
      `${ex.leadApi}/session-bus/tasks?terminalId=${encodeURIComponent(ex.leadSessionId)}`,
      { peer: ex.peerSessionId, summary: TASK_SUMMARY, instruction: INSTRUCTION },
    );
    expect(assigned.ok).toBe(true);
    const taskId: string = assigned.taskId;

    // (a) the assign leaves A addressed to B and (b) B applies it and acks,
    // which is what retires A's outbox entry. The carrier is the only thing that
    // saw either.
    const assign = await crossAndAck(tb, taskId,
      (m) => m.type === "session-bus:assign",
      "the assign frame on the lead's loopback leg");
    expect(assign.from).toEqual(ex.leadKey);
    expect(assign.to).toEqual(ex.peerKey);
    expect(assign.seq).toBe(0);

    // (c) held on B while its turn is open, as the exact template — the wrapper
    // is the whole point: the lead's words are DATA inside a fence, and the
    // scope block restates the brief the peer was created with.
    const held = await until(
      () => queuedLines(tb!.peer.abDir, tb!.peer.projectId, ex.peerSessionId).find((l) => l.kind === "task"),
      20_000, "the task line to be queued on B",
    );
    expect(held.text).toBe(renderTask({
      lead: ex.leadAsMemberOf,
      taskId,
      summary: TASK_SUMMARY,
      instruction: INSTRUCTION,
      scope: briefScope(tb.peer.abDir, tb.peer.projectId, ex.peerSessionId),
      artifacts: [],
    }));
    expect(sinkText(sinks.peer)).toBe("");
    await sleep(1_000);
    expect(sinkText(sinks.peer)).toBe("");

    // (d) the turn closes, and exactly one line is submitted.
    await postJson(`${ex.peerApi}/notify`, {
      type: "task_complete", terminalId: ex.peerSessionId, message: "done",
    });
    const peerSubmitted = await until(
      () => { const t = sinkText(sinks.peer); return t.includes(TASK_MARKER) ? t : undefined; },
      25_000, "the task line to reach B's PTY",
    );
    expect(countMarkers(peerSubmitted, TASK_MARKER)).toBe(1);
    expect(peerSubmitted).toContain(TASK_SUMMARY);
    expect(peerSubmitted).toContain(CANARY);
    await until(
      () => (queuedLines(tb!.peer.abDir, tb!.peer.projectId, ex.peerSessionId).length === 0 ? true : undefined),
      15_000, "B's queue to drop the delivered line",
    );

    // (e) B reports back along the documented path: open, then complete. Opening
    // is no longer a precondition — `submitted` reaches `completed` directly,
    // because a peer holds no tool to see whether it made the call — so this
    // covers the courtesy transition rather than a gate.
    const opened = await postJson(
      `${ex.peerApi}/session-bus/tasks/${encodeURIComponent(taskId)}/open?terminalId=${encodeURIComponent(ex.peerSessionId)}`,
      {},
    );
    expect(opened.ok).toBe(true);
    await crossAndAck(tb, taskId,
      (m) => m.type === "session-bus:transition" && m.state === "working",
      "B's working transition");

    const completed = await postJson(
      `${ex.peerApi}/session-bus/tasks/${encodeURIComponent(taskId)}/complete?terminalId=${encodeURIComponent(ex.peerSessionId)}`,
      { summary: REPORT_SUMMARY, text: "regenerate the prisma client and it passes" },
    );
    expect(completed.ok).toBe(true);

    const transition = await crossAndAck(tb, taskId,
      (m) => m.type === "session-bus:transition" && m.state === "completed",
      "B's completion transition on the peer leg");
    expect(transition.from).toEqual(ex.peerKey);
    expect(transition.to).toEqual(ex.leadKey);

    // (f) the wake is held on A until ITS turn closes.
    const heldWake = await until(
      () => queuedLines(tb!.lead.abDir, tb!.lead.projectId, ex.leadSessionId).find((l) => l.kind === "wake"),
      20_000, "the wake line to be queued on A",
    );
    // The body travels with the wake, not just the summary line: the card is
    // what the lead reads in the turn the result arrives.
    expect(heldWake.text).toBe(renderWake({
      peer: ex.peerRef,
      taskId,
      state: "completed",
      summary: REPORT_SUMMARY,
      result: "regenerate the prisma client and it passes",
    }));
    expect(heldWake.text).toContain("regenerate the prisma client and it passes");
    // Read twice with a settle in between, as on the peer direction: `until`
    // returns the instant the QUEUE file shows the line, and a submission racing
    // it would still be behind its own PTY round trip (submit -> pty -> sink ->
    // append), so a single read here would pass on a boundary that no longer
    // holds anything.
    expect(sinkText(sinks.lead)).toBe("");
    await sleep(1_000);
    expect(sinkText(sinks.lead)).toBe("");

    await postJson(`${ex.leadApi}/notify`, {
      type: "task_complete", terminalId: ex.leadSessionId, message: "done",
    });
    const leadSubmitted = await until(
      () => { const t = sinkText(sinks.lead); return t.includes(WAKE_MARKER) ? t : undefined; },
      25_000, "the wake line to reach A's PTY",
    );
    expect(countMarkers(leadSubmitted, WAKE_MARKER)).toBe(1);
    expect(leadSubmitted).toContain(REPORT_SUMMARY);

    // The task is terminal on the machine that assigned it.
    const leadTask = await untilAsync(
      async () => {
        const t = await taskView(ex.leadApi, ex.leadSessionId, taskId);
        return t?.state === "completed" ? t : undefined;
      },
      20_000, "A's task record to reach completed",
    );
    expect(leadTask.role).toBe("lead");

    // Both directions, after the whole exchange.
    await expectNoBusLeak(tb);
  } finally {
    await tb?.teardown();
    dropSinks(sinks);
  }
}, ROW_TIMEOUT_MS);

// --- S4 ---------------------------------------------------------------------

test("A cancel crosses, lands at the next turn boundary, and closes the task on both bridges", async () => {
  const sinks = newSinks();
  let tb: TwoBridgeEnv | undefined;
  try {
    tb = await setupTwoBridgeEnv({
      prepareProject: writeSink,
      leadEnv: { ANTGRID_EVAL_SINK: sinks.lead },
      peerEnv: { ANTGRID_EVAL_SINK: sinks.peer },
    });
    const ex = await expand(tb, { brief: BRIEF });

    const CANCEL_REASON = "The suite was fixed upstream; stop before you spend a run on it.";

    await postJson(`${ex.peerApi}/turn-start`, { terminalId: ex.peerSessionId });
    const assigned = await postJson(
      `${ex.leadApi}/session-bus/tasks?terminalId=${encodeURIComponent(ex.leadSessionId)}`,
      { peer: ex.peerSessionId, summary: "Bisect the regression", instruction: "Bisect from the last green tag." },
    );
    const taskId: string = assigned.taskId;
    await crossAndAck(tb, taskId, (m) => m.type === "session-bus:assign", "the assign frame");
    // Drain the task line so the cancel below is the only thing the next
    // boundary can submit.
    await peerTurnEnd(ex, "bisect started");
    await until(
      () => (sinkText(sinks.peer).includes(TASK_MARKER) ? true : undefined),
      25_000, "the task line to reach B's PTY",
    );

    await postJson(
      `${ex.peerApi}/session-bus/tasks/${encodeURIComponent(taskId)}/open?terminalId=${encodeURIComponent(ex.peerSessionId)}`,
      {},
    );
    await crossAndAck(tb, taskId,
      (m) => m.type === "session-bus:transition" && m.state === "working",
      "B's working transition");
    await untilAsync(
      async () => {
        const t = await taskView(ex.leadApi, ex.leadSessionId, taskId);
        return t?.state === "working" ? t : undefined;
      },
      20_000, "A to see the task working",
    );

    // A fresh turn, so "held rather than submitted" is a claim about the cancel
    // and not a leftover from the task above.
    await postJson(`${ex.peerApi}/turn-start`, { terminalId: ex.peerSessionId });

    const canceled = await postJson(
      `${ex.leadApi}/session-bus/tasks/${encodeURIComponent(taskId)}/cancel?terminalId=${encodeURIComponent(ex.leadSessionId)}`,
      { reason: CANCEL_REASON },
    );
    expect(canceled.ok).toBe(true);

    const cancelFrame = await crossAndAck(tb, taskId,
      (m) => m.type === "session-bus:cancel",
      "the cancel frame on the lead's loopback leg");
    expect(cancelFrame.from).toEqual(ex.leadKey);
    expect(cancelFrame.to).toEqual(ex.peerKey);
    expect(cancelFrame.reason).toBe(CANCEL_REASON);

    const heldCancel = await until(
      () => queuedLines(tb!.peer.abDir, tb!.peer.projectId, ex.peerSessionId).find((l) => l.kind === "cancel"),
      20_000, "the cancel line to be queued on B",
    );
    expect(heldCancel.text).toBe(renderCancel({
      lead: ex.leadAsMemberOf, taskId, reason: CANCEL_REASON,
    }));
    // Held: a stop that interrupts mid-turn is exactly what the queue exists to
    // prevent.
    expect(sinkText(sinks.peer)).not.toContain(CANCEL_MARKER);
    await sleep(1_000);
    expect(sinkText(sinks.peer)).not.toContain(CANCEL_MARKER);

    await peerTurnEnd(ex, "bisect abandoned");
    const peerSubmitted = await until(
      () => { const t = sinkText(sinks.peer); return t.includes(CANCEL_MARKER) ? t : undefined; },
      25_000, "the cancel line to reach B's PTY",
    );
    expect(countMarkers(peerSubmitted, CANCEL_MARKER)).toBe(1);
    expect(peerSubmitted).toContain(CANCEL_REASON);

    // Canceled on the machine that asked and on the machine that was working.
    expect((await taskView(ex.leadApi, ex.leadSessionId, taskId)).state).toBe("canceled");
    expect((await taskView(ex.peerApi, ex.peerSessionId, taskId)).state).toBe("canceled");

    // A late completion does not resurrect it: `canceled` has no outgoing
    // transition, so B refuses its own agent rather than minting a frame A would
    // have to reconcile.
    const late = await postJson(
      `${ex.peerApi}/session-bus/tasks/${encodeURIComponent(taskId)}/complete?terminalId=${encodeURIComponent(ex.peerSessionId)}`,
      { summary: "finished anyway" },
    );
    expect(late.code).toBe("TASK_TERMINAL");
    await sleep(1_000);
    expect((await taskView(ex.leadApi, ex.leadSessionId, taskId)).state).toBe("canceled");
    expect(busFrame(tb, (m) =>
      m.type === "session-bus:transition" && m.taskId === taskId && m.state === "completed")).toBeUndefined();

    await expectNoBusLeak(tb);
  } finally {
    await tb?.teardown();
    dropSinks(sinks);
  }
}, ROW_TIMEOUT_MS);

// --- S5 ---------------------------------------------------------------------

test("Delete cascades member by member, and an unreachable machine is recorded rather than obeyed", async () => {
  const sinks = newSinks();
  let tb: TwoBridgeEnv | undefined;
  try {
    tb = await setupTwoBridgeEnv({
      prepareProject: writeSink,
      leadEnv: { ANTGRID_EVAL_SINK: sinks.lead },
      peerEnv: { ANTGRID_EVAL_SINK: sinks.peer },
    });
    const ex = await expand(tb, { brief: BRIEF });

    // A line held for B at the moment it is deleted. The delete has to take the
    // whole half with it: a held line is retried at the head of its session's
    // queue forever, and one belonging to a session that no longer exists would
    // sit against the project-wide cap and evict a live assign.
    await postJson(`${ex.peerApi}/turn-start`, { terminalId: ex.peerSessionId });
    await postJson(
      `${ex.leadApi}/session-bus/tasks?terminalId=${encodeURIComponent(ex.leadSessionId)}`,
      { peer: ex.peerSessionId, summary: "Read the failing suite", instruction: "Report the first failing assertion." },
    );
    await until(
      () => (queuedLines(tb!.peer.abDir, tb!.peer.projectId, ex.peerSessionId).length > 0 ? true : undefined),
      20_000, "the task line to be held for B",
    );

    // The second member is a machine that does not exist. A peer BRIDGE cannot
    // refuse its own delete — the refusal codes (WORKTREE_DIRTY, …) live on the
    // isolated-worktree path, and D10 forbids an isolated peer — so the refused
    // half of a cascade is staged the way it actually happens in the field: a
    // machine the carrier cannot reach.
    const ghost: SessionMemberRef = {
      machineId: randomUUID(),
      projectId: "ghost",
      sessionId: "ghost-session",
      machineLabel: "Unreachable laptop",
      sessionName: "ghost worker",
    };
    await sessionVerb(tb.lead.app, tb.leadStreamId, createMessage("session:member-record", {
      requestId: randomUUID(), sessionId: ex.leadSessionId, member: ghost, role: "peer",
    }));

    // Work addressed to the ghost is minted and then has nowhere to go. It must
    // be visibly undeliverable, never quietly handed to whichever leg is open.
    const toGhost = await postJson(
      `${ex.leadApi}/session-bus/tasks?terminalId=${encodeURIComponent(ex.leadSessionId)}`,
      { peer: ghost.sessionId, summary: "Check the other machine", instruction: "Report the branch you are on." },
    );
    expect(toGhost.ok).toBe(true);
    await until(
      () => (tb!.carrier.droppedToPeer.some((m: any) => m.to?.machineId === ghost.machineId) ? true : undefined),
      20_000, "the ghost's assign to be recorded as undeliverable",
    );
    expect(tb.carrier.droppedToPeer.every((m: any) => m.to?.machineId === ghost.machineId)).toBe(true);

    const busDirPeer = sessionBusSessionDir(tb.peer.abDir, tb.peer.projectId, ex.peerSessionId);
    const busDirLead = sessionBusSessionDir(tb.lead.abDir, tb.lead.projectId, ex.leadSessionId);
    expect(existsSync(busDirPeer)).toBe(true);
    expect(existsSync(busDirLead)).toBe(true);

    // The cascade is the app's, one delete per member: no bridge can issue this
    // on another's behalf.
    await sessionVerb(tb.peerApp, tb.peerStreamId, createMessage("session:delete", {
      requestId: randomUUID(), sessionId: ex.peerSessionId, force: true,
    }));
    const afterPeer = await sessionVerb(tb.lead.app, tb.leadStreamId, createMessage("session:member-release", {
      requestId: randomUUID(), sessionId: ex.leadSessionId, member: ex.peerKey,
    }));
    const afterGhost = await sessionVerb(tb.lead.app, tb.leadStreamId, createMessage("session:member-release", {
      requestId: randomUUID(),
      sessionId: ex.leadSessionId,
      member: { machineId: ghost.machineId, projectId: ghost.projectId, sessionId: ghost.sessionId },
      deleteRefused: true,
      reason: "machine unreachable",
    }));

    const memberFor = (session: any, sessionId: string) =>
      (session.members ?? []).find((m: any) => m.sessionId === sessionId);
    expect(memberFor(afterPeer.session, ex.peerSessionId).state).toBe("released");
    expect(typeof memberFor(afterPeer.session, ex.peerSessionId).releasedAt).toBe("number");
    const ghostRow = memberFor(afterGhost.session, ghost.sessionId);
    expect(ghostRow.state).toBe("released-delete-refused");
    expect(ghostRow.releaseReason).toBe("machine unreachable");
    // History, not liveness: a departed member is a rendered line and stays on
    // the row.
    expect(afterGhost.session.members.length).toBe(2);

    // Idempotent, and a member this row never held is a success rather than an
    // error — the app calls this after the peer bridge answered, and the answer
    // can arrive twice.
    const repeat = await sessionVerb(tb.lead.app, tb.leadStreamId, createMessage("session:member-release", {
      requestId: randomUUID(), sessionId: ex.leadSessionId, member: ex.peerKey,
    }));
    expect(memberFor(repeat.session, ex.peerSessionId).state).toBe("released");
    expect(repeat.session.members.length).toBe(2);
    const unknown = await sessionVerb(tb.lead.app, tb.leadStreamId, createMessage("session:member-release", {
      requestId: randomUUID(),
      sessionId: ex.leadSessionId,
      member: { machineId: randomUUID(), projectId: "nowhere", sessionId: "never-joined" },
    }));
    expect(unknown.session.members.length).toBe(2);

    // B kept its own half and nothing else: the row is gone from its session
    // list and its bus store went with it.
    const peerSessions = await listSessions(tb.peerApp, tb.peerStreamId);
    expect(peerSessions.some((s: any) => s.id === ex.peerSessionId)).toBe(false);
    expect(existsSync(busDirPeer)).toBe(false);
    expect(queuedLines(tb.peer.abDir, tb.peer.projectId, ex.peerSessionId)).toEqual([]);

    await sessionVerb(tb.lead.app, tb.leadStreamId, createMessage("session:delete", {
      requestId: randomUUID(), sessionId: ex.leadSessionId, force: true,
    }));
    // Polled, not read once: the verb answers off the live SessionManager and the
    // file behind it is flushed after.
    await until(
      () => (persistedSessions(tb!.lead.abDir, tb!.lead.projectId)
        .some((s) => s.id === ex.leadSessionId) ? undefined : true),
      10_000, "A's session row to leave sessions.json",
    );
    expect(existsSync(busDirLead)).toBe(false);
  } finally {
    await tb?.teardown();
    dropSinks(sinks);
  }
}, ROW_TIMEOUT_MS);

// --- S6 ---------------------------------------------------------------------

test("A lost lead orphans the peer's row and deletes nothing, across a peer restart", async () => {
  const sinks = newSinks();
  let tb: TwoBridgeEnv | undefined;
  try {
    tb = await setupTwoBridgeEnv({
      prepareProject: writeSink,
      leadEnv: { ANTGRID_EVAL_SINK: sinks.lead },
      peerEnv: { ANTGRID_EVAL_SINK: sinks.peer },
    });
    const ex = await expand(tb);

    // The lead machine goes away. The peer bridge cannot observe this — the lead
    // is not reachable from here, ever — so the mark is the app's to make.
    await tb.lead.agent.kill();
    tb.carrier.stop();

    const orphaned = await sessionVerb(tb.peerApp, tb.peerStreamId, createMessage("session:member-orphan", {
      requestId: randomUUID(), sessionId: ex.peerSessionId, orphaned: true,
    }));
    expect(orphaned.session.memberOf.state).toBe("orphaned");
    expect(typeof orphaned.session.memberOf.orphanedAt).toBe("number");
    // D11: an absence marks and never deletes. The session is still there, still
    // running, still unarchived.
    expect(orphaned.session.archived).toBe(false);
    expect(orphaned.session.running).toBe(true);

    // The mark is persisted, not a runtime flag: it has to survive the process
    // that made it.
    await tb.peer.restartAgent();
    await tb.rebindPeerLeg();
    const afterRestart = (await listSessions(tb.peerApp, tb.peerStreamId))
      .find((s: any) => s.id === ex.peerSessionId);
    expect(afterRestart).toBeDefined();
    expect(afterRestart.archived).toBe(false);
    expect(afterRestart.memberOf.state).toBe("orphaned");
    expect(typeof afterRestart.memberOf.orphanedAt).toBe("number");

    // And it is reversible: a lead that comes back is not a new session.
    const restored = await sessionVerb(tb.peerApp, tb.peerStreamId, createMessage("session:member-orphan", {
      requestId: randomUUID(), sessionId: ex.peerSessionId, orphaned: false,
    }));
    expect(restored.session.memberOf.state).toBe("active");
    expect(restored.session.memberOf.orphanedAt).toBeUndefined();
    expect(restored.session.memberOf.sessionId).toBe(ex.leadSessionId);
  } finally {
    await tb?.teardown();
    dropSinks(sinks);
  }
}, ROW_TIMEOUT_MS);
