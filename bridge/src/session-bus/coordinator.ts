// The bus's machine-local half: it owns the stores for the sessions its owner
// hands it — one project's, when a core builds its own fallback instance, or
// every project's on the machine, when the host builds the one shared instance —
// turns an agent's message into an addressed frame, and folds an inbound frame
// back into a store. It knows nothing about how a frame travels: a send to
// another machine goes through `deps.send` (the relay transport) and is kept in
// the outbox until that machine's signed acknowledgement comes back, which is
// what lets this module reason about delivery without owning a socket.
//
// TWO INVARIANTS LIVE HERE AND NOWHERE ELSE.
// Every frame leaves through `deps.send`, never through the MessageBus: a
// published frame reaches every established app session, and the human's phone
// is one of them. And an inbound frame is applied only when its `to` names a
// session THIS bridge holds, so a sender is trusted to deliver and never to say
// which of this bridge's sessions a message belongs to.

import { randomUUID } from "node:crypto";
import { logger } from "../logger";
import { errorName } from "../line-key";
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
  BUS_RELAYED_RESEND_MS,
  BUS_RETRY_BASE_MS,
  BUS_RETRY_MAX_MS,
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
import type { BusHeldReason, BusSendResult, TransportOutcome } from "./relay-transport";
import {
  emptyHeld,
  expireHeld,
  HELD_MESSAGE_TTL_MS,
  holdMessage,
  loadHeld,
  releaseHeld,
  saveHeld,
  type HeldMessage,
  type HeldState,
} from "./held-store";
import {
  appendLog,
  emptyLog,
  lastOutboundSummary,
  loadMessageLog,
  markDelivered,
  markRefused,
  markRelayed,
  saveMessageLog,
  type MessageLogState,
} from "./message-log";
import {
  appendPost,
  emptyMailbox,
  expireOldPosts,
  loadMailbox,
  markRead,
  saveMailbox,
  type MailboxState,
} from "./mailbox";
import {
  emptyThreads,
  expireThreads,
  loadThreads,
  saveThreads,
  upsertThread,
  threadById,
  type ThreadState,
} from "./thread-store";

const log = logger.child({ component: "session-bus" });

/** This bridge's own half of an address, plus the labels it stamps onto what it
 *  sends. Labels travel because the other machine can never look them up: it
 *  cannot reach this one. */
export interface SessionBusSelf {
  key: SessionMemberKey;
  ref: SessionMemberRef;
}

/**
 * What {@link SessionBusCoordinator.handleInbound} did with a frame.
 *
 * `false` means it was not a bus frame at all. The other two carry the
 * difference a local deliverer depends on: only an applied frame reached a
 * session this bridge holds, so only an applied frame may be reported as
 * delivered rather than held and retried.
 */
export type InboundOutcome = false | "applied" | "dropped";

/**
 * Hand one frame bound for another machine to the transport.
 *
 * `{sent:false}` means it did not leave this machine yet and the outbox will
 * offer it again; `{sent:true}` means the transport sealed and queued it, not
 * that anything has arrived. Never a throw: an absent link is not a failed
 * exchange.
 */
export type SessionBusSend = (
  frame: BusFrame,
  ctx: { contextId: string; to: SessionMemberKey; messageId: string; sentAt: number },
) => BusSendResult;

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
   *  a machine has open, not one project's own sessions — so every store call
   *  below resolves its path PER SESSION instead of assuming one shared
   *  projectId. A per-core fallback (no host) answers this with a constant
   *  closure over its own project id, which is what makes it behave exactly
   *  as a single-project coordinator did before this widened. */
  projectIdFor: (sessionId: string) => string | null;
  /** Absent for a core with no relay transport, which holds an off-machine frame
   *  with reason `no-transport` instead of dropping it. */
  send?: SessionBusSend;
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
   *  the relay entirely. False means it could not be delivered in process — the
   *  target's project is not loaded, or a store write failed — and the frame is
   *  HELD and retried, never offered to the transport instead: a same-machine
   *  target is not reachable through a relay that addresses other machines.
   *  Absent means this coordinator has no local path at all, so a same-machine
   *  target is held until one exists. */
  deliverLocal?: (frame: AbMessage, to: SessionMemberKey) => boolean;
  /** Whether this machine may exchange frames with ANOTHER machine at all: its
   *  remote-access switch.
   *
   *  Read in {@link SessionBusCoordinator.dispatch} rather than at the verbs,
   *  because the verbs are not the only way out. A frame held in the outbox
   *  leaves through `flushHeld`, a slice request through `fetch` and its answer
   *  through `fetch:result`, none of which pass the send path's own refusal.
   *  Gating the one chokepoint they share is what makes "the switch governs both
   *  directions" true of the machine rather than of one verb. Absent means
   *  allowed, so a bare coordinator answers to no switch.
   *
   *  A same-machine frame never reaches it. */
  offMachineSendAllowed?: () => boolean;
  /** The per-pair budget, read before a send and charged by every
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
  /** The outbox: messages sent to another machine and not yet acknowledged, or
   *  held for a local target whose project is not loaded. Offered again until
   *  settled; the receiver's dedup is what makes that safe. */
  held: HeldState;
  /** Posts parked for this session to read when it chooses. Loaded with
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
  /** Which verb the caller chose. A post is parked in the target's
   *  mailbox and interrupts nothing; a notify becomes a line at the target's
   *  next turn boundary. Everything after the send decision is identical, which
   *  is why the two travel as one shape. */
  verb: "post" | "notify";
  /** The thread this turn belongs to, or null to open a new one. The coordinator
   *  MINTS an id when this is null and returns it, because an agent that was
   *  never told the id cannot reply on the thread. Correlation only — a
   *  thread has no state machine — so a supplied id is carried and never
   *  validated. */
  threadId: string | null;
  to: SessionMemberRef;
  summary: string;
  parts: BusPart[];
  unexpected?: string;
  contextId?: string;
}

/** How far a message has got, lowest first. Each rung is witnessed by someone
 *  different: `held` by this bridge alone, `relayed` by the relay's receipt,
 *  `delivered` by the recipient bridge's signed ack (or, for a session on this
 *  machine, by the local store write), `refused` by whichever end refused it. */
export type Rung = "held" | "relayed" | "delivered" | "refused";

export interface MessageResult {
  ok: true;
  /** The highest rung reached at the time of the send. Rungs above `held` can
   *  still arrive later; `awaitRung` and the thread read them. */
  rung: Rung;
  /** Why the message is still on this machine, when `rung` is `held` and the
   *  transport said so. */
  heldReason?: BusHeldReason;
  /** Why it was refused, when `rung` is `refused`. */
  refusedCode?: string;
  /** The target is a session on this machine, so `delivered` is its own
   *  mailbox taking it rather than another machine's store. */
  local?: true;
  /** The target's labels as the caller addressed it, when it carried them. */
  machineLabel?: string;
  sessionName?: string;
  /** When a message still held is given up as expired. */
  retryUntil?: number;
  /** `rung !== "held"`: it is no longer only on this machine. Kept for callers
   *  that predate `rung`; never evidence of arrival. */
  sent: boolean;
  held: boolean;
  messageId: string;
  /** Always a real id — minted here when the caller supplied none — because it
   *  is what the caller replies on. */
  threadId: string;
  /** Whether this send OPENED that thread — opening a thread (like publishing
   *  an artifact) counts as progress, so it is the signal the pair budget
   *  resets on. */
  opensThread: boolean;
}

/** Anything this coordinator sends. Every bus frame carries both endpoints, and
 *  the local branch of {@link SessionBusCoordinator.dispatch} needs the sender's
 *  machine id to know whether the target shares it.
 *
 *  Matched on those endpoints and not on the type name alone: the `session-bus:`
 *  prefix also covers the reads an app makes of its OWN bridge, which are
 *  addressed by session id and carry no `from`/`to` at all. */
export type BusFrame = Extract<
  AbMessage,
  { type: `session-bus:${string}`; from: SessionMemberKey; to: SessionMemberKey }
>;

/** Message ids `awaitRung` can still answer for after the send returned. */
const RECENT_SENT_CAP = 1_024;

/** How often held messages are retried. One second is the shortest step worth
 *  taking, so a slower tick would round every retry up to itself. */
export const OUTBOX_TICK_MS = 1_000;

export class SessionBusCoordinator {
  private sessions = new Map<string, SessionState>();
  private timer: ReturnType<typeof setInterval> | null = null;
  private readonly now: () => number;
  private readonly newId: () => string;
  // Which session each held message belongs to, so a transport outcome that
  // names only a message id finds its entry without scanning every session.
  // Rebuilt from the loaded stores (`stateFor`) and kept current by `commit`.
  private readonly heldIndex = new Map<string, string>();
  // Recently sent messages by id, held or not, so `awaitRung` can read the rung
  // of one that has already been settled. Bounded: it answers a question asked
  // moments after a send.
  private readonly recentSent = new Map<string, string>();
  private readonly rungWaiters = new Map<string, Set<{ resolve: () => void; timer: ReturnType<typeof setTimeout> }>>();
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
   * later relay reconnect: it re-enumerates every session bus directory this
   * coordinator can see, and a flaky link reconnecting would otherwise turn
   * into a reconnect storm that re-scans the whole machine on every flap.
   * `retryNow()` alone is what a reconnect needs — the in-memory outbox this
   * call seeded already holds what `resume()` would only rediscover. It also
   * rebuilds the message-id index transport outcomes are routed by.
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
   * itself is forgotten (`HostServer.forget`): `deleteProjectStores`
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
   * Never called on an eviction: a merely-cold project is still real, and its
   * held state must survive for the coordinator to keep retrying once it warms
   * again.
   */
  forgetProjectStates(projectId: string): void {
    for (const [sessionId, state] of this.sessions) {
      if (state.projectId === projectId) this.forget(sessionId);
    }
  }

  forget(sessionId: string): void {
    const s = this.sessions.get(sessionId);
    if (s) {
      for (const m of s.held.held) {
        this.heldIndex.delete(m.messageId);
        this.settleWaiters(m.messageId);
      }
    }
    this.sessions.delete(sessionId);
  }

  stop(): void {
    // Waiters hold a promise an HTTP handler is blocked on; leaving them to
    // their timers would keep a stopped coordinator's callers waiting.
    for (const id of [...this.rungWaiters.keys()]) this.settleWaiters(id);
    if (!this.timer) return;
    clearInterval(this.timer);
    this.timer = null;
  }

  messages(sessionId: string): MessageLogState {
    return this.stateFor(sessionId).log;
  }

  /**
   * Both getters age their store on the way out, not only their loader.
   *
   * `stateFor` loads once and caches for the life of the process, so a
   * coordinator that never restarts would otherwise hand back mail and threads
   * the TTL retired days ago — which makes "threads age out, so open a new one"
   * a sentence that is only true across a restart, and leaves every argument
   * bounded by `MAILBOX_TTL_MS` with no bound at all on a long-lived bridge.
   * A thread row is one half of a send-path security bound, so this expiry is
   * what makes that bound real rather than nominal.
   */
  mailbox(sessionId: string): MailboxState {
    const s = this.stateFor(sessionId);
    const mailbox = expireOldPosts(s.mailbox, this.now());
    if (mailbox !== s.mailbox) this.commit(sessionId, { mailbox });
    return mailbox;
  }

  threads(sessionId: string): ThreadState {
    const s = this.stateFor(sessionId);
    const threads = expireThreads(s.threads, this.now());
    if (threads !== s.threads) this.commit(sessionId, { threads });
    return threads;
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
   * Lift a no-progress halt.
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
   * coordinator is not currently holding — which is exactly the signal that
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
   * Delivery to another machine is at-least-once: the message is kept in the
   * outbox from the moment it is logged and offered again until the recipient's
   * signed ack settles it or it expires, and the receiving bridge deduplicates
   * on the message id. What each rung reported here attests to is in
   * bridge/AGENTS.md. Anything that must outlive the exchange is an Artifact.
   *
   * Logged before it is dispatched, so a receipt that comes back inside this
   * very call finds an entry to stamp.
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
    // sessions it spawned can reach each other. It can reach nothing else,
    // and a frame stamped with the sentinel and held until the relay identity
    // arrives would land carrying a `from` no reply can route back to.
    if (!namesMachine(to.machineId, self.key.machineId) && this.deps.addressable?.() === false) {
      return refuse("AGENT_NOT_READY", "this machine has no relay identity, so it can only reach sessions on itself");
    }
    const s = this.stateFor(input.sessionId);

    const now = this.now();
    // Both pair-budget ceilings, read BEFORE anything is stamped or logged: a
    // refusal must leave no trace of the message it refused, or a halted pair
    // accumulates thread rows for exchanges that never happened.
    const budget = this.pairBudgetFor(input.sessionId, self, to);
    const refusal = refusalForPair(budget, input.verb, now);
    if (refusal) return refusal;
    const contextId = input.contextId ?? input.sessionId;
    // Minted here when the caller has none, and RETURNED either way: the id
    // is bridge-owned except when replying, so an agent that is not told it
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
    // Written BEFORE the send, which is not the order it reads in: `dispatch`
    // may deliver in process and a transport outcome may arrive inside this very
    // call, and an outcome that arrives before its message was logged finds no
    // entry to stamp. The thread row rides the same commit — it is what a reply
    // on this thread later routes on, and it must not depend on the send
    // succeeding.
    this.commit(input.sessionId, {
      log: appendLog(s.log, { at: now, direction: "out", peer: to, envelope }),
      // Advanced on every send rather than only on the one that opened the
      // thread: the row ages on `lastAt`, so a long exchange would otherwise
      // expire underneath itself.
      threads: upsertThread(s.threads, { threadId, contextId, peer: to, lastAt: now, openedByPeer: false }),
    });
    this.noteSent(envelope.messageId, input.sessionId);

    const ctx = { contextId, to, messageId: envelope.messageId, sentAt: now };
    let heldReason: BusHeldReason | undefined;
    let rung: Rung;
    let refusedCode: string | undefined;
    const local = this.isLocalTarget(frame.from, to);
    if (local) {
      const applied = this.deliverToLocal(frame, to);
      if (applied) {
        // The local store write IS the delivery witness here: there is no relay
        // and no peer to acknowledge, so the stamp is made on the spot.
        const after = this.stateFor(input.sessionId);
        this.commit(input.sessionId, { log: markDelivered(after.log, envelope.messageId, now) });
        rung = "delivered";
      } else {
        this.hold(input.sessionId, frame, ctx, now, now + BUS_RETRY_BASE_MS);
        rung = "held";
      }
    } else {
      // Held BEFORE the offer, always: a `sent` from the transport means it was
      // queued, not that anything arrived, so the entry stays until an ack.
      this.hold(input.sessionId, frame, ctx, now, now + BUS_RETRY_BASE_MS);
      const sent = this.dispatchRemote(frame, ctx);
      if ("refused" in sent) {
        this.settleHeld(input.sessionId, envelope.messageId, (log) => markRefused(log, envelope.messageId, now, sent.refused));
        rung = "refused";
        refusedCode = sent.refused;
      } else {
        rung = "held";
        if (!sent.sent) {
          heldReason = sent.reason;
          this.setHeldReason(input.sessionId, envelope.messageId, sent.reason);
        }
        // A receipt can land inside the dispatch above; report what the entry
        // reached rather than what it was before the call.
        const reached = this.rungOf(envelope.messageId);
        if (reached.rung !== "held") {
          rung = reached.rung;
          refusedCode = reached.refusedCode;
          heldReason = undefined;
        }
      }
    }
    // Charged whether or not it left: a held frame is retried, so a pair with no
    // route would otherwise talk to itself forever outside every ceiling.
    if (budget) this.spendBudget(input.sessionId, budget, input.verb, opensThread || carriesArtifact(input.parts), now);
    return {
      ok: true,
      rung,
      ...(heldReason === undefined ? {} : { heldReason }),
      ...(refusedCode === undefined ? {} : { refusedCode }),
      ...(local ? { local: true as const } : {}),
      ...(input.to.machineLabel ? { machineLabel: input.to.machineLabel } : {}),
      ...(input.to.sessionName ? { sessionName: input.to.sessionName } : {}),
      ...(rung === "held" ? { retryUntil: now + HELD_MESSAGE_TTL_MS } : {}),
      sent: rung !== "held",
      held: rung === "held",
      messageId: envelope.messageId,
      threadId,
      opensThread,
    };
  }

  /**
   * Would this pair's budget ceilings refuse [verb] right now? Read-only: it
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
   * Charge one message to this end's mirror of the pair's budget — outbound
   * where it was sent, inbound where it landed, so the two mirrors stay in
   * lockstep.
   *
   * Progress means a NEW thread, or an artifact part, and nothing wider —
   * because a reply on a thread already open is exactly the exchange the
   * no-progress counter exists to notice. Reset before the
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

  /** Whether [to] is a session on the machine [from] speaks for. `namesMachine`
   *  and not plain equality, for the reason its own doc gives: a peer that
   *  stamps the local sentinel itself reaches nothing by it, because the
   *  deliverer resolves the target through this bridge's own session index and
   *  declines when it cannot. */
  private isLocalTarget(from: SessionMemberKey, to: SessionMemberKey): boolean {
    return namesMachine(to.machineId, from.machineId);
  }

  /** Hand a frame to a session on this machine. False holds it for a retry:
   *  the target's project is not loaded or a store write failed.
   *
   *  It must not fall through to the transport, however inviting that reads. A
   *  local decline means the target's project is not loaded here, and the relay
   *  only addresses OTHER machines. A coordinator with no `deliverLocal` has no
   *  local arm at all and holds the frame the same way. */
  private deliverToLocal(frame: BusFrame, to: SessionMemberKey): boolean {
    return this.deps.deliverLocal?.(frame, to) ?? false;
  }

  /**
   * The one off-machine send decision, taken by everything that leaves for
   * another machine: a message, a held retry, and a slice request or answer
   * alike.
   *
   * The remote-access switch is re-read here rather than at the verbs because
   * the verbs are not the only way out. Held rather than dropped when it is off,
   * and for the same reason a missing transport holds: nothing here is a verdict
   * about the exchange, only about this machine right now, and the switch coming
   * back on is an event the outbox already retries against. The interactive
   * verbs never get this far — `api.ts` refuses them up front, where the answer
   * can carry a reason.
   */
  private dispatchRemote(
    frame: BusFrame,
    ctx: { contextId: string; to: SessionMemberKey; messageId: string; sentAt: number },
  ): BusSendResult {
    if (this.deps.offMachineSendAllowed?.() === false) {
      log.debug(
        { type: frame.type, contextId: ctx.contextId, to: ctx.to.machineId },
        "session bus: not sent, this machine's remote access is off",
      );
      return { sent: false, reason: "remote-access-off" };
    }
    return this.deps.send?.(frame, ctx) ?? { sent: false, reason: "no-transport" };
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
    const to = keyOf(input.to);
    const ctx = { contextId: input.contextId, to, messageId: this.newId(), sentAt: this.now() };
    const sent = this.isLocalTarget(self.key, to)
      ? this.deliverToLocal(frame, to)
      : this.dispatchRemote(frame, ctx).sent === true;
    return { ok: true, requestId, sent };
  }

  // -- inbound --------------------------------------------------------------

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
   * Fold one frame delivered from the relay transport or from a local sender.
   * False when it was not a bus frame this bridge owns, so an inbound switch can
   * fall through on anything else.
   *
   * The session is resolved from the frame's `to`, never from where the frame
   * came from. A frame naming a session this bridge does not hold is `dropped`,
   * and the host refuses it rather than acknowledging it: acking it would tell
   * the sender its message landed somewhere that will never read it.
   *
   * Not idempotent: deduplication happens upstream, in the transport's seen
   * store, which is also what keeps the pair budget charged once per message.
   */
  handleInbound(msg: AbMessage): InboundOutcome {
    switch (msg.type) {
      case "session-bus:post":
      case "session-bus:notify":
      case "session-bus:fetch":
      case "session-bus:fetch:result":
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
    // The head of the walk. The message id is the join key here and at `emit`
    // because it is what `lineForEvent` uses as the QueuedLine's own id, so a
    // frame can be followed from admission to the queue row it becomes, and the
    // queue row's sha takes it from there.
    log.debug(
      { type: msg.type, sessionId, msgId: "envelope" in msg ? msg.envelope.messageId : undefined },
      "bus inbound: accepted",
    );
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
   * Offer every due held message again, across every loaded session.
   *
   * Called on the timer, and by `retryNow` whenever the relay link or a peer
   * comes up: the backoff is the fallback for a silent link, not what decides
   * how fast a live one moves.
   */
  pump(): void {
    const now = this.now();
    for (const sessionId of [...this.sessions.keys()]) {
      this.flushHeld(sessionId, now);
    }
    if (this.timer && !this.anyPending()) this.stop();
  }

  /**
   * Apply what the transport learned about one message this machine sent.
   *
   * Looked up by message id and checked against the machine the entry was
   * addressed to, so an outcome for an id this machine never sent, or one that
   * names a different recipient than the entry holds, is ignored rather than
   * trusted. The transport has already verified any ack's signature; this is
   * the only place an ack becomes a `delivered` or `refused` stamp.
   */
  onTransportOutcome(messageId: string, toMachine: string, o: TransportOutcome): void {
    const sessionId = this.heldIndex.get(messageId);
    if (sessionId === undefined) return;
    const s = this.stateFor(sessionId);
    const m = s.held.held.find((h) => h.messageId === messageId);
    if (!m || m.to.machineId !== toMachine) return;
    const now = this.now();
    switch (o.kind) {
      case "relayed": {
        if (m.relayedAt !== undefined) return;
        // The receipt means the relay holds it, so the next offer is the slow
        // safety net, not the next tick.
        const held = {
          held: s.held.held.map((h) =>
            h.messageId === messageId ? { ...h, relayedAt: now, nextAttemptAt: now + BUS_RELAYED_RESEND_MS } : h,
          ),
        };
        this.commit(sessionId, { held, log: markRelayed(s.log, messageId, now) });
        break;
      }
      case "applied":
        this.commit(sessionId, { held: releaseHeld(s.held, [messageId]), log: markDelivered(s.log, messageId, now) });
        break;
      case "refused":
        this.commit(sessionId, { held: releaseHeld(s.held, [messageId]), log: markRefused(s.log, messageId, now, o.code) });
        break;
      case "retry": {
        const held = { held: s.held.held.map((h) => (h.messageId === messageId ? { ...h, lastReason: o.reason } : h)) };
        this.commit(sessionId, { held });
        return;
      }
    }
    this.settleWaiters(messageId);
  }

  /**
   * Make held messages due now, then offer them. For the moments the link is
   * known to have improved: the relay socket authenticated, or a peer machine
   * came online. A relayed entry is offered too, because the relay may have
   * restarted and lost its queue; the duplicate is cheap and the receiver
   * dedupes it.
   */
  retryNow(filter?: { machineId?: string }): void {
    for (const [sessionId, s] of this.sessions) {
      let changed = false;
      const held = s.held.held.map((m) => {
        if (filter?.machineId !== undefined && m.to.machineId !== filter.machineId) return m;
        if (m.nextAttemptAt === 0) return m;
        changed = true;
        return { ...m, nextAttemptAt: 0 };
      });
      if (changed) this.commit(sessionId, { held: { held } });
    }
    this.pump();
  }

  /**
   * Resolve with the first rung above `held` a message reaches, or with the
   * rung it is on when [timeoutMs] runs out. For a caller that is blocked on
   * the answer, so the bound is theirs and not this class's.
   */
  awaitRung(
    messageId: string,
    timeoutMs: number,
  ): Promise<{ rung: Rung; heldReason?: BusHeldReason; refusedCode?: string }> {
    const current = this.rungOf(messageId);
    if (current.rung !== "held") return Promise.resolve(current);
    return new Promise((resolve) => {
      const waiter = {
        timer: setTimeout(() => finish(), timeoutMs),
        resolve: () => finish(),
      };
      const finish = (): void => {
        clearTimeout(waiter.timer);
        this.rungWaiters.get(messageId)?.delete(waiter);
        if (this.rungWaiters.get(messageId)?.size === 0) this.rungWaiters.delete(messageId);
        resolve(this.rungOf(messageId));
      };
      let set = this.rungWaiters.get(messageId);
      if (!set) this.rungWaiters.set(messageId, (set = new Set()));
      set.add(waiter);
    });
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
      for (const m of s.held.held) this.heldIndex.set(m.messageId, sessionId);
      // Hydrating IS how a held message comes back off disk, so the timer has to
      // be considered here and not only at a commit: nothing else re-arms the
      // retries a previous process left.
      this.ensureTimer();
    }
    return s;
  }

  /** The rung a message has reached, read from its log entry: the log is where
   *  every witness stamps, so it is the one place that cannot disagree with
   *  itself. A message this coordinator knows nothing about reads as `held`. */
  private rungOf(messageId: string): { rung: Rung; heldReason?: BusHeldReason; refusedCode?: string } {
    const sessionId = this.heldIndex.get(messageId) ?? this.recentSent.get(messageId);
    if (sessionId === undefined) return { rung: "held" };
    const s = this.stateFor(sessionId);
    const e = s.log.entries.find((x) => x.direction === "out" && x.envelope.messageId === messageId);
    if (e?.refusedAt !== undefined) {
      return { rung: "refused", ...(e.refusedCode === undefined ? {} : { refusedCode: e.refusedCode }) };
    }
    if (e?.deliveredAt !== undefined) return { rung: "delivered" };
    if (e?.relayedAt !== undefined) return { rung: "relayed" };
    const reason = s.held.held.find((h) => h.messageId === messageId)?.lastReason;
    return { rung: "held", ...(reason === undefined ? {} : { heldReason: reason as BusHeldReason }) };
  }

  private noteSent(messageId: string, sessionId: string): void {
    this.recentSent.set(messageId, sessionId);
    if (this.recentSent.size > RECENT_SENT_CAP) {
      const oldest = this.recentSent.keys().next();
      if (!oldest.done) this.recentSent.delete(oldest.value);
    }
  }

  private settleWaiters(messageId: string): void {
    for (const w of [...(this.rungWaiters.get(messageId) ?? [])]) w.resolve();
  }

  /** Keep one message in the outbox. Anything pushed out by the cap is stamped
   *  refused on its log entry and said at warn (ids only), so an eviction is
   *  something the sender can read rather than a message that vanishes. */
  private hold(
    sessionId: string,
    frame: BusFrame,
    ctx: { contextId: string; to: SessionMemberKey; messageId: string; sentAt: number },
    now: number,
    nextAttemptAt: number,
  ): void {
    const s = this.stateFor(sessionId);
    const { state, evicted } = holdMessage(s.held, {
      messageId: ctx.messageId,
      contextId: ctx.contextId,
      to: ctx.to,
      frame,
      heldAt: now,
      attempts: 1,
      nextAttemptAt,
    });
    let logState = s.log;
    for (const e of evicted) {
      logState = markRefused(logState, e.messageId, now, "OUTBOX_FULL");
      log.warn(
        "session bus: outbox of session %s is full; message %s was dropped before it was acknowledged",
        sessionId, e.messageId,
      );
    }
    this.commit(sessionId, { held: state, ...(logState === s.log ? {} : { log: logState }) });
    for (const e of evicted) this.settleWaiters(e.messageId);
  }

  /** Release one message from the outbox and stamp the log, in one commit. */
  private settleHeld(sessionId: string, messageId: string, stamp: (l: MessageLogState) => MessageLogState): void {
    const s = this.stateFor(sessionId);
    this.commit(sessionId, { held: releaseHeld(s.held, [messageId]), log: stamp(s.log) });
    this.settleWaiters(messageId);
  }

  private setHeldReason(sessionId: string, messageId: string, reason: BusHeldReason): void {
    const s = this.stateFor(sessionId);
    if (!s.held.held.some((h) => h.messageId === messageId && h.lastReason !== reason)) return;
    this.commit(sessionId, {
      held: { held: s.held.held.map((h) => (h.messageId === messageId ? { ...h, lastReason: reason } : h)) },
    });
  }

  private commit(sessionId: string, patch: Partial<SessionState>): void {
    const s = this.stateFor(sessionId);
    const next: SessionState = { ...s, ...patch };
    this.sessions.set(sessionId, next);
    if (next.held !== s.held) {
      for (const m of s.held.held) this.heldIndex.delete(m.messageId);
      for (const m of next.held.held) this.heldIndex.set(m.messageId, sessionId);
    }
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

  /**
   * Offer again every held message whose time has come.
   *
   * What stays here is exactly what the far side has not settled, so a retry may
   * reach a recipient that already applied the message; its seen store re-acks
   * instead of re-applying (held-store.ts states the contract). A machine whose
   * offer was refused stops being offered to for the rest of this pass, which is
   * what keeps a sender's messages to one machine arriving in the order it wrote
   * them.
   *
   * Through the dispatch helpers, never `deps.send` directly: a frame held
   * because its target's project was cold is delivered by the LOCAL arm once
   * that project is warm again, and a retry that went straight to `send` would
   * offer a same-machine target to a relay that cannot address it.
   */
  private flushHeld(sessionId: string, now: number): void {
    const s = this.stateFor(sessionId);
    const { state: live, expired } = expireHeld(s.held, now);
    const logOps: ((l: MessageLogState) => MessageLogState)[] = [];
    // A hold is a delay the sender was never told about unless the log says so,
    // so every expiry is stamped on the entry and said once at warn — ids only,
    // never the envelope: `host.log` is a file users are asked to send.
    for (const m of expired) {
      logOps.push((l) => markRefused(l, m.messageId, now, "EXPIRED"));
      log.warn(
        "session bus: held message %s from session %s to %s on context %s expired without being acknowledged; it will not be delivered",
        m.messageId, sessionId, m.to.sessionId, m.contextId,
      );
    }
    const gone = new Set<string>(expired.map((m) => m.messageId));
    const updates = new Map<string, Partial<HeldMessage>>();
    const blocked = new Set<string>();
    for (const m of live.held) {
      if (now < m.nextAttemptAt || blocked.has(m.to.machineId)) continue;
      const attempts = m.attempts + 1;
      const frame = m.frame as BusFrame;
      if (this.isLocalTarget(frame.from, m.to)) {
        if (this.deliverToLocal(frame, m.to)) {
          logOps.push((l) => markDelivered(l, m.messageId, now));
          gone.add(m.messageId);
        } else {
          updates.set(m.messageId, { attempts, nextAttemptAt: now + BUS_RETRY_BASE_MS });
        }
        continue;
      }
      const result = this.dispatchRemote(frame, { contextId: m.contextId, to: m.to, messageId: m.messageId, sentAt: m.heldAt });
      const nextAttemptAt = now + (m.relayedAt === undefined
        ? Math.min(BUS_RETRY_BASE_MS * 2 ** (attempts - 1), BUS_RETRY_MAX_MS)
        : BUS_RELAYED_RESEND_MS);
      if ("refused" in result) {
        logOps.push((l) => markRefused(l, m.messageId, now, result.refused));
        gone.add(m.messageId);
      } else if (result.sent) {
        // lastReason is left as it was: the entry is still unacknowledged, and
        // clearing it would hide why an earlier offer failed.
        updates.set(m.messageId, { attempts, nextAttemptAt });
      } else {
        blocked.add(m.to.machineId);
        updates.set(m.messageId, { attempts, nextAttemptAt, lastReason: result.reason });
      }
    }
    // Applied to the freshest state, not to the copy this pass started from: a
    // dispatch above can bring an outcome back inside the call, and that
    // outcome has already edited the stored entry.
    const fresh = this.stateFor(sessionId);
    const held = fresh.held.held.filter((m) => !gone.has(m.messageId)).map((m) => {
      const u = updates.get(m.messageId);
      return u ? { ...m, ...u } : m;
    });
    const patch: Partial<SessionState> = {};
    if (held.length !== fresh.held.held.length || updates.size > 0) patch.held = { held };
    const logState = logOps.reduce((l, op) => op(l), fresh.log);
    if (logState !== fresh.log) patch.log = logState;
    if (patch.held || patch.log) this.commit(sessionId, patch);
    for (const id of gone) this.settleWaiters(id);
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
      // A post is parked for the target to read when it chooses; a notify
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
      // Without it the reply falls back to this session's own id and answers on
      // a context the peer never opened.
      ...(threadId === null
        ? {}
        : { threads: upsertThread(s.threads, { threadId, contextId, peer: from, lastAt: now, openedByPeer: true }) }),
    });
    // The other half of the pair-budget ceilings. The pair's record is
    // mirrored at each end rather than shared (`pair-budget.ts`'s header), so
    // a message charged only where it was sent leaves this end counting
    // nothing but its own outbound traffic — which is the ping-pong
    // `pairKey`'s doc says cannot happen. Charged AFTER the commit above and
    // before anything renders, so a halt this message trips is already
    // recorded when the line reaches the session.
    const budget = this.pairBudgetFor(sessionId, self, from);
    if (budget) this.spendBudget(sessionId, budget, verb, opensThread || carriesArtifact(envelope.parts), now);
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
    // Not held and not retried: the fetcher retries by asking again, and a
    // slice nobody is waiting for any more must not keep travelling. A requester
    // on this machine is handed the answer in process.
    const ctx = { contextId: msg.contextId, to: msg.from, messageId: this.newId(), sentAt: this.now() };
    if (this.isLocalTarget(self.key, msg.from)) this.deliverToLocal(frame, msg.from);
    else this.dispatchRemote(frame, ctx);
  }

  private emit(event: SessionBusEvent): void {
    try {
      this.deps.onEvent?.(event);
      // Fanned to the OWNING project's own listener, never to every registered
      // one: one coordinator now fires this for every project's sessions, and
      // handing every event to whichever project happened to register would
      // deliver into the wrong project silently — see setListener.
      const projectId = this.deps.projectIdFor(event.sessionId);
      // The store has already committed by the time this runs, so a listener
      // that is absent is the difference between a message that was kept and
      // one that was kept AND read: a session whose project is cold has an
      // owner in the index and no listener here, and nothing downstream says so.
      log.debug(
        { kind: event.kind, sessionId: event.sessionId, msgId: event.envelope.messageId, projectId, listener: projectId !== null && this.listeners.has(projectId) },
        "bus emit: event fanned",
      );
      if (projectId !== null) this.listeners.get(projectId)?.(event);
    } catch (err) {
      // A consumer that throws must not cost the store write that already
      // landed.
      // The name alone, never the error: the consumer on the other end of this
      // renders the peer's own words, so its message is as much a delivery leak
      // as the line itself would be.
      log.error({ err: errorName(err), kind: event.kind }, "session-bus: event consumer threw");
    }
  }
}

const ENVELOPE_TOO_LARGE_REASON =
  "this message is too large for the bus; publish the bulk as an artifact and reference it instead";

function notMember(): SessionBusRefusal {
  return refuse("NOT_MEMBER", "this bridge does not hold a session with that id");
}

/**
 * The pair budget's two ceilings as ONE decision, in the order they refuse:
 * the halt binds every verb, the hourly ceiling only `notify`.
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

/** Whether a message carries something durable, which is half of what counts
 *  as progress for the pair budget. An artifact outlives the exchange that
 *  produced it; text does not, which is why text alone never resets the
 *  counter. */
function carriesArtifact(parts: readonly BusPart[]): boolean {
  return parts.some((p) => p.kind === "artifact");
}

function keyOf(ref: SessionMemberKey | SessionMemberRef): SessionMemberKey {
  return { machineId: ref.machineId, projectId: ref.projectId, sessionId: ref.sessionId };
}
