import { test, expect } from "bun:test";
import { randomUUID } from "node:crypto";
import { setMobileAccess } from "../helpers/harness";
import { readRepoKey } from "../../bridge/src/capability-card";
import { createMessage, type AbMessage } from "../../bridge/src/protocol";
import {
  LOCAL_MACHINE_ID,
  MAX_NOTIFIES_PER_PAIR_HOUR,
  NO_PROGRESS_EXCHANGES,
} from "../../bridge/src/session-bus/constants";
import {
  BUS_REPO_KEY,
  NOTIFY_MARKER,
  REPLY_MARKER,
  apiPort,
  awaitDeliveryLines,
  busCall,
  countMarkers,
  hookDoneMarker,
  hookTriggerData,
  bootLocalBridge,
  createSession,
  localVerb,
  postJson,
  prepareBusProject,
  startSession,
  sinkText,
  sleep,
  untilAsync,
  type BusCall,
  type LocalBridge,
} from "../support/session-bus";

/**
 * The session bus with nothing underneath it: one bridge, no relay and the
 * machine's remote-access switch off.
 *
 * That trio is the whole of the local exchange — two sessions one bridge
 * spawned reach each other with no network, no identity and no switch — and it
 * is the one claim no bridge unit test can make. A unit test builds the
 * coordinator with `send` as a closure and `self` supplied, so it proves the
 * coordinator's arithmetic while assuming away the two things the local
 * exchange is about: that the bridge names itself when
 * nothing else will, and that the local arm of `dispatch` is what carries the
 * frame. Only a real process, booted with no relay at all, exercises either.
 *
 * Everything is driven over the LOOPBACK `/session-bus/*` routes, because that
 * is what an agent's MCP tools call: each tool is one HTTP call to the route
 * that took the decision, so a route asserted here is the tool asserted here.
 */

/** How long a "it must NOT have arrived yet" window stays open. Long enough
 *  that an immediate delivery — the bug the turn-boundary delivery rule
 *  guards against — would have landed many times over; the delivery queue
 *  drains on an edge, not on a timer, so
 *  waiting longer proves nothing more. */
const NOT_YET_MS = 1_500;

/**
 * Wait until this project offers rows at all.
 *
 * The session directory resolves the repo key by spawning git, so for the
 * first moments after a boot the project is addressable-but-not-yet-read and
 * every send answers `AGENT_NOT_READY`. Gating on the directory answering
 * keeps that startup race out of every assertion below it.
 */
async function awaitAddressable(bridge: LocalBridge, terminalId: string): Promise<BusCall> {
  const deadline = Date.now() + 30_000;
  let last: BusCall | undefined;
  for (;;) {
    last = await busCall(bridge.abDir, "sessions", { terminalId });
    if (last.status === 200) return last;
    // Named rather than merely timed out: every reason the directory can refuse
    // is a different bug, and a bare timeout points at none of them.
    if (Date.now() >= deadline) {
      throw new Error(`directory never answered: ${last.status} ${JSON.stringify(last.body)}`);
    }
    await sleep(200);
  }
}

function localTarget(bridge: LocalBridge, sessionId: string): { projectId: string; sessionId: string } {
  // No `machineId`, which is the local-exchange address: an omitted machine
  // IS this machine, and this machine has no id to spell.
  return { projectId: bridge.projectId, sessionId };
}

/**
 * Simulate one real agent hook firing for [sessionId] — a turn-start
 * (`user-prompt`) or a turn-end (`stop`, which is what carries `task_complete`).
 *
 * Not a loopback `/turn-start`/`/notify` POST: those need a `runId` matching
 * the session's own (`SessionManager.acceptsHookRun`), which only the sink's
 * own PTY environment holds. Writing `hookTriggerData` into that PTY's stdin
 * makes the sink script spawn `run-hook.ts` as ITS OWN child, so the real hook
 * runner reads the correct `ANTGRID_RUN_ID` off its inherited environment —
 * see `session-bus.ts`'s doc on `hookTriggerData`.
 *
 * Waits for `hookDoneMarker` rather than assuming completion: the trigger
 * crosses PTY write → sink script → child spawn → loopback POST, and nothing
 * about that chain is synchronous with this call returning.
 */
async function fireHook(bridge: LocalBridge, sessionId: string, agent: string, event: string): Promise<void> {
  // Counted, not merely present: the sink keeps every earlier marker, so a
  // second firing of the same event would otherwise return before it ran.
  const before = countMarkers(sinkText(bridge.sinkPath), hookDoneMarker(event));
  bridge.client.send(createMessage("terminal:input", { terminalId: sessionId, data: hookTriggerData(agent, event) }));
  await untilAsync(
    async () => (countMarkers(sinkText(bridge.sinkPath), hookDoneMarker(event)) > before ? true : undefined),
    20_000,
    `the simulated "${event}" hook to run for session ${sessionId}`,
  );
}

test("a post reaches a sibling session's mailbox on a bridge with no relay identity and remote access off", async () => {
  const bridge = await bootLocalBridge();
  try {
    const sender = await createSession(bridge, "sender");
    const target = await createSession(bridge, "target");
    await startSession(bridge, sender);
    await startSession(bridge, target);

    // Each leg of the local exchange's trio witnessed before anything relies
    // on it, because all three fail OPEN in the same direction: a bridge that
    // had quietly acquired an identity, a relay link or the switch would pass
    // every assertion below while proving something else entirely.
    const directory = await awaitAddressable(bridge, sender);
    expect(directory.body.machineId).toBeNull();
    expect(directory.body.sessions.map((s: { sessionId: string }) => s.sessionId)).toContain(target);
    // The repo key, read through the same probe the bus addresses by. The
    // local rows above do not carry it, so nothing else here would notice the
    // fixture's remote and the key two machines are matched on drifting apart —
    // and a drift costs no local row at all, only every cross-machine one.
    expect(await readRepoKey(bridge.projectDir)).toBe(BUS_REPO_KEY);

    const offMachine = {
      to: { machineId: "a-machine-this-bridge-has-never-met", projectId: bridge.projectId, sessionId: target },
      summary: "off-machine probe",
      text: "probe",
    };
    // The switch is turned ON for this probe. It now gates the send path AHEAD
    // of the relay transport, so leaving it off would witness `REMOTE_ACCESS_OFF` and
    // prove nothing about the missing-link refusal this block exists to pin. (That
    // precedence has its own case in `api-server-session-bus.test.ts`.)
    await setMobileAccess(bridge.abDir, true);
    const noLink = await busCall(bridge.abDir, "post", { terminalId: sender, body: offMachine });
    expect(noLink.status).toBe(503);
    expect(noLink.body.code).toBe("PEER_UNREACHABLE");
    await setMobileAccess(bridge.abDir, false);

    const posted = await busCall(bridge.abDir, "post", {
      terminalId: sender,
      body: { to: localTarget(bridge, target), summary: "the parser rewrite is on branch x", text: "look at lexer.ts" },
    });
    expect(posted.status).toBe(200);
    expect(posted.body.ok).toBe(true);
    expect(posted.body.sent).toBe(true);
    expect(posted.body.held).toBe(false);
    expect(posted.body.opensThread).toBe(true);
    // The id is bridge-owned, and a sender never told it cannot answer on
    // the thread it just opened.
    const threadId = posted.body.threadId;
    expect(typeof threadId).toBe("string");
    expect(threadId.length).toBeGreaterThan(0);

    const inbox = await busCall(bridge.abDir, "inbox", { terminalId: target });
    expect(inbox.status).toBe(200);
    expect(inbox.body.dropped).toBe(0);
    expect(inbox.body.posts).toHaveLength(1);
    expect(inbox.body.posts[0].threadId).toBe(threadId);
    expect(inbox.body.posts[0].summary).toBe("the parser rewrite is on branch x");
    expect(inbox.body.posts[0].text).toEqual(["look at lexer.ts"]);
    expect(inbox.body.posts[0].from.sessionId).toBe(sender);

    // The agent's read spends the unread flag: a post handed over once must not
    // be handed over again.
    const drained = await busCall(bridge.abDir, "inbox", { terminalId: target });
    expect(drained.body.posts).toHaveLength(0);

    // A post is read when its target chooses, so it owes the receiving
    // terminal no line at all.
    expect(countMarkers(sinkText(bridge.sinkPath), NOTIFY_MARKER)).toBe(0);

    // The delivery receipt: a same-machine post is stamped by the target's own
    // store write, and a build that let it fall through to the relay transport
    // would leave it held and stamp nothing here.
    const entry = await untilAsync(async () => {
      const view = await busCall(bridge.abDir, "thread", { terminalId: sender, query: { threadId } });
      const out = (view.body.entries ?? []).find((e: { direction: string }) => e.direction === "out");
      return out?.deliveredAt === undefined ? undefined : out;
    }, 15_000, "the delivery receipt on the sender's own thread entry");
    expect(entry.peer.sessionId).toBe(target);
    // The sentinel the bridge named itself by, persisted into the thread row.
    expect(entry.peer.machineId).toBe(LOCAL_MACHINE_ID);
  } finally {
    await bridge.teardown();
  }
}, 180_000);

test("a notify waits for the target's next turn boundary and arrives there exactly once", async () => {
  const bridge = await bootLocalBridge();
  try {
    const sender = await createSession(bridge, "sender");
    const target = await createSession(bridge, "target");
    await startSession(bridge, sender);
    await startSession(bridge, target);
    await awaitAddressable(bridge, sender);

    // A turn-start naming a session the work-status reduction has not seen
    // running yet is HELD and promoted when it appears, so this needs no race
    // with `session:start`'s own bookkeeping.
    await fireHook(bridge, target, "claude", "user-prompt");

    const notified = await busCall(bridge.abDir, "notify", {
      terminalId: sender,
      body: { to: localTarget(bridge, target), summary: "the migration is blocked on your schema", text: "which column wins?" },
    });
    expect(notified.status).toBe(200);
    expect(notified.body.sent).toBe(true);

    // Half one of the turn-boundary delivery rule, and the half an "it
    // arrived" assertion never tests: mid turn the line exists and has NOT
    // been submitted.
    await sleep(NOT_YET_MS);
    expect(countMarkers(sinkText(bridge.sinkPath), NOTIFY_MARKER)).toBe(0);
    const held = await awaitDeliveryLines(
      bridge.abDir,
      bridge.projectId,
      target,
      1,
      20_000,
      "the notify to remain queued during the target turn",
    );
    expect(held).toHaveLength(1);
    expect(held[0]!.kind).toBe("notify");

    // Half two: the closing edge, which is what a turn-ending notification is.
    await fireHook(bridge, target, "claude", "stop");
    await untilAsync(
      async () => (countMarkers(sinkText(bridge.sinkPath), NOTIFY_MARKER) === 1 ? true : undefined),
      20_000,
      "the notify line at the turn boundary",
    );
    // ...and only once. The queue persists a line before submitting it and
    // removes it after, so a second drain would append a duplicate here rather
    // than fail anything.
    await sleep(NOT_YET_MS);
    expect(countMarkers(sinkText(bridge.sinkPath), NOTIFY_MARKER)).toBe(1);

    // Claude announces the turn a submitted line opens, and that announcement —
    // not the write — is what retires the line. Until it arrives the queue is
    // holding a line it has already submitted, which is the state that lets a
    // line sitting unsubmitted in a composer be retried instead of lost.
    await fireHook(bridge, target, "claude", "user-prompt");
    await awaitDeliveryLines(
      bridge.abDir,
      bridge.projectId,
      target,
      0,
      20_000,
      "the submitted notify to be retired by the turn it opened",
    );
  } finally {
    await bridge.teardown();
  }
}, 180_000);

test("a notify to a stopped same-machine session wakes it and the line arrives once it settles idle", async () => {
  const bridge = await bootLocalBridge();
  try {
    const sender = await createSession(bridge, "sender");
    const target = await createSession(bridge, "sleepy-target");
    await startSession(bridge, sender);
    // Deliberately never started — this is the same-machine wake case, not the
    // already-running one the test above covers.
    await awaitAddressable(bridge, sender);

    const before = await busCall(bridge.abDir, "sessions", { terminalId: sender });
    expect(before.body.sessions.find((s: { sessionId: string }) => s.sessionId === target)?.activity).toBe("stopped");

    const notified = await busCall(bridge.abDir, "notify", {
      terminalId: sender,
      body: { to: localTarget(bridge, target), summary: "wake up", text: "ping" },
    });
    expect(notified.status).toBe(200);
    expect(notified.body.ok).toBe(true);
    expect(notified.body.sent).toBe(true);

    // No turn was ever opened for a session that just booted, so the queue's
    // own "idle reaches it at once" rule applies the moment it comes up
    // — the same edge a line held across an ordinary restart already rides.
    await untilAsync(
      async () => (countMarkers(sinkText(bridge.sinkPath), NOTIFY_MARKER) === 1 ? true : undefined),
      30_000,
      "the notify line once the woken session settles idle",
    );
    await fireHook(bridge, target, "claude", "user-prompt");
    await awaitDeliveryLines(
      bridge.abDir,
      bridge.projectId,
      target,
      0,
      20_000,
      "the submitted notify to be retired by the turn it opened",
    );

    const after = await busCall(bridge.abDir, "sessions", { terminalId: sender });
    expect(after.body.sessions.find((s: { sessionId: string }) => s.sessionId === target)?.activity).not.toBe("stopped");
  } finally {
    await bridge.teardown();
  }
}, 180_000);

test("a reply answers on the thread it was given and reaches the opener at its own turn boundary", async () => {
  const bridge = await bootLocalBridge();
  try {
    const asker = await createSession(bridge, "asker");
    const answerer = await createSession(bridge, "answerer");
    await startSession(bridge, asker);
    await startSession(bridge, answerer);
    await awaitAddressable(bridge, asker);

    const question = "which lock owns the queue";
    const posted = await busCall(bridge.abDir, "post", {
      terminalId: asker,
      body: { to: localTarget(bridge, answerer), summary: question, text: "see queue.ts" },
    });
    expect(posted.status).toBe(200);
    const threadId = posted.body.threadId;

    // The id the answerer replies on is the one it was HANDED, never one it
    // spelled: the id is bridge-owned, and a reply is the verb that
    // needs no address at all because the thread already records one.
    const inbox = await busCall(bridge.abDir, "inbox", { terminalId: answerer });
    expect(inbox.body.posts[0].threadId).toBe(threadId);

    await fireHook(bridge, asker, "claude", "user-prompt");

    const replied = await busCall(bridge.abDir, "reply", {
      terminalId: answerer,
      body: { threadId, summary: "the writer lock does", text: "queue.ts holds it for the whole drain" },
    });
    expect(replied.status).toBe(200);
    expect(replied.body.sent).toBe(true);

    // A reply takes the interrupting verb, so it waits for the asker's
    // boundary exactly as a notify does — and mid-turn it must not have landed.
    await sleep(NOT_YET_MS);
    expect(countMarkers(sinkText(bridge.sinkPath), REPLY_MARKER)).toBe(0);
    const held = await awaitDeliveryLines(
      bridge.abDir,
      bridge.projectId,
      asker,
      1,
      20_000,
      "the reply to remain queued during the asker's turn",
    );
    expect(held).toHaveLength(1);
    // The template turns on whether the thread already existed AT THE RECEIVER,
    // which is the only thing separating an answer from a first contact.
    expect(held[0]!.kind).toBe("reply");

    await fireHook(bridge, asker, "claude", "stop");
    await untilAsync(
      async () => (countMarkers(sinkText(bridge.sinkPath), REPLY_MARKER) === 1 ? true : undefined),
      20_000,
      "the reply line at the asker's turn boundary",
    );
    expect(countMarkers(sinkText(bridge.sinkPath), NOTIFY_MARKER)).toBe(0);
    // The question is not in the reply's body; it reaches the line only as the
    // thread context the delivery was rendered with, so a reply whose exchange
    // was resolved to the wrong thread would arrive naming nothing.
    expect(sinkText(bridge.sinkPath)).toContain(question);

    const view = await busCall(bridge.abDir, "thread", { terminalId: asker, query: { threadId } });
    expect(view.status).toBe(200);
    const answer = view.body.entries.find((e: { direction: string }) => e.direction === "in");
    expect(answer).toBeDefined();
    expect(answer.peer.sessionId).toBe(answerer);
    expect(view.body.entries.some((e: { direction: string }) => e.direction === "out")).toBe(true);
  } finally {
    await bridge.teardown();
  }
}, 180_000);

test("the pair budget refuses through the real verbs, survives a restart, and lifts only for a human", async () => {
  const bridge = await bootLocalBridge();
  try {
    const sender = await createSession(bridge, "sender");
    const rateTarget = await createSession(bridge, "rate-target");
    const haltTarget = await createSession(bridge, "halt-target");
    await startSession(bridge, sender);
    await startSession(bridge, rateTarget);
    await startSession(bridge, haltTarget);
    await awaitAddressable(bridge, sender);

    // The rolling-hour ceiling. Each of these opens its own thread, which is
    // progress — so what refuses below is the notify ceiling and never the halt.
    for (let i = 0; i < MAX_NOTIFIES_PER_PAIR_HOUR; i++) {
      const sent = await busCall(bridge.abDir, "notify", {
        terminalId: sender,
        body: { to: localTarget(bridge, rateTarget), summary: `urgent ${i}`, text: `body ${i}` },
      });
      expect(sent.status).toBe(200);
      expect(sent.body.ok).toBe(true);
    }
    const rateLimited = await busCall(bridge.abDir, "notify", {
      terminalId: sender,
      body: { to: localTarget(bridge, rateTarget), summary: "urgent again", text: "body again" },
    });
    expect(rateLimited.status).toBe(429);
    expect(rateLimited.body.code).toBe("NOTIFY_RATE");
    expect(rateLimited.body.error).toContain(String(MAX_NOTIFIES_PER_PAIR_HOUR));
    expect(rateLimited.body.error).toContain("post");

    // A post is unbudgeted by the ceiling, so the same pair still reaches.
    const stillReaches = await busCall(bridge.abDir, "post", {
      terminalId: sender,
      body: { to: localTarget(bridge, rateTarget), summary: "not urgent", text: "read when you can" },
    });
    expect(stillReaches.status).toBe(200);

    // The pair-budget halt, on a pair of its own so the ceiling above cannot
    // be what stops it. The first send opens a thread (progress); every one
    // after it rides that same thread and publishes nothing, which is the exchange the
    // counter exists to notice.
    const opener = await busCall(bridge.abDir, "post", {
      terminalId: sender,
      body: { to: localTarget(bridge, haltTarget), summary: "round 0", text: "round 0" },
    });
    expect(opener.status).toBe(200);
    const threadId = opener.body.threadId;
    for (let i = 1; i < NO_PROGRESS_EXCHANGES; i++) {
      const sent = await busCall(bridge.abDir, "post", {
        terminalId: sender,
        body: { threadId, summary: `round ${i}`, text: `round ${i}` },
      });
      expect(sent.status).toBe(200);
      expect(sent.body.ok).toBe(true);
    }

    // The one a reader assumes is wrong: a POST is refused too. A halt that
    // gated only `notify` would leave the pair looping on the unbudgeted verb
    // forever and bound nothing.
    const halted = await busCall(bridge.abDir, "post", {
      terminalId: sender,
      body: { to: localTarget(bridge, haltTarget), summary: "round again", text: "round again" },
    });
    expect(halted.status).toBe(429);
    expect(halted.body.code).toBe("NO_PROGRESS");
    expect(halted.body.error).toContain(String(NO_PROGRESS_EXCHANGES));
    expect(halted.body.error).toContain("human");

    // "Only a human clears it" is worth nothing if a crash clears it instead,
    // which is why the halt is forced to disk the moment it trips.
    await bridge.restart();
    const afterRestart = await untilAsync(async () => {
      const answer = await busCall(bridge.abDir, "post", {
        terminalId: sender,
        body: { to: localTarget(bridge, haltTarget), summary: "round after restart", text: "round after restart" },
      });
      // Two startup races, both answered before the pair is ever consulted —
      // the row read runs ahead of `pairRefusal`, so either one wins the poll.
      // The fresh process has to re-read the repo key before it can resolve any
      // address at all (AGENT_NOT_READY), and the target session has to be back
      // in the host's index before a local row for it exists (UNKNOWN_PEER).
      // Both clear on their own; neither is an answer about the halt.
      return answer.body.code === "AGENT_NOT_READY" || answer.body.code === "UNKNOWN_PEER" ? undefined : answer;
    }, 30_000, "the restarted bridge to answer about the pair");
    expect(afterRestart.status).toBe(429);
    expect(afterRestart.body.code).toBe("NO_PROGRESS");

    // The one signal a bridge can observe that a human is looking. Nothing an
    // agent sends arrives as terminal input, which is what makes it unforgeable
    // — and this is its only regression anywhere.
    await startSession(bridge, sender);
    bridge.client.send(createMessage("terminal:input", { terminalId: sender, data: "\r" }));

    const cleared = await untilAsync(async () => {
      const answer = await busCall(bridge.abDir, "post", {
        terminalId: sender,
        body: { to: localTarget(bridge, haltTarget), summary: "round after the human", text: "round after the human" },
      });
      return answer.status === 200 ? answer : undefined;
    }, 20_000, "the human submit to lift the halt");
    expect(cleared.body.ok).toBe(true);
  } finally {
    await bridge.teardown();
  }
}, 300_000);
