import { test, expect } from "bun:test";
import { answerRequest, initialWorkStatus, reduceWorkStatus, turnStart, userReply, type WorkStatusState } from "../src/work-status";
import type { AbMessage } from "../src/protocol";

function push(notificationType: string, sessionId?: string): AbMessage {
  return { id: "m", timestamp: 0, type: "notification:push", notificationType, sessionId } as any;
}
function entry(id: string, extra: Record<string, unknown> = {}) {
  return { id, name: id, createdAt: 0, lastUsedAt: 0, archived: false, running: true, ...extra };
}
function sessionsOf(...entries: Record<string, unknown>[]): AbMessage {
  return { id: "m", timestamp: 0, type: "session:updated", sessions: entries } as any;
}
function sessions(
  running: number,
  opts: { archived?: number; tool?: string; mode?: string } = {},
): AbMessage {
  const per = {
    ...(opts.tool !== undefined ? { tool: opts.tool } : {}),
    ...(opts.mode !== undefined ? { mode: opts.mode } : {}),
  };
  return sessionsOf(
    ...Array.from({ length: running }, (_, i) => entry(`r${i}`, per)),
    ...Array.from({ length: opts.archived ?? 0 }, (_, i) => entry(`a${i}`, { archived: true })),
  );
}
function question(sessionId: string, questionId = "q1"): AbMessage {
  return { id: "m", timestamp: 0, type: "agent:question", sessionId, questionId, kind: "text", prompt: "?" } as any;
}
function permission(sessionId: string, permissionId = "p1"): AbMessage {
  return { id: "m", timestamp: 0, type: "agent:permission-request", sessionId, permissionId, title: "Allow?", options: [] } as any;
}
function retracted(sessionId: string, ids: { permissionId?: string; questionId?: string }): AbMessage {
  return { id: "m", timestamp: 0, type: "agent:request-retracted", sessionId, ...ids } as any;
}
function turnStartFrame(sessionId: string): AbMessage {
  return { id: "m", timestamp: 0, type: "agent:turn-start", sessionId, turnId: "t" } as any;
}
function turnEndFrame(sessionId: string): AbMessage {
  return { id: "m", timestamp: 0, type: "agent:turn-end", sessionId, turnId: "t", stopReason: "end_turn" } as any;
}
function fold(msgs: AbMessage[], from: WorkStatusState = initialWorkStatus): WorkStatusState {
  return msgs.reduce(reduceWorkStatus, from);
}

test("initial state is done", () => {
  expect(initialWorkStatus.status).toBe("done");
});

test("a running session with no turn in flight is done, NOT working", () => {
  // An open chat is not work — only a prompt actually running is.
  expect(fold([sessions(1)]).status).toBe("done");
});

test("a turn in flight yields working", () => {
  expect(fold([sessions(1), turnStartFrame("r0")]).status).toBe("working");
});

test("a turn that ends returns to done while the session stays alive", () => {
  const s = fold([sessions(1), turnStartFrame("r0"), turnEndFrame("r0")]);
  expect(s.status).toBe("done");
  expect(s.runningCount).toBe(1);
});

test("a sibling's turn-end does not close this session's turn", () => {
  const s = fold([sessions(2), turnStartFrame("r0"), turnStartFrame("r1"), turnEndFrame("r1")]);
  expect(s.status).toBe("working");
});

test("archived running sessions do NOT count as working", () => {
  expect(fold([sessions(0, { archived: 2 })]).status).toBe("done");
});

test("permission_request yields attention (the call-to-action)", () => {
  expect(fold([sessions(1), push("permission_request")]).status).toBe("attention");
});

test("error notification yields error", () => {
  expect(fold([sessions(1), push("error")]).status).toBe("error");
});

test("task_complete / idle resolve to done even while a turn looked open", () => {
  expect(fold([sessions(1), turnStartFrame("r0"), push("task_complete")]).status).toBe("done");
  expect(fold([sessions(1), turnStartFrame("r0"), push("idle")]).status).toBe("done");
});

test("a turn-end notification closes the hook-opened turn (terminal-mode sessions)", () => {
  // Terminal-mode sessions have no turn frames: /turn-start opens the turn and
  // the stop hook's task_complete closes it. Without the close the project
  // would stay "working" forever.
  const working = turnStart(fold([sessions(1)]), "r0");
  expect(working.status).toBe("working");
  const ended = reduceWorkStatus(working, push("task_complete", "r0"));
  expect(ended.activeTurns.has("r0")).toBe(false);
});

test("awaiting_input yields attention when the turn hasn't resolved yet (a genuine mid-turn block)", () => {
  expect(fold([sessions(1), push("awaiting_input")]).status).toBe("attention");
});

test("awaiting_input after task_complete is a stale nudge and is ignored (stays done)", () => {
  const done = fold([sessions(1), push("task_complete")]);
  expect(done.status).toBe("done");
  const after = reduceWorkStatus(done, push("awaiting_input"));
  expect(after.status).toBe("done");
  expect(after).toBe(done);
});

test("a new session does NOT clear an active awaiting_input (sibling session still blocked)", () => {
  const blocked = fold([sessions(1), push("awaiting_input")]);
  expect(blocked.status).toBe("attention");
  expect(reduceWorkStatus(blocked, sessions(2)).status).toBe("attention");
});

test("a turn-start clears a stale awaiting_input (question answered, work resumed)", () => {
  const blocked = fold([sessions(1), push("awaiting_input")]);
  expect(blocked.status).toBe("attention");
  expect(turnStart(blocked, "r0").status).toBe("working");
});

test("attention > error > working precedence: a fresh permission wins over a live turn", () => {
  // error then permission_request: latest turn-end signal wins.
  expect(fold([sessions(1), turnStartFrame("r0"), push("error"), push("permission_request")]).status).toBe("attention");
});

test("a newly-started session alone does not read working (no prompt yet)", () => {
  const after = fold([sessions(1), push("task_complete")]);
  expect(after.status).toBe("done");
  // A second session starts (count 1 → 2): the prior task_complete is cleared,
  // but an idle new session is still not work.
  const two = reduceWorkStatus(after, sessions(2));
  expect(two.notifications.size).toBe(0);
  expect(two.status).toBe("done");
  expect(reduceWorkStatus(two, turnStartFrame("r1")).status).toBe("working");
});

test("all sessions stopping yields done", () => {
  expect(fold([sessions(2), turnStartFrame("r0"), sessions(0)]).status).toBe("done");
});

test("a session that dies mid-turn does not leave the project stuck on working", () => {
  // No turn-end ever arrives for a killed agent — the prune on session:updated
  // is what clears it.
  const orphaned = fold([sessions(2), turnStartFrame("r1"), sessions(1)]);
  expect(orphaned.activeTurns.has("r1")).toBe(false);
  expect(orphaned.status).toBe("done");
});

test("a stale error clears to done once every session stops (no live agent to attend)", () => {
  const errored = fold([sessions(1), push("error")]);
  expect(errored.status).toBe("error");
  expect(reduceWorkStatus(errored, sessions(0)).status).toBe("done");
});

test("a stale attention clears to done once every session stops", () => {
  const blocked = fold([sessions(1), push("permission_request")]);
  expect(blocked.status).toBe("attention");
  expect(reduceWorkStatus(blocked, sessions(0)).status).toBe("done");
});

test("attention/error persist while the blocked session is still running", () => {
  const s = fold([sessions(2), push("permission_request"), sessions(1)]);
  expect(s.status).toBe("attention");
});

test("a new session does NOT clear an active permission_request (sibling session still blocked)", () => {
  const blocked = fold([sessions(1), push("permission_request")]);
  expect(blocked.status).toBe("attention");
  expect(reduceWorkStatus(blocked, sessions(2)).status).toBe("attention");
});

test("a new session does NOT clear an active error", () => {
  const errored = fold([sessions(1), push("error")]);
  expect(errored.status).toBe("error");
  expect(reduceWorkStatus(errored, sessions(2)).status).toBe("error");
});

test("a new session after ALL sessions stopped does not inherit the stale error", () => {
  const stopped = fold([sessions(1), push("error"), sessions(0)]);
  expect(stopped.status).toBe("done");
  const fresh = reduceWorkStatus(stopped, sessions(1));
  expect(fresh.status).toBe("done");
  expect(fresh.notifications.size).toBe(0);
  expect(reduceWorkStatus(fresh, turnStartFrame("r0")).status).toBe("working");
});

test("a new session after ALL sessions stopped does not inherit stale attention", () => {
  const stopped = fold([sessions(1), push("permission_request"), sessions(0)]);
  expect(stopped.status).toBe("done");
  const fresh = reduceWorkStatus(stopped, sessions(1));
  expect(fresh.notifications.size).toBe(0);
  expect(fresh.status).toBe("done");
});

test("a turn-start clears a stale task_complete so a same-session re-run reads working", () => {
  const done = fold([sessions(1), push("task_complete")]);
  expect(done.status).toBe("done");
  expect(turnStart(done, "r0").status).toBe("working");
});

test("a turn-start clears a stale attention (permission granted, work resumed)", () => {
  const blocked = fold([sessions(1), push("permission_request")]);
  expect(blocked.status).toBe("attention");
  expect(turnStart(blocked, "r0").status).toBe("working");
});

test("turn-start is a no-op (SAME object) when that session's turn is already open", () => {
  const working = fold([sessions(1), turnStartFrame("r0")]);
  expect(working.status).toBe("working");
  expect(turnStart(working, "r0")).toBe(working);
});

test("an unattributed hook turn-start works when the hook carried no terminal id", () => {
  const working = turnStart(fold([sessions(1)]));
  expect(working.status).toBe("working");
  // It survives while a session runs (there is no id to match it against) and
  // clears once the project goes idle.
  expect(reduceWorkStatus(working, sessions(0)).status).toBe("done");
});

test("an UNATTRIBUTED turn-start with no running session is dropped entirely", () => {
  // Recording it would be worse than useless: the turn has no session to run in,
  // and the prune keeps it while ANY session is live — so an unrelated session
  // starting later would inherit it and read "working" with no prompt in flight.
  const ignored = turnStart(initialWorkStatus);
  expect(ignored).toBe(initialWorkStatus);
  expect(reduceWorkStatus(ignored, sessions(1)).status).toBe("done");
});

test("an ATTRIBUTED turn-start that beats its first session list is held, then promoted", () => {
  // A session's first turn-start can arrive before the session:updated that
  // lists it. Dropping it left the session reading "done" for the whole turn.
  const held = turnStart(initialWorkStatus, "r0");
  expect(held.status).toBe("done"); // nothing running yet — nothing to show
  expect(held.pendingTurns.has("r0")).toBe(true);
  const promoted = reduceWorkStatus(held, sessions(1));
  expect(promoted.status).toBe("working");
  expect(promoted.pendingTurns.size).toBe(0);
});

test("a held turn-start is discarded when its session is not in the next list", () => {
  // The session list is the answer to the race the hold was for, so whatever it
  // doesn't confirm was never a turn — an unrelated session must not inherit it.
  const held = turnStart(initialWorkStatus, "ghost");
  const other = reduceWorkStatus(held, sessions(1));
  expect(other.status).toBe("done");
  expect(other.pendingTurns.size).toBe(0);
  // ...and it does not come back if the ghost id shows up much later.
  expect(reduceWorkStatus(other, sessionsOf(entry("r0"), entry("ghost"))).status).toBe("done");
});

test("answering a session the list has not shown yet is not swallowed by the hold", () => {
  // A request can be keyed to a session no session:updated has listed (openRequest
  // does not gate on liveness). If the hold branch skipped the block-clear, the
  // answer would be lost and the promoted turn would come back "needs you" for
  // its whole length — pendingRequests outranks an open turn.
  const asked = reduceWorkStatus(initialWorkStatus, question("r0"));
  expect(asked.pendingRequests.has("r0")).toBe(true);
  const answered = answerRequest(asked, "r0");
  expect(answered.pendingRequests.has("r0")).toBe(false);
  expect(answered.pendingTurns.has("r0")).toBe(true);
  const promoted = reduceWorkStatus(answered, sessions(1));
  expect(promoted.sessionStatuses.get("r0")).toBe("working");
});

test("a held turn-start leaves a SIBLING's pending request alone", () => {
  // Same sibling protection the running-session path gives: prompting one
  // session does not answer another's question.
  const asked = fold([sessions(1), question("r0")]);
  const held = turnStart(asked, "later");
  expect(held.pendingRequests.get("r0")?.has("q1")).toBe(true);
  expect(held.sessionStatuses.get("r0")).toBe("attention");
});

test("a repeated hold with nothing left to clear is a no-op (SAME object)", () => {
  const held = turnStart(initialWorkStatus, "r0");
  expect(turnStart(held, "r0")).toBe(held);
});

test("a turn-end closes a still-held turn-start (turn over before the list caught up)", () => {
  const held = turnStart(initialWorkStatus, "r0");
  const ended = reduceWorkStatus(held, turnEndFrame("r0"));
  expect(ended.pendingTurns.size).toBe(0);
  expect(reduceWorkStatus(ended, sessions(1)).status).toBe("done");
  // Same via the hook path a terminal-mode session uses.
  const byHook = reduceWorkStatus(turnStart(initialWorkStatus, "r0"), push("task_complete", "r0"));
  expect(byHook.pendingTurns.size).toBe(0);
});

test("a sibling's turn-start does NOT clear an active permission_request", () => {
  // Session r0 is blocked on a prompt; the user prompts r1 instead. Prompting a
  // different session doesn't answer r0's question — same sibling protection
  // session:updated gives, which the per-session turn ids now make possible.
  const blocked = fold([sessions(2), push("permission_request", "r0")]);
  expect(blocked.status).toBe("attention");
  const sibling = reduceWorkStatus(blocked, turnStartFrame("r1"));
  expect(sibling.notifications.get("r0")).toBe("permission_request");
  expect(sibling.status).toBe("attention");
  // r0's own turn-start still clears it (the permission was granted).
  expect(reduceWorkStatus(sibling, turnStartFrame("r0")).status).toBe("working");
});

test("an unattributed notification is cleared by any turn-start", () => {
  // A hook with no ANTGRID_TERMINAL_ID leaves us no way to tell whose block it
  // was; keeping it would strand the project on a dot nobody can clear.
  const blocked = fold([sessions(2), push("permission_request")]);
  expect(blocked.status).toBe("attention");
  expect(reduceWorkStatus(blocked, turnStartFrame("r1")).status).toBe("working");
});

test("a count change with an unchanged status yields a NEW state (advert re-push trigger)", () => {
  // 1 → 2 running sessions: status stays "done", but the count moved — the
  // control-plane advert must re-push (commitWork keys off status OR count) so
  // the phone re-peeks the session list and shows the new desktop-started row.
  const one = fold([sessions(1)]);
  const two = reduceWorkStatus(one, sessions(2));
  expect(two).not.toBe(one);
  expect(two.runningCount).toBe(2);
});

// ── What SessionEntry.workStatus reports ────────────────────────────────────
// `sessionStatuses` is the ONLY per-session reduction; SessionManager stamps it
// onto session:updated rather than folding its own. The mode-switch dialog reads
// the result, so these pin the three answers it branches on.

test("a live session with no turn in flight reports done, not working", () => {
  // The reason the mode switch migrated here: the old per-session projection
  // called any running session "working", so an idle chat — and every session of
  // a hookless agent, permanently — claimed a reply was about to be lost.
  const s = fold([sessions(1)]);
  expect(s.sessionStatuses.get("r0")).toBe("done");
});

test("a session blocked on a request reports attention the instant the frame goes out", () => {
  // Terminal-mode sessions reach this through their hook; a chat session has no
  // notification at all, so pendingRequests is the only thing that can say the
  // pending call would be dropped by a restart.
  const s = fold([sessions(1, { mode: "chat" }), question("r0")]);
  expect(s.sessionStatuses.get("r0")).toBe("attention");
});

test("a stopped session has NO entry, so the wire carries no status for it", () => {
  // undefined reaches the app as a null workStatus — "the bridge didn't say" —
  // which is right: a stopped session is not restarted by a mode flip, so there
  // is nothing to warn about.
  const stopped = fold([sessions(1), push("permission_request", "r0"), sessions(0)]);
  expect(stopped.sessionStatuses.has("r0")).toBe(false);
});

test("re-emitting the session list after a status move settles (no feedback loop)", () => {
  // ProjectCore.commitWork asks SessionManager to re-emit session:updated
  // whenever the per-session map moves, so the stamped workStatus stays current.
  // That frame folds straight back through here. Termination depends ENTIRELY on
  // foldSessions returning the SAME state for an unchanged session set — if a
  // future edit makes it allocate unconditionally, the re-emit becomes infinite.
  const list = sessions(2);
  const working = fold([list, turnStartFrame("r0")]);
  expect(working.sessionStatuses.get("r0")).toBe("working");
  // The re-emit the status move triggered, and every one after it.
  const echoed = reduceWorkStatus(working, list);
  expect(echoed).toBe(working);
  expect(reduceWorkStatus(echoed, list)).toBe(echoed);
});

test("an irrelevant frame and a no-op change return the SAME object (identity)", () => {
  const s = fold([sessions(1)]);
  const irrelevant = { id: "m", timestamp: 0, type: "terminal:output", data: "x" } as any;
  expect(reduceWorkStatus(s, irrelevant)).toBe(s);
  // Same running count again → no input change → identical object.
  expect(reduceWorkStatus(s, sessions(1))).toBe(s);
  // Same notification repeated → identical object.
  const a = reduceWorkStatus(s, push("permission_request"));
  expect(reduceWorkStatus(a, push("permission_request"))).toBe(a);
  // A turn-end for a session with no open turn changes nothing.
  expect(reduceWorkStatus(s, turnEndFrame("r0"))).toBe(s);
});

// ── Per-session statuses ────────────────────────────────────────────────────

test("only running sessions get a status", () => {
  const s = fold([sessions(2)]);
  expect([...s.sessionStatuses.keys()].sort()).toEqual(["r0", "r1"]);
  expect(fold([sessions(0)]).sessionStatuses.size).toBe(0);
});

test("a blocked session does not drag its working sibling's dot with it", () => {
  // The whole point of the per-session view: r0 is blocked on a permission while
  // r1 has a prompt in flight. Project-wide status alone painted both amber.
  const s = fold([sessions(2), turnStartFrame("r1"), push("permission_request", "r0")]);
  expect(s.sessionStatuses.get("r0")).toBe("attention");
  expect(s.sessionStatuses.get("r1")).toBe("working");
  expect(s.status).toBe("attention"); // rollup
});

test("an unattributed notification applies to every running session", () => {
  // A hook with no ANTGRID_TERMINAL_ID gives us no id — the honest reading is
  // that the project-wide signal covers each session.
  const s = fold([sessions(2), push("permission_request")]);
  expect(s.sessionStatuses.get("r0")).toBe("attention");
  expect(s.sessionStatuses.get("r1")).toBe("attention");
});

test("a session's own notification beats the unattributed fallback", () => {
  const s = fold([sessions(2), push("permission_request"), push("task_complete", "r1")]);
  expect(s.sessionStatuses.get("r0")).toBe("attention");
  expect(s.sessionStatuses.get("r1")).toBe("done");
});

test("a question makes ONLY its session need you, immediately", () => {
  // Chat sessions never reach the notification hook path — the request frame is
  // the signal, and it must land on the asking session alone.
  const s = fold([sessions(2), turnStartFrame("r0"), turnStartFrame("r1"), question("r0")]);
  expect(s.sessionStatuses.get("r0")).toBe("attention");
  expect(s.sessionStatuses.get("r1")).toBe("working");
});

test("answering flips that session straight back to working", () => {
  const asked = fold([sessions(1), turnStartFrame("r0"), question("r0")]);
  expect(asked.status).toBe("attention");
  // The inbound question-resolve routes through answerRequest (see agent-core).
  expect(answerRequest(asked, "r0").sessionStatuses.get("r0")).toBe("working");
});

test("answering one of two prompts leaves the session on attention", () => {
  // Parallel tool calls ask permission per call, so a chat session can be
  // stopped on two at once. Answering one clears one; the dot dropping to
  // "working" here is the whole call-to-action signal lying about a session
  // that still needs the user — and it never self-corrects, since the request
  // left open is what keeps the turn from ending.
  const asked = fold([
    sessions(1), turnStartFrame("r0"), permission("r0", "p1"), permission("r0", "p2"),
  ]);
  expect(asked.sessionStatuses.get("r0")).toBe("attention");
  const one = answerRequest(asked, "r0", "p1");
  expect(one.pendingRequests.get("r0")).toEqual(new Set(["p2"]));
  expect(one.sessionStatuses.get("r0")).toBe("attention");
  const both = answerRequest(one, "r0", "p2");
  expect(both.pendingRequests.has("r0")).toBe(false);
  expect(both.sessionStatuses.get("r0")).toBe("working");
});

test("a resolve for a request the retraction already took opens no turn, even beside a live sibling", () => {
  // The retraction-race guard, now that "something pending" is no longer a
  // stand-in for "the answered one was pending". p1 is gone, so this resolve has
  // nothing to resume — and a turn opened on the strength of p2 is one no
  // turn-end closes, which is the wedge on "working" the guard exists for.
  const asked = fold([
    sessions(1), permission("r0", "p1"), permission("r0", "p2"),
    retracted("r0", { permissionId: "p1" }),
  ]);
  expect(asked.activeTurns.has("r0")).toBe(false);
  expect(answerRequest(asked, "r0", "p1")).toBe(asked);
});

test("a resolve with nothing pending does NOT open a turn (no wedge on working)", () => {
  // A resolve can race the retraction that already closed the request, or arrive
  // for one the turn took down. Opening a turn then would leave the session on
  // "working" with no turn-end coming — worse than the dot it was fixing.
  const idle = fold([sessions(1)]);
  expect(answerRequest(idle, "r0")).toBe(idle);
  const retractedFirst = fold([
    sessions(1), turnStartFrame("r0"), permission("r0", "p1"),
    retracted("r0", { permissionId: "p1" }), turnEndFrame("r0"),
  ]);
  expect(retractedFirst.status).toBe("done");
  expect(answerRequest(retractedFirst, "r0")).toBe(retractedFirst);
  // A turn-end state is not something to answer either.
  const done = fold([sessions(1), push("task_complete", "r0")]);
  expect(answerRequest(done, "r0")).toBe(done);
});

test("a permission request blocks its session until retracted", () => {
  const asked = fold([sessions(1), turnStartFrame("r0"), permission("r0", "p7")]);
  expect(asked.status).toBe("attention");
  const cleared = reduceWorkStatus(asked, retracted("r0", { permissionId: "p7" }));
  expect(cleared.sessionStatuses.get("r0")).toBe("working");
});

test("retracting one of two open requests leaves the session blocked", () => {
  const asked = fold([sessions(1), turnStartFrame("r0"), permission("r0", "p1"), question("r0", "q1")]);
  const one = reduceWorkStatus(asked, retracted("r0", { permissionId: "p1" }));
  expect(one.status).toBe("attention");
  expect(reduceWorkStatus(one, retracted("r0", { questionId: "q1" })).status).toBe("working");
});

test("a turn-end clears a request the agent never retracted", () => {
  const asked = fold([sessions(1), turnStartFrame("r0"), question("r0")]);
  expect(reduceWorkStatus(asked, turnEndFrame("r0")).status).toBe("done");
});

test("a request dies with its session (no permanently blocked ghost)", () => {
  const asked = fold([sessions(1), turnStartFrame("r0"), question("r0")]);
  expect(reduceWorkStatus(asked, sessions(0)).status).toBe("done");
});

test("a duplicate request frame is a no-op (SAME object)", () => {
  const asked = fold([sessions(1), question("r0", "q1")]);
  expect(reduceWorkStatus(asked, question("r0", "q1"))).toBe(asked);
  // ...as is retracting one that was never open.
  expect(reduceWorkStatus(asked, retracted("r0", { questionId: "nope" }))).toBe(asked);
});

test("a sibling's notification replaces the map, so the push is not deduped away", () => {
  // project-core keys its push-redundancy check on notifications identity: two
  // sessions raising the same TYPE are two separate call-to-actions.
  const first = fold([sessions(2), push("permission_request", "r0")]);
  const second = reduceWorkStatus(first, push("permission_request", "r1"));
  expect(second.notifications).not.toBe(first.notifications);
  // An exact repeat on the same session is still redundant.
  expect(reduceWorkStatus(second, push("permission_request", "r1")).notifications)
    .toBe(second.notifications);
});

test("typing into a blocked terminal session clears its block without claiming a turn", () => {
  // Terminal-mode sessions have no resolve frame — the keystroke IS the answer.
  const blocked = fold([sessions(1), push("permission_request", "r0")]);
  expect(blocked.status).toBe("attention");
  const replied = userReply(blocked, "r0");
  // No turn was open, so it falls back to done — NOT "working": typing in an
  // idle session is not work.
  expect(replied.status).toBe("done");
  expect(replied.notifications.size).toBe(0);
});

test("a reply mid-turn returns the session to working", () => {
  const blocked = fold([sessions(1), turnStartFrame("r0"), push("permission_request", "r0")]);
  expect(userReply(blocked, "r0").status).toBe("working");
});

test("a reply never clears a SIBLING's block or an unattributed one", () => {
  const sibling = fold([sessions(2), push("permission_request", "r1")]);
  expect(userReply(sibling, "r0")).toBe(sibling);
  // Unattributed: no id to say whose block it was, so a keystroke can't answer it.
  const anon = fold([sessions(2), push("permission_request")]);
  expect(userReply(anon, "r0")).toBe(anon);
});

test("a reply on an unblocked session is a no-op (SAME object)", () => {
  const done = fold([sessions(1), push("task_complete", "r0")]);
  expect(userReply(done, "r0")).toBe(done);
  expect(userReply(done, "not-a-session")).toBe(done);
});

// ── Keystroke-inferred turn starts (agents with no pre-turn hook) ────────────

test("a submitted prompt opens the turn for an agent that has no turn-start hook", () => {
  // codex/cursor/copilot expose turn-END hooks only, so the CR is the sole
  // turn-start signal their terminal-mode sessions have. Without this they read
  // "done" for the whole turn.
  const idle = fold([sessions(1, { tool: "codex" })]);
  expect(idle.status).toBe("done");
  // A PTY sends one keystroke per frame: the prompt text, then the CR.
  const typed = userReply(idle, "r0", { typed: true });
  const working = userReply(typed, "r0", { submitted: true });
  expect(working.status).toBe("working");
  // Their stop hook is what closes it — the inferred turn can never wedge.
  expect(reduceWorkStatus(working, push("task_complete", "r0")).status).toBe("done");
});

test("a submit that arrives as one chunk (paste / send-to-agent) opens the turn", () => {
  const idle = fold([sessions(1, { tool: "codex" })]);
  expect(userReply(idle, "r0", { typed: true, submitted: true }).status).toBe("working");
});

test("a bare enter with nothing typed does NOT open a turn", () => {
  // Enter on an empty prompt, or to dismiss a TUI menu, starts no turn — so no
  // stop hook is coming and an inferred turn would hang the session on
  // "working" until some unrelated later turn ended.
  const idle = fold([sessions(1, { tool: "codex" })]);
  expect(userReply(idle, "r0", { submitted: true })).toBe(idle);
  expect(userReply(idle, "r0", { submitted: true }).status).toBe("done");
});

test("the typed marker is consumed by the turn it opens", () => {
  // The next bare enter has to earn its own content, or one prompt would license
  // every subsequent stray CR.
  const idle = fold([sessions(1, { tool: "codex" })]);
  const working = userReply(idle, "r0", { typed: true, submitted: true });
  const done = reduceWorkStatus(working, push("task_complete", "r0"));
  expect(done.status).toBe("done");
  expect(userReply(done, "r0", { submitted: true })).toBe(done);
});

test("a bare keystroke (no CR) is not a submitted prompt", () => {
  const idle = fold([sessions(1, { tool: "codex" })]);
  expect(userReply(idle, "r0")).toBe(idle);
  expect(userReply(idle, "r0", { submitted: false })).toBe(idle);
});

test("a submitted prompt is NOT inferred for an agent that reports its own turns", () => {
  // Claude has a real /turn-start hook and chat sessions have turn frames —
  // guessing from keystrokes there could only be wrong.
  // Typed content is present in every case below, so the tool gate is the only
  // thing keeping these sessions out of an inferred turn.
  const submit = (s: WorkStatusState) =>
    userReply(userReply(s, "r0", { typed: true }), "r0", { submitted: true });

  const claude = fold([sessions(1, { tool: "claude-code" })]);
  expect(submit(claude).status).toBe("done");
  const chat = fold([sessions(1, { tool: "codex", mode: "chat" })]);
  expect(submit(chat).status).toBe("done");
});

test("a submitted prompt is NOT inferred for a hookless agent (nothing would close it)", () => {
  // opencode/kilo/kimi/mistral-vibe install no lifecycle hooks, so an inferred
  // turn would run until the session stopped.
  const submit = (s: WorkStatusState) =>
    userReply(userReply(s, "r0", { typed: true }), "r0", { submitted: true });

  const hookless = fold([sessions(1, { tool: "opencode" })]);
  expect(submit(hookless).status).toBe("done");
  // ...and an entry with no `tool` and no project default (custom `agent.command`)
  // is treated the same.
  const untooled = fold([sessions(1)]);
  expect(submit(untooled).status).toBe("done");
});

test("a submitted prompt clears the previous turn's end before opening the new one", () => {
  // statusFor reads notifications before activeTurns, so a leftover
  // task_complete would keep the re-prompted session on "done".
  const done = fold([sessions(1, { tool: "codex" }), push("task_complete", "r0")]);
  expect(done.status).toBe("done");
  expect(userReply(done, "r0", { typed: true, submitted: true }).status).toBe("working");
});

test("a submitted prompt on an already-working session is a no-op (SAME object)", () => {
  const working = userReply(
    fold([sessions(1, { tool: "codex" })]),
    "r0",
    { typed: true, submitted: true },
  );
  expect(userReply(working, "r0", { submitted: true })).toBe(working);
  // Typing DURING an open turn is recorded (TUIs let you queue the next prompt)
  // but opens nothing — the turn already running is the one that will close.
  const queued = userReply(working, "r0", { typed: true, submitted: true });
  expect(queued.status).toBe("working");
  expect(queued.activeTurns).toEqual(working.activeTurns);
});

test("the project's agent.tool is what a session with no tool of its own inherits", () => {
  // A SessionEntry only carries `tool` when it OVERRODE the project default, so
  // reading it alone opted every default-spec session out of the inference.
  const hello = { id: "m", timestamp: 0, type: "agent:hello", tool: "codex", version: "0" } as any;
  const s = fold([hello, sessions(1)]);
  expect(s.keystrokeTurnSessions.has("r0")).toBe(true);
  expect(userReply(s, "r0", { typed: true, submitted: true }).status).toBe("working");
});

test("a session's own tool still overrides the project default", () => {
  const hello = { id: "m", timestamp: 0, type: "agent:hello", tool: "codex", version: "0" } as any;
  // claude-code has a real /turn-start hook, so it must stay out of the set even
  // though the project default would have put it in.
  const s = fold([hello, sessions(1, { tool: "claude-code" })]);
  expect(s.keystrokeTurnSessions.has("r0")).toBe(false);
});

// ── Notification attribution ────────────────────────────────────────────────

test("a notification for an id that is not a running session falls back to project-wide", () => {
  // ANTGRID_TERMINAL_ID is also stamped on config-`terminals:` slots, whose ids
  // never appear in a session list. Filed under their own key the notification
  // would be invisible (only running sessions get a status) and then pruned —
  // silently losing an error the project-wide fallback would have shown.
  const s = fold([sessions(1), push("error", "service-terminal-1")]);
  expect(s.notifications.get("")).toBe("error");
  expect(s.sessionStatuses.get("r0")).toBe("error");
  expect(s.status).toBe("error");
});

test("a sibling's task_complete does not swallow a session's first awaiting_input", () => {
  // The stale-nudge check reads this session's OWN prior turn-end, not the
  // unattributed fallback: a config-`terminals:` slot finishing must not make
  // r1's genuine mid-turn block look like a post-completion nudge — the drop
  // would be permanent (nothing recorded ⇒ the dot never lights up).
  const done = fold([sessions(2), push("task_complete", "service-terminal-1")]);
  expect(done.notifications.get("")).toBe("task_complete");
  const blocked = reduceWorkStatus(done, push("awaiting_input", "r1"));
  expect(blocked.notifications.get("r1")).toBe("awaiting_input");
  expect(blocked.sessionStatuses.get("r1")).toBe("attention");
  // r0 has no signal of its own, so it still inherits the project-wide one.
  expect(blocked.sessionStatuses.get("r0")).toBe("done");
});

test("a session's own notification still wins over that fallback", () => {
  const s = fold([
    sessions(2), push("error", "service-terminal-1"), push("task_complete", "r1"),
  ]);
  expect(s.sessionStatuses.get("r0")).toBe("error");
  expect(s.sessionStatuses.get("r1")).toBe("done");
});
