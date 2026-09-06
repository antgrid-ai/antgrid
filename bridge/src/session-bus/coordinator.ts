// The bus's transport half: it owns the stores for one project's sessions, turns
// an agent's action into an addressed frame, and folds an inbound frame back
// into a store. It knows nothing about how a frame travels — a `send` that
// returns false is all it needs to hold the frame and try again — which is what
// lets ONE module serve both roles across a link neither end can open (D7: the
// lead bridge can never reach the peer bridge; the lead's desktop app carries).
//
// TWO INVARIANTS LIVE HERE AND NOWHERE ELSE.
// Every frame leaves through `deps.send`, never through the MessageBus: a
// published frame reaches every established app session, and the human's phone
// is one of them (spec 4.1). And an inbound frame is applied only when its `to`
// names a session THIS bridge holds, so a carrier is trusted to deliver and
// never to say which of this bridge's sessions a task belongs to.

import { randomUUID } from "node:crypto";
import { logger } from "../logger";
import {
  createMessage,
  type AbMessage,
  type BusEnvelope,
  type BusPart,
  type SessionMemberKey,
  type SessionMemberRef,
  type TaskState,
  type WaitingOn,
} from "../protocol";
import { sameAddress } from "./address";
import { listSessionBusSessions } from "./store-fs";
import { artifactById, loadArtifacts, readArtifactContent, type ArtifactState } from "./artifact-store";
import { ARTIFACT_CHUNK_BYTES } from "./constants";
import { checkEnvelopeSize, stampEnvelope, type EnvelopeDraft } from "./envelope";
import { refuse, type SessionBusRefusal } from "./errors";
import {
  appendLog,
  loadMessageLog,
  saveMessageLog,
  type MessageLogState,
} from "./message-log";
import {
  checkAssign,
  clearHalt as clearGuardHalt,
  guardBudget,
  noteExchange,
  type GuardBudget,
} from "./task-guard";
import {
  ackOutbound,
  applyTransition,
  dueOutbox,
  holdOutbound,
  isTerminal,
  loadTasks,
  mintOutbound,
  mintTask,
  noteAttempt,
  recordFinding,
  saveTasks,
  taskCreatedAts,
  taskFor,
  tasksFor,
  setHumanWait,
  tickExpiry,
  type TaskRecord,
  type TaskStoreState,
} from "./task-store";

const log = logger.child({ component: "session-bus" });

export type BusRole = "lead" | "peer";

/** This bridge's own half of an address, plus the labels it stamps onto what it
 *  sends. Labels travel because the other machine can never look them up: it
 *  cannot reach this one (D7). */
export interface SessionBusSelf {
  key: SessionMemberKey;
  ref: SessionMemberRef;
}

/**
 * Hand one frame to whatever carries this context.
 *
 * False means it did not leave — no carrier, or a carrier that cannot forward —
 * and the frame stays in the outbox at its current backoff. Never a throw and
 * never a failure: an absent carrier is not a failed task (D11).
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
 *  it into a line an agent reads. Emitted AFTER the store is written and the ack
 *  has gone, so a consumer that throws cannot cost either. */
export type SessionBusEvent =
  | { kind: "assigned"; sessionId: string; task: TaskRecord; envelope: BusEnvelope }
  | { kind: "transitioned"; sessionId: string; task: TaskRecord; state: TaskState; envelope: BusEnvelope }
  | { kind: "canceled"; sessionId: string; task: TaskRecord; reason: string }
  | { kind: "message"; sessionId: string; taskId: string | null; peer: SessionMemberRef; envelope: BusEnvelope }
  | { kind: "expired"; sessionId: string; task: TaskRecord };

export interface CoordinatorDeps {
  abDir: string;
  projectId: string;
  send: SessionBusSend;
  /** This bridge's address for one of its own sessions, or null when the session
   *  is not a bus member or the machine has no identity to be addressed by. */
  self: (sessionId: string) => SessionBusSelf | null;
  /** Whether this machine has a bus address at all. Consulted ONLY when `self`
   *  answers null, to tell the two reasons it can apart: a session that joined
   *  nothing is `NOT_MEMBER`, while a machine with no relay identity is
   *  `AGENT_NOT_READY` — the same split `/session` already makes. Without it a
   *  lead whose `/role` says `lead:true` is refused "not a member", which reads
   *  as a membership bug and sends the reader looking in the wrong place.
   *  Absent means addressable, so a core that never wires it keeps today's
   *  answer. */
  addressable?: () => boolean;
  onEvent?: (event: SessionBusEvent) => void;
  now?: () => number;
  newId?: () => string;
}

interface SessionState {
  tasks: TaskStoreState;
  log: MessageLogState;
  /** Read on the first fetch this session answers: most sessions publish nothing
   *  and never pay for the file. */
  artifacts: ArtifactState | null;
}

export interface AssignInput {
  sessionId: string;
  peer: SessionMemberRef;
  summary: string;
  parts: BusPart[];
  /** Defaults to the summary. The wire carries no separate title — the peer
   *  names the task by what the lead said it is. */
  title?: string;
  unexpected?: string;
  /** Defaults to the lead's own session id, which is the one identifier both
   *  machines can name for the same exchange. */
  contextId?: string;
  expiresAt?: number;
}

export interface ReportInput {
  sessionId: string;
  taskId: string;
  summary: string;
  parts: BusPart[];
  unexpected?: string;
  waitingOn?: WaitingOn;
}

export interface MessageInput {
  sessionId: string;
  taskId: string | null;
  to: SessionMemberRef;
  summary: string;
  parts: BusPart[];
  unexpected?: string;
  contextId?: string;
}

/** How often the outbox is drained. One second is the shortest backoff step, so
 *  a slower tick would round every retry up to itself. */
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
   *  session joins a bus: a restart must resume retrying rather than drop a
   *  completed task's report on the floor. */
  load(sessionId: string): void {
    this.stateFor(sessionId);
    this.ensureTimer();
  }

  /**
   * Hydrate every session this project left bus state on disk for.
   *
   * A restart is the only case that needs it, and the case that would otherwise
   * lose work in silence: `pump` drains the sessions it holds in memory, a fresh
   * process holds none, and D11 forbids reading failure into silence -- so a
   * report the dead process had queued would simply never go. Called once as the
   * project comes up, and again whenever a carrier appears, which is when the
   * outbox can finally drain.
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

  tasks(sessionId: string): readonly TaskRecord[] {
    return this.stateFor(sessionId).tasks.tasks;
  }

  task(sessionId: string, taskId: string): TaskRecord | null {
    return taskFor(this.stateFor(sessionId).tasks, taskId);
  }

  budget(sessionId: string): GuardBudget {
    const s = this.stateFor(sessionId).tasks;
    return guardBudget(s.guard, taskCreatedAts(s), this.now());
  }

  messages(sessionId: string): MessageLogState {
    return this.stateFor(sessionId).log;
  }

  /**
   * Report whether a human at this machine is what [sessionId] is waiting on.
   *
   * Driven by the session's own work status, which is the only place a bridge
   * learns that its agent is sitting on a permission prompt or a question. It
   * pauses the expiry clock on the tasks that session is working (spec 5.3), so
   * a human who takes the weekend does not lapse a task nobody abandoned.
   */
  humanBlocked(sessionId: string, blocked: boolean): void {
    // Loaded sessions only, for the reason `clearHalt` gives: every session in
    // the project reaches this on a status edge, and nearly none are on a bus.
    const s = this.sessions.get(sessionId);
    if (!s) return;
    const tasks = setHumanWait(s.tasks, blocked, this.now());
    if (tasks === s.tasks) return;
    this.commit(sessionId, { tasks });
  }

  /**
   * Lift a no-progress halt (spec 8).
   *
   * A human's own submitted reply into the halted session is what reaches here.
   * The halt says two agents exchanged findings while the work stood still, and
   * the guard holds out for a human to look -- a person typing into that very
   * session is exactly that, and it is the only such signal a bridge can
   * observe. An agent cannot forge it: nothing an agent submits arrives as
   * terminal input.
   */
  clearHalt(sessionId: string): void {
    // Loaded sessions only. This runs on every human submit in the project, and
    // hydrating a store for a session that is on no bus would put two file reads
    // behind every keypress; a halted session always has records on disk, so
    // `resume` has already brought it back.
    const s = this.sessions.get(sessionId);
    if (!s) return;
    const guard = clearGuardHalt(s.tasks.guard);
    if (guard === s.tasks.guard) return;
    this.commit(sessionId, { tasks: { guard, tasks: s.tasks.tasks } });
  }

  // -- outbound, lead side --------------------------------------------------

  /**
   * Open a task and put its assign in the outbox.
   *
   * The task exists the moment this returns, whether or not the frame left: the
   * outbox is what makes the send eventual, and a task that came into being only
   * once a carrier answered would be a task the lead cannot see it created.
   *
   * `delivered` says which of those two happened. It is not a second success
   * flag — the task is created either way — but a lead told only "assigned"
   * cannot tell an assignment its peer is already reading from one still sitting
   * in the outbox because no carrier has ever reached that machine.
   */
  assign(input: AssignInput): { ok: true; taskId: string; seq: number; delivered: boolean } | SessionBusRefusal {
    const self = this.deps.self(input.sessionId);
    if (!self) return this.noSelf();

    const now = this.now();
    const state = this.stateFor(input.sessionId);
    const guardRefusal = checkAssign(state.tasks.guard, taskCreatedAts(state.tasks), now);
    if (guardRefusal) return refuse(guardRefusal.code, guardRefusal.reason);

    const taskId = this.newId();
    const contextId = input.contextId ?? input.sessionId;
    const envelope = this.stamp(self, {
      taskId,
      contextId,
      parts: input.parts,
      summary: input.summary,
      ...(input.unexpected === undefined ? {} : { unexpected: input.unexpected }),
    });
    const tooLarge = checkEnvelopeSize(envelope);
    if (tooLarge) return refuse(tooLarge, ENVELOPE_TOO_LARGE_REASON);

    const minted = mintTask(state.tasks, {
      taskId,
      contextId,
      peer: input.peer,
      title: input.title ?? input.summary,
      now,
      ...(input.expiresAt === undefined ? {} : { expiresAt: input.expiresAt }),
    });
    const task = taskFor(minted.next, taskId);
    const frame = createMessage("session-bus:assign", {
      from: self.key,
      to: keyOf(input.peer),
      contextId,
      taskId,
      seq: minted.seq,
      expiresAt: task?.expiresAt ?? now,
      envelope,
    });

    const queued = mintOutbound(minted.next, { taskId, frame, seq: minted.seq, now });
    if (queued.kind !== "queued") {
      // Unreachable: the record was minted with an empty outbox one statement
      // ago. Refusing rather than asserting keeps a future edit that breaks that
      // pairing from creating a task no frame will ever carry.
      return refuse("AGENT_NOT_READY", "the task could not be queued for its peer");
    }
    const attempt = this.firstAttempt(queued.next, queued.task, minted.seq, frame, now);
    this.commit(input.sessionId, {
      tasks: attempt.tasks,
      log: appendLog(state.log, { at: now, direction: "out", peer: keyOf(input.peer), envelope }),
    });
    return { ok: true, taskId, seq: minted.seq, delivered: attempt.sent };
  }

  /** Withdraw a task. The cancel is a transition like any other — sequenced,
   *  retried and acked — because "stop" arriving unreliably is worse than the
   *  work continuing. */
  cancel(sessionId: string, taskId: string, reason: string): { ok: true; seq: number } | SessionBusRefusal {
    const self = this.deps.self(sessionId);
    if (!self) return this.noSelf();
    const s = this.stateFor(sessionId);
    const rec = taskFor(s.tasks, taskId);
    if (!rec) return unknownTask();
    if (isTerminal(rec.state)) return refuse("TASK_TERMINAL", `this task is already ${rec.state}`);

    const now = this.now();
    const frame = createMessage("session-bus:cancel", {
      from: self.key,
      to: keyOf(rec.peer),
      contextId: rec.contextId,
      taskId,
      seq: 0,
      reason,
    });
    const queued = mintOutbound(s.tasks, { taskId, state: "canceled", frame, now, cancelReason: reason });
    if (queued.kind !== "queued") return blocked(queued.reason);
    // The seq the record actually minted, stamped back onto the frame already in
    // the outbox: `mintOutbound` is the only thing allowed to choose one, and a
    // frame whose seq disagreed with its outbox entry would be acked into a slot
    // that never retires.
    frame.seq = queued.seq;
    this.commit(sessionId, { tasks: this.firstAttempt(queued.next, queued.task, queued.seq, frame, now).tasks });
    return { ok: true, seq: queued.seq };
  }

  // -- outbound, peer side --------------------------------------------------

  /**
   * Report a state this bridge has reached on a task it was assigned.
   *
   * `waitingOn` is chosen by the CALLER from the cause (spec 3.4) — the agent
   * asks to be unblocked, it never declares who is holding it.
   */
  report(input: ReportInput, state: TaskState): { ok: true; seq: number } | SessionBusRefusal {
    const self = this.deps.self(input.sessionId);
    if (!self) return this.noSelf();
    const s = this.stateFor(input.sessionId);
    const rec = taskFor(s.tasks, input.taskId);
    if (!rec) return unknownTask();
    if (isTerminal(rec.state)) return refuse("TASK_TERMINAL", `this task is already ${rec.state}`);

    const now = this.now();
    const envelope = this.stamp(self, {
      taskId: input.taskId,
      contextId: rec.contextId,
      parts: input.parts,
      summary: input.summary,
      ...(input.unexpected === undefined ? {} : { unexpected: input.unexpected }),
    });
    const tooLarge = checkEnvelopeSize(envelope);
    if (tooLarge) return refuse(tooLarge, ENVELOPE_TOO_LARGE_REASON);

    const frame = createMessage("session-bus:transition", {
      from: self.key,
      to: keyOf(rec.peer),
      contextId: rec.contextId,
      taskId: input.taskId,
      seq: 0,
      state,
      ...(input.waitingOn === undefined ? {} : { waitingOn: input.waitingOn }),
      envelope,
    });
    const queued = mintOutbound(s.tasks, {
      taskId: input.taskId,
      state,
      frame,
      now,
      ...(input.waitingOn === undefined ? {} : { waitingOn: input.waitingOn }),
    });
    if (queued.kind !== "queued") return blocked(queued.reason);
    frame.seq = queued.seq;
    this.commit(input.sessionId, {
      tasks: this.firstAttempt(queued.next, queued.task, queued.seq, frame, now).tasks,
      log: appendLog(s.log, { at: now, direction: "out", peer: keyOf(rec.peer), envelope }),
    });
    return { ok: true, seq: queued.seq };
  }

  // -- outbound, either side ------------------------------------------------

  /**
   * An unsequenced, unacked note: a finding, an answer, an aside.
   *
   * Spec 6 makes these lossy on purpose, so a send that does not leave is
   * dropped rather than queued — unbounded retry behind text that changes no
   * state buys nothing, and the state that matters travels as a transition.
   */
  message(input: MessageInput): { ok: true; sent: boolean; messageId: string } | SessionBusRefusal {
    const self = this.deps.self(input.sessionId);
    if (!self) return this.noSelf();
    const s = this.stateFor(input.sessionId);
    const rec = input.taskId === null ? null : taskFor(s.tasks, input.taskId);
    if (input.taskId !== null && !rec) return unknownTask();

    const now = this.now();
    const contextId = rec?.contextId ?? input.contextId ?? input.sessionId;
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
    // The route follows the SESSION's side of this context, not a task record a
    // taskless finding does not have: defaulting a peer's aside to "lead" posts
    // it to the peer machine's own desktop app, which accepts it and reports it
    // sent. A record refines the answer when there is one.
    const role = rec?.role ?? this.roleForContext(input.sessionId, contextId);
    const sent = this.deps.send(frame, { contextId, role, to: keyOf(input.to) });

    let tasks = s.tasks;
    if (rec) {
      tasks = recordFinding(tasks, rec.taskId, {
        at: now,
        messageId: envelope.messageId,
        summary: envelope.metadata.summary,
        ...textOf(input.parts),
      });
    }
    this.commit(input.sessionId, {
      tasks: withExchange(tasks, now),
      log: appendLog(s.log, { at: now, direction: "out", peer: keyOf(input.to), envelope }),
    });
    return { ok: true, sent, messageId: envelope.messageId };
  }

  /** Ask the machine that published an artifact for one slice of it. Unacked and
   *  unqueued like a message: the fetcher retries by asking again, because a
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
   * WITHOUT an ack: acking it would tell the sender a task is being worked that
   * nothing here will ever work.
   */
  handleInbound(msg: AbMessage): InboundOutcome {
    switch (msg.type) {
      case "session-bus:assign":
      case "session-bus:transition":
      case "session-bus:cancel":
      case "session-bus:message":
      case "session-bus:fetch":
      case "session-bus:fetch:result":
      case "session-bus:ack":
        break;
      default:
        return false;
    }
    const self = this.deps.self(msg.to.sessionId);
    if (!self || !sameAddress(self.key, msg.to)) {
      log.warn(
        { type: msg.type, to: msg.to },
        "session-bus: inbound frame addressed to a session this bridge does not hold; dropped",
      );
      return "dropped";
    }
    const sessionId = msg.to.sessionId;
    switch (msg.type) {
      case "session-bus:assign":
        this.onTransition(sessionId, self, msg.from, msg.contextId, msg.taskId, msg.seq, "submitted", msg.envelope, {
          expiresAt: msg.expiresAt,
        });
        return "applied";
      case "session-bus:transition":
        this.onTransition(sessionId, self, msg.from, msg.contextId, msg.taskId, msg.seq, msg.state, msg.envelope, {
          ...(msg.waitingOn === undefined ? {} : { waitingOn: msg.waitingOn }),
        });
        return "applied";
      case "session-bus:cancel":
        this.onCancel(sessionId, self, msg.from, msg.contextId, msg.taskId, msg.seq, msg.reason);
        return "applied";
      case "session-bus:message":
        this.onMessage(sessionId, msg.from, msg.taskId, msg.envelope);
        return "applied";
      case "session-bus:ack":
        this.onAck(sessionId, msg.taskId, msg.seq);
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
   * Drain every due outbox entry across every loaded session.
   *
   * Called on the timer, and directly whenever a carrier appears: a retry
   * schedule is the fallback for a silent link, not what decides how fast a live
   * one moves.
   */
  pump(): void {
    const now = this.now();
    for (const sessionId of [...this.sessions.keys()]) {
      this.expire(sessionId, now);
      this.flushOutbox(sessionId, now);
    }
    if (this.timer && !this.anyPending()) this.stop();
  }

  // -- internals ------------------------------------------------------------

  private stateFor(sessionId: string): SessionState {
    let s = this.sessions.get(sessionId);
    if (!s) {
      s = {
        tasks: loadTasks(this.deps.abDir, this.deps.projectId, sessionId),
        log: loadMessageLog(this.deps.abDir, this.deps.projectId, sessionId),
        artifacts: null,
      };
      this.sessions.set(sessionId, s);
      // Hydrating IS how an outbox comes back off disk, so the timer has to be
      // considered here and not only at a commit: nothing else re-arms the
      // retries a previous process queued.
      this.ensureTimer();
    }
    return s;
  }

  private commit(sessionId: string, patch: Partial<SessionState>): void {
    const s = this.stateFor(sessionId);
    const next: SessionState = { ...s, ...patch };
    this.sessions.set(sessionId, next);
    if (next.tasks !== s.tasks) saveTasks(this.deps.abDir, this.deps.projectId, sessionId, next.tasks);
    if (next.log !== s.log) saveMessageLog(this.deps.abDir, this.deps.projectId, sessionId, next.log);
    this.ensureTimer();
  }

  /** The retry-and-expiry timer runs only while this project has something to
   *  wait for. A project whose sessions are on no bus — nearly all of them —
   *  must not wake the process once a second forever. */
  private ensureTimer(): void {
    if (this.timer || !this.anyPending()) return;
    this.timer = setInterval(() => this.pump(), OUTBOX_TICK_MS);
    this.timer.unref?.();
  }

  private anyPending(): boolean {
    for (const s of this.sessions.values()) {
      for (const t of s.tasks.tasks) {
        if (t.outbox.length > 0) return true;
        if (!isTerminal(t.state) && t.expiredAt === undefined) return true;
      }
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

  /** Which end of the bus this session is on for a context, for a caller that
   *  needs to know before there is a task to ask.
   *
   *  A task record answers outright. With none, the CONTEXT ID does: a context
   *  is named by its lead's session id (`contextOf`, session-bus/api.ts), so a
   *  session whose own id is the context id opened that context and leads it,
   *  and any other context id is one this session was joined into as a peer.
   *
   *  Defaulting to "lead" instead is exactly the misroute `message` warns about
   *  one call up. A fresh peer has no tasks by definition, and reporting a
   *  finding before it is assigned anything is what its brief asks of it — so
   *  that default would post its first finding to its OWN machine's desktop app,
   *  which accepts it and reports it sent. */
  private roleForContext(sessionId: string, contextId: string): BusRole {
    const tasks = tasksFor(this.stateFor(sessionId).tasks, contextId);
    if (tasks[0]) return tasks[0].role;
    return contextId === sessionId ? "lead" : "peer";
  }

  /** Make the one attempt `mintOutbound` counted on the caller's behalf.
   *
   * Kept out of the timer's drain because a frame must go the instant it is
   * queued: routing the first send through the retry schedule would put a whole
   * backoff step in front of every task, on a link that is usually up.
   *
   * `sent` rides back with the state because the state alone cannot say: a held
   * frame and a delivered one differ only in an outbox entry the caller does not
   * read.
   */
  private firstAttempt(
    tasks: TaskStoreState,
    rec: TaskRecord,
    seq: number,
    frame: AbMessage,
    now: number,
  ): { tasks: TaskStoreState; sent: boolean } {
    const sent = this.deps.send(frame, { contextId: rec.contextId, role: rec.role, to: keyOf(rec.peer) });
    return { tasks: sent ? tasks : holdOutbound(tasks, rec.taskId, seq, now), sent };
  }

  private flushOutbox(sessionId: string, now: number): void {
    const s = this.stateFor(sessionId);
    const due = dueOutbox(s.tasks, now);
    if (due.length === 0) return;
    let tasks = s.tasks;
    for (const { taskId, entry } of due) {
      const rec = taskFor(tasks, taskId);
      if (!rec) continue;
      const sent = this.deps.send(entry.frame as AbMessage, {
        contextId: rec.contextId,
        role: rec.role,
        to: keyOf(rec.peer),
      });
      // A send that never left is not an attempt, and counting it would push a
      // live task's next retry out to a minute for a link that was never tried.
      if (sent) tasks = noteAttempt(tasks, taskId, entry.seq, now);
    }
    if (tasks !== s.tasks) this.commit(sessionId, { tasks });
  }

  private expire(sessionId: string, now: number): void {
    const s = this.stateFor(sessionId);
    const ticked = tickExpiry(s.tasks, now);
    if (ticked.expired.length === 0) return;
    this.commit(sessionId, { tasks: ticked.next });
    for (const task of ticked.expired) this.emit({ kind: "expired", sessionId, task });
  }

  private ack(
    self: SessionBusSelf,
    to: SessionMemberKey,
    contextId: string,
    taskId: string,
    seq: number,
    role: BusRole,
  ): void {
    const frame = createMessage("session-bus:ack", { from: self.key, to, contextId, taskId, seq, ok: true });
    this.deps.send(frame, { contextId, role, to });
  }

  private onTransition(
    sessionId: string,
    self: SessionBusSelf,
    from: SessionMemberKey,
    contextId: string,
    taskId: string,
    seq: number,
    state: TaskState,
    envelope: BusEnvelope,
    extra: { waitingOn?: WaitingOn; expiresAt?: number },
  ): void {
    const now = this.now();
    const s = this.stateFor(sessionId);
    const outcome = applyTransition(
      s.tasks,
      {
        taskId,
        contextId,
        seq,
        state,
        peer: envelope.metadata.peer,
        messageId: envelope.messageId,
        summary: envelope.metadata.summary,
        ...textOf(envelope.parts),
        ...(extra.waitingOn === undefined ? {} : { waitingOn: extra.waitingOn }),
        ...(extra.expiresAt === undefined ? {} : { expiresAt: extra.expiresAt }),
      },
      now,
    );
    // No exchange is counted here. A transition that APPLIES is progress and the
    // fold has already reset the counter; one that does not is a duplicate, a
    // stale seq or a gap -- the retry machinery doing its job. Counting either
    // would halt a session for a lossy link, and spec 8 bounds chatter between
    // agents, not packets.
    this.commit(sessionId, {
      tasks: outcome.next,
      log: appendLog(s.log, { at: now, direction: "in", peer: from, envelope }),
    });
    // Acked BEFORE the event fires, and for EVERY outcome — applied, duplicate,
    // stale, gap, illegal, post-terminal. The ack means "this seq will never
    // change my state again", not "I liked it", and declining to re-ack is what
    // wedges a sender whose ack was the thing that got lost.
    this.ack(self, from, contextId, taskId, seq, this.roleOf(sessionId, taskId));
    if (outcome.kind !== "applied") return;
    this.emit(
      state === "submitted"
        ? { kind: "assigned", sessionId, task: outcome.task, envelope }
        : { kind: "transitioned", sessionId, task: outcome.task, state, envelope },
    );
  }

  private onCancel(
    sessionId: string,
    self: SessionBusSelf,
    from: SessionMemberKey,
    contextId: string,
    taskId: string,
    seq: number,
    reason: string,
  ): void {
    const now = this.now();
    const s = this.stateFor(sessionId);
    const rec = taskFor(s.tasks, taskId);
    // A cancel carries no envelope — nothing an agent wrote crosses on it — so
    // the provenance the fold wants comes from the task's own peer, and from the
    // sender only when there is no task to ask.
    const peer: SessionMemberRef = rec?.peer ?? { ...from };
    const outcome = applyTransition(
      s.tasks,
      {
        taskId,
        contextId,
        seq,
        state: "canceled",
        peer,
        messageId: `${taskId}:cancel:${seq}`,
        summary: reason || "canceled by the lead",
        cancelReason: reason,
      },
      now,
    );
    // Not an exchange, for the reason `onTransition` gives.
    this.commit(sessionId, { tasks: outcome.next });
    this.ack(self, from, contextId, taskId, seq, this.roleOf(sessionId, taskId));
    if (outcome.kind !== "applied") return;
    this.emit({ kind: "canceled", sessionId, task: outcome.task, reason });
  }

  private onMessage(
    sessionId: string,
    from: SessionMemberKey,
    taskId: string | null,
    envelope: BusEnvelope,
  ): void {
    const now = this.now();
    const s = this.stateFor(sessionId);
    let tasks = s.tasks;
    if (taskId !== null && taskFor(tasks, taskId)) {
      tasks = recordFinding(tasks, taskId, {
        at: now,
        messageId: envelope.messageId,
        summary: envelope.metadata.summary,
        ...textOf(envelope.parts),
      });
    }
    this.commit(sessionId, {
      tasks: withExchange(tasks, now),
      log: appendLog(s.log, { at: now, direction: "in", peer: from, envelope }),
    });
    this.emit({ kind: "message", sessionId, taskId, peer: envelope.metadata.peer, envelope });
  }

  private onAck(sessionId: string, taskId: string, seq: number): void {
    const s = this.stateFor(sessionId);
    const next = ackOutbound(s.tasks, taskId, seq);
    if (next === s.tasks) return;
    this.commit(sessionId, { tasks: next });
  }

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

  private roleOf(sessionId: string, taskId: string): BusRole {
    return taskFor(this.stateFor(sessionId).tasks, taskId)?.role ?? "peer";
  }

  private emit(event: SessionBusEvent): void {
    try {
      this.deps.onEvent?.(event);
    } catch (err) {
      // A consumer that throws must not cost the ack that already went, nor the
      // store write that already landed.
      log.error({ err, kind: event.kind }, "session-bus: event consumer threw");
    }
  }
}

const ENVELOPE_TOO_LARGE_REASON =
  "this message is too large for the bus; publish the bulk as an artifact and reference it instead";

function notMember(): SessionBusRefusal {
  return refuse("NOT_MEMBER", "this session is not a member of a multi-machine session");
}

function unknownTask(): SessionBusRefusal {
  return refuse("UNKNOWN_TASK", "no such task on this session");
}

function blocked(reason: "unknown-task" | "in-flight" | "illegal" | "outbox-full"): SessionBusRefusal {
  if (reason === "unknown-task") return unknownTask();
  if (reason === "illegal") return refuse("TASK_TERMINAL", "that is not a state this task can reach from here");
  // Stop-and-wait: one transition per task is in flight at a time, so a second
  // one is not lost, it is early. The caller retries once the ack lands.
  return refuse("AGENT_NOT_READY", "the previous report on this task is still unacknowledged");
}

function keyOf(ref: SessionMemberKey | SessionMemberRef): SessionMemberKey {
  return { machineId: ref.machineId, projectId: ref.projectId, sessionId: ref.sessionId };
}

/** The first text part, which is what a finding keeps as its durable body. A
 *  data or artifact part is a handle the finding already names by summary. */
function textOf(parts: readonly BusPart[]): { text?: string } {
  const first = parts.find((p) => p.kind === "text");
  return first && first.kind === "text" ? { text: first.text } : {};
}

/** Count one exchange that moved no task: a finding, an answer, an aside. Only
 *  agent-authored text reaches this -- never an ack, a duplicate or a retry. */
function withExchange(s: TaskStoreState, now: number): TaskStoreState {
  const guard = noteExchange(s.guard, now);
  return guard === s.guard ? s : { guard, tasks: s.tasks };
}
