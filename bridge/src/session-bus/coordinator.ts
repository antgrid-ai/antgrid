// The bus's transport half: it owns the stores for the sessions its owner hands
// it — one project's, when a core builds its own fallback instance, or every
// project's on the machine, when the host builds the one shared instance — and
// turns an agent's message into an addressed frame, and folds an inbound frame
// back into a store. It knows nothing about how a frame travels — a `send` that
// returns false is all it needs to hold the frame and try again — which is what
// lets ONE module serve both ends of a link neither can open (E4: a bridge
// cannot dial another bridge; the initiating machine's desktop app carries).
//
// TWO INVARIANTS LIVE HERE AND NOWHERE ELSE.
// Every frame leaves through `deps.send`, never through the MessageBus: a
// published frame reaches every established app session, and the human's phone
// is one of them. And an inbound frame is applied only when its `to` names a
// session THIS bridge holds, so a carrier is trusted to deliver and never to say
// which of this bridge's sessions a message belongs to.

import { randomUUID } from "node:crypto";
import { logger } from "../logger";
import {
  createMessage,
  type AbMessage,
  type BusEnvelope,
  type BusPart,
  type SessionMemberKey,
  type SessionMemberRef,
} from "../protocol";
import { addressesSameSession, namesMachine } from "./address";
import { listSessionBusSessions } from "./store-fs";
import { artifactById, loadArtifacts, readArtifactContent, type ArtifactState } from "./artifact-store";
import {
  ARTIFACT_CHUNK_BYTES,
  BUS_ROUTE_PERSIST_INTERVAL_MS,
  BUS_ROUTE_TTL_MS,
  MAX_BUS_ROUTES,
} from "./constants";
import {
  budgetFor,
  checkHalt,
  checkNotify,
  noteExchange,
  noteNotify,
  noteProgress,
  pairKey,
  type PairBudgetState,
} from "./pair-budget";
import { checkEnvelopeSize, stampEnvelope, type EnvelopeDraft } from "./envelope";
import { refuse, type SessionBusRefusal } from "./errors";
import { loadBusRoutes, saveBusRoutes, type BusRouteDrops, type BusRouteMap } from "./route-store";
import {
  emptyHeld,
  expireHeld,
  hasHeld,
  holdMessage,
  loadHeld,
  releaseHeld,
  saveHeld,
  type HeldState,
} from "./held-store";
import {
  appendLog,
  emptyLog,
  lastOutboundSummary,
  loadMessageLog,
  markDelivered,
  saveMessageLog,
  type MessageLogState,
} from "./message-log";
import {
  appendPost,
  emptyMailbox,
  loadMailbox,
  markRead,
  saveMailbox,
  type MailboxState,
} from "./mailbox";
import {
  emptyThreads,
  loadThreads,
  saveThreads,
  upsertThread,
  threadById,
  type ThreadState,
} from "./thread-store";

const log = logger.child({ component: "session-bus" });

export type BusRole = "lead" | "peer";

/** This bridge's own half of an address, plus the labels it stamps onto what it
 *  sends. Labels travel because the other machine can never look them up: it
 *  cannot reach this one (E4). */
export interface SessionBusSelf {
  key: SessionMemberKey;
  ref: SessionMemberRef;
}

/**
 * Hand one frame to whatever carries this context.
 *
 * False means it did not leave — no carrier, or a carrier that cannot forward —
 * and the frame is held rather than dropped. Never a throw and never a failure:
 * an absent carrier is not a failed exchange.
 */
/**
 * What {@link SessionBusCoordinator.handleInbound} did with a frame.
 *
 * `false` means it was not a bus frame at all. The other two carry the
 * difference a local deliverer depends on: only an applied frame reached a
 * session this bridge holds, so only an applied frame may be reported as
 * delivered rather than held and retried.
 */
export type InboundOutcome = false | "applied" | "dropped";

export type SessionBusSend = (
  frame: AbMessage,
  ctx: { contextId: string; role: BusRole; to: SessionMemberKey },
) => boolean;

/** What the coordinator learned from an inbound frame, for the layer that turns
 *  it into a line an agent reads. Emitted AFTER the store is written, so a
 *  consumer that throws cannot cost the fold. */
export type SessionBusEvent = {
  /** The verb the sender chose, carried through unchanged: a post is read when
   *  the target chooses and a notify interrupts, and only the sender knows
   *  which it meant. */
  kind: "post" | "notify";
  sessionId: string;
  threadId: string | null;
  /** Whether this arrival is the first one on its thread at THIS receiver, which
   *  is not the same question as whether the frame carries a thread id: every
   *  send mints one, so an id is always present and only the thread store can
   *  say whether the exchange is new here. */
  opensThread: boolean;
  peer: SessionMemberRef;
  envelope: BusEnvelope;
  /** What this session last said on this thread, when the event continues one
   *  and the log still holds it. Read here rather than by the layer that
   *  renders it: the coordinator owns the log, and a second reader would resolve
   *  the owning project for itself and could answer about a different one. */
  answering?: string;
};

export interface CoordinatorDeps {
  abDir: string;
  /** Which project owns [sessionId]'s bus state, or null when this coordinator
   *  has no record of it at all. One coordinator now answers for every project
   *  a machine has open (E9/§5.4's directory), not one project's own sessions —
   *  so every store call below resolves its path PER SESSION instead of
   *  assuming one shared projectId. A per-core fallback (no host) answers this
   *  with a constant closure over its own project id, which is what makes it
   *  behave exactly as a single-project coordinator did before this widened. */
  projectIdFor: (sessionId: string) => string | null;
  send: SessionBusSend;
  /** This bridge's address for one of its own sessions, or null when the machine
   *  has no identity to be addressed by. */
  self: (sessionId: string) => SessionBusSelf | null;
  /** Whether this machine has a bus address at all. Consulted ONLY when `self`
   *  answers null, to tell the two reasons it can apart: a session this bridge
   *  does not hold is `NOT_MEMBER`, while a machine with no relay identity is
   *  `AGENT_NOT_READY`. Without it a caller on a live session is refused "not a
   *  member", which reads as an addressing bug and sends the reader looking in
   *  the wrong place. Absent means addressable, so a core that never wires it
   *  keeps today's answer. */
  addressable?: () => boolean;
  /** Hand a frame straight to the session it names on THIS machine, bypassing
   *  the relay, the carrier and the route table entirely (§6.1). False means it
   *  could not be delivered in process — the target's project is not loaded, or
   *  a store write failed — and the frame takes the ordinary send path so it is
   *  held rather than lost. Absent means this coordinator has no local path at
   *  all, which is every caller until the host wires one. */
  deliverLocal?: (frame: AbMessage, to: SessionMemberKey) => boolean;
  /** The per-pair budget (§7.4), read before a send and charged by every
   *  message this end sends OR receives — see `pair-budget.ts`'s header for why
   *  both halves have to land on this end's mirror.
   *  Held by whoever owns every project's rather than by this class: a halt
   *  "cleared only by a human" has to survive a restart, and a counter kept in
   *  memory here would be cleared by one. Absent means unbudgeted — the honest
   *  answer for a bare bus with no host above it, and the reason a unit test
   *  that wires none is not silently subject to a ceiling it never asked for. */
  pairBudget?: {
    recordsFor(sessionId: string): readonly PairBudgetState[];
    write(sessionId: string, next: PairBudgetState): void;
  };
  /** Lift the no-progress halt on every pair this session is an end of, at both
   *  mirrors of it this machine holds.
   *  Held by whoever owns the budget rather than here: a halt cleared only by a
   *  human has to survive a restart, and a counter this class kept in memory
   *  would be cleared by one. */
  clearHalt?: (sessionId: string) => void;
  onEvent?: (event: SessionBusEvent) => void;
  now?: () => number;
  newId?: () => string;
}

interface SessionState {
  log: MessageLogState;
  /** Messages the transport refused, awaiting a route. Held rather than dropped
   *  because a `send` that returned false never reached the relay, so putting
   *  the frame out later is a delivery and not a second copy. */
  held: HeldState;
  /** Posts parked for this session to read when it chooses (§7.1). Loaded with
   *  the log rather than lazily like artifacts: an inbound post writes it, and a
   *  session that has one waiting is exactly the session a restart must find. */
  mailbox: MailboxState;
  /** Which exchange each thread this session is part of rides on — the only
   *  thing that can tell a reply where to go, for a thread a peer opened over a
   *  notify that left no mail. */
  threads: ThreadState;
  /** Read on the first fetch this session answers: most sessions publish nothing
   *  and never pay for the file. */
  artifacts: ArtifactState | null;
  /** `deps.projectIdFor(sessionId)` as answered when this state was first
   *  loaded, pinned rather than re-queried on every commit: a session mid
   *  project-teardown must not have one write land under the project its
   *  first read came from and a later write land under whatever the resolver
   *  says next. Null means unresolved — kept in memory only, never persisted,
   *  which is the honest answer for bus state this bridge cannot place. */
  projectId: string | null;
}

export interface MessageInput {
  sessionId: string;
  /** Which verb the caller chose (§7.1). A post is parked in the target's
   *  mailbox and interrupts nothing; a notify becomes a line at the target's
   *  next turn boundary. Everything after the send decision is identical, which
   *  is why the two travel as one shape. */
  verb: "post" | "notify";
  /** The thread this turn belongs to, or null to open a new one. The coordinator
   *  MINTS an id when this is null and returns it, because an agent that was
   *  never told the id cannot reply on the thread (§4.3). Correlation only — a
   *  thread has no state machine (§4.2) — so a supplied id is carried and never
   *  validated. */
  threadId: string | null;
  to: SessionMemberRef;
  summary: string;
  parts: BusPart[];
  unexpected?: string;
  contextId?: string;
}

export interface MessageResult {
  ok: true;
  /** That the frame LEFT, never that it arrived: everything this side of the
   *  relay can only report departure, and the other end's receipt is the one
   *  honest witness (E6). */
  sent: boolean;
  held: boolean;
  messageId: string;
  /** Always a real id — minted here when the caller supplied none — because it
   *  is what the caller replies on. */
  threadId: string;
  /** Whether this send OPENED that thread, which is §7.4's definition of
   *  progress and so the signal the budget resets on. */
  opensThread: boolean;
}

/** Anything this coordinator sends. Every bus frame carries both endpoints, and
 *  the local branch of {@link SessionBusCoordinator.dispatch} needs the sender's
 *  machine id to know whether the target shares it.
 *
 *  Matched on those endpoints and not on the type name alone: the `session-bus:`
 *  prefix also covers the reads an app makes of its OWN bridge, which are
 *  addressed by session id and carry no `from`/`to` at all. */
type BusFrame = Extract<
  AbMessage,
  { type: `session-bus:${string}`; from: SessionMemberKey; to: SessionMemberKey }
>;

/** How often held messages are retried. One second is the shortest step worth
 *  taking, so a slower tick would round every retry up to itself. */
export const OUTBOX_TICK_MS = 1_000;

export class SessionBusCoordinator {
  private sessions = new Map<string, SessionState>();
  private timer: ReturnType<typeof setInterval> | null = null;
  private readonly now: () => number;
  private readonly newId: () => string;
  // Which app session — and which project's stream — carried a context in,
  // machine-wide. Moved here (from a per-core closure) so a route learned while
  // handling project A's inbound frame is the SAME table project B's outbound
  // send for that context consults; see noteRoute/routeFor. This table does not
  // decide anything on its own: every frame leaves through `dispatch`, which
  // consults `deliverLocal` first and this table not at all — the
  // lookup-then-send decision belongs to whoever wired `send`, because only it
  // knows what a `sendToAppSession`/`sendToOwner` call means.
  private routes: BusRouteMap = new Map();
  private routesSavedAt = 0;
  // Per-project bus-event consumers, registered via `setListener` (the seam
  // `AgentCore.setSessionBusListener` feeds). One coordinator now fires one
  // `onEvent` for every project's sessions, so a single hard-wired consumer
  // would deliver into whichever project registered — silently wrong for
  // every other one. Resolved per event through `deps.projectIdFor`.
  private readonly listeners = new Map<string, (event: SessionBusEvent) => void>();

  constructor(private deps: CoordinatorDeps) {
    this.now = deps.now ?? (() => Date.now());
    this.newId = deps.newId ?? (() => randomUUID());
  }

  /**
   * Seed the route table from the machine-level store (E9/§5.4).
   *
   * Unlike a session's message log or held store — loaded lazily, the first
   * time THAT session is addressed, because each belongs to exactly one
   * project — a route is looked up by CONTEXT id, which may name a session in
   * any project on the machine, so there is no single project whose warm-up
   * can defer this. Synchronous, because `loadBusRoutes` is: meant to run once,
   * before the first inbound frame this process folds, so a restart does not
   * relearn every route a live link would otherwise still have.
   */
  hydrateRoutes(): void {
    for (const [contextId, route] of loadBusRoutes(this.deps.abDir, BUS_ROUTE_TTL_MS, this.now())) {
      // The host's own call site runs this off a `.finally()` on an async
      // hydrate, so live inbound traffic can already have called `noteRoute`
      // for [contextId] before this resolves — newest `at` wins, same rule as
      // the write-side merge in route-store.ts, or a route learned live is
      // silently overwritten by whatever a slower disk read turns up.
      const existing = this.routes.get(contextId);
      if (!existing || route.at > existing.at) this.routes.set(contextId, route);
    }
  }

  /**
   * Record which app session — and which project's stream — carried
   * [contextId] in, so a later peer-role send on this context knows where home
   * is. Called only for a frame that cleared `handleInbound`'s address check —
   * from its `onAccepted` hook, which fires at exactly that point: the check is
   * what proves the sender is talking about a session this bridge actually
   * holds, and this table is the other end's only route back, so noting ahead
   * of it would let any app session rebind the context with one syntactically
   * valid frame carrying someone else's contextId, and take the next answer for
   * itself.
   *
   * The project named here is the one whose stream the frame ARRIVED on, and
   * it is deliberately not compared against whichever project owns
   * [contextId]: a lead context's id IS a local session id
   * (`roleForContext`'s own rule below), so on the same machine E9/§5.4's own
   * case — a worktree session in project W answering its parent's context in
   * project P — always arrives with the two disagreeing. Refusing that
   * mismatch reinstates exactly the unreachability the move exists to remove,
   * and buys nothing: a forged frame stamping another project's session id as
   * its contextId presents identically here (applied frame, addressed to a
   * session in the arriving project, contextId owned elsewhere), and the
   * genuinely remote context the check would have to let through — its lead
   * living on the OTHER machine, so attributable to no local project at all —
   * is the common shape anyway. What a peer may name once admitted is bounded
   * at the gate that admits it, not at this table; see bridge/CLAUDE.md's E9
   * bullet for what does and does not bound it today.
   *
   * No peerId means the loopback owner — this machine's own desktop app,
   * already reachable without a route.
   */
  noteRoute(contextId: string, peerId: string | undefined, projectId: string): void {
    if (!peerId) return;
    const now = this.now();
    // Named, not counted: the save below has to say which rows it means gone,
    // or the merge reads their absence from this table as "unknown" and copies
    // them straight back off disk.
    const dropped: string[] = [];
    for (const [key, origin] of this.routes) {
      if (now - origin.at >= BUS_ROUTE_TTL_MS) {
        this.routes.delete(key);
        dropped.push(key);
      }
    }
    const previous = this.routes.get(contextId)?.peerId;
    // Deleted before it is set so a restamp moves the entry to the back: a Map
    // keeps first-insertion order, and the eviction below reads the front as
    // the least recently carried.
    this.routes.delete(contextId);
    this.routes.set(contextId, { peerId, projectId, at: now });
    while (this.routes.size > MAX_BUS_ROUTES) {
      const oldest = this.routes.keys().next();
      if (oldest.done) break;
      this.routes.delete(oldest.value);
      dropped.push(oldest.value);
    }
    this.saveRoutesIfDue(now, dropped.length > 0 || previous !== peerId, { contextIds: dropped });
    // Logged because a carrier attach is otherwise invisible: nothing else
    // records which app session a bus context routes through, which makes a
    // peer that cannot answer indistinguishable from one that was never
    // carried.
    if (previous !== peerId) {
      log.info("session bus: context %s routes home via app session %s (project %s)", contextId, peerId, projectId);
    }
  }

  /**
   * The live route entry, or null. Returned by reference so a caller that
   * actually gets a frame out can stamp `.at` — see each `send` implementation
   * (agent-core.ts's per-core fallback, host-server.ts's machine dispatcher).
   *
   * A route is sized to outlast a conversation rather than a round trip: a
   * reply may be the first frame the other side sends after a long stretch of
   * silence, and one that lapsed in between would strand it. A successful send
   * refreshes it too (the `.at` restamp above), so a route in continuous use
   * never ages out at all. An expired entry costs nothing but a held frame,
   * which the next inbound frame on the context releases — and a miss here is
   * NEVER a fallback to broadcast: that would put another session's words on
   * the human's phone.
   */
  routeFor(contextId: string): { peerId: string; projectId: string; at: number } | null {
    const origin = this.routes.get(contextId);
    if (!origin) return null;
    const now = this.now();
    if (now - origin.at >= BUS_ROUTE_TTL_MS) {
      this.routes.delete(contextId);
      this.saveRoutesIfDue(now, true, { contextIds: [contextId] });
      return null;
    }
    return origin;
  }

  /** Persist the map, throttled: a binding change or a drop is written at
   *  once, a bare restamp only every {@link BUS_ROUTE_PERSIST_INTERVAL_MS}.
   *  One machine-level file (E9/§5.4/C5), so this table's own rows are only
   *  ONE process's view of it — two hosts pointed at one ANTGRID_DIR is a
   *  documented setup (dev stack beside an installed bridge), not a
   *  once-per-abDir guarantee this coordinator can lean on. `saveBusRoutes`
   *  merges into whatever the other one last wrote rather than replacing it,
   *  which is what makes that sharing safe — and is why every DELETION has to
   *  be named in [drops]: a merge cannot read a row's absence from this table
   *  as anything but "unknown to me", so a forced write of a pruned map would
   *  otherwise persist nothing at all. */
  private saveRoutesIfDue(now: number, force: boolean, drops?: BusRouteDrops): void {
    if (!force && now - this.routesSavedAt < BUS_ROUTE_PERSIST_INTERVAL_MS) return;
    this.routesSavedAt = now;
    try {
      saveBusRoutes(this.deps.abDir, this.routes, drops);
    } catch (err) {
      // A route that outlives this process is an optimisation over relearning
      // one; a bridge must not fail to carry a frame because it could not
      // write that down.
      log.warn("session bus: could not persist carrier routes: %s", err);
    }
  }

  /**
   * Drop every route naming [projectId], from the table AND from disk. Called
   * only when the project itself is forgotten (`HostServer.forget`): the
   * machine-level route table (`bus-db.ts`) lives outside
   * `agents/<projectId>/`, so the tree delete that reclaims everything else the
   * project owned cannot reach these rows — this is their only reclaim. The
   * write is FORCED rather than throttled, and names [projectId] as a
   * `BusRouteDrops` — a plain merge-on-write would read this project's absence
   * from the in-memory table as "unknown", not "gone", and write the very rows
   * this call means to erase straight back from disk. The drop must be durable
   * on its own: `forget` may be the last bus-relevant thing this process ever
   * does, and an in-memory drop nothing persisted is undone by the next process
   * start, since `hydrateRoutes` reads the file without asking whether the
   * machine still holds the projects it names.
   *
   * Never called on an eviction: a merely-cold project is still real, and its
   * routes must survive for the coordinator to keep dispatching against once it
   * warms again, the same way its sessions survive in the session index.
   */
  forgetProjectRoutes(projectId: string): void {
    let dropped = false;
    for (const [contextId, route] of this.routes) {
      if (route.projectId === projectId) {
        this.routes.delete(contextId);
        dropped = true;
      }
    }
    if (dropped) this.saveRoutesIfDue(this.now(), true, { projectId });
  }

  /** Register (or, with null, clear) the per-project consumer that turns a bus
   *  event into a line its own agent reads. `AgentCore.setSessionBusListener`
   *  is the public seam that feeds this — called by whoever holds the core
   *  (a host, or a test) once per project, so this table has at most one entry
   *  per project regardless of how many projects share this coordinator. */
  setListener(projectId: string, fn: ((event: SessionBusEvent) => void) | null): void {
    if (fn) this.listeners.set(projectId, fn);
    else this.listeners.delete(projectId);
  }

  /** Read one session's stores off disk. Idempotent, and worth calling as a
   *  session becomes addressable: a restart must resume retrying rather than
   *  drop a held message on the floor. */
  load(sessionId: string): void {
    this.stateFor(sessionId);
    this.ensureTimer();
  }

  /**
   * Hydrate every session this coordinator answers for that left bus state on
   * disk — machine-wide when a host owns it, since the enumeration below reads
   * every project's directory and only `projectIdFor` narrows it.
   *
   * A restart is the only case that needs it, and the case that would otherwise
   * lose a message in silence: `pump` drains the sessions it holds in memory and
   * a fresh process holds none, so a message the dead process could not send
   * would simply never go. Called once, at process start — machine-wide when
   * host-injected, or once per fallback core with no host — never again on a
   * later carrier attach: it re-enumerates every session bus directory this
   * coordinator can see, and a flaky carrier reconnecting would otherwise turn
   * into a reconnect storm that re-scans the whole machine on every flap.
   * `pump()` alone is what a carrier attach needs — the in-memory outbox this
   * call seeded already holds what `resume()` would only rediscover.
   */
  resume(): void {
    for (const { projectId, sessionId } of listSessionBusSessions(this.deps.abDir)) {
      // The directory enumeration names the project bytes are FILED under; the
      // index (`projectIdFor`) is the authoritative answer for who OWNS them
      // now — the two can disagree for a session whose project was renamed,
      // reassigned or forgotten but not yet swept, and comparing against the
      // enumerated id (rather than only checking non-null) is what tells that
      // apart from a resolver that isn't session-aware at all: a per-core
      // fallback (no host) answers `projectIdFor` with a constant closure over
      // its own project id (CoordinatorDeps's own doc on the field), so a bare
      // non-null check never skips anything and a hostless core resuming
      // against the shared machine-wide `agents/` tree would load every OTHER
      // project's on-disk bus state and pin it under its own project id.
      const owner = this.deps.projectIdFor(sessionId);
      if (owner !== projectId) {
        log.warn(
          "session-bus: resume found bus state for session %s filed under project %s, but this bridge attributes it to %s — skipped",
          sessionId, projectId, owner ?? "no known project",
        );
        continue;
      }
      this.stateFor(sessionId);
    }
  }

  /**
   * Drop every session state this coordinator holds for [projectId], from
   * memory only — nothing here touches disk. Called only when the project
   * itself is forgotten (`HostServer.forget`), symmetric with
   * `forgetProjectRoutes` above and for the same reason: `deleteProjectStores`
   * has already removed `agents/<projectId>/session-bus/` by the time this
   * runs, and a `SessionState` left in `this.sessions` is exactly what
   * recreates it — a held-message retry commits under whatever
   * `SessionState.projectId` was PINNED to at first load (see that field's own
   * doc), not under whatever `projectIdFor` answers now, so leaving the entry
   * in place would write straight back to the directory forget() just
   * reclaimed.
   *
   * Reads the pinned field rather than re-querying `deps.projectIdFor`
   * deliberately: `HostServer.forget()` drops the project from its session
   * index before calling this, so by the time this runs `projectIdFor` no
   * longer resolves any of this project's sessions at all — a live re-query
   * would find nothing to drop.
   *
   * Never called on an eviction, mirroring `forgetProjectRoutes`: a merely-cold
   * project is still real, and its held state must survive for the coordinator
   * to keep retrying once it warms again.
   */
  forgetProjectStates(projectId: string): void {
    for (const [sessionId, state] of this.sessions) {
      if (state.projectId === projectId) this.sessions.delete(sessionId);
    }
  }

  forget(sessionId: string): void {
    this.sessions.delete(sessionId);
  }

  stop(): void {
    if (!this.timer) return;
    clearInterval(this.timer);
    this.timer = null;
  }

  messages(sessionId: string): MessageLogState {
    return this.stateFor(sessionId).log;
  }

  mailbox(sessionId: string): MailboxState {
    return this.stateFor(sessionId).mailbox;
  }

  threads(sessionId: string): ThreadState {
    return this.stateFor(sessionId).threads;
  }

  /** Mark what a reader was just handed. Separate from {@link mailbox} because
   *  reading is what spends the unread flag, and a getter that marked would make
   *  every incidental peek destroy the inbox. */
  markMailboxRead(sessionId: string, messageIds: readonly string[]): void {
    const s = this.stateFor(sessionId);
    const mailbox = markRead(s.mailbox, messageIds);
    if (mailbox !== s.mailbox) this.commit(sessionId, { mailbox });
  }

  /**
   * Lift a no-progress halt (`docs/session-messaging.md` §7.4).
   *
   * A human's own submitted reply into the halted session is what reaches here.
   * The halt says two agents exchanged messages while the work stood still, and
   * it holds out for a human to look — a person typing into that very session is
   * exactly that, and it is the only such signal a bridge can observe. An agent
   * cannot forge it: nothing an agent submits arrives as terminal input.
   *
   * Delegated rather than answered here, and with no loaded-session check in
   * front of it: the budget is per PAIR and belongs to whoever holds every
   * project's, so a keystroke has to be able to lift a halt on a session this
   * coordinator is not currently holding — which is exactly the signal §7.4 says
   * lifts it. A coordinator with no budget wired clears nothing, which is the
   * honest answer for a bare bus with no host above it.
   */
  clearHalt(sessionId: string): void {
    this.deps.clearHalt?.(sessionId);
  }

  // -- outbound ---------------------------------------------------------------

  /**
   * Send one message to another session.
   *
   * Lossy on purpose: a send that does not leave is HELD, not queued for
   * unbounded retry, and a message carries no seq and expects no reliable
   * delivery. Anything that must survive is an Artifact (§4.1).
   */
  message(input: MessageInput): MessageResult | SessionBusRefusal {
    const self = this.deps.self(input.sessionId);
    if (!self) return this.noSelf();
    const to = keyOf(input.to);
    // Structural, not defensive. `dispatch` delivers a local target in process
    // by re-entering `handleInbound`, so a self-addressed send would fold this
    // one session's state twice inside a single call and commit the half read
    // before the fold over the half written by it. The directory never offers
    // the caller its own row, so refusing costs nothing legitimate.
    if (addressesSameSession(self.key, to)) {
      return refuse("UNKNOWN_PEER", "a session cannot address itself; name another session on this repository");
    }
    // A bridge with no relay identity names itself by the local sentinel so the
    // sessions it spawned can reach each other (§6.1). It can reach nothing
    // else, and a frame stamped with the sentinel and held for a carrier that
    // attaches later would arrive carrying a `from` no reply can route back to.
    if (!namesMachine(to.machineId, self.key.machineId) && this.deps.addressable?.() === false) {
      return refuse("AGENT_NOT_READY", "this machine has no relay identity, so it can only reach sessions on itself");
    }
    const s = this.stateFor(input.sessionId);

    const now = this.now();
    // Both ceilings of §7.4, read BEFORE anything is stamped or logged: a
    // refusal must leave no trace of the message it refused, or a halted pair
    // accumulates thread rows for exchanges that never happened.
    const budget = this.pairBudgetFor(input.sessionId, self, to);
    const refusal = refusalForPair(budget, input.verb, now);
    if (refusal) return refusal;
    const contextId = input.contextId ?? input.sessionId;
    // Minted here when the caller has none, and RETURNED either way: §4.3 makes
    // the id bridge-owned except when replying, so an agent that is not told it
    // has no way to answer on the thread it just opened.
    const opensThread = input.threadId === null;
    const threadId = input.threadId ?? this.newId();
    const envelope = this.stamp(self, {
      threadId,
      contextId,
      parts: input.parts,
      summary: input.summary,
      ...(input.unexpected === undefined ? {} : { unexpected: input.unexpected }),
    });
    const tooLarge = checkEnvelopeSize(envelope);
    if (tooLarge) return refuse(tooLarge, ENVELOPE_TOO_LARGE_REASON);

    const frame = createMessage(input.verb === "notify" ? "session-bus:notify" : "session-bus:post", {
      from: self.key,
      to,
      contextId,
      threadId,
      envelope,
    });
    const role = this.roleForContext(input.sessionId, contextId);

    // Written BEFORE the send, which is not the order it reads in: `dispatch`
    // may deliver in process and bring the receipt back inside this very call,
    // and a receipt that arrives before its message was logged finds no entry to
    // stamp. The thread row rides the same commit — it is what a reply on this
    // thread later routes on, and it must not depend on the send succeeding.
    this.commit(input.sessionId, {
      log: appendLog(s.log, { at: now, direction: "out", peer: to, envelope }),
      // Advanced on every send rather than only on the one that opened the
      // thread: the row ages on `lastAt`, so a long exchange would otherwise
      // expire underneath itself.
      threads: upsertThread(s.threads, { threadId, contextId, peer: to, lastAt: now, openedByPeer: false }),
    });

    const sent = this.dispatch(frame, { contextId, role, to });

    // A false return is this bridge refusing before the frame reached the relay,
    // so keeping it is redelivery rather than a duplicate — the one retry an
    // unacked message can safely have (held-store). Re-read rather than taken
    // from `s`: the dispatch above may have folded this session's own state.
    const after = this.stateFor(input.sessionId);
    const held = sent
      ? after.held
      : holdMessage(after.held, { messageId: envelope.messageId, contextId, role, to, frame, heldAt: now });
    if (held !== after.held) this.commit(input.sessionId, { held });
    // Charged whether or not it left: a held frame is retried, so a pair with no
    // route would otherwise talk to itself forever outside every ceiling.
    if (budget) this.spendBudget(input.sessionId, budget, input.verb, opensThread || carriesArtifact(input.parts), now);
    return { ok: true, sent, held: hasHeld(held, envelope.messageId), messageId: envelope.messageId, threadId, opensThread };
  }

  /**
   * Would this pair's §7.4 ceilings refuse [verb] right now? Read-only: it
   * charges nothing, writes nothing, and loads no session state.
   *
   * It exists so a caller can ORDER its own refusals, not so it can gate.
   * A refusal ladder that asked liveness first would tell a halted pair "that
   * session is not running", sending it to wait for something that cannot help
   * when what it needs is a human on the other session — so the ladder has to
   * be able to see the halt before it looks at anything else.
   *
   * {@link message} runs the SAME decision again on the way through and is the
   * only place that charges it. That second run is not redundant with this one:
   * it is what makes the ceiling hold for every caller, including ones written
   * after this method and ones that never ask. Deleting it leaves the budget
   * enforced only by whoever remembered to call ahead.
   *
   * A session with no `self` answers null rather than a refusal — whether that
   * is `NOT_MEMBER` or `AGENT_NOT_READY` belongs to the caller's ladder, and
   * this method speaks only about the pair.
   */
  pairRefusal(sessionId: string, to: SessionMemberKey, verb: "post" | "notify"): SessionBusRefusal | null {
    const self = this.deps.self(sessionId);
    if (!self) return null;
    return refusalForPair(this.pairBudgetFor(sessionId, self, to), verb, this.now());
  }

  /** This session's budget record for one peer, or null when nothing above this
   *  coordinator holds a budget at all — see `deps.pairBudget`. */
  private pairBudgetFor(sessionId: string, self: SessionBusSelf, to: SessionMemberKey): PairBudgetState | null {
    if (!this.deps.pairBudget) return null;
    return budgetFor(this.deps.pairBudget.recordsFor(sessionId), pairKey(self.key, to));
  }

  /**
   * Charge one message to this end's mirror of the pair's budget (§7.4) —
   * outbound where it was sent, inbound where it landed, so the two mirrors
   * stay in lockstep.
   *
   * Progress is §7.4's own definition and nothing wider — a NEW thread, or an
   * artifact part — because a reply on a thread already open is exactly the
   * exchange the no-progress counter exists to notice. Reset before the
   * increment, so the message that made the progress starts the next count at
   * one rather than being forgiven retroactively.
   */
  private spendBudget(
    sessionId: string,
    budget: PairBudgetState,
    verb: "post" | "notify",
    progressed: boolean,
    now: number,
  ): void {
    let next = progressed ? noteProgress(budget) : budget;
    next = noteExchange(next, now);
    if (verb === "notify") next = noteNotify(next, now);
    this.deps.pairBudget?.write(sessionId, next);
  }

  /**
   * The one send decision, taken by everything that leaves this coordinator —
   * a message and the receipt that answers one alike.
   *
   * A target on this machine is handed straight to it (§6.1): no relay, no
   * carrier, no route table, and nothing that can fail for transport reasons.
   * Local delivery that does not take the frame FALLS THROUGH to the ordinary
   * send rather than reporting failure, so a target whose project is not loaded
   * leaves the frame held and retried instead of dropped.
   */
  private dispatch(frame: BusFrame, ctx: { contextId: string; role: BusRole; to: SessionMemberKey }): boolean {
    // `namesMachine`, not plain equality, for the reason its own doc gives; a
    // peer that stamps the sentinel itself reaches nothing by it, because
    // `deliverLocal` still resolves the target through this bridge's own
    // session index and falls through to the carrier when it cannot.
    if (namesMachine(ctx.to.machineId, frame.from.machineId) && this.deps.deliverLocal?.(frame, ctx.to)) return true;
    return this.deps.send(frame, ctx);
  }

  /** Ask the machine that published an artifact for one slice of it. Unheld and
   *  unretried unlike a message: the fetcher retries by asking again, because a
   *  slice nobody is waiting for any more must not keep travelling. */
  fetch(input: {
    sessionId: string;
    to: SessionMemberRef;
    contextId: string;
    artifactId: string;
    offset: number;
    length: number;
  }): { ok: true; requestId: string; sent: boolean } | SessionBusRefusal {
    const self = this.deps.self(input.sessionId);
    if (!self) return this.noSelf();
    const requestId = this.newId();
    const frame = createMessage("session-bus:fetch", {
      from: self.key,
      to: keyOf(input.to),
      contextId: input.contextId,
      requestId,
      artifactId: input.artifactId,
      offset: input.offset,
      length: Math.min(Math.max(1, input.length), ARTIFACT_CHUNK_BYTES),
    });
    const role = this.roleForContext(input.sessionId, input.contextId);
    const sent = this.dispatch(frame, { contextId: input.contextId, role, to: keyOf(input.to) });
    return { ok: true, requestId, sent };
  }

  // -- inbound --------------------------------------------------------------

  /**
   * Fold one frame the carrier delivered. True when it was a bus frame this
   * bridge owns, so an inbound switch can fall through on anything else.
   *
   * The session is resolved from the frame's `to`, never from the connection it
   * arrived on. A frame naming a session this bridge does not hold is dropped
   * WITHOUT an ack: acking it would tell the sender its message landed somewhere
   * that will never read it.
   */
  /** Sessions already reported as addressed by a project id other than this
   *  bridge's own. A stored address does not change its mind, so without the
   *  latch this is a line per retry for the life of the session. */
  private readonly driftWarned = new Set<string>();

  /** Says once that the far side knows this session by a different project.
   *
   *  Nothing routes on that id any more, so this costs no delivery — but the
   *  disagreement is worth a name: it is what a directory row RENDERS, and it
   *  used to be the difference between a session that worked and one that
   *  refused every frame in silence. */
  private warnIfProjectDrifted(self: SessionBusSelf, to: SessionMemberKey): void {
    if (self.key.projectId === to.projectId) return;
    if (this.driftWarned.has(to.sessionId)) return;
    this.driftWarned.add(to.sessionId);
    log.warn(
      "session bus: the other machine addresses session %s as project %s, which this bridge holds as %s — matched on the session id",
      to.sessionId, to.projectId, self.key.projectId,
    );
  }

  /**
   * [onAccepted] runs the instant the address check below passes and before any
   * verb is folded, because folding a message DISPATCHES its receipt — and that
   * receipt is itself a peer-role send, which reaches nobody until the caller
   * has recorded the route this very frame arrived on. Running it on the
   * outcome instead loses the receipt for the first frame of every context,
   * permanently: an ack is fire-and-forget and nothing retries it.
   *
   * Optional because a caller with no carrier to record — local delivery on
   * this machine (host-server.ts's `deliverLocal`) — has no route to bind.
   */
  handleInbound(msg: AbMessage, onAccepted?: () => void): InboundOutcome {
    switch (msg.type) {
      case "session-bus:post":
      case "session-bus:notify":
      case "session-bus:fetch":
      case "session-bus:fetch:result":
      case "session-bus:ack":
        break;
      default:
        return false;
    }
    const self = this.deps.self(msg.to.sessionId);
    if (!self || !addressesSameSession(self.key, msg.to)) {
      log.warn(
        { type: msg.type, to: msg.to },
        "session-bus: inbound frame addressed to a session this bridge does not hold; dropped",
      );
      return "dropped";
    }
    const sessionId = msg.to.sessionId;
    onAccepted?.();
    this.warnIfProjectDrifted(self, msg.to);
    switch (msg.type) {
      case "session-bus:post":
      case "session-bus:notify":
        this.onMessage(
          sessionId,
          self,
          msg.from,
          msg.type === "session-bus:notify" ? "notify" : "post",
          msg.threadId,
          msg.contextId,
          msg.envelope,
        );
        return "applied";
      case "session-bus:ack":
        this.onAck(sessionId, msg.messageId);
        return "applied";
      case "session-bus:fetch":
        this.onFetch(sessionId, self, msg);
        return "applied";
      case "session-bus:fetch:result":
        // Answering a fetch is this module's job; consuming one belongs to the
        // caller that asked, and a result nobody is waiting for is a late answer
        // to a request that already gave up. Dropping it is the whole of the
        // correct behaviour.
        return "applied";
    }
  }

  /**
   * Retry every held message across every loaded session.
   *
   * Called on the timer, and directly whenever a carrier appears: a retry
   * schedule is the fallback for a silent link, not what decides how fast a live
   * one moves.
   */
  pump(): void {
    const now = this.now();
    for (const sessionId of [...this.sessions.keys()]) {
      this.flushHeld(sessionId, now);
    }
    if (this.timer && !this.anyPending()) this.stop();
  }

  // -- internals ------------------------------------------------------------

  private stateFor(sessionId: string): SessionState {
    let s = this.sessions.get(sessionId);
    if (!s) {
      const projectId = this.deps.projectIdFor(sessionId);
      if (projectId === null) {
        // Unresolvable rather than a throw: a send racing the project that owns
        // it being forgotten must not crash the coordinator over one message.
        // Kept in memory only — see the field's own doc on SessionState.
        log.warn("session-bus: no owning project for session %s — state kept in memory only, not persisted", sessionId);
        s = { log: emptyLog(), held: emptyHeld(), mailbox: emptyMailbox(), threads: emptyThreads(), artifacts: null, projectId: null };
      } else {
        const now = this.now();
        s = {
          log: loadMessageLog(this.deps.abDir, projectId, sessionId),
          held: loadHeld(this.deps.abDir, projectId, sessionId),
          mailbox: loadMailbox(this.deps.abDir, projectId, sessionId, now),
          threads: loadThreads(this.deps.abDir, projectId, sessionId, now),
          artifacts: null,
          projectId,
        };
      }
      this.sessions.set(sessionId, s);
      // Hydrating IS how a held message comes back off disk, so the timer has to
      // be considered here and not only at a commit: nothing else re-arms the
      // retries a previous process left.
      this.ensureTimer();
    }
    return s;
  }

  private commit(sessionId: string, patch: Partial<SessionState>): void {
    const s = this.stateFor(sessionId);
    const next: SessionState = { ...s, ...patch };
    this.sessions.set(sessionId, next);
    if (next.projectId !== null) {
      if (next.log !== s.log) saveMessageLog(this.deps.abDir, next.projectId, sessionId, next.log);
      if (next.held !== s.held) saveHeld(this.deps.abDir, next.projectId, sessionId, next.held);
      if (next.mailbox !== s.mailbox) saveMailbox(this.deps.abDir, next.projectId, sessionId, next.mailbox);
      if (next.threads !== s.threads) saveThreads(this.deps.abDir, next.projectId, sessionId, next.threads);
    }
    this.ensureTimer();
  }

  /** The retry timer runs only while some session this coordinator holds has
   *  something to wait for — every project on the machine, once a host owns it.
   *  A machine holding nothing — nearly always — must not wake the process once
   *  a second forever. */
  private ensureTimer(): void {
    if (this.timer || !this.anyPending()) return;
    this.timer = setInterval(() => this.pump(), OUTBOX_TICK_MS);
    this.timer.unref?.();
  }

  private anyPending(): boolean {
    for (const s of this.sessions.values()) {
      if (s.held.held.length > 0) return true;
    }
    return false;
  }

  /** Why `self` came back null, as a refusal the caller can act on. */
  private noSelf(): SessionBusRefusal {
    if (this.deps.addressable?.() === false) {
      return refuse("AGENT_NOT_READY", "this machine has no relay identity, so it has no bus address");
    }
    return notMember();
  }

  private stamp(self: SessionBusSelf, draft: EnvelopeDraft): BusEnvelope {
    return stampEnvelope(draft, { messageId: this.newId(), peer: self.ref, now: this.now() });
  }

  /** Which way a frame on this context leaves: to this machine's own carrier, or
   *  back down the carrier that brought the context in.
   *
   *  The CONTEXT ID decides. A context is named by the session that opened it,
   *  so a session whose own id is the context id opened it and reaches the other
   *  end through its own desktop app; any other context id is one this session
   *  was contacted on, and its only way home is the carrier that delivered.
   *
   *  Defaulting to "lead" instead is the misroute this exists to prevent: it
   *  posts the answer to THIS machine's own desktop app, which accepts it and
   *  reports it sent. */
  private roleForContext(sessionId: string, contextId: string): BusRole {
    return contextId === sessionId ? "lead" : "peer";
  }

  /**
   * Retry what a missing route refused.
   *
   * Only frames that never left are held (held-store), so redelivery here cannot
   * duplicate at the receiver. A route belongs to a context and fails whole, so
   * stopping that context at its first refusal is what keeps a sender's messages
   * arriving in the order it wrote them.
   *
   * Through `dispatch`, never `deps.send`: a frame held because its target's
   * project was cold is delivered by the LOCAL arm once that project is warm
   * again, and a retry that went straight to `send` would keep offering it to a
   * carrier that has no route for it until the hold aged out.
   */
  private flushHeld(sessionId: string, now: number): void {
    const s = this.stateFor(sessionId);
    const live = expireHeld(s.held, now);
    const sent: string[] = [];
    const refused = new Set<string>();
    for (const m of live.held) {
      if (refused.has(m.contextId)) continue;
      if (this.dispatch(m.frame as BusFrame, { contextId: m.contextId, role: m.role, to: m.to })) {
        sent.push(m.messageId);
      } else {
        refused.add(m.contextId);
      }
    }
    const next = releaseHeld(live, sent);
    if (next !== s.held) this.commit(sessionId, { held: next });
  }

  private onMessage(
    sessionId: string,
    self: SessionBusSelf,
    from: SessionMemberKey,
    verb: "post" | "notify",
    threadId: string | null,
    contextId: string,
    envelope: BusEnvelope,
  ): void {
    const now = this.now();
    const s = this.stateFor(sessionId);
    // Read before the upsert below, which would otherwise make the answer no for
    // everything. It is the thread STORE and not the presence of an id that says
    // whether this exchange is new here: every send mints an id, so one is always
    // on the wire.
    const opensThread = threadId === null || threadById(s.threads, threadId) === null;
    this.commit(sessionId, {
      log: appendLog(s.log, { at: now, direction: "in", peer: from, envelope }),
      // A post is parked for the target to read when it chooses (§7.1); a notify
      // is rendered into its session instead, and a mailbox row for one would
      // re-offer a message the agent has already been handed.
      ...(verb === "post"
        ? {
            mailbox: appendPost(
              s.mailbox,
              {
                kind: "post",
                messageId: envelope.messageId,
                threadId,
                contextId,
                at: now,
                from,
                summary: envelope.metadata.summary,
                envelope,
                read: false,
              },
              now,
            ),
          }
        : {}),
      // BOTH verbs, because a notify leaves no mailbox row and this is then the
      // only record of the context a reply on that thread has to go back out on.
      // Without it the reply falls back to this session's own id, which
      // `roleForContext` reads as "lead" and posts to this machine's own desktop.
      ...(threadId === null
        ? {}
        : { threads: upsertThread(s.threads, { threadId, contextId, peer: from, lastAt: now, openedByPeer: true }) }),
    });
    // The other half of §7.4's ceilings. The pair's record is mirrored at each
    // end rather than shared (`pair-budget.ts`'s header), so a message charged
    // only where it was sent leaves this end counting nothing but its own
    // outbound traffic — which is the ping-pong `pairKey`'s doc says cannot
    // happen. Charged AFTER the commit above and before anything renders, so a
    // halt this message trips is already recorded when the line reaches the
    // session.
    const budget = this.pairBudgetFor(sessionId, self, from);
    if (budget) this.spendBudget(sessionId, budget, verb, opensThread || carriesArtifact(envelope.parts), now);
    // The receipt takes the same send decision a message does, so it must go
    // through `dispatch` and never `deps.send`: two sessions on ONE machine
    // exchange on a peer-role context nothing ever taught a route for, and the
    // ordinary send finds nowhere to put it and drops it with a warning.
    // Fire-and-forget — an unacked ack is not retried, and `ok: false` would
    // still be a receipt.
    this.dispatch(
      createMessage("session-bus:ack", {
        from: self.key,
        to: from,
        contextId,
        messageId: envelope.messageId,
        ok: true,
      }),
      { contextId, role: this.roleForContext(sessionId, contextId), to: from },
    );
    this.emit({
      kind: verb,
      sessionId,
      threadId,
      opensThread,
      peer: envelope.metadata.peer,
      envelope,
      // Read off the log as it stood BEFORE the append above, which is where
      // this session's own side of the exchange already is; the entry just
      // appended is the inbound one and is not an answer to anything.
      ...(threadId !== null && !opensThread
        ? { answering: lastOutboundSummary(s.log, threadId) }
        : {}),
    });
  }

  /** Stamp the outbound entry a receipt answers (E6).
   *
   *  Nothing to stamp is not a failure: a message already trimmed out of the
   *  ring, or a second receipt for one already stamped, both leave the log where
   *  it was. The receipt says the frame arrived; the log is a rendering aid and
   *  is allowed to have moved on. */
  private onAck(sessionId: string, messageId: string): void {
    const s = this.stateFor(sessionId);
    const log = markDelivered(s.log, messageId, this.now());
    if (log !== s.log) this.commit(sessionId, { log });
  }

  private onFetch(sessionId: string, self: SessionBusSelf, msg: Extract<AbMessage, { type: "session-bus:fetch" }>): void {
    const s = this.stateFor(sessionId);
    if (!s.artifacts && s.projectId !== null) {
      this.sessions.set(sessionId, {
        ...s,
        artifacts: loadArtifacts(this.deps.abDir, s.projectId, sessionId),
      });
    }
    const current = this.stateFor(sessionId);
    const artifacts = current.artifacts;
    const handle = artifacts ? artifactById(artifacts, msg.artifactId) : null;
    // A handle with no bytes under it, an artifact this session never
    // published, and a session with no owning project to read one from are all
    // the same answer to the fetcher: there is nothing to read.
    const slice = handle && current.projectId !== null
      ? readArtifactContent(
          this.deps.abDir,
          current.projectId,
          sessionId,
          msg.artifactId,
          msg.offset,
          Math.min(msg.length, ARTIFACT_CHUNK_BYTES),
        )
      : null;
    const frame = createMessage("session-bus:fetch:result", {
      from: self.key,
      to: msg.from,
      contextId: msg.contextId,
      requestId: msg.requestId,
      artifactId: msg.artifactId,
      offset: msg.offset,
      ...(slice
        ? { ok: true, eof: slice.eof, dataBase64: Buffer.from(slice.data).toString("base64") }
        : {
            ok: false,
            eof: true,
            dataBase64: "",
            errorCode: "UNKNOWN_ARTIFACT" satisfies string,
            error: "no artifact with that id on this session",
          }),
    });
    // Through `dispatch` for the same reason the ack is: a slice answered
    // between two sessions on ONE machine travels a peer-role context nothing
    // taught a route for, and the ordinary send would drop it with a warning.
    this.dispatch(frame, {
      contextId: msg.contextId,
      role: this.roleForContext(sessionId, msg.contextId),
      to: msg.from,
    });
  }

  private emit(event: SessionBusEvent): void {
    try {
      this.deps.onEvent?.(event);
      // Fanned to the OWNING project's own listener, never to every registered
      // one: one coordinator now fires this for every project's sessions, and
      // handing every event to whichever project happened to register would
      // deliver into the wrong project silently — see setListener.
      const projectId = this.deps.projectIdFor(event.sessionId);
      if (projectId !== null) this.listeners.get(projectId)?.(event);
    } catch (err) {
      // A consumer that throws must not cost the store write that already
      // landed.
      log.error({ err, kind: event.kind }, "session-bus: event consumer threw");
    }
  }
}

const ENVELOPE_TOO_LARGE_REASON =
  "this message is too large for the bus; publish the bulk as an artifact and reference it instead";

function notMember(): SessionBusRefusal {
  return refuse("NOT_MEMBER", "this bridge does not hold a session with that id");
}

/**
 * §7.4's two ceilings as ONE decision, in the order they refuse: the halt binds
 * every verb, the hourly ceiling only `notify`.
 *
 * Shared by {@link SessionBusCoordinator.message} and
 * {@link SessionBusCoordinator.pairRefusal} rather than written twice, so the
 * answer a caller orders its ladder by and the answer the send is actually
 * refused with can never drift apart. Pure — a null budget is an unbudgeted
 * bus, which refuses nothing.
 */
function refusalForPair(
  budget: PairBudgetState | null,
  verb: "post" | "notify",
  now: number,
): SessionBusRefusal | null {
  if (!budget) return null;
  const halted = checkHalt(budget);
  if (halted) return halted;
  return verb === "notify" ? checkNotify(budget, now) : null;
}

/** Whether a message carries something durable, which is half of §7.4's
 *  definition of progress. An artifact outlives the exchange that produced it;
 *  text does not, which is why text alone never resets the counter. */
function carriesArtifact(parts: readonly BusPart[]): boolean {
  return parts.some((p) => p.kind === "artifact");
}

function keyOf(ref: SessionMemberKey | SessionMemberRef): SessionMemberKey {
  return { machineId: ref.machineId, projectId: ref.projectId, sessionId: ref.sessionId };
}
