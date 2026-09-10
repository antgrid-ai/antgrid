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
import { addressesSameSession } from "./address";
import { listSessionBusSessions } from "./store-fs";
import { artifactById, loadArtifacts, readArtifactContent, type ArtifactState } from "./artifact-store";
import { ARTIFACT_CHUNK_BYTES, BUS_ROUTE_PERSIST_INTERVAL_MS, BUS_ROUTE_TTL_MS, MAX_BUS_ROUTES } from "./constants";
import { checkEnvelopeSize, stampEnvelope, type EnvelopeDraft } from "./envelope";
import { refuse, type SessionBusRefusal } from "./errors";
import { loadBusRoutes, saveBusRoutes, type BusRouteMap } from "./route-store";
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
  loadMessageLog,
  saveMessageLog,
  type MessageLogState,
} from "./message-log";
import { clearHalt as clearGuardHalt, emptyGuard, type GuardState } from "./task-guard";

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
 * difference a carrier-routing caller depends on: only an applied frame has been
 * proven to name a session this bridge holds, so only an applied frame may be
 * trusted to say anything about where its sender is.
 */
export type InboundOutcome = false | "applied" | "dropped";

export type SessionBusSend = (
  frame: AbMessage,
  ctx: { contextId: string; role: BusRole; to: SessionMemberKey },
) => boolean;

/** What the coordinator learned from an inbound frame, for the layer that turns
 *  it into a line an agent reads. Emitted AFTER the store is written, so a
 *  consumer that throws cannot cost the fold. */
export type SessionBusEvent =
  | { kind: "message"; sessionId: string; taskId: string | null; peer: SessionMemberRef; envelope: BusEnvelope };

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
  /** In-memory and deliberately unpersisted: nothing counts an exchange while
   *  the no-progress halt is dormant, so a file would only record a zero. */
  guard: GuardState;
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
  /** The thread this turn belongs to, or null to start one. Correlation only —
   *  a thread has no state machine (`docs/session-messaging.md` §4.2) — so it is
   *  carried and never validated. */
  taskId: string | null;
  to: SessionMemberRef;
  summary: string;
  parts: BusPart[];
  unexpected?: string;
  contextId?: string;
}

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
  // decide anything on its own — message()/fetch()/flushHeld()/onFetch() still
  // hand every frame to `deps.send` unconditionally, exactly as before the
  // move — because the lookup-then-dispatch decision belongs to whoever wired
  // `send`: only it knows what a `sendToAppSession`/`sendToOwner` call means.
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
   * Seed the route table from the machine-level routes.json (E9/§5.4).
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
      this.routes.set(contextId, route);
    }
  }

  /**
   * Record which app session — and which project's stream — carried
   * [contextId] in, so a later peer-role send on this context knows where home
   * is. Called only for a frame `handleInbound` already reported `"applied"`:
   * that address check is what proves the sender is talking about a session
   * this bridge actually holds, and this table is the other end's only route
   * back — noting on an unapplied frame would let any app session rebind it
   * with one syntactically valid frame carrying someone else's contextId, and
   * take the next answer for itself.
   *
   * That address check proves only that the frame's `to` names a session this
   * bridge holds — it says nothing about the caller-supplied [contextId],
   * which the sender is otherwise free to set to anything. A lead context's id
   * IS a local session id (`roleForContext`'s own rule below), so when the
   * machine session index already attributes [contextId] to a project, that
   * project is the only one entitled to carry it: an admitted peer on project
   * A's stream must not be able to make project B's own lead context answer on
   * A's stream just by stamping B's session id into an otherwise-legitimate
   * frame addressed to one of A's own sessions. This table widened to the
   * whole machine in E9/§5.4 without this check, which is exactly what made
   * that rebind possible — a per-project table never faced another project's
   * contexts at all. A context the index cannot attribute to any local
   * session — the ordinary shape of a genuinely remote peer's context, whose
   * lead lives on the OTHER machine — carries no such claim to violate, so it
   * is left to establish or refresh exactly as before.
   *
   * No peerId means the loopback owner — this machine's own desktop app,
   * already reachable without a route.
   */
  noteRoute(contextId: string, peerId: string | undefined, projectId: string): void {
    if (!peerId) return;
    const owner = this.deps.projectIdFor(contextId);
    if (owner !== null && owner !== projectId) {
      // Refused, not merely ignored: touching nothing here is what keeps an
      // existing legitimate route (or the absence of one) intact against a
      // forged frame. Latched like `warnIfProjectDrifted` and
      // `HostServer.latchBusWarn` — a hostile or confused peer retrying the
      // same contextId must say so once, not on every frame it sends.
      if (this.latchRebindRefused(contextId)) {
        log.warn(
          "session bus: refused to route context %s onto project %s's stream — it belongs to project %s",
          contextId, projectId, owner,
        );
      }
      return;
    }
    this.rebindRefusedWarned.delete(contextId);
    const now = this.now();
    let pruned = false;
    for (const [key, origin] of this.routes) {
      if (now - origin.at >= BUS_ROUTE_TTL_MS) {
        this.routes.delete(key);
        pruned = true;
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
      pruned = true;
    }
    this.saveRoutesIfDue(now, pruned || previous !== peerId);
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
      this.saveRoutesIfDue(now, true);
      return null;
    }
    return origin;
  }

  /** Persist the map, throttled: a binding change or a prune is written at
   *  once, a bare restamp only every {@link BUS_ROUTE_PERSIST_INTERVAL_MS}.
   *  One machine-level file (E9/§5.4/C5) — every row, from every project, in
   *  one wholesale write — which is why this table may only ever have the one
   *  in-memory owner this coordinator is: two writers here would erase each
   *  other's rows with valid JSON and no error. That single-owner bound is per
   *  PROCESS (`HostServer` builds exactly one), not per abDir — two hosts
   *  pointed at one ANTGRID_DIR still overwrite each other wholesale, which is
   *  survivable only because a lost route costs a relearn (route-store.ts's
   *  header) and never a misdelivery. */
  private saveRoutesIfDue(now: number, force: boolean): void {
    if (!force && now - this.routesSavedAt < BUS_ROUTE_PERSIST_INTERVAL_MS) return;
    this.routesSavedAt = now;
    try {
      saveBusRoutes(this.deps.abDir, this.routes);
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
   * machine routes.json (`sessionBusMachineDir`) lives outside
   * `agents/<projectId>/`, so the tree delete that reclaims everything else the
   * project owned cannot reach these rows — this is their only reclaim. The
   * write is FORCED rather than throttled, and is the half that makes the drop
   * durable: `forget` may be the last bus-relevant thing this process ever
   * does, and an in-memory drop nothing persisted is undone wholesale by the
   * next process start, since `hydrateRoutes` sets every row it finds without
   * asking whether the machine still holds that project. Never called on an
   * eviction: a merely-cold project is still real, and its routes must survive
   * for the coordinator to keep dispatching against once it warms again, the
   * same way its sessions survive in the session index.
   */
  forgetProjectRoutes(projectId: string): void {
    let dropped = false;
    for (const [contextId, route] of this.routes) {
      if (route.projectId === projectId) {
        this.routes.delete(contextId);
        dropped = true;
      }
    }
    if (dropped) this.saveRoutesIfDue(this.now(), true);
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
    for (const { sessionId } of listSessionBusSessions(this.deps.abDir)) {
      // The directory enumeration names the project bytes are FILED under; the
      // index (`projectIdFor`) is the authoritative answer for who OWNS them
      // now — the two can disagree for a session whose project was renamed,
      // reassigned or forgotten but not yet swept. Trusting the directory here
      // would resume retries against a project this bridge no longer believes
      // holds the session.
      if (this.deps.projectIdFor(sessionId) === null) {
        log.warn("session-bus: resume found bus state for session %s with no known owning project — skipped", sessionId);
        continue;
      }
      this.stateFor(sessionId);
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

  /**
   * Lift a no-progress halt (`docs/session-messaging.md` §7.4).
   *
   * A human's own submitted reply into the halted session is what reaches here.
   * The halt says two agents exchanged messages while the work stood still, and
   * the guard holds out for a human to look — a person typing into that very
   * session is exactly that, and it is the only such signal a bridge can
   * observe. An agent cannot forge it: nothing an agent submits arrives as
   * terminal input.
   *
   * Dormant until the per-pair counters of §7.4 are rebuilt: nothing counts an
   * exchange today, so nothing halts and this clears nothing. Kept wired because
   * it is the human's entry point and re-finding it later is how a halt ships
   * with no way out.
   */
  clearHalt(sessionId: string): void {
    // Loaded sessions only. This runs on every human submit in the project, and
    // hydrating a store for a session that has never sent would put two file
    // reads behind every keypress.
    const s = this.sessions.get(sessionId);
    if (!s) return;
    const guard = clearGuardHalt(s.guard);
    if (guard === s.guard) return;
    this.commit(sessionId, { guard });
  }

  // -- outbound ---------------------------------------------------------------

  /**
   * Send one message to another session.
   *
   * Lossy on purpose: a send that does not leave is HELD, not queued for
   * unbounded retry, and a message carries no seq and expects no ack. Anything
   * that must survive is an Artifact (§4.1).
   */
  message(input: MessageInput): { ok: true; sent: boolean; held: boolean; messageId: string } | SessionBusRefusal {
    const self = this.deps.self(input.sessionId);
    if (!self) return this.noSelf();
    const s = this.stateFor(input.sessionId);

    const now = this.now();
    const contextId = input.contextId ?? input.sessionId;
    const envelope = this.stamp(self, {
      taskId: input.taskId,
      contextId,
      parts: input.parts,
      summary: input.summary,
      ...(input.unexpected === undefined ? {} : { unexpected: input.unexpected }),
    });
    const tooLarge = checkEnvelopeSize(envelope);
    if (tooLarge) return refuse(tooLarge, ENVELOPE_TOO_LARGE_REASON);

    const frame = createMessage("session-bus:message", {
      from: self.key,
      to: keyOf(input.to),
      contextId,
      taskId: input.taskId,
      envelope,
    });
    const role = this.roleForContext(input.sessionId, contextId);
    const to = keyOf(input.to);
    const sent = this.deps.send(frame, { contextId, role, to });

    // A false return is this bridge refusing before the frame reached the relay,
    // so keeping it is redelivery rather than a duplicate — the one retry an
    // unacked message can safely have (held-store).
    const held = sent
      ? s.held
      : holdMessage(s.held, { messageId: envelope.messageId, contextId, role, to, frame, heldAt: now });
    this.commit(input.sessionId, {
      log: appendLog(s.log, { at: now, direction: "out", peer: to, envelope }),
      ...(held === s.held ? {} : { held }),
    });
    return { ok: true, sent, held: hasHeld(held, envelope.messageId), messageId: envelope.messageId };
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
    const sent = this.deps.send(frame, { contextId: input.contextId, role, to: keyOf(input.to) });
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

  /** Contexts whose most recent rebind attempt `noteRoute` refused. Bounded
   *  the same way `HostServer.latchBusWarn` bounds its own sets: a latch
   *  tracking more refusals than {@link MAX_BUS_ROUTES} is tracking more than
   *  this machine has contexts for, so clearing it costs nothing but a
   *  possible repeat of an already-said line. */
  private readonly rebindRefusedWarned = new Set<string>();

  private latchRebindRefused(contextId: string): boolean {
    if (this.rebindRefusedWarned.has(contextId)) return false;
    if (this.rebindRefusedWarned.size >= MAX_BUS_ROUTES) this.rebindRefusedWarned.clear();
    this.rebindRefusedWarned.add(contextId);
    return true;
  }

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

  handleInbound(msg: AbMessage): InboundOutcome {
    switch (msg.type) {
      case "session-bus:message":
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
    this.warnIfProjectDrifted(self, msg.to);
    switch (msg.type) {
      case "session-bus:message":
        this.onMessage(sessionId, msg.from, msg.taskId, msg.envelope);
        return "applied";
      case "session-bus:ack":
        this.onAck();
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
        s = { log: emptyLog(), held: emptyHeld(), guard: emptyGuard(), artifacts: null, projectId: null };
      } else {
        s = {
          log: loadMessageLog(this.deps.abDir, projectId, sessionId),
          held: loadHeld(this.deps.abDir, projectId, sessionId),
          guard: emptyGuard(),
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
   */
  private flushHeld(sessionId: string, now: number): void {
    const s = this.stateFor(sessionId);
    const live = expireHeld(s.held, now);
    const sent: string[] = [];
    const refused = new Set<string>();
    for (const m of live.held) {
      if (refused.has(m.contextId)) continue;
      if (this.deps.send(m.frame as AbMessage, { contextId: m.contextId, role: m.role, to: m.to })) {
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
    from: SessionMemberKey,
    taskId: string | null,
    envelope: BusEnvelope,
  ): void {
    const now = this.now();
    const s = this.stateFor(sessionId);
    this.commit(sessionId, {
      log: appendLog(s.log, { at: now, direction: "in", peer: from, envelope }),
    });
    this.emit({
      kind: "message",
      sessionId,
      taskId,
      peer: envelope.metadata.peer,
      envelope,
    });
  }

  /** Reserved and dark. E6 keeps the receipt verb, but nothing on this bridge
   *  emits an ack and nothing holds an unacked frame for one to retire, so an
   *  empty body is the honest one until the receipt is re-keyed to a message id.
   *  The frame is still reported `applied`, which is what lets the caller bind
   *  the route it arrived on. */
  private onAck(): void {}

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
    this.deps.send(frame, {
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

function keyOf(ref: SessionMemberKey | SessionMemberRef): SessionMemberKey {
  return { machineId: ref.machineId, projectId: ref.projectId, sessionId: ref.sessionId };
}
