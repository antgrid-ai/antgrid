import type { AbMessage, NotificationType, WorkStatus } from "./protocol";

/** Reduced per-project work status for the control-plane advert, folded from a
 *  core's OUTBOUND bus frames. `lastNotification` is the most recent turn-end
 *  signal (notification:push); `runningCount` is the live non-archived
 *  running-session count; `activeTurns` holds the sessions with a prompt
 *  actually in flight. `status` is derived from those three (`lastNotification
 *  Session` only scopes who may clear the notification). */
export interface WorkStatusState {
  readonly lastNotification: NotificationType | null;
  /** Which session raised `lastNotification`, or null when it arrived without
   *  attribution (a hook with no `ANTGRID_TERMINAL_ID`). Lets a turn-start
   *  clear only its OWN stale notification: the reduction is project-wide, so
   *  without this a second session's prompt would wipe a sibling's outstanding
   *  permission_request — the same sibling protection `session:updated` gives. */
  readonly lastNotificationSession: string | null;
  readonly runningCount: number;
  /** Sessions with an OPEN turn: a turn-start (structured `agent:turn-start`
   *  frame, or a `POST /turn-start` hook) that has not been closed by its
   *  turn-end. A session merely being alive is NOT a turn — that's the whole
   *  point: an open-but-idle chat must not read "working". */
  readonly activeTurns: ReadonlySet<string>;
  readonly status: WorkStatus;
}

/** Turn-key for a signal that carries no session attribution — a hook POST
 *  without `ANTGRID_TERMINAL_ID`. The project is mid-turn; we just can't say
 *  which session, so it's tracked as one anonymous turn that any unattributed
 *  turn-end closes. Never collides with a real session id (a uuid). */
export const UNATTRIBUTED_TURN = "";

const EMPTY_TURNS: ReadonlySet<string> = new Set();

export const initialWorkStatus: WorkStatusState = {
  lastNotification: null,
  lastNotificationSession: null,
  runningCount: 0,
  activeTurns: EMPTY_TURNS,
  status: "done",
};

/** Notification types that mean "the turn is over" (as opposed to the two
 *  call-to-action states, which are mid-turn blocks). */
function endsTurn(n: NotificationType): boolean {
  return n === "task_complete" || n === "idle" || n === "error";
}

/** Precedence: the two turn-end call-to-action states (attention/error) win;
 *  then the notification's own resolved state; else an OPEN TURN — a prompt
 *  actually in flight — gives "working".
 *
 *  A running session is not by itself work: opening a chat, or leaving one
 *  open after the agent answered, spawns a live session with nothing running
 *  in it, and reporting that as "working" made the indicator meaningless (every
 *  open session looked busy forever). Only a turn-start with no matching
 *  turn-end counts.
 *
 *  Nothing running ⇒ "done" regardless of the last notification: attention
 *  ("blocked, needs you") and error both imply a LIVE agent, so once every
 *  session has stopped there is nothing left to attend to. This clears a stale
 *  red error / amber attention dot that would otherwise stick on an idle
 *  project until the next notification or session (a call-to-action for a
 *  project with no running agent is a lie). */
function derive(
  lastNotification: NotificationType | null,
  runningCount: number,
  activeTurns: ReadonlySet<string>,
): WorkStatus {
  if (runningCount === 0) return "done";
  switch (lastNotification) {
    case "permission_request":
    case "awaiting_input": return "attention";
    case "error": return "error";
    case "task_complete":
    case "idle": return "done";
    default: return activeTurns.size > 0 ? "working" : "done";
  }
}

function build(
  lastNotification: NotificationType | null,
  lastNotificationSession: string | null,
  runningCount: number,
  activeTurns: ReadonlySet<string>,
): WorkStatusState {
  return {
    lastNotification,
    lastNotificationSession: lastNotification === null ? null : lastNotificationSession,
    runningCount,
    activeTurns,
    status: derive(lastNotification, runningCount, activeTurns),
  };
}

/** A fresh turn started on [sessionId] (the user submitted a prompt — a
 *  turn-start hook, routed out-of-band because it is state, not a
 *  notification). Opens the turn and clears THIS session's stale turn-end
 *  notification so a re-run on the SAME session returns to "working" instead of
 *  showing a stale done/attention. A sibling's notification is left alone: its
 *  session is still blocked, and prompting a different one doesn't answer it.
 *  An unattributed notification is cleared by any turn-start — there's no id to
 *  tell whose it was, and leaving it would strand the project on a
 *  call-to-action nobody can clear. Pass no id when the hook carried no
 *  terminal id (see {@link UNATTRIBUTED_TURN}).
 *
 *  Pure; returns the SAME object when nothing changes — including when no
 *  session is running, since a turn with no session to run in is not work and
 *  would otherwise sit in `activeTurns` waiting to light up an unrelated
 *  session that starts later. */
export function turnStart(prev: WorkStatusState, sessionId?: string): WorkStatusState {
  if (prev.runningCount === 0) return prev;
  const id = sessionId ?? UNATTRIBUTED_TURN;
  const ownsNotification = prev.lastNotification !== null
    && (prev.lastNotificationSession === null || prev.lastNotificationSession === id);
  if (!ownsNotification && prev.activeTurns.has(id)) return prev;
  return build(
    ownsNotification ? null : prev.lastNotification,
    prev.lastNotificationSession,
    prev.runningCount,
    new Set(prev.activeTurns).add(id),
  );
}

function withoutTurn(turns: ReadonlySet<string>, id: string): ReadonlySet<string> {
  if (!turns.has(id)) return turns;
  const next = new Set(turns);
  next.delete(id);
  return next;
}

/** Fold one outbound bus frame into the reduction. Pure and total; returns the
 *  SAME object when the frame is irrelevant or changes no input, so callers can
 *  detect a real transition by `next !== prev` (and re-advertise only then). */
export function reduceWorkStatus(prev: WorkStatusState, msg: AbMessage): WorkStatusState {
  let { lastNotification, lastNotificationSession, runningCount, activeTurns } = prev;
  if (msg.type === "agent:turn-start") {
    return turnStart(prev, msg.sessionId);
  } else if (msg.type === "agent:turn-end") {
    activeTurns = withoutTurn(activeTurns, msg.sessionId);
    if (activeTurns === prev.activeTurns) return prev;
  } else if (msg.type === "notification:push") {
    // A turn-end notification closes the turn even when the reduction ignores
    // the notification itself (below): the hook path is the ONLY turn-end
    // signal a terminal-mode session has, so dropping it would leave the turn
    // open forever and the project stuck on "working".
    if (endsTurn(msg.notificationType)) {
      activeTurns = withoutTurn(activeTurns, msg.sessionId ?? UNATTRIBUTED_TURN);
    }
    if (msg.notificationType === lastNotification) {
      return activeTurns === prev.activeTurns
        ? prev
        : build(lastNotification, lastNotificationSession, runningCount, activeTurns);
    }
    // "awaiting_input" fires from the same idle-timeout signal whether the
    // agent is genuinely blocked mid-turn (no prior task_complete this turn)
    // or just idling after the turn already ended — the hook can't tell those
    // apart. Once a turn has resolved to task_complete, a later awaiting_input
    // ping is the stale post-completion nudge: ignore it so a finished session
    // doesn't flip back to "attention" just because the user hasn't looked yet.
    if (msg.notificationType === "awaiting_input" && lastNotification === "task_complete") return prev;
    lastNotification = msg.notificationType;
    lastNotificationSession = msg.sessionId ?? null;
  } else if (msg.type === "session:updated") {
    const live = new Set(msg.sessions.filter((s) => s.running && !s.archived).map((s) => s.id));
    // A turn cannot outlive its session: a killed/crashed agent never sends its
    // turn-end, so prune turns whose session is gone rather than leaving the
    // project permanently "working". The unattributed turn is kept while ANY
    // session runs — there is no id to match it against.
    const pruned = new Set<string>();
    for (const id of activeTurns) {
      if (id === UNATTRIBUTED_TURN ? live.size > 0 : live.has(id)) pruned.add(id);
    }
    const turnsChanged = pruned.size !== activeTurns.size;
    if (live.size === runningCount && !turnsChanged) return prev;
    if (turnsChanged) activeTurns = pruned;
    // A newly-started session is a fresh turn of work — clear stale done-type
    // turn-end notifications (task_complete, idle) so a turn-start on it isn't
    // masked. permission_request, awaiting_input, and error are LIVE
    // call-to-action signals for an already-running session; a new session
    // starting does not resolve an outstanding prompt or clear an error/block
    // on a sibling session.
    //
    // That sibling protection only applies while a sibling is actually
    // running. From 0 the call-to-action has no session left to belong to —
    // `derive` already masks it to "done" for display, but the value survives,
    // so without this an unrelated next session would inherit the previous
    // one's error/attention on its 0→1 transition.
    const noLiveSibling = runningCount === 0;
    if (live.size > runningCount &&
        (noLiveSibling ||
          (lastNotification !== "permission_request" &&
            lastNotification !== "awaiting_input" &&
            lastNotification !== "error"))) {
      lastNotification = null;
    }
    runningCount = live.size;
  } else {
    return prev;
  }
  return build(lastNotification, lastNotificationSession, runningCount, activeTurns);
}
