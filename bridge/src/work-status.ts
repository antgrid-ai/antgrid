import { needsKeystrokeTurnStart } from "./agents/registry";
import type { InboundSource } from "./message-bus";
import type { AbMessage, NotificationType, WorkStatus } from "./protocol";

/** Reduced work status for the control-plane advert, folded from a core's
 *  OUTBOUND bus frames plus the inbound turn-start/answer hooks.
 *
 *  The reduction is PER SESSION: `sessionStatuses` is the authoritative view and
 *  `status` is its rollup (attention > error > working > done). A project-wide
 *  status alone made every session on a project wear its noisiest sibling's dot
 *  — two chats, one blocked, and both read "needs you". */
export interface WorkStatusState {
  readonly runningCount: number;
  /** Live non-archived running sessions — the key set of {@link sessionStatuses}
   *  and the liveness gate every other map is pruned against. */
  readonly runningSessions: ReadonlySet<string>;
  /** Latest turn-end signal PER session. The {@link UNATTRIBUTED_TURN} key is
   *  the project-wide fallback a session with no entry of its own inherits. */
  readonly notifications: ReadonlyMap<string, NotificationType>;
  /** Open permission-requests/questions per session, by request id. A chat
   *  session blocked on one is "needs you" the instant the frame goes out —
   *  it never reaches the hook path a terminal session's notification does. */
  readonly pendingRequests: ReadonlyMap<string, ReadonlySet<string>>;
  /** Sessions with an OPEN turn: a turn-start (structured `agent:turn-start`
   *  frame, or a `POST /turn-start` hook) that has not been closed by its
   *  turn-end. A session merely being alive is NOT a turn — that's the whole
   *  point: an open-but-idle chat must not read "working". */
  readonly activeTurns: ReadonlySet<string>;
  /** Turn-starts that named a session the last `session:updated` didn't list as
   *  running yet, held for exactly one session list (see {@link turnStart}). */
  readonly pendingTurns: ReadonlySet<string>;
  /** Running sessions whose agent reports turn ENDS but no turn STARTS, so a
   *  submitted keystroke is the only thing that can open their turn — see
   *  {@link needsKeystrokeTurnStart} and {@link userReply}. */
  readonly keystrokeTurnSessions: ReadonlySet<string>;
  /** Sessions that have received PTY input carrying more than the submitting CR
   *  since their last inferred turn. The evidence half of the keystroke
   *  inference: without it a bare enter — on an empty prompt, or to dismiss a
   *  TUI menu — opened a turn no stop hook was ever going to close. */
  readonly typedSessions: ReadonlySet<string>;
  /** What each client has ON SCREEN — at most one session per client, since a
   *  client shows one at a time. Keyed by {@link InboundSource} because that is
   *  the honest granularity: the desktop reaches a core over loopback and the
   *  phone over the relay, and they look at different sessions.
   *
   *  A SET of watchers, not one slot, and that is the whole point. With a single
   *  slot the last client to speak stole it, so a phone opening session B put a
   *  blue dot on session A under the desktop's cursor. A session is "seen" if
   *  ANYONE is on it.
   *
   *  Entries are dropped by {@link clientFocusState} (backgrounded — a phone in
   *  someone's pocket is looking at nothing) and by {@link clientGone} (the
   *  socket closed), so a client that walks away stops vouching for a session it
   *  can no longer see. */
  readonly focusedSessions: ReadonlyMap<InboundSource, string>;
  /** True once ANY client has declared its focus on this project. The gate on
   *  {@link WorkStatusState.unreadSessions}: before a client says what it is
   *  looking at, the bridge has no basis to call an answer unseen — a bare
   *  agent, an eval, or a desktop the user drives from its own terminal would
   *  otherwise turn every finished turn blue with nothing able to clear it. */
  readonly readTracking: boolean;
  /** Sessions whose turn finished while the user was looking elsewhere, and
   *  which nobody has visited since. Derived in {@link build} from the live→done
   *  transition, and carried on the state rather than recomputed because the
   *  fact it records ("nobody looked") leaves no other trace in the reduction.
   *  In memory only, and deliberately so: a bridge restart is a fresh read
   *  state, and the app never persists what it is told here. */
  readonly unreadSessions: ReadonlySet<string>;
  /** `agent.tool` from the project's antgrid.yaml, learned from `agent:hello`.
   *  A `SessionEntry` only carries `tool` when the session overrode the project
   *  default, so this is what the rest of the bridge spells `entry.tool ??
   *  agentSpec.name` — without it every default-spec session looked toolless and
   *  silently opted out of the keystroke inference. */
  readonly defaultTool: string | undefined;
  /** Rollup of {@link sessionStatuses} — what the project row shows. */
  readonly status: WorkStatus;
  readonly sessionStatuses: ReadonlyMap<string, WorkStatus>;
}

/** Turn-key for a signal that carries no session attribution — a hook POST
 *  without `ANTGRID_TERMINAL_ID`. The project is mid-turn; we just can't say
 *  which session, so it's tracked as one anonymous turn that any unattributed
 *  turn-end closes. Never collides with a real session id (a uuid). */
export const UNATTRIBUTED_TURN = "";

/** Shared empty set for every session-id set on the state — turns, running
 *  sessions, keystroke/typed markers. */
const EMPTY_IDS: ReadonlySet<string> = new Set();
const EMPTY_NOTIFICATIONS: ReadonlyMap<string, NotificationType> = new Map();
const EMPTY_REQUESTS: ReadonlyMap<string, ReadonlySet<string>> = new Map();
const EMPTY_FOCUS: ReadonlyMap<InboundSource, string> = new Map();

/** The mutable inputs {@link build} folds into a state; everything else on
 *  WorkStatusState is derived from these. */
interface WorkInputs {
  runningSessions: ReadonlySet<string>;
  notifications: ReadonlyMap<string, NotificationType>;
  pendingRequests: ReadonlyMap<string, ReadonlySet<string>>;
  activeTurns: ReadonlySet<string>;
  pendingTurns: ReadonlySet<string>;
  keystrokeTurnSessions: ReadonlySet<string>;
  typedSessions: ReadonlySet<string>;
  focusedSessions: ReadonlyMap<InboundSource, string>;
  readTracking: boolean;
  unreadSessions: ReadonlySet<string>;
  defaultTool: string | undefined;
}

/** Notification types that mean "the turn is over" (as opposed to the two
 *  call-to-action states, which are mid-turn blocks). */
function endsTurn(n: NotificationType): boolean {
  return n === "task_complete" || n === "idle" || n === "error";
}

/** A live block on a session — outlives a sibling session starting, unlike the
 *  turn-end states. */
function isCallToAction(n: NotificationType): boolean {
  return n === "permission_request" || n === "awaiting_input" || n === "error";
}

/** Has [sessionId]'s OWN turn already ended? The only window in which an
 *  agent's "waiting for your input" signal can be the generic post-completion
 *  idle nudge rather than a live mid-turn block — the hook fires the identical
 *  text for both and cannot tell them apart, so the host answers it from turn
 *  state. A pure read; it changes nothing.
 *
 *  The window is exactly "between turns": every path that begins a turn
 *  ({@link turnStart}, an inferred open in {@link userReply},
 *  {@link answerRequest}) drops the entry.
 *
 *  The CALLER chooses the key, and an id with no entry of its own answers
 *  false. A caller that cannot prove its id was folded under its own key must
 *  pass the raw id and take that false rather than reading the
 *  {@link UNATTRIBUTED_TURN} fallback: one session's task_complete swallowing
 *  another's genuine first block is a permanent drop (nothing is recorded, so
 *  nothing can raise it again). */
export function isStaleIdleNudge(state: WorkStatusState, sessionId: string): boolean {
  return state.notifications.get(sessionId) === "task_complete";
}

/** Rollup order for the project row. `unread` outranks `done` and nothing else:
 *  it is a "come and look" nudge, never a claim that the agent is still busy. */
const RANK: Record<WorkStatus, number> = {
  attention: 4, error: 3, working: 2, unread: 1, done: 0,
};

/** One running session's status.
 *
 *  Precedence: an unanswered request (attention) wins, then the session's own
 *  turn-end notification — falling back to the unattributed one, which is the
 *  only signal a hook without a terminal id can give us — else an OPEN TURN
 *  gives "working".
 *
 *  A running session is not by itself work: opening a chat, or leaving one open
 *  after the agent answered, spawns a live session with nothing running in it,
 *  and reporting that as "working" made the indicator meaningless (every open
 *  session looked busy forever). Only a turn-start with no matching turn-end
 *  counts. */
function statusFor(sessionId: string, i: WorkInputs): WorkStatus {
  if ((i.pendingRequests.get(sessionId)?.size ?? 0) > 0) return "attention";
  const n = i.notifications.get(sessionId) ?? i.notifications.get(UNATTRIBUTED_TURN);
  switch (n) {
    case "permission_request":
    case "awaiting_input": return "attention";
    case "error": return "error";
    case "task_complete":
    case "idle": return "done";
    default:
      return i.activeTurns.has(sessionId) || i.activeTurns.has(UNATTRIBUTED_TURN)
        ? "working"
        : "done";
  }
}

/** Sessions holding an answer nobody has looked at, for the state {@link build}
 *  is about to produce.
 *
 *  Unread is the only part of the reduction that is a TRANSITION rather than a
 *  fold of the current inputs: "the agent finished and you weren't watching" is
 *  invisible in `raw` alone, since a session that finished an hour ago and one
 *  that finished this instant are both plainly "done". So it is derived by
 *  diffing against [prev] and then carried on the state.
 *
 *  Three rules, in order: carry an existing mark only while its session is still
 *  running and still idle (a new turn supersedes it, and a stopped session has
 *  no dot to wear); mark a session that just fell from a live state to "done";
 *  and then clear every session someone is actually WATCHING. The clear runs
 *  last so it always wins — that is what keeps the session you are sitting on
 *  from going blue under you, and it covers the interrupt case for free (an Esc
 *  reaches this the same way a real turn-end does, and the user is by definition
 *  looking at the session they just interrupted). */
function deriveUnread(i: WorkInputs, raw: ReadonlyMap<string, WorkStatus>, prev?: WorkStatusState): Set<string> {
  const unread = new Set<string>();
  for (const id of i.unreadSessions) if (raw.get(id) === "done") unread.add(id);
  if (i.readTracking && prev) {
    for (const [id, s] of raw) {
      if (s !== "done") continue;
      const before = prev.sessionStatuses.get(id);
      if (before !== undefined && before !== "done" && before !== "unread") unread.add(id);
    }
  }
  for (const seen of i.focusedSessions.values()) unread.delete(seen);
  return unread;
}

/** Derive the per-session map and its rollup.
 *
 *  Only RUNNING sessions get a status, so nothing running ⇒ "done" regardless of
 *  the stored notifications: attention ("blocked, needs you") and error both
 *  imply a LIVE agent, so once every session has stopped there is nothing left
 *  to attend to. This clears a stale red/amber dot that would otherwise stick on
 *  an idle project (a call-to-action for a project with no running agent is a
 *  lie).
 *
 *  [prev] is the state being replaced, and is what {@link deriveUnread} diffs
 *  against — every caller passes it; only {@link initialWorkStatus}, which has
 *  no predecessor, omits it. */
function build(i: WorkInputs, prev?: WorkStatusState): WorkStatusState {
  const raw = new Map<string, WorkStatus>();
  for (const id of i.runningSessions) raw.set(id, statusFor(id, i));
  const unreadSessions = deriveUnread(i, raw, prev);
  const sessionStatuses = new Map<string, WorkStatus>();
  let status: WorkStatus = "done";
  for (const [id, s] of raw) {
    // Only an otherwise-idle session wears the unread dot: a session that went
    // back to work, or is blocked again, has something louder to say.
    const shown = s === "done" && unreadSessions.has(id) ? "unread" : s;
    sessionStatuses.set(id, shown);
    if (RANK[shown] > RANK[status]) status = shown;
  }
  return {
    focusedSessions: i.focusedSessions,
    readTracking: i.readTracking,
    unreadSessions,
    runningCount: i.runningSessions.size,
    runningSessions: i.runningSessions,
    notifications: i.notifications,
    pendingRequests: i.pendingRequests,
    activeTurns: i.activeTurns,
    pendingTurns: i.pendingTurns,
    keystrokeTurnSessions: i.keystrokeTurnSessions,
    typedSessions: i.typedSessions,
    defaultTool: i.defaultTool,
    status,
    sessionStatuses,
  };
}

function inputsOf(s: WorkStatusState): WorkInputs {
  return {
    runningSessions: s.runningSessions,
    notifications: s.notifications,
    pendingRequests: s.pendingRequests,
    activeTurns: s.activeTurns,
    pendingTurns: s.pendingTurns,
    keystrokeTurnSessions: s.keystrokeTurnSessions,
    typedSessions: s.typedSessions,
    focusedSessions: s.focusedSessions,
    readTracking: s.readTracking,
    unreadSessions: s.unreadSessions,
    defaultTool: s.defaultTool,
  };
}

export const initialWorkStatus: WorkStatusState = build({
  runningSessions: EMPTY_IDS,
  notifications: EMPTY_NOTIFICATIONS,
  pendingRequests: EMPTY_REQUESTS,
  activeTurns: EMPTY_IDS,
  pendingTurns: EMPTY_IDS,
  keystrokeTurnSessions: EMPTY_IDS,
  typedSessions: EMPTY_IDS,
  focusedSessions: EMPTY_FOCUS,
  readTracking: false,
  unreadSessions: EMPTY_IDS,
  defaultTool: undefined,
});

/** Drop [id]'s notification AND the unattributed one. The latter has no id to
 *  tell whose block it was, and leaving it would strand the project on a
 *  call-to-action nobody can clear.
 *
 *  The cost is real and accepted: prompting session A discards an unattributed
 *  block — a config-`terminals:` slot's error, or a hook that fired without a
 *  terminal id — that may have had nothing to do with A. Stranding is the worse
 *  failure (a dot the user cannot clear by any action) so it wins, but a block
 *  that IS attributed is never touched. Returns the SAME map when neither
 *  exists. */
function clearNotifications(
  map: ReadonlyMap<string, NotificationType>,
  id: string,
): ReadonlyMap<string, NotificationType> {
  if (!map.has(id) && !map.has(UNATTRIBUTED_TURN)) return map;
  const next = new Map(map);
  next.delete(id);
  next.delete(UNATTRIBUTED_TURN);
  return next;
}

/** Drop [id]'s open requests — [requestId] to drop only that one, absent for all
 *  of them. Returns the SAME map when there was nothing to drop, including for a
 *  [requestId] the session never had open. */
function clearRequests(
  map: ReadonlyMap<string, ReadonlySet<string>>,
  id: string,
  requestId?: string,
): ReadonlyMap<string, ReadonlySet<string>> {
  const open = map.get(id);
  if (!open || (requestId !== undefined && !open.has(requestId))) return map;
  const next = new Map(map);
  if (requestId === undefined || open.size === 1) {
    next.delete(id);
  } else {
    const rest = new Set(open);
    rest.delete(requestId);
    next.set(id, rest);
  }
  return next;
}

function withoutTurn(turns: ReadonlySet<string>, id: string): ReadonlySet<string> {
  if (!turns.has(id)) return turns;
  const next = new Set(turns);
  next.delete(id);
  return next;
}

function sameIds(a: ReadonlySet<string>, b: ReadonlySet<string>): boolean {
  if (a.size !== b.size) return false;
  for (const id of a) if (!b.has(id)) return false;
  return true;
}

/** A fresh turn started on [sessionId] — the user submitted a prompt, or
 *  answered the question/permission that was blocking this session. Opens the
 *  turn and clears THIS session's stale block so it returns to "working"
 *  immediately instead of showing the answered prompt one advert longer. A
 *  sibling's block is left alone: its session is still waiting, and prompting a
 *  different one doesn't answer it. Pass no id when the hook carried no terminal
 *  id (see {@link UNATTRIBUTED_TURN}).
 *
 *  An ATTRIBUTED start for a session the last session list didn't show running
 *  is HELD in `pendingTurns` rather than dropped: a session's first turn-start
 *  can beat its first `session:updated`, and dropping it left the session
 *  reading "done" for the whole turn. {@link foldSessions} promotes it the
 *  moment the session appears and discards it otherwise, so the hold lasts
 *  exactly the length of that race.
 *
 *  [answered] narrows the block-clear to one request id, for the caller that
 *  knows which one the user replied to ({@link answerRequest}). Absent — the
 *  hook path, which carries no request id — clears the session's whole set.
 *
 *  Pure; returns the SAME object when nothing changes — including for an
 *  UNATTRIBUTED start with nothing running, which has no session to be held
 *  against and would otherwise light up an unrelated session that starts later. */
export function turnStart(
  prev: WorkStatusState,
  sessionId?: string,
  answered?: string,
): WorkStatusState {
  if (sessionId !== undefined && !prev.runningSessions.has(sessionId)) {
    // The held start still clears this session's block: `openRequest` does not
    // gate on liveness, so a request CAN be keyed to a session no list has shown
    // yet, and leaving it would have {@link answerRequest} swallowed — the
    // promoted turn comes back "needs you" for its whole length, since
    // pendingRequests outranks an open turn in {@link statusFor}. Only its own
    // block: a NOTIFICATION can never be filed under a not-yet-running id
    // (foldNotification falls back to the project-wide key), so clearing
    // notifications here could only wipe an unattributed one on the word of a
    // session that may never exist.
    const pendingRequests = clearRequests(prev.pendingRequests, sessionId, answered);
    if (prev.pendingTurns.has(sessionId) && pendingRequests === prev.pendingRequests) return prev;
    return build({
      ...inputsOf(prev),
      pendingRequests,
      pendingTurns: new Set(prev.pendingTurns).add(sessionId),
    }, prev);
  }
  if (prev.runningSessions.size === 0) return prev;
  const id = sessionId ?? UNATTRIBUTED_TURN;
  const notifications = clearNotifications(prev.notifications, id);
  const pendingRequests = clearRequests(prev.pendingRequests, id, answered);
  const open = prev.activeTurns.has(id);
  if (notifications === prev.notifications && pendingRequests === prev.pendingRequests && open) {
    return prev;
  }
  return build({
    ...inputsOf(prev),
    notifications,
    pendingRequests,
    activeTurns: open ? prev.activeTurns : new Set(prev.activeTurns).add(id),
  }, prev);
}

/** The user answered the permission/question [requestId] that [sessionId] was
 *  blocked on (a chat `agent:permission-resolve` / `agent:question-resolve`).
 *
 *  {@link turnStart}, but ONLY when there was actually something to answer. A
 *  resolve that races a retraction — or arrives for a request the turn already
 *  took down — would otherwise open a turn that no turn-end will ever close,
 *  wedging the session on "working" until it stops.
 *
 *  Scoped to [requestId], because an agent can be stopped on several at once
 *  (parallel tool calls ask permission per call) and one answer unblocks one of
 *  them. Taking the whole set dropped the session from "attention" to "working"
 *  while it was still waiting, and nothing later corrected it: the request left
 *  open is what holds the turn open, so the turn-end that would have refreshed
 *  the dot cannot arrive until the block the dot is denying is gone. Absent —
 *  every request on the session, the reading {@link clearRequests} gives an
 *  id-less caller.
 *
 *  Pure; SAME object when nothing was pending. */
export function answerRequest(
  prev: WorkStatusState,
  sessionId: string,
  requestId?: string,
): WorkStatusState {
  const own = prev.notifications.get(sessionId);
  const blocked = own !== undefined && isCallToAction(own);
  const open = prev.pendingRequests.get(sessionId);
  const answered = requestId === undefined ? open !== undefined : open?.has(requestId) === true;
  if (!blocked && !answered) return prev;
  return turnStart(prev, sessionId, requestId);
}

/** The user typed into [sessionId]'s PTY. Terminal-mode sessions have no
 *  resolve frame — answering a permission prompt IS the keystroke — so this is
 *  the only signal that the block the hook reported is gone. Clears the
 *  session's own call-to-action and pending requests; the session falls back to
 *  whatever it was really doing (working if its turn is still open, done if
 *  not). Typing in an idle session must not read as work.
 *
 *  [submitted] (the input carried a carriage return) additionally OPENS the turn,
 *  but only for a session in `keystrokeTurnSessions` — an agent that reports turn
 *  ends and no turn starts. Those sessions would otherwise read "done" for the
 *  whole turn, and inferring the start is safe precisely because their stop hook
 *  will close it. Agents with a real turn-start signal are left to it: guessing
 *  from keystrokes there could only be wrong.
 *
 *  ...and only once [typed] has reported content for this session. A PTY sends
 *  one keystroke per frame, so the submitting CR normally arrives alone and
 *  `submitted` alone cannot distinguish a prompt from enter on an empty prompt or
 *  on a TUI menu. Those start no turn, so the stop hook the inference relies on
 *  never fires and the session hangs on "working" until some LATER turn ends.
 *  Requiring typed content since the last inferred turn is the evidence that a
 *  prompt existed at all; the marker is consumed when the turn opens, so the next
 *  bare enter has to earn its own.
 *
 *  Otherwise deliberately narrower than {@link turnStart}: a bare keystroke is
 *  weaker evidence than a submitted prompt, so it never clears the UNATTRIBUTED
 *  notification (it may belong to a different session) nor a turn-end state
 *  (nothing to resolve). Pure; SAME object when there was nothing to do. */
export function userReply(
  prev: WorkStatusState,
  sessionId: string,
  opts: { submitted?: boolean; typed?: boolean } = {},
): WorkStatusState {
  const own = prev.notifications.get(sessionId);
  const blocked = own !== undefined && isCallToAction(own);
  const pending = prev.pendingRequests.has(sessionId);
  // Content in THIS frame counts toward this same submit: a paste (or the app's
  // send-to-agent composer) delivers "prompt text\r" as one chunk.
  const typed = opts.typed === true || prev.typedSessions.has(sessionId);
  const opens = opts.submitted === true
    && typed
    && prev.keystrokeTurnSessions.has(sessionId)
    && !prev.activeTurns.has(sessionId);
  const recordTyped = opts.typed === true && !prev.typedSessions.has(sessionId);
  if (!blocked && !pending && !opens && !recordTyped) return prev;
  let notifications = prev.notifications;
  // Opening the turn means clearing the session's turn-end notification too:
  // statusFor reads notifications BEFORE activeTurns, so a leftover
  // task_complete would keep the session on "done" through the new turn.
  if (blocked || opens) {
    const next = new Map(notifications);
    next.delete(sessionId);
    notifications = next;
  }
  let typedSessions = prev.typedSessions;
  if (opens) {
    typedSessions = withoutTurn(typedSessions, sessionId);
  } else if (recordTyped) {
    typedSessions = new Set(typedSessions).add(sessionId);
  }
  return build({
    ...inputsOf(prev),
    notifications,
    pendingRequests: clearRequests(prev.pendingRequests, sessionId),
    activeTurns: opens ? new Set(prev.activeTurns).add(sessionId) : prev.activeTurns,
    typedSessions,
  }, prev);
}

/** The turn on [sessionId] is over — its turn-end frame, a chat cancel, or a
 *  hook-based session's Esc interrupt (see {@link isInterruptKeystroke} in
 *  keystrokes.ts, dispatched from agent-core.ts, the only other
 *  caller). Anything it was blocked on died with it. Pure; SAME object
 *  when there was nothing open to close, so a
 *  second Esc — or one after the real turn-end already landed — is a no-op. */
export function closeTurn(prev: WorkStatusState, sessionId: string): WorkStatusState {
  const activeTurns = withoutTurn(prev.activeTurns, sessionId);
  const pendingTurns = withoutTurn(prev.pendingTurns, sessionId);
  const pendingRequests = clearRequests(prev.pendingRequests, sessionId);
  // A chat session's block lives in pendingRequests; a terminal-mode session's
  // lives in notifications (permission_request/awaiting_input from the hook) —
  // clearing only the former left an Esc-interrupted terminal session stuck on
  // "attention" forever, since neither a chat turn-end nor a cancel had ever
  // needed to touch this map before. Same helper turnStart uses to open a turn,
  // for the same reason: it also drops the UNATTRIBUTED fallback, since nothing
  // is left running THIS session's block against once its turn is gone.
  const notifications = clearNotifications(prev.notifications, sessionId);
  if (activeTurns === prev.activeTurns
    && pendingTurns === prev.pendingTurns
    && pendingRequests === prev.pendingRequests
    && notifications === prev.notifications) {
    return prev;
  }
  return build({ ...inputsOf(prev), activeTurns, pendingTurns, pendingRequests, notifications }, prev);
}

/** Replace one client's focus entry, or drop it when [sessionId] is undefined.
 *  Returns the SAME map when it already said that. */
function withFocus(
  map: ReadonlyMap<InboundSource, string>,
  client: InboundSource,
  sessionId: string | undefined,
): ReadonlyMap<InboundSource, string> {
  if (map.get(client) === sessionId) return map;
  const next = new Map(map);
  if (sessionId === undefined) next.delete(client); else next.set(client, sessionId);
  return next;
}

/** [client] says [sessionId] is what its user is looking at (`session:focus`).
 *
 *  Two jobs, and the second is why this is not just a setter: it clears
 *  [sessionId]'s unread mark — visiting a session IS reading it — and it arms
 *  {@link WorkStatusState.readTracking}, which is what lets any later turn-end
 *  be called unseen at all.
 *
 *  Scoped to [client], so the desktop and the phone each vouch for their own
 *  session and neither can take the other's dot down or put one up.
 *
 *  Deliberately NOT gated on [sessionId] being a running session. A focus can
 *  land before the session's first `session:updated` (the same race
 *  {@link turnStart} holds `pendingTurns` for), and dropping it there would let
 *  the session's first answer come back blue under the user's nose. Nothing
 *  keyed to a dead id survives: {@link deriveUnread} carries a mark only while
 *  its session is still running.
 *
 *  Pure; SAME object when that client is already here with nothing to clear. */
export function sessionFocus(
  prev: WorkStatusState,
  sessionId: string,
  client: InboundSource,
): WorkStatusState {
  const focusedSessions = withFocus(prev.focusedSessions, client, sessionId);
  if (prev.readTracking
    && focusedSessions === prev.focusedSessions
    && !prev.unreadSessions.has(sessionId)) {
    return prev;
  }
  const unreadSessions = new Set(prev.unreadSessions);
  unreadSessions.delete(sessionId);
  return build(
    { ...inputsOf(prev), focusedSessions, readTracking: true, unreadSessions },
    prev,
  );
}

/** [client] declared whether it can render this project at all
 *  (`client:focus-state`). [paused] — backgrounded, or no heavy subscriber —
 *  means ITS user is looking at nothing here, so it stops vouching for whatever
 *  it had on screen and a turn that ends while they are away lands as unread.
 *  That is the case unread exists for: the phone in a pocket, the app killed
 *  overnight. A sibling client that is still watching keeps its own entry, and
 *  keeps its session read.
 *
 *  Resuming does NOT restore the previous focus — the app restates it (see
 *  `_setFocusPaused` in app_shell.dart), because only the app knows whether the
 *  session it left on screen is still the one on screen.
 *
 *  Either value arms {@link WorkStatusState.readTracking}: a client that has
 *  declared its lifecycle is attached and reading, even if it never named a
 *  session (it may be sitting on the sessions list).
 *
 *  Pure; SAME object when nothing moves. */
export function clientFocusState(
  prev: WorkStatusState,
  paused: boolean,
  client: InboundSource,
): WorkStatusState {
  const focusedSessions = paused
    ? withFocus(prev.focusedSessions, client, undefined)
    : prev.focusedSessions;
  if (prev.readTracking && focusedSessions === prev.focusedSessions) return prev;
  return build({ ...inputsOf(prev), focusedSessions, readTracking: true }, prev);
}

/** [client]'s socket closed — the phone left the relay, or the desktop app quit.
 *  It stops vouching for whatever it had on screen: a session nothing can render
 *  any more is not being read, and leaving the entry would keep it permanently
 *  exempt from unread.
 *
 *  Does NOT disarm {@link WorkStatusState.readTracking}. That flag records that
 *  this project HAS a reader, which a disconnect does not undo — the app will be
 *  back, and clearing it would replay every answer it missed as plain "done".
 *
 *  Pure; SAME object when that client had nothing on screen. */
export function clientGone(prev: WorkStatusState, client: InboundSource): WorkStatusState {
  const focusedSessions = withFocus(prev.focusedSessions, client, undefined);
  if (focusedSessions === prev.focusedSessions) return prev;
  return build({ ...inputsOf(prev), focusedSessions }, prev);
}

/** The agent asked [sessionId] something it cannot proceed without. */
function openRequest(prev: WorkStatusState, sessionId: string, requestId: string): WorkStatusState {
  if (prev.pendingRequests.get(sessionId)?.has(requestId)) return prev;
  const next = new Map(prev.pendingRequests);
  next.set(sessionId, new Set([...(prev.pendingRequests.get(sessionId) ?? []), requestId]));
  return build({ ...inputsOf(prev), pendingRequests: next }, prev);
}

/** The request is no longer answerable (retracted, turn ended, driver disposed).
 *  With no id — every pending request on that session. */
function closeRequest(
  prev: WorkStatusState,
  sessionId: string,
  requestId: string | undefined,
): WorkStatusState {
  const pendingRequests = clearRequests(prev.pendingRequests, sessionId, requestId);
  if (pendingRequests === prev.pendingRequests) return prev;
  return build({ ...inputsOf(prev), pendingRequests }, prev);
}

function foldNotification(
  prev: WorkStatusState,
  msg: Extract<AbMessage, { type: "notification:push" }>,
): WorkStatusState {
  const raw = msg.sessionId ?? UNATTRIBUTED_TURN;
  // Turn bookkeeping keys on the id as sent; the DISPLAY entry falls back to the
  // project-wide key when that id is not a running session. `ANTGRID_TERMINAL_ID`
  // is also stamped on config-`terminals:` slots, whose ids never appear in a
  // session list — filed under their own key the notification would be invisible
  // (statusFor only reads running sessions) and then pruned, silently losing an
  // error or a permission prompt the project-wide fallback would have shown.
  //
  // It FANS OUT, and that is the accepted cost: statusFor reads the unattributed
  // entry for every running session, so one config-terminal error dots them all.
  // Losing the signal entirely is worse than over-reporting it, and the only fix
  // that doesn't trade one for the other is attribution the hook can't give us.
  const key = raw === UNATTRIBUTED_TURN || prev.runningSessions.has(raw)
    ? raw
    : UNATTRIBUTED_TURN;
  let activeTurns = prev.activeTurns;
  let pendingTurns = prev.pendingTurns;
  let pendingRequests = prev.pendingRequests;
  // A turn-end notification closes the turn even when the reduction ignores the
  // notification itself (below): the hook path is the ONLY turn-end signal a
  // terminal-mode session has, so dropping it would leave the turn open forever
  // and the session stuck on "working". Anything it was blocked on died with
  // the turn.
  if (endsTurn(msg.notificationType)) {
    activeTurns = withoutTurn(activeTurns, raw);
    pendingTurns = withoutTurn(pendingTurns, raw);
    pendingRequests = clearRequests(pendingRequests, raw);
  }
  const own = prev.notifications.get(key);
  // "awaiting_input" fires from the same idle-timeout signal whether the agent
  // is genuinely blocked mid-turn (no prior task_complete this turn) or just
  // idling after the turn already ended — the hook can't tell those apart. Once
  // a turn has resolved to task_complete, a later awaiting_input ping is the
  // stale post-completion nudge: ignore it so a finished session doesn't flip
  // back to "attention" just because the user hasn't looked yet.
  //
  // Compared against THIS key's own prior state only — never the unattributed
  // fallback `statusFor` displays. A project that mixes attributed and
  // unattributed hooks would otherwise have one session's task_complete swallow
  // a different session's genuine first block, and the drop is permanent
  // (nothing is recorded, so the dot never lights up).
  const stale = msg.notificationType === "awaiting_input" && isStaleIdleNudge(prev, key);
  if (msg.notificationType === own || stale) {
    if (activeTurns === prev.activeTurns
      && pendingTurns === prev.pendingTurns
      && pendingRequests === prev.pendingRequests) {
      return prev;
    }
    return build({ ...inputsOf(prev), activeTurns, pendingTurns, pendingRequests }, prev);
  }
  return build({
    ...inputsOf(prev),
    notifications: new Map(prev.notifications).set(key, msg.notificationType),
    pendingRequests,
    activeTurns,
    pendingTurns,
  }, prev);
}

/** One entry of a `session:updated` list, narrowed to what the reduction reads.
 *  `mode`/`tool` decide which sessions need a keystroke-inferred turn start. */
type SessionFoldEntry = {
  id: string;
  running: boolean;
  archived: boolean;
  mode?: string;
  tool?: string;
};

function foldSessions(
  prev: WorkStatusState,
  entries: readonly SessionFoldEntry[],
): WorkStatusState {
  const running = entries.filter((s) => s.running && !s.archived);
  const live = new Set(running.map((s) => s.id));
  const grew = live.size > prev.runningSessions.size;
  const keystrokeTurnSessions = new Set(
    running
      .filter((s) => s.mode !== "chat" && needsKeystrokeTurnStart(s.tool ?? prev.defaultTool))
      .map((s) => s.id),
  );

  // Nothing keyed by a session may outlive it: a killed/crashed agent never
  // sends its turn-end or retracts its question, so prune rather than leave the
  // project permanently "working"/"needs you". The unattributed turn and
  // notification are kept while ANY session runs — there is no id to match them
  // against.
  const activeTurns = new Set<string>();
  for (const id of prev.activeTurns) {
    if (id === UNATTRIBUTED_TURN ? live.size > 0 : live.has(id)) activeTurns.add(id);
  }
  // A held turn-start is promoted the moment its session shows up running, and
  // discarded otherwise: this list is the answer to the race it was held for, so
  // whatever it doesn't confirm was never a turn.
  for (const id of prev.pendingTurns) {
    if (live.has(id)) activeTurns.add(id);
  }
  const pendingRequests = new Map<string, ReadonlySet<string>>();
  for (const [id, open] of prev.pendingRequests) {
    if (live.has(id)) pendingRequests.set(id, open);
  }
  const notifications = new Map<string, NotificationType>();
  for (const [id, n] of prev.notifications) {
    if (id === UNATTRIBUTED_TURN ? live.size > 0 : live.has(id)) notifications.set(id, n);
  }
  const typedSessions = new Set<string>();
  for (const id of prev.typedSessions) if (live.has(id)) typedSessions.add(id);
  // A newly-started session is a fresh turn of work — clear a stale done-type
  // UNATTRIBUTED notification so a turn-start on the new session isn't masked by
  // a fallback that predates it. permission_request, awaiting_input and error
  // are LIVE call-to-action signals for an already-running session; a new
  // session starting does not resolve an outstanding prompt or clear an error on
  // a sibling. Attributed entries need none of this — they only ever apply to
  // their own session.
  const unattributed = notifications.get(UNATTRIBUTED_TURN);
  if (grew && unattributed !== undefined && !isCallToAction(unattributed)) {
    notifications.delete(UNATTRIBUTED_TURN);
  }

  if (sameIds(live, prev.runningSessions)
    && sameIds(activeTurns, prev.activeTurns)
    && sameIds(keystrokeTurnSessions, prev.keystrokeTurnSessions)
    && prev.pendingTurns.size === 0
    && pendingRequests.size === prev.pendingRequests.size
    && notifications.size === prev.notifications.size
    && typedSessions.size === prev.typedSessions.size) {
    return prev;
  }
  return build({
    ...inputsOf(prev),
    runningSessions: live,
    activeTurns,
    pendingTurns: EMPTY_IDS,
    keystrokeTurnSessions,
    typedSessions,
    pendingRequests,
    notifications,
  }, prev);
}

/** Fold one outbound bus frame into the reduction. Pure and total; returns the
 *  SAME object when the frame is irrelevant or changes no input, so callers can
 *  detect a real transition by `next !== prev` (and re-advertise only then). */
export function reduceWorkStatus(prev: WorkStatusState, msg: AbMessage): WorkStatusState {
  switch (msg.type) {
    case "agent:turn-start": return turnStart(prev, msg.sessionId);
    // Covers cancels too: structured-manager answers an `agent:cancel` with a
    // turn-end either from the driver or synthesized in its `finally`, so there
    // is no cancel path that leaves a turn open here.
    case "agent:turn-end": return closeTurn(prev, msg.sessionId);
    case "agent:permission-request": return openRequest(prev, msg.sessionId, msg.permissionId);
    case "agent:question": return openRequest(prev, msg.sessionId, msg.questionId);
    case "agent:request-retracted":
      return closeRequest(prev, msg.sessionId, msg.permissionId ?? msg.questionId);
    case "notification:push": return foldNotification(prev, msg);
    case "session:updated": return foldSessions(prev, msg.sessions);
    // The project's `agent.tool`, which a SessionEntry only carries when it
    // overrode it. Emitted on every handshake and always ahead of the first
    // session list (see onHandshakeComplete in agent-core.ts), so `foldSessions`
    // has it by the time it needs it; a later change is picked up by the next
    // session list rather than recomputed here, since the fold keeps no
    // per-session tool to recompute from.
    case "agent:hello":
      return msg.tool === prev.defaultTool
        ? prev
        : build({ ...inputsOf(prev), defaultTool: msg.tool }, prev);
    default: return prev;
  }
}
