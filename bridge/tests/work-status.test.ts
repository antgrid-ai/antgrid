import { test, expect } from "bun:test";
import { initialWorkStatus, reduceWorkStatus, turnStart, type WorkStatusState } from "../src/work-status";
import type { AbMessage } from "../src/protocol";

function push(notificationType: string): AbMessage {
  return { id: "m", timestamp: 0, type: "notification:push", notificationType } as any;
}
function sessions(running: number, opts: { archived?: number } = {}): AbMessage {
  const list = [
    ...Array.from({ length: running }, (_, i) => ({ id: `r${i}`, name: "r", createdAt: 0, lastUsedAt: 0, archived: false, running: true })),
    ...Array.from({ length: opts.archived ?? 0 }, (_, i) => ({ id: `a${i}`, name: "a", createdAt: 0, lastUsedAt: 0, archived: true, running: true })),
  ];
  return { id: "m", timestamp: 0, type: "session:updated", sessions: list } as any;
}
function fold(msgs: AbMessage[], from: WorkStatusState = initialWorkStatus): WorkStatusState {
  return msgs.reduce(reduceWorkStatus, from);
}

test("initial state is done", () => {
  expect(initialWorkStatus.status).toBe("done");
});

test("a running session yields working", () => {
  expect(fold([sessions(1)]).status).toBe("working");
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

test("task_complete / idle resolve to done even while a session is alive", () => {
  expect(fold([sessions(1), push("task_complete")]).status).toBe("done");
  expect(fold([sessions(1), push("idle")]).status).toBe("done");
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
  expect(turnStart(blocked).status).toBe("working");
});

test("attention > error > working precedence: a fresh permission wins over a live session", () => {
  // error then permission_request: latest turn-end signal wins.
  expect(fold([sessions(1), push("error"), push("permission_request")]).status).toBe("attention");
});

test("a newly-started session clears a prior turn-end notification (fresh turn ⇒ working)", () => {
  const after = fold([sessions(1), push("task_complete")]);
  expect(after.status).toBe("done");
  // A second session starts (count 1 → 2): the prior task_complete is cleared.
  expect(reduceWorkStatus(after, sessions(2)).status).toBe("working");
});

test("all sessions stopping yields done", () => {
  expect(fold([sessions(2), sessions(0)]).status).toBe("done");
});

test("a stale error clears to done once every session stops (no live agent to attend)", () => {
  // error while a session is alive → error; then the session stops → done, not
  // a red dot stuck forever on an idle project.
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
  // Two sessions running, one errors: still 1 running after (not 0), so the
  // call-to-action is real and must NOT be cleared.
  const s = fold([sessions(2), push("permission_request"), sessions(1)]);
  expect(s.status).toBe("attention");
});

test("a new session does NOT clear an active permission_request (sibling session still blocked)", () => {
  // Session 1 is waiting on a permission prompt; session 2 starts. The attention
  // dot must stay — the new session doesn't resolve session 1's prompt.
  const blocked = fold([sessions(1), push("permission_request")]);
  expect(blocked.status).toBe("attention");
  expect(reduceWorkStatus(blocked, sessions(2)).status).toBe("attention");
});

test("a new session does NOT clear an active error", () => {
  // Session 1 errored; session 2 starts. Error must persist.
  const errored = fold([sessions(1), push("error")]);
  expect(errored.status).toBe("error");
  expect(reduceWorkStatus(errored, sessions(2)).status).toBe("error");
});

test("a turn-start clears a stale task_complete so a same-session re-run reads working", () => {
  // The common gap: prompt an existing session again — no new session, so the
  // count-increase clear never fires. The turn-start hook clears it.
  const done = fold([sessions(1), push("task_complete")]);
  expect(done.status).toBe("done");
  expect(turnStart(done).status).toBe("working");
});

test("a turn-start clears a stale attention (permission granted, work resumed)", () => {
  const blocked = fold([sessions(1), push("permission_request")]);
  expect(blocked.status).toBe("attention");
  expect(turnStart(blocked).status).toBe("working");
});

test("turn-start is a no-op (SAME object) when already working", () => {
  const working = fold([sessions(1)]);
  expect(working.status).toBe("working");
  expect(turnStart(working)).toBe(working);
});

test("turn-start with no running session stays done (no phantom working)", () => {
  expect(turnStart(initialWorkStatus)).toBe(initialWorkStatus);
});

test("a count change with an unchanged status yields a NEW state (advert re-push trigger)", () => {
  // 1 → 2 running sessions: status stays "working", but the count moved — the
  // control-plane advert must re-push (commitWork keys off status OR count) so
  // the phone re-peeks the session list and shows the new desktop-started row.
  const one = fold([sessions(1)]);
  const two = reduceWorkStatus(one, sessions(2));
  expect(two).not.toBe(one);
  expect(two.status).toBe("working");
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
});
