import type { AbMessage, NotificationType, WorkStatus } from "./protocol";

/** Reduced per-project work status for the control-plane advert, folded from a
 *  core's OUTBOUND bus frames. `lastNotification` is the most recent turn-end
 *  signal (notification:push); `runningCount` is the live non-archived
 *  running-session count. `status` is derived from the two. */
export interface WorkStatusState {
  readonly lastNotification: NotificationType | null;
  readonly runningCount: number;
  readonly status: WorkStatus;
}

export const initialWorkStatus: WorkStatusState = {
  lastNotification: null,
  runningCount: 0,
  status: "done",
};

/** Precedence: the two turn-end call-to-action states (attention/error) win;
 *  then the notification's own resolved state; else session-running gives
 *  today's working/done.
 *
 *  Nothing running ⇒ "done" regardless of the last notification: attention
 *  ("blocked, needs you") and error both imply a LIVE agent, so once every
 *  session has stopped there is nothing left to attend to. This clears a stale
 *  red error / amber attention dot that would otherwise stick on an idle
 *  project until the next notification or session (a call-to-action for a
 *  project with no running agent is a lie). */
function derive(lastNotification: NotificationType | null, runningCount: number): WorkStatus {
  if (runningCount === 0) return "done";
  switch (lastNotification) {
    case "permission_request":
    case "awaiting_input": return "attention";
    case "error": return "error";
    case "task_complete":
    case "idle": return "done";
    default: return "working";
  }
}

/** A fresh turn started (the user submitted a prompt — a turn-start hook). Clear
 *  the prior turn-end notification so a re-run on the SAME session returns to
 *  "working" instead of showing a stale done/attention: without this, only a
 *  NEW session (running-count increase) reset the reduction, so re-prompting an
 *  existing session — the common case — stayed "done", and a granted permission
 *  stayed "attention" until the turn ended. Pure; returns the SAME object when
 *  nothing changes (already working, or no running session to work on). */
export function turnStart(prev: WorkStatusState): WorkStatusState {
  const status = derive(null, prev.runningCount);
  if (prev.lastNotification === null && prev.status === status) return prev;
  return { lastNotification: null, runningCount: prev.runningCount, status };
}

/** Fold one outbound bus frame into the reduction. Pure and total; returns the
 *  SAME object when the frame is irrelevant or changes no input, so callers can
 *  detect a real transition by `next !== prev` (and re-advertise only then). */
export function reduceWorkStatus(prev: WorkStatusState, msg: AbMessage): WorkStatusState {
  let { lastNotification, runningCount } = prev;
  if (msg.type === "notification:push") {
    if (msg.notificationType === lastNotification) return prev;
    // "awaiting_input" fires from the same idle-timeout signal whether the
    // agent is genuinely blocked mid-turn (no prior task_complete this turn)
    // or just idling after the turn already ended — the hook can't tell those
    // apart. Once a turn has resolved to task_complete, a later awaiting_input
    // ping is the stale post-completion nudge: ignore it so a finished session
    // doesn't flip back to "attention" just because the user hasn't looked yet.
    if (msg.notificationType === "awaiting_input" && lastNotification === "task_complete") return prev;
    lastNotification = msg.notificationType;
  } else if (msg.type === "session:updated") {
    const running = msg.sessions.filter((s) => s.running && !s.archived).length;
    if (running === runningCount) return prev;
    // A newly-started session is a fresh turn of work — clear stale done-type
    // turn-end notifications (task_complete, idle) so status returns to
    // "working". permission_request, awaiting_input, and error are LIVE
    // call-to-action signals for an already-running session; a new session
    // starting does not resolve an outstanding prompt or clear an error/block
    // on a sibling session.
    if (running > runningCount &&
        lastNotification !== "permission_request" &&
        lastNotification !== "awaiting_input" &&
        lastNotification !== "error") {
      lastNotification = null;
    }
    runningCount = running;
  } else {
    return prev;
  }
  return { lastNotification, runningCount, status: derive(lastNotification, runningCount) };
}
