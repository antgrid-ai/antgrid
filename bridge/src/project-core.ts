import { randomBytes } from "node:crypto";
import { buildAgentCore, type AgentCore, type BuildAgentCoreOptions } from "./agent-core";
import { MessageBus, type ClientKey } from "./message-bus";
import { LocalListener } from "./local-listener";
import type { AttachStreamOpts, PeerSessionView, StreamHandle } from "./project-streams";
import type { AbMessage, SessionEntry, WorkStatus } from "./protocol";
import type { DeleteSessionOptions } from "./session-manager";
import { answerRequest, becameDeliverable, busDeliverable, clientFocusState, clientGone, closeInterruptedTurn, DEFAULT_TURN_IDLE_MS, expireTurns, hookTurnEnd, initialWorkStatus, isStaleIdleNudge, noteHookChannelLost, noteHookChannelRestored, openedTurns, PROVISIONAL_TURN_GRACE_MS, reduceWorkStatus, retractProvisionalTurn, sessionFocus, turnActivity, turnOpenFor, turnStart, UNATTRIBUTED_TURN, userReply, type WorkStatusState } from "./work-status";
import { SessionBusDeliveryQueue, type QueuedLine } from "./session-bus/delivery-queue";
import { logger } from "./logger";
const log = logger.child({ component: "project-core" });
import { createPushDispatcher } from "./push/push-dispatcher";
import { sealPush } from "./push/seal";

/** How often {@link ProjectCore} checks for turns {@link expireTurns} should
 *  close. Five minutes is coarse enough that the check never shows up as work,
 *  and precise enough against a 30-minute idle bound that nobody watching the
 *  dot would notice the difference from an exact deadline. */
const EXPIRE_CHECK_INTERVAL_MS = 5 * 60_000;

/** Host-level dependencies injected into a remote-mode ProjectCore. In local
 * mode these are unused. The host owns the machine's native peer sessions; a
 * core attaches its bus as a host-local multiplexed stream. */
export interface ProjectCoreRemoteDeps {
  /** Attach this core's bus as a host-local stream on the machine's native
   *  peer sessions. */
  attachStream(bus: MessageBus, opts: AttachStreamOpts): StreamHandle;
  /** Every app device that currently holds a session with this machine —
   *  the push dispatcher's authorized-device list, and the fan-out this stream
   *  feeds. Central presence does not own or mutate these native sessions. */
  establishedPeers(): PeerSessionView[];
  /** One device's session by route address, or null when it holds none. The
   *  core asks this of the device a frame ARRIVED on, so every per-device answer
   *  (push identity) is that device's own. */
  peerSession(peerId: string): PeerSessionView | null;
  /** The bare machine deviceUuid this host registers under. The phone addresses
   *  a project as `<machineUuid>.<projectId>`, so a push sealed without it is a
   *  push the phone cannot open. Required, not optional: optional would let a
   *  supplier ship unroutable pushes and still compile. */
  machineDeviceId(): string;
  /** Blind FCM/APNs push forward over the central control socket. */
  sendPushDeliver(msg: { pushToken: string; provider: "fcm" | "apns"; blob: { epk: string; box: string } }): void;
}

export interface ProjectCoreDeps extends BuildAgentCoreOptions {
  remote?: ProjectCoreRemoteDeps; // Required when mode === "remote".
  /** This machine's account-scoped device id, supplied by the host for cores of EVERY
   *  mode. The session bus needs it on a local core too: a desktop-opened
   *  project is `mode === "local"` and still has to stamp its own half of every
   *  address it sends. Distinct from `identity.deviceId`, which for a local core
   *  is a fresh randomUUID that addresses no machine any peer knows. Null when
   *  the host has no remote identity yet, which is a machine with no bus address
   *  rather than a session this bridge does not hold — see the coordinator's
   *  `addressable`. */
  machineDeviceId?: () => string | null;
}

/** Handle for a native project binding added to an already-open core via {@link ProjectCore.promote}.
 *  `stop()` is idempotent and tears down ONLY the added native binding — the live
 *  loopback session is left attached (Task 3 owns the full demotion semantics). */
export interface PromotionHandle {
  stop(): void;
  /** Resolves once the host-local project binding is ready. */
  firstRegister: Promise<void>;
}

function sameStatuses(a: ReadonlyMap<string, WorkStatus>, b: ReadonlyMap<string, WorkStatus>): boolean {
  if (a.size !== b.size) return false;
  for (const [id, s] of a) if (b.get(id) !== s) return false;
  return true;
}

/**
 * Per-project runtime aggregate. Owns the {@link AgentCore}, its outbound
 * {@link MessageBus}, and the mode-specific transport (loopback listener for
 * local; native peer transport for remote). This is the seam for a singleton host that
 * runs N cores in one process.
 */
export class ProjectCore {
  private core: AgentCore | null = null;
  private bus: MessageBus | null = null;
  private listener: LocalListener | null = null;
  /** This core's project stream with the push subscriber that rides it: the
   *  primary binding for a remote-mode core, the promoted one for a local-mode
   *  core. {@link sendToAppSession} has no other way to reach the wire, so a
   *  promoted core that left this unset could carry a session-bus exchange IN
   *  and never answer it. Written only by {@link attachRelayStream}. */
  private slot: {
    handle: StreamHandle;
    /** An ADDITIVE subscriber on a bus that outlives the stream, so whoever
     *  detaches the handle must drop this too. */
    unsubscribePush: () => void;
  } | null = null;
  private relayFirstRegister: Promise<void> | null = null;
  private relayRegistered = false;
  private _localConnectInfo: { port: number; token: string } | null = null;

  // Reduced per-project work status for the always-on control-plane advert, so
  // the app's Recent/sidebar reflect activity WITHOUT warming this core. The
  // reduction is a pure fold over outbound bus frames — see work-status.ts.
  private _work: WorkStatusState = initialWorkStatus;
  /** Turn-boundary delivery for this project's session-bus lines.
   *  Owned here because the turn-open set it waits on is THIS reduction, and
   *  nothing below the core can see one. */
  private deliveries: SessionBusDeliveryQueue | null = null;
  /** Periodic {@link expireTurns} sweep — the backstop for a turn nothing else
   *  closes. Unref'd so it never keeps the process alive on its own; cleared in
   *  {@link shutdown}. */
  private expireInterval: ReturnType<typeof setInterval> | null = null;
  private readonly provisionalTimers = new Set<ReturnType<typeof setTimeout>>();
  private _onWorkStatusChange: (() => void) | null = null;
  private _onSessionsChange: (() => void) | null = null;
  /** Identity signature (id/name/archived, sorted) of the last `session:updated`
   *  this core observed. `session:updated` also re-fires on a pure work-status
   *  re-stamp ({@link SessionManager.refreshWorkStatus}, no list change at all),
   *  so {@link onSessionsChange} cannot just listen for the message type — it
   *  has to diff against this to fire only on a REAL list mutation (rename,
   *  create, archive, delete). Null until the first frame, so startup never
   *  counts as a change. */
  private _sessionsSignature: string | null = null;
  /** Set by {@link observeWorkStatus} for the message it just folded: true when
   *  the notification carried nothing new (exact-repeat or the
   *  awaiting_input-after-task_complete stale nudge). The push subscriber
   *  (attached later, so its
   *  bus callback always runs after this one for the same publish()) reads
   *  this to skip pushing a notification that carries no new information —
   *  see attachRelayStream. */
  private _lastNotificationRedundant = false;

  constructor(private readonly deps: ProjectCoreDeps) {}

  get projectId(): string { return this.core?.projectId ?? ""; }
  /** The core's resolved name (antgrid.yaml `name:`, else folder basename) —
   *  `undefined` before the core has finished starting, which callers must
   *  treat as "unknown right now", never as "this project has no name". */
  get projectName(): string | undefined { return this.core?.projectName; }
  get localConnectInfo(): { port: number; token: string } | null { return this._localConnectInfo; }

  /** Session-bus outbound for a context this machine opened. A bridge cannot
   *  dial another bridge, so the desktop owner is the only carrier, and the
   *  frame goes to it directly: publishing would fan the exchange out to the
   *  human's phone as well. False means it did not leave. */
  sendToOwner(msg: AbMessage): boolean {
    return this.listener?.deliverToOwner(msg) ?? false;
  }

  /** Session-bus outbound on a context this machine was contacted on, addressed
   *  at the one app session that carried it in. The phone is attached to the
   *  same stream, so a broadcast here would leak the whole exchange to it — the
   *  mirror image of the invariant {@link sendToOwner} keeps. */
  sendToAppSession(peerId: string, msg: AbMessage): boolean {
    // `sendTo` settles when the frame leaves the send queue, which is long after
    // the caller has to decide whether to hold it. "The session is live" is the
    // strongest fact available synchronously and is exactly what the boolean
    // used to mean.
    const slot = this.slot;
    if (!slot?.handle.deliverableTo(peerId)) return false;
    void slot.handle.sendTo(msg, "control", { kind: "peer", peerId });
    return true;
  }
  /** Current reduced work status (working/attention/done/error) for the
   *  control-plane advert. Defaults to "done" before any signal. */
  get workStatus(): WorkStatus { return this._work.status; }

  /** Live non-archived running-session count from the same reduction, carried
   *  in the control-plane advert (`runningSessions`) so the app re-peeks the
   *  session list exactly when it actually changed — see protocol.ts. */
  get workRunningCount(): number { return this._work.runningCount; }

  /** Per-running-session work status for the control-plane advert, so the app
   *  dots each SESSION row rather than painting every session on the project
   *  with its noisiest sibling's state. Empty (not absent) when nothing runs —
   *  presence is how the app tells a per-session bridge from an older one. */
  get sessionWorkStatuses(): Record<string, WorkStatus> {
    return Object.fromEntries(this._work.sessionStatuses);
  }

  /** {@link sessionWorkStatuses} restricted to sessions a main-checkout branch
   *  switch would actually disturb. An isolated session works in its own
   *  worktree, so counting it would block a switch it cannot be affected by.
   *  Only the branch guards read this; the advert must keep dotting every
   *  session. */
  get mainSessionWorkStatuses(): Record<string, WorkStatus> {
    const out: Record<string, WorkStatus> = {};
    for (const [id, status] of this._work.sessionStatuses) {
      if (this.core?.isMainCheckoutSession(id) ?? true) out[id] = status;
    }
    return out;
  }

  /** Register a callback fired whenever {@link workStatus},
   *  {@link workRunningCount} or {@link sessionWorkStatuses} CHANGES (deduped),
   *  so the host can re-advertise the control plane on a real transition rather
   *  than polling. Pass null to clear. */
  onWorkStatusChange(cb: (() => void) | null): void { this._onWorkStatusChange = cb; }

  /** Register a callback fired whenever the session list's IDENTITY changes —
   *  a session created, renamed, archived/unarchived or deleted — so a cold
   *  peeker (a device with this project's drawer collapsed, never warmed) can
   *  be told to re-peek even though nothing here moved {@link workStatus} or
   *  {@link workRunningCount}. A pure per-turn work-status re-stamp does NOT
   *  fire this (see {@link _sessionsSignature}). Pass null to clear. */
  onSessionsChange(cb: (() => void) | null): void { this._onSessionsChange = cb; }

  /** Diff an observed `session:updated` against {@link _sessionsSignature},
   *  firing {@link onSessionsChange} only when the session set's identity
   *  actually moved. `workStatus`/`agentSessionResumable`/etc. are deliberately
   *  excluded from the signature — those churn on ordinary turn boundaries via
   *  {@link SessionManager.refreshWorkStatus}, which re-emits the exact same
   *  `session:updated` message type with an unchanged list. */
  private observeSessionsIdentity(sessions: readonly SessionEntry[]): void {
    const signature = sessions
      .map((s) => JSON.stringify([s.id, s.name, s.archived]))
      .sort()
      .join(",");
    const prev = this._sessionsSignature;
    this._sessionsSignature = signature;
    if (prev !== null && prev !== signature) this._onSessionsChange?.();
  }

  /** Commit a new work-status reduction, firing {@link onWorkStatusChange} only
   *  on a real transition of the advertised values (a fresh object with all of
   *  them unchanged — e.g. a turn-start while already working — re-advertises
   *  nothing). Count changes with an unchanged status (a 2nd session starting
   *  while one is working) must still re-advertise, or the phone's Recent list
   *  misses the new session until an unrelated flip; likewise a per-session flip
   *  that leaves the ROLLUP unchanged (one session unblocks while a sibling is
   *  still working) is exactly the transition the session dots exist to show. */
  private commitWork(next: WorkStatusState): void {
    if (next === this._work) return;
    const perSessionChanged = !sameStatuses(next.sessionStatuses, this._work.sessionStatuses);
    const changed = next.status !== this._work.status
      || next.runningCount !== this._work.runningCount
      || perSessionChanged;
    // Computed against the OLD state and drained against the new one: the
    // releasing edge is the whole delivery boundary, and reading it after the
    // swap would compare the new state with itself.
    const released = becameDeliverable(this._work, next);
    // The other half of the same edge pair: a line already submitted is retired
    // by the turn it opened, which is the only evidence this bridge gets that
    // the agent read it rather than left it sitting in its composer.
    const opened = openedTurns(this._work, next);
    this._work = next;
    for (const sessionId of opened) this.deliveries?.confirm(sessionId);
    for (const sessionId of released) {
      // An agent with no per-session turn reporting closes the UNATTRIBUTED_TURN
      // key instead of its own id (see work-status.ts), and that close is a real
      // boundary for every session in the project — the same reading `statusFor`
      // already takes. Draining only the literal id would leave those agents'
      // deliveries waiting for an edge that never comes.
      if (sessionId === UNATTRIBUTED_TURN) this.deliveries?.drainAll();
      else this.deliveries?.drain(sessionId);
    }
    if (changed) this._onWorkStatusChange?.();
    // The advert is not the only consumer: `session:updated` stamps each entry's
    // status from this same reduction, and the session list is otherwise only
    // re-emitted when the sessions themselves change. Gated on the per-session
    // map so a rollup-only move doesn't churn the list.
    if (perSessionChanged) this.core?.refreshSessionWork();
  }

  /** Fold one outbound bus frame into the work-status reduction. Must never
   *  throw — the bus lets subscriber throws propagate, and this rides the same
   *  publish() as the live native-stream subscriber (reduceWorkStatus is pure/total). */
  private observeWorkStatus(msg: AbMessage): void {
    const next = reduceWorkStatus(this._work, msg);
    // Redundant = the notification told us nothing new (exact repeat on the same
    // session, or the awaiting_input-after-task_complete stale nudge). Keyed on
    // the notification MAP's identity, not on the state object's: a repeat
    // notification still closes its session's turn, so it yields a new state
    // while recording no notification worth pushing to the phone. A sibling
    // session raising the same type IS new information — it lands on a different
    // key, so the map is replaced and the push goes out.
    this._lastNotificationRedundant = msg.type === "notification:push"
      && next.notifications === this._work.notifications;
    this.commitWork(next);
  }

  /** A turn-start hook fired (user submitted a prompt), or the user answered
   *  what was blocking [sessionId]: open its turn and clear its stale
   *  notification/pending request, so the session reads "working" for as long as
   *  the prompt actually runs. Routed here from the per-core api-server (never a
   *  bus frame — the app must not see it as a notification) and from the inbound
   *  permission/question resolves, via {@link AgentContext.onTurnStart}. */
  noteTurnStart(sessionId?: string): void {
    this.commitWork(turnStart(this._work, sessionId, undefined, Date.now()));
  }

  /** A per-tool-call hook re-asserted that [sessionId] is still working. Unlike
   *  {@link noteTurnStart}, never clears a pending request or a call-to-action
   *  notification — see {@link turnActivity}. Routed here from the per-core
   *  api-server via {@link AgentContext.onTurnActivity}. */
  noteTurnActivity(sessionId?: string): void {
    this.commitWork(turnActivity(this._work, sessionId, Date.now()));
  }

  /** The user typed into [sessionId]'s PTY — the only "I answered" signal a
   *  terminal-mode session has. Claims a turn only for an agent that cannot
   *  report its own starts, and only for a typed PROMPT. See {@link userReply}. */
  noteUserReply(
    sessionId: string,
    opts: { submitted: boolean; typed: boolean; command?: boolean },
  ): void {
    const now = Date.now();
    const before = this._work.provisionalTurns.get(sessionId);
    this.commitWork(userReply(this._work, sessionId, opts, now));
    const openedAt = this._work.provisionalTurns.get(sessionId);
    if (openedAt === undefined || openedAt === before) return;
    const timer = setTimeout(() => {
      this.provisionalTimers.delete(timer);
      this.commitWork(retractProvisionalTurn(this._work, sessionId, openedAt));
    }, PROVISIONAL_TURN_GRACE_MS);
    if (typeof timer.unref === "function") timer.unref();
    this.provisionalTimers.add(timer);
  }

  /** The user answered the permission/question [requestId] on [sessionId].
   *  Clears that block and resumes the turn, but only if it was pending; see
   *  {@link answerRequest}. */
  noteAnswer(sessionId: string, requestId?: string): void {
    this.commitWork(answerRequest(this._work, sessionId, requestId, Date.now()));
  }

  /** [client] is looking at [sessionId] (`session:focus`) — clear its unread
   *  mark and record it as on screen, so an answer that lands while the user
   *  sits here is never called unseen. See {@link sessionFocus}. */
  noteSessionFocus(sessionId: string, client: ClientKey): void {
    this.commitWork(sessionFocus(this._work, sessionId, client));
  }

  /** [client] declared whether it can render this project (`client:focus-state`).
   *  Paused releases what that client had on screen, which is what makes a turn
   *  finishing while the app is backgrounded come back unread. See
   *  {@link clientFocusState}. */
  noteClientFocusState(paused: boolean, client: ClientKey): void {
    this.commitWork(clientFocusState(this._work, paused, client));
  }

  /** [client]'s transport session closed — it stops vouching for whatever it had on screen.
   *  Without this a desktop that quit, or a phone whose native session ended,
   *  would keep one session permanently exempt from unread. See
   *  {@link clientGone}. */
  noteClientGone(client: ClientKey): void {
    this.commitWork(clientGone(this._work, client));
    // The core keeps its own copy of what each client has on screen (the setup
    // push reads it); a stale entry there mutes that push for good.
    this.core?.noteClientGone(client);
  }

  /** The user pressed an interrupt key into [sessionId]'s PTY — close its turn
   *  now rather than wait on a Stop hook the CLI may never fire for a manual
   *  interrupt. See {@link closeInterruptedTurn}.
   *
   *  Gated on {@link turnOpenFor}: closeInterruptedTurn clears whatever the
   *  session (or the project's unattributed slot) was blocked on
   *  unconditionally, with no notion of whether a turn was actually open to
   *  close. An idle session's Ctrl+C — reflexive after Claude/Codex added it
   *  as an interrupt key, where Esc rarely fired outside a live turn — would
   *  otherwise delete its own `task_complete` record and defeat
   *  {@link isStaleIdleNudge}, or (via the unattributed fallback) another
   *  session's live call-to-action. */
  noteInterrupt(sessionId: string): void {
    if (!turnOpenFor(this._work.activeTurns, sessionId)) return;
    this.commitWork(closeInterruptedTurn(this._work, sessionId));
  }

  /** A hook reported [sessionId]'s turn over on a channel that files no
   *  notification — the second closer. See {@link hookTurnEnd}. */
  noteHookTurnEnd(sessionId: string): void {
    this.commitWork(hookTurnEnd(this._work, sessionId));
  }

  /** [sessionId]'s injected hooks have been written off, so nothing is left to
   *  close a turn inferred from a keystroke. See {@link noteHookChannelLost}. */
  noteHookChannelLost(sessionId: string): void {
    this.commitWork(noteHookChannelLost(this._work, sessionId));
  }

  /** ...and they answered after all. See {@link noteHookChannelRestored}. */
  noteHookChannelRestored(sessionId: string): void {
    this.commitWork(noteHookChannelRestored(this._work, sessionId));
  }

  /** Resolves when a remote core's host-local project binding is ready. */
  whenRelayRegistered(): Promise<void> | null { return this.relayFirstRegister; }

  /** True once this core has a host-local native stream binding. Covers both
   *  a remote-mode core's primary binding and a promoted local core's additive
   *  binding; flips false when that binding is torn down. This is what the
   *  phone-facing advert's `running` flag means: remotely dialable, not merely
   *  warm/open on the host. The desktop hub advertises plain warmth separately. */
  isRelayRegistered(): boolean { return this.relayRegistered; }

  /** Forward a session delete to the live AgentCore. False if not started. */
  deleteSession(id: string, options?: DeleteSessionOptions): boolean | Promise<boolean> {
    return this.core?.deleteSession(id, options) ?? false;
  }

  /** Forward a session start to the live AgentCore. A no-op if not started —
   *  the host only calls this for a project it already found warm. */
  startSession(id: string): void {
    this.core?.startSession(id);
  }

  /** Forward the live session list (with true per-session `running`) to the
   *  control-plane `sessions.list` peek. Returns null if not started, so the
   *  caller can fall back to the on-disk persisted list. */
  listSessions(includeArchived: boolean): SessionEntry[] | null {
    return this.core?.listSessions(includeArchived) ?? null;
  }

  /** Host-level checkouts bypass the core's inbound bus handler. */
  async refreshGitState(): Promise<void> {
    await this.core?.refreshGitState();
  }

  async start(): Promise<void> {
    // Validate host-injected deps before building the core so a misconfigured
    // remote launch fails fast (and predictably) rather than spinning up
    // subsystems first.
    if (this.deps.mode === "remote" && !this.deps.remote) {
      throw new Error("ProjectCore: remote mode requires remote deps");
    }
    const core = await buildAgentCore({
      folder: this.deps.folder,
      configPath: this.deps.configPath,
      mode: this.deps.mode,
      identity: this.deps.identity,
      pairedPhones: this.deps.pairedPhones,
      remoteAccessEnabled: this.deps.remoteAccessEnabled,
      agentReachEnabled: this.deps.agentReachEnabled,
      tierClaim: this.deps.tierClaim,
      onTurnStart: (sessionId) => this.noteTurnStart(sessionId),
      onTurnActivity: (sessionId) => this.noteTurnActivity(sessionId),
      onUserReply: (sessionId, replyOpts) => this.noteUserReply(sessionId, replyOpts),
      onAnswer: (sessionId, requestId) => this.noteAnswer(sessionId, requestId),
      onInterrupt: (sessionId) => this.noteInterrupt(sessionId),
      onHookTurnEnd: (sessionId) => this.noteHookTurnEnd(sessionId),
      onHookChannelLost: (sessionId) => this.noteHookChannelLost(sessionId),
      onHookChannelRestored: (sessionId) => this.noteHookChannelRestored(sessionId),
      onSessionFocus: (sessionId, client) => this.noteSessionFocus(sessionId, client),
      onClientFocusState: (paused, client) => this.noteClientFocusState(paused, client),
      // The single source of per-session work status: SessionManager stamps it
      // onto `session:updated` from THIS reduction rather than keeping a second
      // one of its own. Read lazily — the fold that answers it runs after the
      // frame this feeds, so `refreshSessionWork` below is what re-emits.
      sessionWorkStatusFor: (id) => this._work.sessionStatuses.get(id),
      // The same reduction, and the same question `attachRelayStream`'s push
      // subscriber asks via `_lastNotificationRedundant` — asked here too so the
      // Handler never pays a context assemble plus a judge spawn for a nudge on
      // a turn that already finished.
      isStaleIdleNudge: (id) => isStaleIdleNudge(this._work, id),
      // Gates whether a lone Esc/Ctrl+C is even worth confirming against the
      // transcript — see shouldArmInterruptConfirm in agent-core.ts.
      isTurnOpenFor: (id) => turnOpenFor(this._work.activeTurns, id),
      sendToOwner: (msg) => this.sendToOwner(msg),
      sendToAppSession: (peerId, msg) => this.sendToAppSession(peerId, msg),
      // This machine's half of every session-bus address. The remote device id
      // wins when there is one, but a local core falls back to the host's — the
      // bus travels by its app carrier, not central control, so an address and a
      // native project stream are independent.
      machineId: () => this.deps.remote?.machineDeviceId() ?? this.deps.machineDeviceId?.() ?? null,
      // Only a desktop owner that declared itself a carrier can move a frame to
      // the machine it is addressed to; anything else is an unreachable target,
      // not a failed send.
      carrierPresent: () => this.listener?.ownerCarriesSessionBus ?? false,
      // Host-injected: absent only for a standalone core built with no host
      // (evals, most of this file's own test callers), which falls back to a
      // coordinator scoped to itself.
      sessionBus: this.deps.sessionBus,
      // Host-injected like the coordinator above, and forwarded by name because
      // this list is explicit rather than a spread: a field the host supplies
      // and this list omits reaches the core as undefined, and the bus then
      // refuses AGENT_NOT_READY ahead of every other gate on a real bridge
      // while every in-process test that injects a directory stays green.
      ...(this.deps.sessionDirectory ? { sessionDirectory: this.deps.sessionDirectory } : {}),
      // Host-injected for the same reason and forwarded the same way: a bridge
      // with no host (evals, most of this file's own test callers) offers no
      // wake at all, and the refusal falls back to its unconditional shape.
      ...(this.deps.startSession ? { startSession: this.deps.startSession } : {}),
      queueBusLine: (line: Omit<QueuedLine, "queuedAt">) => this.deliveries?.queue(line),
      forgetBusLines: (sessionId: string) => this.deliveries?.forget(sessionId),
      relayUrl: this.deps.relayUrl,
    });
    this.core = core;
    // Lazily reached in both directions on purpose: the queue reads the core to
    // submit and the core writes the queue to hold, and neither exists when the
    // other is built.
    this.deliveries = new SessionBusDeliveryQueue({
      abDir: core.abDir,
      projectId: core.projectId,
      // The reduction's own predicate, not a second reading of its inputs: an
      // agent that cannot attribute its turn-starts records them under
      // UNATTRIBUTED_TURN, and a delivery submitted against one lands mid-turn.
      canDeliver: (sessionId) => busDeliverable(this._work, sessionId),
      inject: (line) => this.core?.injectBusLine(line.sessionId, line.text) ?? "refused",
    });
    const bus = new MessageBus();
    this.bus = bus;
    core.attachTransport(bus);
    // Fold outbound frames into the control-plane work-status reduction. Additive
    // subscriber (like the push dispatcher); lives for the bus's lifetime.
    bus.subscribe({ deliver: (msg) => {
      this.observeWorkStatus(msg);
      if (msg.type === "session:updated") {
        this.observeSessionsIdentity(msg.sessions);
        // A line held across a restart has no turn to close behind it: its
        // session boots idle, so this list — emitted whenever a session starts
        // or stops — is the edge that gets it delivered. A no-op on an empty
        // queue, which is every ordinary project.
        this.deliveries?.drainAll();
      }
    } });
    if (this.deps.mode === "local") {
      await this.startLocal(core, bus);
    } else {
      await this.startRemote(core, bus);
    }
    // Bounds a turn nothing else closes (a missed interrupt key, a lost loopback
    // POST, a bridge restart mid-turn). Committed through the same path as every
    // other reducer transition, so a real expiry still re-advertises and drains
    // whatever the delivery queue was holding on it.
    this.expireInterval = setInterval(
      () => this.commitWork(expireTurns(this._work, Date.now(), DEFAULT_TURN_IDLE_MS)),
      EXPIRE_CHECK_INTERVAL_MS,
    );
    if (typeof this.expireInterval.unref === "function") this.expireInterval.unref();
  }

  /** Binds the loopback listener, sets `_localConnectInfo`, and eagerly primes
   *  managers via `core.onHandshakeComplete()`. Called from both startLocal and
   *  startRemote so every core exposes a usable loopback endpoint regardless of
   *  whether it also holds a native project binding. The eager prime is safe in remote mode:
   *  a later re-fire when a phone pairs calls setupServices guarded by
   *  `if (manager) resyncState()` — a benign resync, not a re-setup. */
  private async bindLoopback(core: AgentCore, bus: MessageBus): Promise<void> {
    const token = randomBytes(32).toString("base64url");
    const listener = new LocalListener({
      bus,
      token,
      projectId: core.projectId,
      // `onHandshakeComplete` is called twice intentionally and is idempotent:
      // here per owner connection, and eagerly below to prime managers at startup
      // (the loopback socket + token is the trust boundary; there's no
      // session handshake to gate on for the local data plane).
      onOwnerConnected: () => {
        // A local owner now shares the bus — clear any suppression a prior
        // peer-offline latched while no owner was attached.
        core.connState.peerOnline = true;
        core.onHandshakeComplete();
      },
      // The desktop app quit (or its socket dropped): it stops vouching for the
      // session it had on screen, so a turn ending afterwards is unread by the
      // time it comes back.
      onOwnerDisconnected: () => this.noteClientGone("loopback"),
    });
    await listener.start();
    this.listener = listener;

    // Connect info is published via the control-plane `project:open` response
    // (no per-project discovery file). Surface it for the host to hand out.
    this._localConnectInfo = { port: listener.port, token };
    log.info(`local listener ready on port ${listener.port}`);

    core.onHandshakeComplete();
  }

  private async startLocal(core: AgentCore, bus: MessageBus): Promise<void> {
    const projectId = core.projectId;
    const folder = this.deps.folder;
    log.info(`local: folder=${folder} projectId=${projectId} pid=${process.pid}`);

    await this.bindLoopback(core, bus);
  }

  private async startRemote(core: AgentCore, bus: MessageBus): Promise<void> {
    const remote = this.deps.remote;
    // Unreachable: start() already guards remote mode before building the core.
    // This narrows `remote` from optional to defined for the rest of the method.
    if (!remote) throw new Error("ProjectCore: remote mode requires remote deps");

    await this.bindLoopback(core, bus);

    this.relayFirstRegister = this.attachRelayStream(core, bus, remote).firstRegister;
  }

  /** Attach an already-built core+bus as a host-local native project stream and wire
   *  its tunnel-stream server, remote-peer provider, and fallback push
   *  path. The stream is an ADDITIVE bus subscriber, so the live loopback
   *  session is undisturbed. Shared by {@link startRemote} (fresh remote core)
   *  and {@link promote} (already-open local core); the caller owns the returned
   *  handle's lifetime. Encryption is NEVER optional: every project stream rides an
   *  authenticated Iroh connection to the one peer it was opened by. */
  private attachRelayStream(
    core: AgentCore,
    bus: MessageBus,
    remote: ProjectCoreRemoteDeps,
  ): {
    handle: StreamHandle;
    firstRegister: Promise<void>;
    unsubscribePush: () => void;
    /** Full teardown for this attach; idempotent, and safe once a re-attach
     *  has taken the slot over. False once it has. */
    detachSlot: () => boolean;
  } {
    // A binding is ready synchronously once the host's project-stream registry
    // admits it. Keep the promise-shaped seam so callers cannot race the ready
    // advertisement.
    let settle!: () => void;
    const firstRegister = new Promise<void>((res) => { settle = res; });
    let settled = false;
    const settleOnce = () => { if (!settled) { settled = true; settle(); } };

    // Whether a phone is live on THIS stream. Starts false: a fresh stream has
    // no peer until one connects. `connState.peerOnline` cannot express that —
    // it defaults true (a local core must stream to its loopback owner
    // un-suppressed) and its peer-offline transition is deliberately skipped
    // while a desktop owner is attached, so it reads "online" for a phone that
    // has never dialled in.
    let peerConnected = false;

    const handle = remote.attachStream(bus, {
      // Outbound half of the mobile-access gate. The inbound half (agent-core's
      // remoteFrameAllowed) only stops the phone DRIVING this project; without
      // this one a core the phone cold-started keeps streaming its terminal, file
      // tree and git status to that phone after the machine switch is turned off,
      // because a remote-mode core holds no PromotionHandle for demoteAllPromoted
      // to tear down. Fail-closed, same as the inbound side.
      mayDeliver: () => this.deps.remoteAccessEnabled?.() ?? false,
      projectId: core.projectId,
      // Fail-closed: a stream open with no resolvable session for the peer is
      // refused rather than admitted with nothing to route by.
      mayAcceptFrom: (peer) => peer === null ? { code: "NOT_ALLOWED", message: "no session for this peer" } : null,
      onAdmitted: () => { this.relayRegistered = true; settleOnce(); },
      // Suppress the heavy stream while the phone is gone; it rebuilds from
      // snapshots on reconnect. connState gates ALL bus subscribers at the source,
      // so don't suppress while a desktop owner shares it over loopback — that
      // would freeze the live local session.
      onPeerOnline: () => {
        peerConnected = true;
        core.connState.peerOnline = true;
      },
      onPeerOffline: () => {
        // Unconditional, unlike the stream gate below: the loopback carve-out
        // keeps the DESKTOP's stream live, it doesn't make the phone reachable
        // in-band. Leaving this set would mute push on every promoted core.
        peerConnected = false;
        // Unlike the stream gate, the read state is per-client: the last phone
        // has left whether or not a desktop owner is still here, so it must stop
        // vouching for the session it had on screen before the early return.
        // Named devices are cleared one at a time by onPeerSessionGone; this
        // clears the unnamed key a transport that threads no peerId writes under.
        this.noteClientGone("relay");
        if (this.listener?.hasOwner) return;
        core.connState.peerOnline = false;
      },
      onPeerSessionGone: (peerId) => {
        this.noteClientGone(peerId);
      },
      // Fired when this peer's project-stream binding itself closes (unbind,
      // reset, or the stream reader ending) rather than the whole peer session —
      // the read-state cleanup is the same either way.
      onPeerStreamClosed: (peerId) => this.noteClientGone(peerId),
      tunnels: core.tunnelStreams,
      uploads: core.uploadStreams,
    });

    // Mark this connection as REMOTE for the core's mobile-access gate, and let
    // every per-device question (capabilities, push identity) resolve against the
    // device that asked. Local mode never wires this, so loopback control stays
    // ungated.
    core.setPeerSessionProvider((peerId) => remote.peerSession(peerId));
    core.setTerminalStreamHooks(handle.terminalHooks ?? null);

    // Fallback push path: while the paired phone can't receive in-band (no live
    // peer on this stream OR the app is backgrounded), seal a notification to its
    // persistent push key and hand the ciphertext to the relay as a blind
    // FCM/APNs forward (push:deliver). This is an ADDITIVE bus subscriber — it
    // does NOT replace the stream's own live subscription (attachStream above);
    // the live path handles the online case and the dispatcher no-ops then.
    const dispatcher = createPushDispatcher({
      projectId: core.projectId,
      machineUuid: () => remote.machineDeviceId(),
      // Fire when NO attached client can receive in-band: no native session
      // at all, OR every client that has declared a focus state is backgrounded
      // (`appFocusPaused` is that conjunction, so one device in the user's hand
      // keeps push quiet while its backgrounded sibling would not). NOT
      // connState.suppressed — that's the heavy-stream gate, whose `peerOnline`
      // defaults true, so it reads "can receive in-band" for a phone that has
      // never connected and mutes push after a host restart.
      shouldFallback: () => !peerConnected || core.connState.appFocusPaused,
      // Read live, never captured: a slot is armed and disarmed under a stream
      // that outlives both.
      isHandlerArmed: (terminalId) => core.isHandlerArmed(terminalId),
      handlerOwnsCompletion: (terminalId) => core.handlerOwnsCompletion(terminalId),
      // Target every registered phone that CANNOT receive this in band right
      // now, which is the question push actually answers. A device is in band
      // only while it holds an established native session AND that session's
      // client has not backgrounded itself; anything else — no session, a
      // retired one, a backgrounded one — is a push target. Asking it per
      // device is what keeps a sibling from suppressing the fallback: a desktop
      // app establishes a session exactly like a phone but registers no push
      // token, so "some session exists" would silence the phone in the user's
      // pocket. Delivery never needs the socket (the relay forwards to FCM/APNs
      // blindly), which is also why a host restart — no sessions at all — still
      // targets every registered phone rather than guessing by `lastSeenAt`,
      // stale in exactly that window.
      resolveTargets: () => {
        // Push carries project activity off this machine, so it rides the same
        // machine switch as every inbound verb — a token+pubkey alone must not
        // leak notifications from a machine that isn't mobile-reachable.
        // Fail-closed: an unwired host provider means no push.
        if (!(this.deps.remoteAccessEnabled?.() ?? false)) return [];
        const inBand = new Set(
          remote.establishedPeers()
            .filter((p) => core.clientFocusPaused(p.peerId) !== true)
            .map((p) => p.peerPubkey),
        );
        const paired = core.pairedPhones.list();
        const candidates = paired.filter((p) => !inBand.has(p.phonePubkey));
        const targets = candidates.flatMap((p) =>
          p.pushToken && p.pushPubkey
            ? [{ pushToken: p.pushToken, provider: p.pushProvider ?? "fcm", pushPubkey: p.pushPubkey }]
            : [],
        );
        if (targets.length === 0) {
          // The dispatcher can only report THAT it dropped the notification. A
          // pruned token and no phone at all are indistinguishable in host.log
          // without this.
          log.warn(
            "push: no eligible phone for project %s (in band: %d, paired: %d) — need a registered phone with a push token",
            core.projectId,
            inBand.size,
            paired.length,
          );
        }
        return targets;
      },
      seal: (json, pubkey) => sealPush(json, pubkey),
      deliver: (token, provider, blob) => remote.sendPushDeliver({ pushToken: token, provider, blob }),
    });
    const unsubscribePush = bus.subscribe({
      deliver: (msg) => {
        // The work-status subscriber (subscribed in start(), before this one)
        // already folded this same message and flagged it redundant — e.g. the
        // generic post-completion "awaiting_input" nudge that follows a
        // task_complete this turn. That fold carries no new information for the
        // phone either, so skip the push rather than pinging a backgrounded user
        // for a turn that already resolved.
        if (msg.type === "notification:push" && this._lastNotificationRedundant) return;
        // Isolate the push dispatcher: a throw here (malformed target, seal
        // failure) must NOT abort publish() and starve the live stream subscriber
        // on the same message. push is best-effort, so we log.
        try {
          dispatcher.onOutbound(msg);
        } catch (err) {
          log.error("push dispatcher threw during deliver (type=%s): %s", msg.type, String(err));
        }
      },
    });

    // Claimed here, not by the caller: an attach leaving the slot unset can carry
    // a session-bus exchange IN and never answer it, the reply expiring at the
    // TTL with the send having reported itself on its way. `promote` refuses a
    // remote-mode core, so a takeover means a second promote without a stop —
    // warn rather than throw, since the overwrite would fail a live path.
    if (this.slot) {
      log.warn(
        "project stream slot for %s taken over by a second attach — the earlier stream can no longer be answered on",
        core.projectId,
      );
    }
    this.slot = { handle, unsubscribePush };

    // Push and stream go first, so `sendToAppSession` refuses rather than
    // reporting a send onto a dead stream. The core's hooks are its single copy,
    // which a second attach now owns, so they are cleared only by the attach
    // that still holds the slot.
    const detachSlot = (): boolean => {
      try { unsubscribePush(); } catch { /* best-effort */ }
      try { handle.detach(); } catch { /* best-effort */ }
      if (this.slot?.handle !== handle) return false;
      this.slot = null;
      try { core.setPeerSessionProvider(null); } catch { /* best-effort */ }
      try { core.setTerminalStreamHooks(null); } catch { /* best-effort */ }
      return true;
    };

    return { handle, firstRegister, unsubscribePush, detachSlot };
  }

  /** Promote an already-open (typically LOCAL) core to remote access by adding a
   *  native project binding to its EXISTING bus — the live loopback session keeps running
   *  untouched. The phone here is machine-trusted (account inventory + the
   *  machine's mobile-access switch), NOT QR-paired per project, so this does NOT
   *  open a pairing window. `remoteDeps` MUST come from the host's ONE shared
   *  runtime (remoteDepsFor) — promote constructs no OAuthClient / token timer. */
  promote(remoteDeps: ProjectCoreRemoteDeps): PromotionHandle {
    // A remote-mode core's native binding IS its primary remote session; promoting it would
    // wire a SECOND client whose PromotionHandle.stop() nulls
    // setPeerSessionProvider, tearing down the live primary session's hooks. Only
    // a local-mode core (whose loopback session owns no remote hooks) is promotable.
    if (this.deps.mode === "remote") {
      throw new Error("ProjectCore.promote: cannot promote a remote-mode core (its native project binding is primary)");
    }
    const core = this.core;
    const bus = this.bus;
    if (!core || !bus) throw new Error("ProjectCore.promote: core not started (call start() first)");

    const { firstRegister, detachSlot } = this.attachRelayStream(core, bus, remoteDeps);

    let stopped = false;
    return {
      firstRegister,
      stop: () => {
        if (stopped) return;
        stopped = true;
        // No stream → not dialable, so the advert reads not-running (a re-promote
        // flips it back). Unless a second attach owns the slot: ITS stream is
        // still admitted.
        if (detachSlot()) this.relayRegistered = false;
      },
    };
  }

  /** Tear down transport + subsystems. */
  async shutdown(reason?: string): Promise<void> {
    if (this.expireInterval) { clearInterval(this.expireInterval); this.expireInterval = null; }
    for (const timer of this.provisionalTimers) clearTimeout(timer);
    this.provisionalTimers.clear();
    try { this.core?.setPeerSessionProvider(null); } catch {}
    try { this.core?.setTerminalStreamHooks(null); } catch {}
    // Before detaching — deliver() would otherwise hand a frame to a torn-down
    // stream.
    try { this.slot?.unsubscribePush(); } catch {}
    // After the core, not before: the bus subscriber stays attached for the
    // bus's lifetime, and the `session:updated` frames a shutdown emits as
    // sessions stop reach `drainAll` — which arms a fresh timer on a queue that
    // has just been disposed.
    try { await this.core?.shutdown(); } catch {}
    try { this.deliveries?.dispose(); } catch {}
    try { await this.listener?.stop(); } catch {}
    try { this.slot?.handle.detach(); } catch {}
    // Match promote().stop(): a detached handle left in the slot would have
    // `sendToAppSession` still answering true onto a dead stream.
    this.slot = null;
  }
}
