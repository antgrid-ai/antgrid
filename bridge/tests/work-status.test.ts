import { test, expect } from "bun:test";
import { initialWorkStatus, reduceWorkStatus, turnStart, type WorkStatusState } from "../src/work-status";
import type { AbMessage } from "../src/protocol";

function push(notificationType: string, sessionId?: string): AbMessage {
  return { id: "m", timestamp: 0, type: "notification:push", notificationType, sessionId } as any;
}
function sessions(running: number, opts: { archived?: number } = {}): AbMessage {
  const list = [
    ...Array.from({ length: running }, (_, i) => ({ id: `r${i}`, name: "r", createdAt: 0, lastUsedAt: 0, archived: false, running: true })),
    ...Array.from({ length: opts.archived ?? 0 }, (_, i) => ({ id: `a${i}`, name: "a", createdAt: 0, lastUsedAt: 0, archived: true, running: true })),
  ];
  return { id: "m", timestamp: 0, type: "session:updated", sessions: list } as any;
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
  expect(two.lastNotification).toBeNull();
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
  expect(fresh.lastNotification).toBeNull();
  expect(reduceWorkStatus(fresh, turnStartFrame("r0")).status).toBe("working");
});

test("a new session after ALL sessions stopped does not inherit stale attention", () => {
  const stopped = fold([sessions(1), push("permission_request"), sessions(0)]);
  expect(stopped.status).toBe("done");
  const fresh = reduceWorkStatus(stopped, sessions(1));
  expect(fresh.lastNotification).toBeNull();
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

test("turn-start with no running session is dropped entirely (no phantom working)", () => {
  // Recording it would be worse than useless: the turn has no session to run in,
  // and the prune keeps it while ANY session is live — so an unrelated session
  // starting later would inherit it and read "working" with no prompt in flight.
  const ignored = turnStart(initialWorkStatus, "r0");
  expect(ignored).toBe(initialWorkStatus);
  expect(reduceWorkStatus(ignored, sessions(1)).status).toBe("done");
  expect(reduceWorkStatus(turnStart(initialWorkStatus), sessions(1)).status).toBe("done");
});

test("a sibling's turn-start does NOT clear an active permission_request", () => {
  // Session r0 is blocked on a prompt; the user prompts r1 instead. Prompting a
  // different session doesn't answer r0's question — same sibling protection
  // session:updated gives, which the per-session turn ids now make possible.
  const blocked = fold([sessions(2), push("permission_request", "r0")]);
  expect(blocked.status).toBe("attention");
  const sibling = reduceWorkStatus(blocked, turnStartFrame("r1"));
  expect(sibling.lastNotification).toBe("permission_request");
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
