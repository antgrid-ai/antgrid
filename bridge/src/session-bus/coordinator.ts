// The bus's transport half: it owns the stores for one project's sessions, turns
// an agent's message into an addressed frame, and folds an inbound frame back
// into a store. It knows nothing about how a frame travels — a `send` that
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
import { ARTIFACT_CHUNK_BYTES } from "./constants";
import { checkEnvelopeSize, stampEnvelope, type EnvelopeDraft } from "./envelope";
import { refuse, type SessionBusRefusal } from "./errors";
import {
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
  projectId: string;
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

  constructor(private deps: CoordinatorDeps) {
    this.now = deps.now ?? (() => Date.now());
    this.newId = deps.newId ?? (() => randomUUID());
  }

  /** Read one session's stores off disk. Idempotent, and worth calling as a
   *  session becomes addressable: a restart must resume retrying rather than
   *  drop a held message on the floor. */
  load(sessionId: string): void {
    this.stateFor(sessionId);
    this.ensureTimer();
  }

  /**
   * Hydrate every session this project left bus state on disk for.
   *
   * A restart is the only case that needs it, and the case that would otherwise
   * lose a message in silence: `pump` drains the sessions it holds in memory and
   * a fresh process holds none, so a message the dead process could not send
   * would simply never go. Called once as the project comes up, and again
   * whenever a carrier appears, which is when a held message can finally leave.
   */
  resume(): void {
    for (const sessionId of listSessionBusSessions(this.deps.abDir, this.deps.projectId)) {
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
      s = {
        log: loadMessageLog(this.deps.abDir, this.deps.projectId, sessionId),
        held: loadHeld(this.deps.abDir, this.deps.projectId, sessionId),
        guard: emptyGuard(),
        artifacts: null,
      };
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
    if (next.log !== s.log) saveMessageLog(this.deps.abDir, this.deps.projectId, sessionId, next.log);
    if (next.held !== s.held) saveHeld(this.deps.abDir, this.deps.projectId, sessionId, next.held);
    this.ensureTimer();
  }

  /** The retry timer runs only while this project has something to wait for. A
   *  project holding nothing — nearly always — must not wake the process once a
   *  second forever. */
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
    if (!s.artifacts) {
      this.sessions.set(sessionId, {
        ...s,
        artifacts: loadArtifacts(this.deps.abDir, this.deps.projectId, sessionId),
      });
    }
    const artifacts = this.stateFor(sessionId).artifacts;
    const handle = artifacts ? artifactById(artifacts, msg.artifactId) : null;
    // A handle with no bytes under it and an artifact this session never
    // published are the same answer to the fetcher: there is nothing to read.
    const slice = handle
      ? readArtifactContent(
          this.deps.abDir,
          this.deps.projectId,
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
