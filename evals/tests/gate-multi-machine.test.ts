import { test, expect, afterEach } from "bun:test";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createMessage } from "../../bridge/src/protocol";
import { loadDeliveries } from "../../bridge/src/session-bus/delivery-queue";
import { setMobileAccess } from "../helpers/harness";
import { setupTwoBridgeEnv, type BridgeMachine, type TwoBridgeEnv } from "../helpers/two-bridge";
import {
  NOTIFY_MARKER,
  SINK_SCRIPT_NAME,
  apiPort,
  busCall,
  countMarkers,
  postJson,
  prepareBusProject,
  sessionVerb,
  sinkText,
  sleep,
  until,
  untilAsync,
  type BusCall,
} from "../support/session-bus";

/**
 * Two real bridges, one relay, one account, and the desktop app that carries
 * every frame between them.
 *
 * Every wait here carries its own deadline and says what it was waiting for.
 * On two machines a bare timeout is indistinguishable from a flake, and the
 * next reader will shrug off the defect rather than the harness.
 */

// Long enough for two bridges, their PTY trees and a shared relay to come up,
// and for a frame to cross both legs of the carrier.
const ROW_TIMEOUT_MS = 240_000;
const CROSS_TIMEOUT_MS = 20_000;
// What a redelivery would need to arrive in. Only ever used to prove nothing
// arrived, so it buys nothing to make it long — the coordinator's outbox tick
// is a second.
const SETTLE_MS = 2_500;

let env: TwoBridgeEnv | undefined;
let sinkDir: string | undefined;

afterEach(async () => {
  await env?.teardown();
  env = undefined;
  // Last, and tolerated: a PTY on either machine may still hold its sink open
  // for a moment after the bridge it belonged to is gone.
  if (sinkDir) try { rmSync(sinkDir, { recursive: true, force: true }); } catch { /* the PTY still has it */ }
  sinkDir = undefined;
});

/** One stdin-sink log per machine. The sink script reads one fixed variable
 *  name, so the two paths have to differ per machine rather than per env. */
function newSinks(): { a: string; b: string } {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-bus-sinks-"));
  sinkDir = dir;
  return { a: join(dir, "machine-a.log"), b: join(dir, "machine-b.log") };
}

/**
 * A session on one machine, running and directory-visible.
 *
 * `session:start` is not optional bookkeeping: work-status opens a turn only
 * for a session it already counts as running, so a stopped session has no
 * boundary for a notify to wait at and is refused `NOT_RUNNING` outright.
 */
async function startBusSession(machine: BridgeMachine, name: string): Promise<string> {
  const created = await sessionVerb(
    machine.env.app,
    machine.streamId,
    createMessage("session:create", {
      requestId: randomUUID(),
      name,
      // A bare command rather than a `tool`: the fixture declares no agent, and
      // these sessions only have to record what the bridge submits into them.
      command: `node ${SINK_SCRIPT_NAME}`,
      mode: "terminal",
    }),
  );
  const sessionId = created.session.id as string;
  await sessionVerb(
    machine.env.app,
    machine.streamId,
    createMessage("session:start", { requestId: randomUUID(), sessionId }),
  );
  return sessionId;
}

/** What a poll last actually saw. A deadline alone says a row never appeared;
 *  this says what the bridge was answering instead, which is the half that
 *  names the bug. */
function lastAnswer(call: BusCall | undefined): string {
  return call === undefined ? "the probe never answered at all" : `${call.status} ${JSON.stringify(call.body)}`;
}

/** This machine's own directory read, over loopback. Loopback and not the
 *  project stream on purpose: the rows below are asserted in windows where a
 *  switch is off, and a relay-origin verb is refused in every one of them. */
async function readDirectory(machine: BridgeMachine, sessionId: string): Promise<BusCall> {
  return busCall(machine.env.abDir, "sessions", { terminalId: sessionId });
}

/** As {@link readDirectory}, for a read a row takes as given.
 *
 *  Asserting and reading are split because a poll must not assert: a throw
 *  inside an `untilAsync` closure escapes the poll instead of being retried, so
 *  one transient non-200 during warm-up retires the deadline and the message
 *  that were supposed to report the failure. */
async function directory(machine: BridgeMachine, sessionId: string): Promise<any> {
  const res = await readDirectory(machine, sessionId);
  expect(res.status).toBe(200);
  return res.body;
}

async function peerRow(
  machine: BridgeMachine,
  sessionId: string,
  peer: BridgeMachine,
  peerSessionId: string,
): Promise<any> {
  let last: BusCall | undefined;
  try {
    return await untilAsync(
      async () => {
        last = await readDirectory(machine, sessionId);
        if (last.status !== 200) return undefined;
        return (last.body.sessions ?? []).find(
          (r: any) => r.sessionId === peerSessionId && r.machineId === peer.machineId,
        );
      },
      CROSS_TIMEOUT_MS,
      `machine ${machine.name} to offer a directory row for session ${peerSessionId} on machine ${peer.name}`,
    );
  } catch (err) {
    throw new Error(`${(err as Error).message}; last directory read: ${lastAnswer(last)}`);
  }
}

/** The address a send names, taken from the row rather than assembled from what
 *  the harness believes: a target the directory does not actually offer refuses
 *  `UNKNOWN_PEER`, which reads as a routing bug rather than a wrong address. */
function addressOf(row: any): { machineId: string; projectId: string; sessionId: string } {
  return { machineId: row.machineId, projectId: row.projectId, sessionId: row.sessionId };
}

async function readInbox(machine: BridgeMachine, sessionId: string): Promise<BusCall> {
  return busCall(machine.env.abDir, "inbox", { terminalId: sessionId });
}

/** As {@link readInbox}, asserting. Split for the same reason as
 *  {@link directory} — see there. */
async function inbox(machine: BridgeMachine, sessionId: string): Promise<any> {
  const res = await readInbox(machine, sessionId);
  expect(res.status).toBe(200);
  return res.body;
}

/** Poll the mailbox until it holds something. Reading marks read, so the poll
 *  that finds the post is the one that consumes it — every earlier poll saw an
 *  empty mailbox and marked nothing. */
async function awaitPost(machine: BridgeMachine, sessionId: string, what: string): Promise<any> {
  let last: BusCall | undefined;
  try {
    return await untilAsync(
      async () => {
        last = await readInbox(machine, sessionId);
        if (last.status !== 200) return undefined;
        return (last.body.posts ?? []).length > 0 ? last.body : undefined;
      },
      CROSS_TIMEOUT_MS,
      what,
    );
  } catch (err) {
    throw new Error(`${(err as Error).message}; last mailbox read: ${lastAnswer(last)}`);
  }
}

async function readThread(machine: BridgeMachine, sessionId: string, threadId: string): Promise<BusCall> {
  return busCall(machine.env.abDir, "thread", { terminalId: sessionId, query: { threadId } });
}

/** One thread's outbound entries, as the SENDER's own surface reads them. The
 *  receipt lives here and nowhere else: a send that was answered but never
 *  arrived differs from a delivered one only by a missing `deliveredAt`. */
async function outEntries(machine: BridgeMachine, sessionId: string, threadId: string): Promise<any[]> {
  const res = await readThread(machine, sessionId, threadId);
  expect(res.status).toBe(200);
  return (res.body.entries ?? []).filter((e: any) => e.direction === "out");
}

/** Wait for one message's receipt to come home. The only proof of arrival a
 *  sender ever gets: the verb's own answer says the frame left this machine and
 *  nothing more, so every "it was heard" below waits here. */
async function awaitReceipt(
  machine: BridgeMachine,
  sessionId: string,
  threadId: string,
  summary: string,
): Promise<any> {
  let last: BusCall | undefined;
  try {
    return await untilAsync(
      async () => {
        last = await readThread(machine, sessionId, threadId);
        if (last.status !== 200) return undefined;
        const entry = (last.body.entries ?? []).find(
          (e: any) => e.direction === "out" && e.summary === summary,
        );
        return entry?.deliveredAt !== undefined ? entry : undefined;
      },
      CROSS_TIMEOUT_MS,
      `the receipt for "${summary}" to come home to session ${sessionId} on machine ${machine.name}`,
    );
  } catch (err) {
    throw new Error(`${(err as Error).message}; last thread read: ${lastAnswer(last)}`);
  }
}

async function agentReach(machine: BridgeMachine, enabled: boolean): Promise<void> {
  const res = await postJson(
    `http://127.0.0.1:${machine.host.controlPort}/control`,
    { id: `bus-reach-${randomUUID()}`, type: "agent-reach:set", enabled },
    machine.host.token,
  );
  expect(res.ok).toBe(true);
  expect(res.enabled).toBe(enabled);
}

/** Both machines' rows into the other's mirror, asserted rather than assumed:
 *  an empty mirror refuses every cross-machine send `UNKNOWN_PEER`, which is
 *  also what half the rows below assert on purpose. */
async function pumpAndExpectRows(carrier: TwoBridgeEnv["carrier"]): Promise<void> {
  const pushes = await carrier.pumpDirectory();
  expect(pushes).toHaveLength(2);
  for (const push of pushes) {
    expect(`${push.into}<-${push.about}: ${push.outcome}${push.why ? ` (${push.why})` : ""}`).toBe(
      `${push.into}<-${push.about}: rows`,
    );
    expect(push.ack.ok).toBe(true);
    expect(push.ack.accepted).toBeGreaterThan(0);
  }
}

test("a message crosses to the other machine, comes back receipted, and refuses at the verb when the carrier is gone", async () => {
  const sinks = newSinks();
  env = await setupTwoBridgeEnv({
    prepareProject: prepareBusProject,
    envA: { ANTGRID_EVAL_SINK: sinks.a },
    envB: { ANTGRID_EVAL_SINK: sinks.b },
  });
  const { a, b, carrier } = env;
  const sessionA = await startBusSession(a, "alpha");
  const sessionB = await startBusSession(b, "beta");

  // No bridge can ask another what it is running, so the app's pump is the only
  // thing that ever makes a peer addressable.
  await pumpAndExpectRows(carrier);

  const dirA = await directory(a, sessionA);
  // The id every address below is stamped with, proven against the bridge's own
  // answer: a frame addressed to any other id is dropped unacked, so a wrong
  // assumption here would surface as a silent timeout further down.
  expect(dirA.machineId).toBe(a.machineId);
  const target = addressOf(await peerRow(a, sessionA, b, sessionB));

  const POST_SUMMARY = "The generated client is stale; the migration is fine.";
  const posted = await busCall(a.env.abDir, "post", {
    terminalId: sessionA,
    body: { to: target, summary: POST_SUMMARY, text: "Regenerate before rerunning the suite." },
  });
  expect(posted.status).toBe(200);
  expect(posted.body.ok).toBe(true);
  expect(posted.body.sent).toBe(true);
  expect(posted.body.held).toBe(false);

  const mail = await awaitPost(b, sessionB, `the post from machine a to land in session ${sessionB}'s mailbox on machine b`);
  expect(mail.posts).toHaveLength(1);
  expect(mail.posts[0].summary).toBe(POST_SUMMARY);
  expect(mail.posts[0].from.machineId).toBe(a.machineId);
  expect(mail.posts[0].from.sessionId).toBe(sessionA);
  expect(mail.dropped).toBe(0);
  // A post is read when its target chooses, so it must reach no terminal on the
  // way — a post that rendered a line would interrupt the peer exactly as a
  // notify does, and nothing downstream would report the difference.
  expect(countMarkers(sinkText(sinks.b), NOTIFY_MARKER)).toBe(0);

  const portB = await apiPort(b.env.abDir);
  // A turn is opened on the receiver so the notify below has a boundary to wait
  // at: an idle session reaches one immediately, which would prove the frame
  // crossed but nothing about when it is allowed to speak.
  await postJson(`http://127.0.0.1:${portB}/turn-start`, { terminalId: sessionB });

  const NOTIFY_SUMMARY = "Main is red on the same two tests; stop rebasing onto it.";
  const notified = await busCall(a.env.abDir, "notify", {
    terminalId: sessionA,
    body: { to: target, summary: NOTIFY_SUMMARY, text: "Both failures predate your branch." },
  });
  expect(notified.status).toBe(200);
  expect(notified.body.ok).toBe(true);
  expect(notified.body.sent).toBe(true);
  const threadId = notified.body.threadId as string;

  // The receiving bridge's own queue, which is written before a line is
  // submitted and cleared only once it went in. Waiting on it is what makes the
  // "nothing reached the terminal" assertion below a statement about the turn
  // boundary rather than about a frame that never crossed at all.
  const queued = await untilAsync(
    async () => {
      const lines = loadDeliveries(b.env.abDir, b.env.projectId).lines.filter((l) => l.sessionId === sessionB);
      return lines.length > 0 ? lines : undefined;
    },
    CROSS_TIMEOUT_MS,
    `the notify from machine a to be queued for session ${sessionB} on machine b`,
  );
  expect(queued).toHaveLength(1);
  expect(queued[0]!.kind).toBe("notify");
  expect(countMarkers(sinkText(sinks.b), NOTIFY_MARKER)).toBe(0);

  await postJson(`http://127.0.0.1:${portB}/notify`, {
    type: "task_complete",
    terminalId: sessionB,
    message: `turn closed ${randomUUID()}`,
  });
  await until(
    () => (countMarkers(sinkText(sinks.b), NOTIFY_MARKER) === 1 ? true : undefined),
    CROSS_TIMEOUT_MS,
    `the queued notify to be submitted into session ${sessionB} once its turn closed`,
  );
  await sleep(SETTLE_MS);
  expect(countMarkers(sinkText(sinks.b), NOTIFY_MARKER)).toBe(1);

  const receipt = await awaitReceipt(a, sessionA, threadId, NOTIFY_SUMMARY);
  expect(receipt.deliveredAt).toBeGreaterThan(0);
  // One receipt for one message: an ack keyed loosely enough to stamp a sibling
  // would read here as delivery and there as silence.
  expect(await outEntries(a, sessionA, threadId)).toHaveLength(1);

  // The desktop app on machine a quits. It is the only thing that carries a
  // frame off this machine, and an agent reads every answer but a refusal as
  // delivered — so a send here has to REFUSE rather than answer held, or the
  // agent believes it said something nobody will ever receive.
  carrier.detachApp("a");
  const ORPHAN_SUMMARY = "Nobody carried this one.";
  const orphan = await busCall(a.env.abDir, "post", {
    terminalId: sessionA,
    body: { to: target, summary: ORPHAN_SUMMARY, text: "Sent with no desktop attached." },
  });
  expect(orphan.status).toBe(503);
  expect(orphan.body.code).toBe("PEER_UNREACHABLE");
  expect(orphan.body.ok).toBeUndefined();

  await sleep(SETTLE_MS);
  expect((await inbox(b, sessionB)).posts).toHaveLength(0);

  // The app comes back and the same message crosses — once. A refusal that
  // secretly queued the frame would deliver it here as well as the resend, and
  // the receiver is the only place that shows the difference.
  await carrier.attachApp("a");
  const resent = await busCall(a.env.abDir, "post", {
    terminalId: sessionA,
    body: { to: target, summary: ORPHAN_SUMMARY, text: "Sent with no desktop attached." },
  });
  expect(resent.status).toBe(200);
  expect(resent.body.sent).toBe(true);

  const redelivered = await awaitPost(b, sessionB, `the resent post to reach session ${sessionB} once machine a's desktop came back`);
  expect(redelivered.posts).toHaveLength(1);
  expect(redelivered.posts[0].summary).toBe(ORPHAN_SUMMARY);
  await sleep(SETTLE_MS);
  expect((await inbox(b, sessionB)).posts).toHaveLength(0);
}, ROW_TIMEOUT_MS);

test("a switch at either end stops a cross-machine send, and only the sender's own refuses where the agent can read it", async () => {
  const sinks = newSinks();
  env = await setupTwoBridgeEnv({
    prepareProject: prepareBusProject,
    envA: { ANTGRID_EVAL_SINK: sinks.a },
    envB: { ANTGRID_EVAL_SINK: sinks.b },
  });
  const { a, b, carrier } = env;
  const sessionA = await startBusSession(a, "alpha");
  const sessionB = await startBusSession(b, "beta");

  await pumpAndExpectRows(carrier);
  const target = addressOf(await peerRow(a, sessionA, b, sessionB));

  const body = (summary: string) => ({ to: target, summary, text: "Two switches, two answers." });

  /** Everything the sender can observe about a send nothing travelled back
   *  from: the verb's own answer, that the target's mailbox stayed empty, and
   *  that the thread never receipted.
   *
   *  An absent receipt is read against the delivered opener below, which takes
   *  this same path with both switches on. */
  async function sendWithReceiverShut(summary: string): Promise<BusCall> {
    const answer = await busCall(a.env.abDir, "post", { terminalId: sessionA, body: body(summary) });
    await sleep(SETTLE_MS);
    expect((await inbox(b, sessionB)).posts).toHaveLength(0);
    const out = await outEntries(a, sessionA, answer.body.threadId);
    expect(out).toHaveLength(1);
    expect(out[0].summary).toBe(summary);
    expect(out[0].deliveredAt).toBeUndefined();
    return answer;
  }

  // One exchange while both ends are willing, and the control every silence
  // below is read against: it is the same verb, the same address and the same
  // receipt path, so a missing `deliveredAt` after a switch flip is the switch
  // and not a receipt this pair never gets.
  const OPENER = "Both ends willing, and this one arrived.";
  const opened = await busCall(a.env.abDir, "post", { terminalId: sessionA, body: body(OPENER) });
  expect(opened.status).toBe(200);
  const openerMail = await awaitPost(b, sessionB, `the opening post to reach session ${sessionB} with both switches on`);
  expect(openerMail.posts).toHaveLength(1);
  expect(openerMail.posts[0].summary).toBe(OPENER);
  expect((await awaitReceipt(a, sessionA, opened.body.threadId, OPENER)).deliveredAt).toBeGreaterThan(0);

  // §6.3's RECEIVING half, against a mirror that is still warm. Deliberately
  // not pumped: a push in this window empties a's mirror, and the send would
  // then be refused by machine a's own row lookup without the frame ever
  // reaching machine b's inbound gate.
  //
  // Nothing travels back to say the frame was dropped, so the sender is told it
  // left — which is the whole failure this row exists to pin.
  await agentReach(b, false);
  const unreached = await sendWithReceiverShut("Reach is off over there.");
  expect(unreached.status).toBe(200);
  expect(unreached.body.ok).toBe(true);
  expect(unreached.body.sent).toBe(true);
  expect(unreached.body.held).toBe(false);
  await agentReach(b, true);

  // The same switch one pump later, which is a different fact: b answers no
  // session-bearing card, so its rows leave a's mirror and the send is refused
  // here rather than dropped there.
  await agentReach(b, false);
  const refusedPushes = await carrier.pumpDirectory();
  const intoA = refusedPushes.find((p) => p.into === "a")!;
  expect(intoA.about).toBe("b");
  expect(intoA.outcome).toBe("reach-refused");
  expect(intoA.rows).toHaveLength(0);
  expect(intoA.ack.ok).toBe(true);

  const unknown = await busCall(a.env.abDir, "post", { terminalId: sessionA, body: body("Nobody to address.") });
  expect(unknown.status).toBe(404);
  expect(unknown.body.code).toBe("UNKNOWN_PEER");

  // The refusal alone would send the agent hunting for a wrong address, so the
  // directory has to name the machine and say which switch it was.
  const reachDir = await directory(a, sessionA);
  expect((reachDir.sessions ?? []).some((r: any) => r.sessionId === sessionB)).toBe(false);
  expect(reachDir.reach.scope).toBe("network");
  const reachLine = (reachDir.reach.machines ?? []).find((m: any) => m.machineId === b.machineId);
  expect(reachLine?.status).toBe("reach-refused");
  expect(reachLine?.rows).toBe(0);

  await agentReach(b, true);
  await pumpAndExpectRows(carrier);
  await peerRow(a, sessionA, b, sessionB);

  // Machine a stops letting anything leave. Deliberately NOT pumped in this
  // window: a push into a machine with remote access off is refused AND empties
  // its mirror, which would turn the answer below into UNKNOWN_PEER and hide
  // the outbound gate this row exists to prove.
  await setMobileAccess(a.env.abDir, false);
  const blocked = await busCall(a.env.abDir, "post", { terminalId: sessionA, body: body("Nothing leaves this machine.") });
  expect(blocked.status).toBe(403);
  expect(blocked.body.code).toBe("REMOTE_ACCESS_OFF");

  await sleep(SETTLE_MS);
  expect((await inbox(b, sessionB)).posts).toHaveLength(0);

  // Turning the switch back on restores nothing by itself: flipping it OFF
  // empties this machine's mirror on the spot (`mobile-access:set`,
  // host-server.ts), so the address taken before it is stale until the app
  // pushes rows again.
  await setMobileAccess(a.env.abDir, true);
  await pumpAndExpectRows(carrier);
  await peerRow(a, sessionA, b, sessionB);

  const BOTH_ON = "Both switches on, and only then.";
  const sent = await busCall(a.env.abDir, "post", { terminalId: sessionA, body: body(BOTH_ON) });
  expect(sent.status).toBe(200);
  expect(sent.body.ok).toBe(true);
  expect(sent.body.sent).toBe(true);

  const delivered = await awaitPost(b, sessionB, `the post to reach session ${sessionB} with both switches back on`);
  expect(delivered.posts).toHaveLength(1);
  expect(delivered.posts[0].summary).toBe(BOTH_ON);

  // The receiver's OTHER switch, and last in this row because turning it off
  // tears down that machine's relay slots for good. Silent in the same way
  // agent reach was: nothing travels back, so the sender is told the frame
  // left while the machine it named admits no relay-origin frame at all.
  await setMobileAccess(b.env.abDir, false);
  const unadmitted = await sendWithReceiverShut("Nothing enters that machine.");
  expect(unadmitted.status).toBe(200);
  expect(unadmitted.body.ok).toBe(true);
  expect(unadmitted.body.sent).toBe(true);
}, ROW_TIMEOUT_MS);

test("machine b opens an exchange of its own, and a frame the carrier never handed over is visible rather than lost", async () => {
  const sinks = newSinks();
  env = await setupTwoBridgeEnv({
    prepareProject: prepareBusProject,
    envA: { ANTGRID_EVAL_SINK: sinks.a },
    envB: { ANTGRID_EVAL_SINK: sinks.b },
  });
  const { a, b, carrier } = env;
  const sessionA = await startBusSession(a, "alpha");
  const sessionB = await startBusSession(b, "beta");

  await pumpAndExpectRows(carrier);
  // Machine b's OWN mirror, and the address it offers for a session on machine
  // a. The reverse leg has its own mirror, its own carrier pairing and its own
  // route home, and a file that only ever sent from a would pass with all three
  // wired in one direction.
  const target = addressOf(await peerRow(b, sessionB, a, sessionA));

  const SUMMARY = "I have the staging lock tonight; don't take it.";
  const posted = await busCall(b.env.abDir, "post", {
    terminalId: sessionB,
    body: { to: target, summary: SUMMARY, text: "It goes back before the morning run." },
  });
  expect(posted.status).toBe(200);
  expect(posted.body.ok).toBe(true);
  expect(posted.body.sent).toBe(true);

  const mail = await awaitPost(a, sessionA, `the post from machine b to land in session ${sessionA}'s mailbox on machine a`);
  expect(mail.posts).toHaveLength(1);
  expect(mail.posts[0].summary).toBe(SUMMARY);
  expect(mail.posts[0].from.machineId).toBe(b.machineId);
  expect(mail.posts[0].from.sessionId).toBe(sessionB);

  // Asserted where the carrier SAW it, not only where it landed: a send to an
  // address on the sender's own machine never leaves the bridge, so this is
  // what says the frame actually crossed.
  const crossed = carrier.frames.filter(
    (f: any) =>
      f.type === "session-bus:post" && f.from?.machineId === b.machineId && f.to?.machineId === a.machineId,
  );
  expect(crossed).toHaveLength(1);

  // The receipt for the frame that OPENED the exchange, home over the pairing
  // that frame did not use: an answer leaves machine a on the leg that carried
  // the context in, and the route to it is learned from this very frame. It has
  // to be bound before the frame is folded, because folding dispatches the ack
  // — and an ack is fire-and-forget, so one that finds no route is not held,
  // not retried, and gone for good.
  const openingReceipt = await awaitReceipt(b, sessionB, posted.body.threadId, SUMMARY);
  expect(openingReceipt.deliveredAt).toBeGreaterThan(0);

  // A second message on the same exchange: the route is bound once, by the
  // opening frame, and everything after it rides what that frame left behind.
  const FOLLOW_UP = "Lock's back; the migration is on main.";
  const followed = await busCall(b.env.abDir, "post", {
    terminalId: sessionB,
    body: { threadId: posted.body.threadId, summary: FOLLOW_UP, text: "Rebase whenever you like." },
  });
  expect(followed.status).toBe(200);
  expect(followed.body.sent).toBe(true);

  const answeredMail = await awaitPost(a, sessionA, `machine b's follow-up to land in session ${sessionA}'s mailbox on machine a`);
  expect(answeredMail.posts).toHaveLength(1);
  expect(answeredMail.posts[0].threadId).toBe(posted.body.threadId);

  const followUpReceipt = await awaitReceipt(b, sessionB, posted.body.threadId, FOLLOW_UP);
  expect(followUpReceipt.deliveredAt).toBeGreaterThan(0);
  // Two messages, two receipts, one thread — a route that survived its first
  // use rather than one rebound by each arrival.
  expect(await outEntries(b, sessionB, posted.body.threadId)).toHaveLength(2);

  // Every frame above was routed to a machine, so nothing may be sitting here:
  // this array is the only place a misrouted frame shows up at all, and one
  // nobody asserts on is a routing bug that reads as a timeout.
  expect(carrier.undeliverable).toHaveLength(0);

  // The link goes lossy while both bridges stay live. The sending bridge is
  // told the frame left — its desktop took it — so this is the one outage a
  // receiver-side assertion alone could not tell from a slow delivery.
  carrier.stop();
  const lost = await busCall(b.env.abDir, "post", {
    terminalId: sessionB,
    body: { to: target, summary: "Staged while the link was down.", text: "Nobody carried this one." },
  });
  expect(lost.status).toBe(200);
  expect(lost.body.sent).toBe(true);
  await sleep(SETTLE_MS);
  expect((await inbox(a, sessionA)).posts).toHaveLength(0);
  expect(carrier.undeliverable).toHaveLength(1);
  expect(carrier.undeliverable[0]!.type).toBe("session-bus:post");

  // And it stays lost when the link returns: the send was already answered, so
  // nothing holds it and nothing retries it.
  carrier.start();
  await sleep(SETTLE_MS);
  expect((await inbox(a, sessionA)).posts).toHaveLength(0);
}, ROW_TIMEOUT_MS);
