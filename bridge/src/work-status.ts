import { needsKeystrokeTurnStart, opensProvisionalTurn } from "./agent-runtime";
import type { ClientKey } from "./message-bus";
import type { AbMessage, NotificationType, WorkStatus } from "./protocol";

/** What a session's half-typed composer line will be if submitted: a prompt the
 *  agent answers with a model turn, or one of the CLI's own `/` commands. */
export type TypedLine = "prompt" | "command";

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
  /** Running sessions whose agent DOES report its turn starts, but too late to
   *  show work the moment the user submits (codex runs its start hook through a
   *  fresh shell, a second or more after Enter). A submitted prompt opens their
   *  turn at once as a {@link provisionalTurns} entry for the hook to confirm.
   *  See {@link opensProvisionalTurn}. */
  readonly provisionalStartSessions: ReadonlySet<string>;
  /** Turns {@link userReply} opened on a keystroke for a
   *  {@link provisionalStartSessions} session that nothing has confirmed yet,
   *  keyed to the clock reading that opened them. A turn-start, a tool
   *  completion or any turn end settles one; the bridge retracts one still here
   *  after a grace period ({@link retractProvisionalTurn}), which is what keeps
   *  an Enter the agent swallowed (an overlay, a dialog) from reading "working"
   *  until the idle decay. */
  readonly provisionalTurns: ReadonlyMap<string, number>;
  /** Running sessions whose hook channel has been declared dead. Subtracted from
   *  {@link keystrokeTurnSessions} on every fold, which recomputes from the agent's
   *  STATIC spec — so without this the bridge goes on inferring starts that
   *  nothing can close. See {@link noteHookChannelLost}. */
  readonly deadHookSessions: ReadonlySet<string>;
  /** Sessions {@link closeInterruptedTurn} just closed on a confirmed manual
   *  interrupt. {@link turnActivity} refuses to reopen a session in this set —
   *  a catch-all PostToolUse/PostToolUseFailure hook already in flight when the
   *  confirmation lands (`interrupt-confirm.ts` polls on a timer; the hook spawn
   *  itself costs several hundred ms) can still resolve afterward, and with
   *  nothing recorded to check against it reopened a turn the interrupt had just
   *  closed for good. Cleared by whatever opens the NEXT turn ({@link turnStart},
   *  a submitted {@link userReply}), the same window {@link isStaleIdleNudge}
   *  documents. */
  readonly interruptedTurns: ReadonlySet<string>;
  /** Timestamp (ms) of the last recorded activity for each OPEN turn — refreshed
   *  by {@link turnStart}, {@link turnActivity} and the opening path of
   *  {@link userReply}, whichever last touched it. This is the only clock
   *  anywhere in this reducer, and it is always an ARGUMENT, never read off the
   *  wall: {@link expireTurns} is the one function that compares it against a
   *  caller-supplied `now`, so every other function here stays a pure fold of
   *  its inputs regardless of when it happens to run. Keyed like
   *  {@link activeTurns}. A turn opened by a call that carried no clock reading
   *  (most of this file's own tests) has no entry, which makes it ineligible for
   *  expiry rather than eligible by a false zero. */
  readonly lastActivityAt: ReadonlyMap<string, number>;
  /** Clock reading for a HELD start/activity signal — one that named a session
   *  the last `session:updated` had not listed yet — keyed like
   *  {@link pendingTurns}, which it always has the same or fewer entries than.
   *  {@link foldSessions} carries an entry over into {@link lastActivityAt} the
   *  moment it promotes the matching `pendingTurns` id, so the exact race
   *  {@link pendingTurns} holds for is not also a turn {@link expireTurns} can
   *  never see: a promoted turn with nothing here would sit with no clock
   *  reading at all, which reads as "nothing to measure against" rather than
   *  "measured as ancient" — ineligible for expiry for its entire length. */
  readonly pendingActivityAt: ReadonlyMap<string, number>;
  /** What is sitting in each session's composer since its last inferred turn,
   *  classified by the first thing typed on it. The evidence half of the keystroke
   *  inference: a bare enter and a `/` command both start no turn, so neither has
   *  a turn-end coming. See `opensCommandLine` in keystrokes.ts. */
  readonly typedSessions: ReadonlyMap<string, TypedLine>;
  /** What each client has ON SCREEN — at most one session per client, since a
   *  client shows one at a time. Keyed by {@link ClientKey} because that is the
   *  honest granularity: the desktop owner reaches a core over loopback while
   *  each attached app device holds its own relay session, and they look at
   *  different sessions.
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
  readonly focusedSessions: ReadonlyMap<ClientKey, string>;
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
  /** Sessions an armed Handler is driving, from the latest `handler:status`
   *  (a full snapshot listing ARMED sessions only). Read by
   *  {@link parkedByHandler}; the push dispatcher asks AgentCore's own mirror of
   *  the same frame, so the two cannot disagree for long. */
  readonly handlerArmedSessions: ReadonlySet<string>;
  /** Rollup of {@link sessionStatuses} — what the project row shows. */
  readonly status: WorkStatus;
  readonly sessionStatuses: ReadonlyMap<string, WorkStatus>;
}

/** Turn-key for a signal that carries no session attribution — a hook POST
 *  without `ANTGRID_TERMINAL_ID`. The project is mid-turn; we just can't say
 *  which session, so it's tracked as one anonymous turn that any unattributed
 *  turn-end closes. Never collides with a real session id (a uuid). */
export const UNATTRIBUTED_TURN = "";

/** Is a turn open for [sessionId]? True for the session's own turn and for the
 *  anonymous one, because a project mid-turn under {@link UNATTRIBUTED_TURN}
 *  cannot say WHICH session is busy — so every session is, as far as anything
 *  that must not interrupt one is concerned. Shared with the session-bus
 *  delivery gate, which fails silently if it drifts from the status reduction:
 *  a delivery submitted against an unattributed turn lands mid-turn. */
export function turnOpenFor(activeTurns: ReadonlySet<string>, sessionId: string): boolean {
  return activeTurns.has(sessionId) || activeTurns.has(UNATTRIBUTED_TURN);
}

/** May a session-bus line be submitted into [sessionId] right now?
 *
 *  Two deliberate divergences from {@link statusFor}:
 *
 *  - The {@link UNATTRIBUTED_TURN} notification fallback is not read. A hook
 *    installed without `ANTGRID_TERMINAL_ID` files every notification under the
 *    anonymous key, which would park one project's whole queue on one config
 *    error with nothing to clear it. The same fallback IS kept for turns via
 *    {@link turnOpenFor}, where the wrong answer costs one delayed line rather
 *    than a permanent hold.
 *  - `error` does not block. It is a turn END, so no answer is coming to lift
 *    it, and a line held on one would wait for an edge nothing is going to
 *    produce instead of going in at a boundary that is already clear.
 */
export function busDeliverable(state: WorkStatusState, sessionId: string): boolean {
  if (turnOpenFor(state.activeTurns, sessionId)) return false;
  if ((state.pendingRequests.get(sessionId)?.size ?? 0) > 0) return false;
  const own = state.notifications.get(sessionId);
  // Read off `isCallToAction` rather than re-listed, minus the `error` the doc
  // above carves out: a seventh blocking notification would otherwise be added
  // there and silently miss here, parking a queue with no edge to release it.
  return own === undefined || !isCallToAction(own) || own === "error";
}

/** Sessions that were blocked for a bus delivery and are not any more — the edge
 *  a held line waits on. Pure so `commitWork` can compute it before it swaps the
 *  state it is comparing against.
 *
 *  Every condition {@link busDeliverable} holds on has to appear here or a line
 *  held on it waits for an edge nothing produces: clearing a permission prompt
 *  or answering a request leaves `activeTurns` untouched, so a turn-close edge
 *  alone would never release either. This is what bounds the hold, in place of
 *  a clock nothing would wind.
 *
 *  {@link UNATTRIBUTED_TURN} is reported as ITSELF rather than resolved: a
 *  project whose anonymous turn closed is at a boundary for every session in it,
 *  and only the caller knows which sessions those are. It is reported on the
 *  turn alone — the anonymous NOTIFICATION key is deliberately not a block (see
 *  {@link busDeliverable}), so it is not a release either. */
export function becameDeliverable(prev: WorkStatusState, next: WorkStatusState): string[] {
  const touched = new Set<string>([
    ...prev.activeTurns,
    ...prev.pendingRequests.keys(),
    ...prev.notifications.keys(),
  ]);
  return [...touched].filter((id) =>
    id === UNATTRIBUTED_TURN
      ? prev.activeTurns.has(id) && !next.activeTurns.has(id)
      : !busDeliverable(prev, id) && busDeliverable(next, id));
}

/** Sessions whose turn just OPENED — the edge a submitted session-bus line
 *  waits on to know it was actually read (`delivery-queue.ts`).
 *
 *  {@link UNATTRIBUTED_TURN} is excluded HERE rather than at the caller, because
 *  the two directions are not symmetric. An anonymous CLOSE releases every
 *  session in the project and costs at most a delayed line; an anonymous OPEN
 *  fanned out would retire every session's unconfirmed line against a turn none
 *  of them may have started, which is the silent loss the confirmation exists to
 *  end. */
export function openedTurns(prev: WorkStatusState, next: WorkStatusState): string[] {
  return [...next.activeTurns].filter((id) => id !== UNATTRIBUTED_TURN && !prev.activeTurns.has(id));
}

/** Shared empty set for every session-id set on the state — turns, running
 *  sessions, keystroke/typed markers. */
const EMPTY_IDS: ReadonlySet<string> = new Set();
const EMPTY_NOTIFICATIONS: ReadonlyMap<string, NotificationType> = new Map();
const EMPTY_REQUESTS: ReadonlyMap<string, ReadonlySet<string>> = new Map();
const EMPTY_TYPED: ReadonlyMap<string, TypedLine> = new Map();
const EMPTY_FOCUS: ReadonlyMap<ClientKey, string> = new Map();
const EMPTY_ACTIVITY: ReadonlyMap<string, number> = new Map();

/** The mutable inputs {@link build} folds into a state; everything else on
 *  WorkStatusState is derived from these. */
interface WorkInputs {
  runningSessions: ReadonlySet<string>;
  notifications: ReadonlyMap<string, NotificationType>;
  pendingRequests: ReadonlyMap<string, ReadonlySet<string>>;
  activeTurns: ReadonlySet<string>;
  pendingTurns: ReadonlySet<string>;
  keystrokeTurnSessions: ReadonlySet<string>;
  provisionalStartSessions: ReadonlySet<string>;
  provisionalTurns: ReadonlyMap<string, number>;
  deadHookSessions: ReadonlySet<string>;
  interruptedTurns: ReadonlySet<string>;
  lastActivityAt: ReadonlyMap<string, number>;
  pendingActivityAt: ReadonlyMap<string, number>;
  typedSessions: ReadonlyMap<string, TypedLine>;
  focusedSessions: ReadonlyMap<ClientKey, string>;
  readTracking: boolean;
  unreadSessions: ReadonlySet<string>;
  defaultTool: string | undefined;
  handlerArmedSessions: ReadonlySet<string>;
}

/** Notification types that mean "the turn is over" (as opposed to the
 *  call-to-action states, which are mid-turn blocks). */
function endsTurn(n: NotificationType): boolean {
  return n === "task_complete" || n === "idle" || n === "error";
}

/** A live block on a session — outlives a sibling session starting, unlike the
 *  turn-end states. `question` belongs here and NEVER in {@link endsTurn}: an
 *  agent asking is an agent still working on the turn it asked from. */
function isCallToAction(n: NotificationType): boolean {
  return n === "permission_request" || n === "awaiting_input"
    || n === "question" || n === "error";
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
    case "awaiting_input":
    case "question": return "attention";
    case "error": return parkedByHandler(sessionId, i) ? "done" : "error";
    case "task_complete":
    case "idle": return "done";
    default:
      return turnOpenFor(i.activeTurns, sessionId) ? "working" : "done";
  }
}

/** Did [sessionId]'s turn end in its OWN error while an armed Handler drives it?
 *
 *  Such a session reads done, not error: the Handler announces that stop itself
 *  (a park notice, a wrap-up or an escalation) and resumes the agent when a
 *  limit lifts, so a red dot held for the length of a park would contradict it.
 *  The error stays on record, so disarming turns the dot red again at once —
 *  a stopped agent nothing will resume is exactly what error is for. The
 *  unattributed fallback never qualifies: arming names one session, and that
 *  error could belong to any of them. */
function parkedByHandler(sessionId: string, i: WorkInputs): boolean {
  return i.handlerArmedSessions.has(sessionId) && i.notifications.get(sessionId) === "error";
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
function deriveUnread(
  i: WorkInputs,
  raw: ReadonlyMap<string, WorkStatus>,
  prev?: WorkStatusState,
  decayed?: ReadonlySet<string>,
): Set<string> {
  const unread = new Set<string>();
  for (const id of i.unreadSessions) if (raw.get(id) === "done") unread.add(id);
  if (i.readTracking && prev) {
    for (const [id, s] of raw) {
      // A decay is silence, never an answer nobody looked at — see expireTurns.
      // Nor is a Handler park: the Handler's own notice is that announcement.
      if (s !== "done" || decayed?.has(id) || parkedByHandler(id, i)) continue;
      const before = prev.sessionStatuses.get(id);
      if (before !== undefined && before !== "done" && before !== "unread") unread.add(id);
    }
  }
  for (const seen of i.focusedSessions.values()) unread.delete(seen);
  return unread;
}

/**
 * Sessions whose "blocked on a human" state flipped between two reductions.
 *
 * `attention` is this reduction's word for an unanswered permission request or
 * question, which is the only thing on a bridge that says its own human is what
 * the work waits on. Pure, so a caller can read the edge BEFORE it swaps the
 * state it is comparing against, for the reason {@link becameDeliverable} is.
 *
 * A session that left the map stopped waiting on anyone: only a running session
 * carries a status, and a stopped agent is blocked on nothing.
 */
export function attentionEdges(
  prev: { sessionStatuses: ReadonlyMap<string, WorkStatus> },
  next: { sessionStatuses: ReadonlyMap<string, WorkStatus> },
): { sessionId: string; blocked: boolean }[] {
  const edges: { sessionId: string; blocked: boolean }[] = [];
  for (const [id, status] of next.sessionStatuses) {
    const was = prev.sessionStatuses.get(id) === "attention";
    const is = status === "attention";
    if (was !== is) edges.push({ sessionId: id, blocked: is });
  }
  for (const [id, status] of prev.sessionStatuses) {
    if (status === "attention" && !next.sessionStatuses.has(id)) {
      edges.push({ sessionId: id, blocked: false });
    }
  }
  return edges;
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
 *  no predecessor, omits it. [decayed] forwards to {@link deriveUnread}; only
 *  {@link expireTurns} passes it. */
function build(i: WorkInputs, prev?: WorkStatusState, decayed?: ReadonlySet<string>): WorkStatusState {
  const raw = new Map<string, WorkStatus>();
  for (const id of i.runningSessions) raw.set(id, statusFor(id, i));
  const unreadSessions = deriveUnread(i, raw, prev, decayed);
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
    provisionalStartSessions: i.provisionalStartSessions,
    provisionalTurns: i.provisionalTurns,
    deadHookSessions: i.deadHookSessions,
    interruptedTurns: i.interruptedTurns,
    lastActivityAt: i.lastActivityAt,
    pendingActivityAt: i.pendingActivityAt,
    typedSessions: i.typedSessions,
    defaultTool: i.defaultTool,
    handlerArmedSessions: i.handlerArmedSessions,
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
    provisionalStartSessions: s.provisionalStartSessions,
    provisionalTurns: s.provisionalTurns,
    deadHookSessions: s.deadHookSessions,
    interruptedTurns: s.interruptedTurns,
    lastActivityAt: s.lastActivityAt,
    pendingActivityAt: s.pendingActivityAt,
    typedSessions: s.typedSessions,
    focusedSessions: s.focusedSessions,
    readTracking: s.readTracking,
    unreadSessions: s.unreadSessions,
    defaultTool: s.defaultTool,
    handlerArmedSessions: s.handlerArmedSessions,
  };
}

export const initialWorkStatus: WorkStatusState = build({
  runningSessions: EMPTY_IDS,
  notifications: EMPTY_NOTIFICATIONS,
  pendingRequests: EMPTY_REQUESTS,
  activeTurns: EMPTY_IDS,
  pendingTurns: EMPTY_IDS,
  keystrokeTurnSessions: EMPTY_IDS,
  provisionalStartSessions: EMPTY_IDS,
  provisionalTurns: EMPTY_ACTIVITY,
  deadHookSessions: EMPTY_IDS,
  interruptedTurns: EMPTY_IDS,
  lastActivityAt: EMPTY_ACTIVITY,
  pendingActivityAt: EMPTY_ACTIVITY,
  typedSessions: EMPTY_TYPED,
  focusedSessions: EMPTY_FOCUS,
  readTracking: false,
  unreadSessions: EMPTY_IDS,
  defaultTool: undefined,
  handlerArmedSessions: EMPTY_IDS,
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

/** Drop [id]'s recorded activity clock. Same shape as {@link withoutTurn}, over
 *  the map a turn's close must also retire — a stale reading left behind would
 *  cost nothing today (only an id in {@link WorkStatusState.activeTurns} is ever
 *  read against it), but there is no reason to let it outlive the turn it was
 *  measuring. */
function withoutActivity(map: ReadonlyMap<string, number>, id: string): ReadonlyMap<string, number> {
  if (!map.has(id)) return map;
  const next = new Map(map);
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
 *  [now], when given, refreshes {@link WorkStatusState.lastActivityAt} for the
 *  opened turn — the evidence {@link expireTurns} bounds a stuck "working" by.
 *  Omitted, the clock is left untouched rather than read off the wall, so every
 *  caller that has no timestamp handy (most of this file's own tests) keeps
 *  today's behavior exactly.
 *
 *  Pure; returns the SAME object when nothing changes — including for an
 *  UNATTRIBUTED start with nothing running, which has no session to be held
 *  against and would otherwise light up an unrelated session that starts later. */
export function turnStart(
  prev: WorkStatusState,
  sessionId?: string,
  answered?: string,
  now?: number,
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
    const pendingActivityAt = now !== undefined && prev.pendingActivityAt.get(sessionId) !== now
      ? new Map(prev.pendingActivityAt).set(sessionId, now)
      : prev.pendingActivityAt;
    if (prev.pendingTurns.has(sessionId) && pendingRequests === prev.pendingRequests
      && pendingActivityAt === prev.pendingActivityAt) return prev;
    return build({
      ...inputsOf(prev),
      pendingRequests,
      pendingActivityAt,
      pendingTurns: new Set(prev.pendingTurns).add(sessionId),
    }, prev);
  }
  if (prev.runningSessions.size === 0) return prev;
  const id = sessionId ?? UNATTRIBUTED_TURN;
  const notifications = clearNotifications(prev.notifications, id);
  const pendingRequests = clearRequests(prev.pendingRequests, id, answered);
  const open = prev.activeTurns.has(id);
  // A fresh turn retires the confirmed-interrupt mark {@link closeInterruptedTurn}
  // left on [id] — see {@link WorkStatusState.interruptedTurns}.
  const interruptedTurns = withoutTurn(prev.interruptedTurns, id);
  const lastActivityAt = now !== undefined && prev.lastActivityAt.get(id) !== now
    ? new Map(prev.lastActivityAt).set(id, now)
    : prev.lastActivityAt;
  // The agent's own word that the turn is real — see WorkStatusState.provisionalTurns.
  const provisionalTurns = withoutActivity(prev.provisionalTurns, id);
  if (notifications === prev.notifications && pendingRequests === prev.pendingRequests && open
    && interruptedTurns === prev.interruptedTurns && lastActivityAt === prev.lastActivityAt
    && provisionalTurns === prev.provisionalTurns) {
    return prev;
  }
  return build({
    ...inputsOf(prev),
    notifications,
    pendingRequests,
    interruptedTurns,
    lastActivityAt,
    provisionalTurns,
    activeTurns: open ? prev.activeTurns : new Set(prev.activeTurns).add(id),
  }, prev);
}

/** A tool call completed on [sessionId] — a catch-all "the agent is still
 *  here" signal fired after every tool use, not just at turn boundaries.
 *  Re-opens the turn if a Stop hook closed it early (an agent whose own tools
 *  keep firing cannot really be idle), and never clears a live block.
 *
 *  Deliberately not {@link turnStart}: that clears pendingRequests and every
 *  call-to-action notification, which is right for an actual new turn but
 *  wrong here — a sibling tool call finishing while the SAME turn is waiting
 *  on a question or a permission prompt must not make that block disappear
 *  out from under the user.
 *
 *  A session's own turn-end notification ({@link endsTurn}) — or the
 *  unattributed fallback it may be reading — is left standing rather than
 *  reopened under it. This signal is `async` and races the hook that actually
 *  ends a turn, so it can arrive after the REAL last Stop of a turn, with no
 *  further tool call coming to close what it would reopen: the agent has
 *  stopped, and the only thing that reopens its turn from here is the user
 *  prompting again. Reopening anyway would flip `busDeliverable` false on a
 *  session no answer is coming to unblock (`error`), or defeat
 *  {@link isStaleIdleNudge} by deleting the very `task_complete` record that
 *  suppresses the next post-completion nudge. Recording is left untouched so
 *  that suppression keeps working. A confirmed manual interrupt is the OTHER
 *  early close this races: {@link closeInterruptedTurn} clears notifications
 *  on its way out (same as an ordinary {@link closeTurn}), which would leave
 *  nothing here to check against — so it also marks the session in
 *  {@link WorkStatusState.interruptedTurns}, and this reads that mark
 *  alongside the notification check below.
 *
 *  The not-yet-listed hold mirrors {@link turnStart}'s, for the same race — a
 *  tool-completion hook can beat the session's first `session:updated` just
 *  as a turn-start can, and {@link foldSessions} promotes both holds off the
 *  same set. Unlike turnStart's hold, there is no block to clear on the way
 *  in (this signal never carries an answer), so the hold does nothing but
 *  wait.
 *
 *  [now], when given, refreshes {@link WorkStatusState.lastActivityAt} the same
 *  way {@link turnStart} does — a tool completing is exactly the kind of
 *  evidence {@link expireTurns} looks for. Omitted, the clock is left alone.
 *
 *  Pure; SAME object when nothing changes. */
export function turnActivity(
  prev: WorkStatusState,
  sessionId?: string,
  now?: number,
): WorkStatusState {
  if (sessionId !== undefined && !prev.runningSessions.has(sessionId)) {
    const pendingActivityAt = now !== undefined && prev.pendingActivityAt.get(sessionId) !== now
      ? new Map(prev.pendingActivityAt).set(sessionId, now)
      : prev.pendingActivityAt;
    if (prev.pendingTurns.has(sessionId) && pendingActivityAt === prev.pendingActivityAt) return prev;
    return build({
      ...inputsOf(prev),
      pendingActivityAt,
      pendingTurns: new Set(prev.pendingTurns).add(sessionId),
    }, prev);
  }
  if (prev.runningSessions.size === 0) return prev;
  const id = sessionId ?? UNATTRIBUTED_TURN;
  const alreadyEnded = (n: NotificationType | undefined): boolean => n !== undefined && endsTurn(n);
  if ((sessionId !== undefined && alreadyEnded(prev.notifications.get(sessionId)))
    || alreadyEnded(prev.notifications.get(UNATTRIBUTED_TURN))
    || (sessionId !== undefined && prev.interruptedTurns.has(sessionId))) {
    return prev;
  }
  const activeTurns = prev.activeTurns.has(id)
    ? prev.activeTurns
    : new Set(prev.activeTurns).add(id);
  const lastActivityAt = now !== undefined && prev.lastActivityAt.get(id) !== now
    ? new Map(prev.lastActivityAt).set(id, now)
    : prev.lastActivityAt;
  // A tool completing is the agent at work, so it confirms a provisional turn.
  const provisionalTurns = withoutActivity(prev.provisionalTurns, id);
  if (activeTurns === prev.activeTurns && lastActivityAt === prev.lastActivityAt
    && provisionalTurns === prev.provisionalTurns) return prev;
  return build({ ...inputsOf(prev), activeTurns, lastActivityAt, provisionalTurns }, prev);
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
  now?: number,
): WorkStatusState {
  const own = prev.notifications.get(sessionId);
  const blocked = own !== undefined && isCallToAction(own);
  const open = prev.pendingRequests.get(sessionId);
  const answered = requestId === undefined ? open !== undefined : open?.has(requestId) === true;
  if (!blocked && !answered) return prev;
  return turnStart(prev, sessionId, requestId, now);
}

/** The user typed into [sessionId]'s PTY. Terminal-mode sessions have no
 *  resolve frame — answering a permission prompt IS the keystroke — so this is
 *  the only signal that the block the hook reported is gone. Clears the
 *  session's own call-to-action and pending requests; the session falls back to
 *  whatever it was really doing (working if its turn is still open, done if
 *  not). Typing in an idle session must not read as work.
 *
 *  [submitted] additionally OPENS the turn, but only for a session in
 *  `keystrokeTurnSessions` (an agent reporting turn ends and no starts), and only
 *  on a line [typed] recorded as a PROMPT: a bare enter and a `/` command both
 *  fire no turn-end, so either would open a turn nothing could close. The submit
 *  consumes the line either way, so the next one classifies itself afresh.
 *
 *  Otherwise deliberately narrower than {@link turnStart}: a bare keystroke is
 *  weaker evidence than a submitted prompt, so it never clears the UNATTRIBUTED
 *  notification (it may belong to a different session) nor a turn-end state
 *  (nothing to resolve). Pure; SAME object when there was nothing to do.
 *
 *  [now], when given, refreshes {@link WorkStatusState.lastActivityAt} — but
 *  only on the [opens] path: a bare keystroke into an already-open turn is not
 *  new evidence the turn is still running, {@link turnActivity} already covers
 *  that case via the tool-completion hook. */
export function userReply(
  prev: WorkStatusState,
  sessionId: string,
  opts: { submitted?: boolean; typed?: boolean; command?: boolean } = {},
  now?: number,
): WorkStatusState {
  const own = prev.notifications.get(sessionId);
  const blocked = own !== undefined && isCallToAction(own);
  const pending = prev.pendingRequests.has(sessionId);
  // What a line this frame OPENS would be — a paste delivers "prompt text\r" as
  // one chunk, so its content counts toward its own submit.
  const opening: TypedLine | undefined = opts.typed === true
    ? (opts.command === true ? "command" : "prompt")
    : undefined;
  // A line already in the composer wins: what opened it is what classifies it,
  // and every frame after the first carries the middle of a line.
  const held = prev.typedSessions.get(sessionId);
  const line = held ?? opening;
  const provisional = prev.provisionalStartSessions.has(sessionId);
  const opens = opts.submitted === true
    && line === "prompt"
    && (prev.keystrokeTurnSessions.has(sessionId) || provisional)
    && !prev.activeTurns.has(sessionId);
  // A frame that both types and submits (a paste) leaves nothing behind: the
  // line it opens is the line the same frame consumes.
  const recordTyped = opening !== undefined && held === undefined && opts.submitted !== true;
  // The submit takes the line either way: a classification latched past its own
  // submit would mean one `/compact` silenced the session for good.
  const clearsLine = opts.submitted === true && held !== undefined;
  if (!blocked && !pending && !opens && !recordTyped && !clearsLine) return prev;
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
  if (clearsLine) {
    const next = new Map(prev.typedSessions);
    next.delete(sessionId);
    typedSessions = next;
  } else if (recordTyped && opening !== undefined) {
    typedSessions = new Map(typedSessions).set(sessionId, opening);
  }
  return build({
    ...inputsOf(prev),
    notifications,
    pendingRequests: clearRequests(prev.pendingRequests, sessionId),
    activeTurns: opens ? new Set(prev.activeTurns).add(sessionId) : prev.activeTurns,
    // A submitted prompt that actually opens a turn retires a confirmed-interrupt
    // mark the same way turnStart does — see WorkStatusState.interruptedTurns.
    interruptedTurns: opens ? withoutTurn(prev.interruptedTurns, sessionId) : prev.interruptedTurns,
    lastActivityAt: opens && now !== undefined
      ? new Map(prev.lastActivityAt).set(sessionId, now)
      : prev.lastActivityAt,
    provisionalTurns: opens && provisional
      ? new Map(prev.provisionalTurns).set(sessionId, now ?? 0)
      : prev.provisionalTurns,
    typedSessions,
  }, prev);
}

/** The maps a turn's end empties, whichever channel reported it. Shared by
 *  {@link closeTurn}, {@link hookTurnEnd} and {@link foldNotification} so a
 *  further one added here reaches all of them; [changed] is the SAME-object test. */
function withTurnEnded(prev: WorkStatusState, sessionId: string): {
  activeTurns: ReadonlySet<string>;
  pendingTurns: ReadonlySet<string>;
  pendingRequests: ReadonlyMap<string, ReadonlySet<string>>;
  lastActivityAt: ReadonlyMap<string, number>;
  provisionalTurns: ReadonlyMap<string, number>;
  changed: boolean;
} {
  const activeTurns = withoutTurn(prev.activeTurns, sessionId);
  const pendingTurns = withoutTurn(prev.pendingTurns, sessionId);
  const pendingRequests = clearRequests(prev.pendingRequests, sessionId);
  const lastActivityAt = withoutActivity(prev.lastActivityAt, sessionId);
  const provisionalTurns = withoutActivity(prev.provisionalTurns, sessionId);
  return {
    activeTurns,
    pendingTurns,
    pendingRequests,
    lastActivityAt,
    provisionalTurns,
    changed: activeTurns !== prev.activeTurns
      || pendingTurns !== prev.pendingTurns
      || pendingRequests !== prev.pendingRequests
      || lastActivityAt !== prev.lastActivityAt
      || provisionalTurns !== prev.provisionalTurns,
  };
}

/** The turn on [sessionId] is over — its turn-end frame or a chat cancel.
 *  Anything it was blocked on died with it. Pure; SAME object when there was
 *  nothing open to close.
 *
 *  NOT the confirmed-interrupt path — see {@link closeInterruptedTurn} — which
 *  needs everything here plus a mark the chat case has no use for. */
export function closeTurn(prev: WorkStatusState, sessionId: string): WorkStatusState {
  const { changed, ...ended } = withTurnEnded(prev, sessionId);
  // A chat session's block lives in pendingRequests; a terminal-mode session's
  // lives in notifications (the hook's permission_request/awaiting_input/
  // question) —
  // clearing only the former left an Esc-interrupted terminal session stuck on
  // "attention" forever, since neither a chat turn-end nor a cancel had ever
  // needed to touch this map before. Same helper turnStart uses to open a turn,
  // for the same reason: it also drops the UNATTRIBUTED fallback, since nothing
  // is left running THIS session's block against once its turn is gone.
  const notifications = clearNotifications(prev.notifications, sessionId);
  if (!changed && notifications === prev.notifications) return prev;
  return build({ ...inputsOf(prev), ...ended, notifications }, prev);
}

/** A hook-based session's manual interrupt, confirmed against its own
 *  transcript (`interrupt-confirm.ts` and `shouldArmInterruptConfirm` in
 *  agent-core.ts, the only caller) — {@link closeTurn}, plus a mark in
 *  {@link WorkStatusState.interruptedTurns} so {@link turnActivity} cannot
 *  reopen what this just closed. See that field's own doc for why the mark
 *  exists and {@link turnStart}/{@link userReply} for where it is lifted.
 *  Pure; SAME object when {@link closeTurn} was already a no-op and the
 *  session was already marked (a second Esc, or one after the mark's own
 *  turn-start already cleared it). */
export function closeInterruptedTurn(prev: WorkStatusState, sessionId: string): WorkStatusState {
  const closed = closeTurn(prev, sessionId);
  if (closed.interruptedTurns.has(sessionId)) return closed;
  return build({
    ...inputsOf(closed),
    interruptedTurns: new Set(closed.interruptedTurns).add(sessionId),
  }, closed);
}

/** A hook reported [sessionId]'s turn over on a channel carrying no notification
 *  (codex's `notify` argv) — the second closer, so an inferred turn does not hang
 *  when the other channel is silent. NOT {@link closeTurn}: it must leave the
 *  notifications map alone, or {@link isStaleIdleNudge} loses its only record and
 *  every post-completion idle nudge reads as a live block. Pure. */
export function hookTurnEnd(prev: WorkStatusState, sessionId: string): WorkStatusState {
  const { changed, ...ended } = withTurnEnded(prev, sessionId);
  if (!changed) return prev;
  return build({ ...inputsOf(prev), ...ended }, prev);
}

/** [sessionId]'s hook channel has been written off, so stop inferring turn STARTS
 *  for it and close the one it may already have inferred. The close is scoped to
 *  {@link keystrokeTurnSessions} — a turn the agent announced for itself is real
 *  work, not something a probe may call finished. Pure. */
export function noteHookChannelLost(prev: WorkStatusState, sessionId: string): WorkStatusState {
  if (prev.deadHookSessions.has(sessionId)) return prev;
  const inferred = prev.keystrokeTurnSessions.has(sessionId);
  const keystrokeTurnSessions = withoutTurn(prev.keystrokeTurnSessions, sessionId);
  return build({
    ...inputsOf(prev),
    deadHookSessions: new Set(prev.deadHookSessions).add(sessionId),
    keystrokeTurnSessions,
    // Nothing is left to confirm one; foldSessions drops it again on every list.
    provisionalStartSessions: withoutTurn(prev.provisionalStartSessions, sessionId),
    activeTurns: inferred ? withoutTurn(prev.activeTurns, sessionId) : prev.activeTurns,
    pendingTurns: inferred ? withoutTurn(prev.pendingTurns, sessionId) : prev.pendingTurns,
  }, prev);
}

/** [sessionId]'s hooks pinged after all. Drops the mark and nothing else — the
 *  inference comes back with the next `session:updated`, which recomputes the set
 *  from each entry's own tool rather than guessing off `defaultTool`. Pure. */
export function noteHookChannelRestored(prev: WorkStatusState, sessionId: string): WorkStatusState {
  if (!prev.deadHookSessions.has(sessionId)) return prev;
  return build({
    ...inputsOf(prev),
    deadHookSessions: withoutTurn(prev.deadHookSessions, sessionId),
  }, prev);
}

/** Replace one client's focus entry, or drop it when [sessionId] is undefined.
 *  Returns the SAME map when it already said that. */
function withFocus(
  map: ReadonlyMap<ClientKey, string>,
  client: ClientKey,
  sessionId: string | undefined,
): ReadonlyMap<ClientKey, string> {
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
  client: ClientKey,
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
  client: ClientKey,
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
export function clientGone(prev: WorkStatusState, client: ClientKey): WorkStatusState {
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
  let lastActivityAt = prev.lastActivityAt;
  let provisionalTurns = prev.provisionalTurns;
  // A turn-end notification closes the turn even when the reduction ignores the
  // notification itself (below) — the primary closer; hookTurnEnd only backs it up.
  if (endsTurn(msg.notificationType)) {
    ({ activeTurns, pendingTurns, pendingRequests, lastActivityAt, provisionalTurns } = withTurnEnded(prev, raw));
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
      && pendingRequests === prev.pendingRequests
      && lastActivityAt === prev.lastActivityAt
      && provisionalTurns === prev.provisionalTurns) {
      return prev;
    }
    return build({ ...inputsOf(prev), activeTurns, pendingTurns, pendingRequests, lastActivityAt, provisionalTurns }, prev);
  }
  return build({
    ...inputsOf(prev),
    notifications: new Map(prev.notifications).set(key, msg.notificationType),
    pendingRequests,
    activeTurns,
    pendingTurns,
    lastActivityAt,
    provisionalTurns,
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
  const deadHookSessions = new Set<string>();
  for (const id of prev.deadHookSessions) if (live.has(id)) deadHookSessions.add(id);
  // The spec says which agents can't report a turn START; the dead set says which
  // sessions can't report the matching END, and inferring without one wedges the
  // dot on "working" — see {@link noteHookChannelLost}.
  const keystrokeTurnSessions = new Set(
    running
      .filter((s) => s.mode !== "chat"
        && !deadHookSessions.has(s.id)
        && needsKeystrokeTurnStart(s.tool ?? prev.defaultTool))
      .map((s) => s.id),
  );
  // Same exclusions: a dead channel has no start hook left to confirm with.
  const provisionalStartSessions = new Set(
    running
      .filter((s) => s.mode !== "chat"
        && !deadHookSessions.has(s.id)
        && opensProvisionalTurn(s.tool ?? prev.defaultTool))
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
  const typedSessions = new Map<string, TypedLine>();
  for (const [id, line] of prev.typedSessions) if (live.has(id)) typedSessions.set(id, line);
  const interruptedTurns = new Set<string>();
  for (const id of prev.interruptedTurns) if (live.has(id)) interruptedTurns.add(id);
  const lastActivityAt = new Map<string, number>();
  for (const [id, t] of prev.lastActivityAt) {
    if (id === UNATTRIBUTED_TURN ? live.size > 0 : live.has(id)) lastActivityAt.set(id, t);
  }
  const provisionalTurns = new Map<string, number>();
  for (const [id, t] of prev.provisionalTurns) if (live.has(id)) provisionalTurns.set(id, t);
  // A promoted pendingTurns id carries its HELD clock reading forward the same
  // way its turn itself is promoted above — see WorkStatusState.pendingActivityAt
  // — so the exact race pendingTurns holds for does not also produce a turn
  // {@link expireTurns} can never see (no entry here reads as ineligible for
  // expiry, not as freshly active).
  for (const id of prev.pendingTurns) {
    if (!live.has(id)) continue;
    const held = prev.pendingActivityAt.get(id);
    if (held !== undefined) lastActivityAt.set(id, held);
  }
  // A newly-started session is a fresh turn of work — clear a stale done-type
  // UNATTRIBUTED notification so a turn-start on the new session isn't masked by
  // a fallback that predates it. The call-to-action signals ({@link
  // isCallToAction}) are LIVE for an already-running session; a new
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
    && sameIds(provisionalStartSessions, prev.provisionalStartSessions)
    && provisionalTurns.size === prev.provisionalTurns.size
    && prev.pendingTurns.size === 0
    && pendingRequests.size === prev.pendingRequests.size
    && notifications.size === prev.notifications.size
    && deadHookSessions.size === prev.deadHookSessions.size
    && typedSessions.size === prev.typedSessions.size
    && interruptedTurns.size === prev.interruptedTurns.size
    && lastActivityAt.size === prev.lastActivityAt.size) {
    return prev;
  }
  return build({
    ...inputsOf(prev),
    runningSessions: live,
    activeTurns,
    pendingTurns: EMPTY_IDS,
    pendingActivityAt: EMPTY_ACTIVITY,
    keystrokeTurnSessions,
    provisionalStartSessions,
    provisionalTurns,
    deadHookSessions,
    typedSessions,
    interruptedTurns,
    lastActivityAt,
    pendingRequests,
    notifications,
  }, prev);
}

/** Fold one outbound bus frame into the reduction. Pure and total; returns the
 *  SAME object when the frame is irrelevant or changes no input, so callers can
 *  detect a real transition by `next !== prev` (and re-advertise only then). */
export function reduceWorkStatus(prev: WorkStatusState, msg: AbMessage): WorkStatusState {
  switch (msg.type) {
    // The message's own `timestamp` is the clock reading, never `Date.now()` —
    // this function stays a pure fold of its arguments so it can double as an
    // `Array.reduce` callback (a third parameter here would silently bind to
    // the array INDEX instead of a caller's clock).
    case "agent:turn-start": return turnStart(prev, msg.sessionId, undefined, msg.timestamp);
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
    case "handler:status": {
      const armed = new Set(msg.sessions.map((s) => s.terminalId));
      // Every emit repeats the whole map, most of them for a backlog or goal
      // change that arms nothing; an unchanged set must return [prev] itself.
      return sameIds(armed, prev.handlerArmedSessions)
        ? prev
        : build({ ...inputsOf(prev), handlerArmedSessions: armed }, prev);
    }
    default: return prev;
  }
}

/** How long a turn may go with no recorded activity before {@link expireTurns}
 *  treats it as abandoned rather than working. */
export const DEFAULT_TURN_IDLE_MS = 30 * 60_000;

/** How long a provisional turn waits for its agent's start hook before
 *  {@link retractProvisionalTurn} takes it back. Several times the slowest start
 *  measured (codex's first prompt, about 4 s), because a retraction that comes
 *  too early flips a working session to done until its next tool completes. */
export const PROVISIONAL_TURN_GRACE_MS = 30_000;

/** Close every OPEN turn idle longer than [maxIdleMs], measured against [now]
 *  and each turn's {@link WorkStatusState.lastActivityAt} — the backstop for
 *  whatever leaves a turn with no closer of its own: a missed interrupt key, a
 *  loopback POST that never arrived, a bridge restart mid-turn. Per-agent key
 *  detection and the catch-all tool-completion hook ({@link turnActivity}) are
 *  what should ordinarily close a turn; this is what bounds the ones they miss.
 *
 *  Three classes of turn are excluded from consideration entirely, rather than
 *  closed and papered over:
 *  - {@link WorkStatusState.keystrokeTurnSessions} — an agent with no per-tool
 *    hook to re-assert liveness (cursor/copilot) has no way to repair a false
 *    close before its real one, unlike Claude/Codex's {@link turnActivity}.
 *  - A pending request, or a call-to-action notification (own or the
 *    UNATTRIBUTED fallback): the session's idle time belongs to the human, not
 *    the agent. {@link statusFor}'s precedence already shows the block ahead of
 *    an open turn, so decaying the turn underneath it is invisible right up
 *    until the block clears via a path that does not reopen one (a retraction,
 *    a terminal keystroke answer) — at which point the session would read
 *    "done" and go bus-deliverable while the agent is actually resuming.
 *
 *  Deliberately NOT {@link closeTurn}: a decay is a guess, not the agent's own
 *  word that it is done, so it records no notification.
 *
 *  A turn nothing has ever stamped a clock reading onto (every caller in this
 *  file's own tests that omits [now]) is left alone: absence from
 *  {@link WorkStatusState.lastActivityAt} is "nothing to measure against", not
 *  "measured as ancient".
 *
 *  Pure; SAME object when nothing expires. */
export function expireTurns(prev: WorkStatusState, now: number, maxIdleMs: number): WorkStatusState {
  const expired = new Set<string>();
  for (const id of prev.activeTurns) {
    // A session with no repair path for a false decay (see {@link
    // WorkStatusState.keystrokeTurnSessions}) never gets a re-assert from
    // {@link turnActivity} — cursor/copilot have no per-tool hook at all — so a
    // false close here is not temporary the way it is for an agent with one:
    // nothing ever reopens it before the turn really ends. Leaving the clock
    // unenforced for them is the smaller cost.
    if (prev.keystrokeTurnSessions.has(id)) continue;
    // A session genuinely waiting on the human (a pending request, or a
    // call-to-action notification) never decays: its idle time belongs to
    // the human, not the agent, and {@link statusFor}'s own precedence
    // already reads that block ahead of an open turn — so closing the turn
    // underneath it would be invisible right up until the block clears via a
    // path (a retraction, a terminal keystroke answer) that does not reopen
    // one, at which point the session would read "done" and become
    // deliverable while the agent is actually resuming.
    if ((prev.pendingRequests.get(id)?.size ?? 0) > 0) continue;
    const ownOrFallback = prev.notifications.get(id) ?? prev.notifications.get(UNATTRIBUTED_TURN);
    if (ownOrFallback !== undefined && isCallToAction(ownOrFallback)) continue;
    const last = prev.lastActivityAt.get(id);
    if (last !== undefined && now - last > maxIdleMs) expired.add(id);
  }
  if (expired.size === 0) return prev;
  const activeTurns = new Set(prev.activeTurns);
  const lastActivityAt = new Map(prev.lastActivityAt);
  const provisionalTurns = new Map(prev.provisionalTurns);
  for (const id of expired) {
    activeTurns.delete(id);
    lastActivityAt.delete(id);
    provisionalTurns.delete(id);
  }
  // A decayed UNATTRIBUTED_TURN was the ONLY reason every other running session
  // read "working" (see turnOpenFor's fallback) — deriveUnread's exclusion has
  // to reach those sessions by their own id, since nothing in `raw` is ever
  // keyed by the anonymous one.
  const decayed = expired.has(UNATTRIBUTED_TURN)
    ? new Set([...expired, ...prev.runningSessions])
    : expired;
  // decayed excludes these closes from deriveUnread's transition scan — see its
  // own doc for why a decay must not raise the "come and look" mark.
  return build({ ...inputsOf(prev), activeTurns, lastActivityAt, provisionalTurns }, prev, decayed);
}

/** Take back the turn {@link userReply} opened provisionally at [openedAt] on
 *  [sessionId], because nothing confirmed it inside the bridge's grace period —
 *  the Enter never reached the agent as a prompt. Keyed to [openedAt] so a timer
 *  from an earlier Enter cannot retract the turn a later one opened.
 *
 *  Closed the way {@link expireTurns} closes a turn, and for the same reason: a
 *  guess, not the agent's word, so it records no notification and raises no
 *  unread mark. Pure; SAME object when that turn is no longer provisional. */
export function retractProvisionalTurn(prev: WorkStatusState, sessionId: string, openedAt: number): WorkStatusState {
  if (prev.provisionalTurns.get(sessionId) !== openedAt) return prev;
  return build({
    ...inputsOf(prev),
    activeTurns: withoutTurn(prev.activeTurns, sessionId),
    lastActivityAt: withoutActivity(prev.lastActivityAt, sessionId),
    provisionalTurns: withoutActivity(prev.provisionalTurns, sessionId),
  }, prev, new Set([sessionId]));
}
