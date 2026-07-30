import { randomBytes } from "node:crypto";
import { buildAgentCore, type AgentCore, type BuildAgentCoreOptions } from "./agent-core";
import { MessageBus } from "./message-bus";
import { LocalListener } from "./local-listener";
import { createRelayPromotion, type RelayPromotionController, type RelayPromotionDeps } from "./relay-promotion";
import type { AttachStreamOpts, StreamHandle } from "./stream-mux";
import { createMessage, type AbMessage, type SessionEntry, type WorkStatus } from "./protocol";
import { initialWorkStatus, reduceWorkStatus, turnStart, type WorkStatusState } from "./work-status";
import { logger } from "./logger";
const log = logger.child({ component: "project-core" });
import { createPushDispatcher } from "./push/push-dispatcher";
import { sealPush } from "./push/seal";

/** Host-level dependencies injected into a remote-mode ProjectCore. In local
 *  mode these are unused. The host owns the single machine relay socket (design
 *  §7); a core attaches its bus as a multiplexed stream rather than owning a
 *  RelayClient of its own. */
export interface ProjectCoreRemoteDeps {
  /** Attach this core's bus as a stream on the machine socket, allocating a
   *  streamId and driving stream-open admission. */
  attachStream(bus: MessageBus, opts: AttachStreamOpts): StreamHandle;
  /** The machine's currently-connected phone pubkey (the mobile-access gate's
   *  remote-vs-local signal, and the push dispatcher's live-device hint). */
  currentPeerPubkey(): string | null;
  /** Blind FCM push forward over the machine socket (fallback delivery). */
  sendPushDeliver(msg: { pushToken: string; provider: "fcm" | "apns"; blob: { epk: string; box: string } }): void;
}

export interface ProjectCoreDeps extends BuildAgentCoreOptions {
  remote?: ProjectCoreRemoteDeps; // Required when mode === "remote".
  /** Host hook that lets the local wizard promotion path bring the machine relay
   *  socket up from the app-supplied credentials and attach this core as a
   *  stream. Absent for a bare agent (enabling relay is then unsupported). */
  ensureMachineRelay?: RelayPromotionDeps["ensureMachineRelay"];
}

/** Handle for a relay slot added to an already-open core via {@link ProjectCore.promote}.
 *  `stop()` is idempotent and tears down ONLY the added relay slot — the live
 *  loopback session is left attached (Task 3 owns the full demotion semantics). */
export interface PromotionHandle {
  stop(): void;
  /** Resolves with the FIRST register outcome of the added relay slot: `ok`
   *  once the relay authenticates it, or a terminal rejection the gate closed it
   *  with (only the retired `SESSION_LIMIT_EXCEEDED`, from a relay predating the
   *  worker-limit change, reaches this today). Lets the host gate the
   *  phone-facing `running:true` advert on a real slot and surface the rejection
   *  instead of letting the phone dial an empty data-plane slot. */
  firstRegister: Promise<RegisterOutcome>;
}

/** Outcome of a relay stream's FIRST admission — `ok` once the relay acks the
 *  stream-open, otherwise the typed rejection the relay answered with (current
 *  relays admit unconditionally; the retired `SESSION_LIMIT_EXCEEDED` still
 *  arrives from older ones). Stream admission is its own signal (design §7.3):
 *  a rejection leaves the socket and every other stream live. */
export type RegisterOutcome =
  | { ok: true }
  | { ok: false; code: string; message: string };

/**
 * Per-project runtime aggregate. Owns the {@link AgentCore}, its outbound
 * {@link MessageBus}, and the mode-specific transport (loopback listener for
 * local; relay for remote). This is the seam for a future singleton host that
 * runs N cores in one process.
 */
export class ProjectCore {
  private core: AgentCore | null = null;
  private bus: MessageBus | null = null;
  private listener: LocalListener | null = null;
  private promotion: RelayPromotionController | null = null;
  /** The primary (remote-mode) core's stream on the machine socket. */
  private streamHandle: StreamHandle | null = null;
  /** Unsubscribe for the primary (remote-mode) stream's push dispatcher bus
   *  subscription. Torn down in shutdown() alongside the stream. The promote()
   *  slot owns its own unsub in its PromotionHandle.stop() instead. */
  private relayPushUnsub: (() => void) | null = null;
  private relayFirstRegister: Promise<RegisterOutcome> | null = null;
  private relayRegistered = false;
  private _localConnectInfo: { port: number; token: string } | null = null;

  // Reduced per-project work status for the always-on control-plane advert, so
  // the app's Recent/sidebar reflect activity WITHOUT warming this core. The
  // reduction is a pure fold over outbound bus frames — see work-status.ts.
  private _work: WorkStatusState = initialWorkStatus;
  private _onWorkStatusChange: (() => void) | null = null;
  /** Set by {@link observeWorkStatus} for the message it just folded: true when
   *  the reduction was a no-op (exact-repeat or the awaiting_input-after-
   *  task_complete stale nudge). The push subscriber (attached later, so its
   *  bus callback always runs after this one for the same publish()) reads
   *  this to skip pushing a notification that carries no new information —
   *  see attachRelayStream. */
  private _lastNotificationRedundant = false;

  constructor(private readonly deps: ProjectCoreDeps) {}

  get projectId(): string { return this.core?.projectId ?? ""; }
  get localConnectInfo(): { port: number; token: string } | null { return this._localConnectInfo; }

  /** Current reduced work status (working/attention/done/error) for the
   *  control-plane advert. Defaults to "done" before any signal. */
  get workStatus(): WorkStatus { return this._work.status; }

  /** Live non-archived running-session count from the same reduction, carried
   *  in the control-plane advert (`runningSessions`) so the app re-peeks the
   *  session list exactly when it actually changed — see protocol.ts. */
  get workRunningCount(): number { return this._work.runningCount; }

  /** Register a callback fired whenever {@link workStatus} or
   *  {@link workRunningCount} CHANGES (deduped), so the host can re-advertise
   *  the control plane on a real transition rather than polling. Pass null to
   *  clear. */
  onWorkStatusChange(cb: (() => void) | null): void { this._onWorkStatusChange = cb; }

  /** Commit a new work-status reduction, firing {@link onWorkStatusChange} only
   *  on a real transition of status OR running-session count (a fresh object
   *  with both unchanged — e.g. a turn-start while already working —
   *  re-advertises nothing). Count changes with an unchanged status (a 2nd
   *  session starting while one is working) must still re-advertise, or the
   *  phone's Recent list misses the new session until an unrelated flip. */
  private commitWork(next: WorkStatusState): void {
    if (next === this._work) return;
    const changed = next.status !== this._work.status
      || next.runningCount !== this._work.runningCount;
    this._work = next;
    if (changed) this._onWorkStatusChange?.();
  }

  /** Fold one outbound bus frame into the work-status reduction. Must never
   *  throw — the bus lets subscriber throws propagate, and this rides the same
   *  publish() as the live relay subscriber (reduceWorkStatus is pure/total). */
  private observeWorkStatus(msg: AbMessage): void {
    const next = reduceWorkStatus(this._work, msg);
    this._lastNotificationRedundant = msg.type === "notification:push" && next === this._work;
    this.commitWork(next);
  }

  /** A turn-start hook fired (user submitted a prompt): clear a stale turn-end
   *  notification so re-prompting an existing session returns to "working"
   *  rather than showing the previous turn's done/attention. Routed here from
   *  the per-core api-server (never a bus frame — the app must not see it as a
   *  notification), via {@link AgentContext.onTurnStart}. */
  noteTurnStart(): void {
    this.commitWork(turnStart(this._work));
  }

  /** First register outcome of a REMOTE-mode core's primary relay slot (null in
   *  local mode, or before start()). Lets the host gate the phone-facing
   *  `running:true` advert on a real register and surface a terminal rejection
   *  (today only the retired `SESSION_LIMIT_EXCEEDED`, from an older relay).
   *  Promotion's slot exposes the same via its
   *  {@link PromotionHandle.firstRegister}. */
  whenRelayRegistered(): Promise<RegisterOutcome> | null { return this.relayFirstRegister; }

  /** True once this core's relay slot has AUTHENTICATED on the relay — i.e. the
   *  data-plane slot is admitted and a phone can dial it. Covers both a
   *  remote-mode core's primary slot and a promoted local core's added slot;
   *  flips false when that slot is torn down (promote stop / fatal register
   *  rejection). This is what the phone-facing advert's `running` flag means:
   *  "dialable", NOT merely "warm/open on the host". A desktop-open project that
   *  was never promoted reads false here — dialing it would loop AGENT_OFFLINE —
   *  until project:start promotes it and the slot registers. (The desktop hub's
   *  `knownProjectsForHub` advertises plain warmth separately; do not conflate.) */
  isRelayRegistered(): boolean { return this.relayRegistered; }

  /** Forward a session delete to the live AgentCore. False if not started. */
  deleteSession(id: string): boolean {
    return this.core?.deleteSession(id) ?? false;
  }

  /** Forward the live session list (with true per-session `running`) to the
   *  control-plane `sessions.list` peek. Returns null if not started, so the
   *  caller can fall back to the on-disk persisted list. */
  listSessions(includeArchived: boolean): SessionEntry[] | null {
    return this.core?.listSessions(includeArchived) ?? null;
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
      mobileAccessEnabled: this.deps.mobileAccessEnabled,
      onTurnStart: () => this.noteTurnStart(),
      relayUrl: this.deps.relayUrl,
    });
    this.core = core;
    const bus = new MessageBus();
    this.bus = bus;
    core.attachTransport(bus);
    // Fold outbound frames into the control-plane work-status reduction. Additive
    // subscriber (like the push dispatcher); lives for the bus's lifetime.
    bus.subscribe({ deliver: (msg) => this.observeWorkStatus(msg) });
    if (this.deps.mode === "local") {
      await this.startLocal(core, bus);
    } else {
      await this.startRemote(core, bus);
    }
  }

  /** Binds the loopback listener, sets `_localConnectInfo`, and eagerly primes
   *  managers via `core.onHandshakeComplete()`. Called from both startLocal and
   *  startRemote so every core exposes a usable loopback endpoint regardless of
   *  whether it also holds a relay slot. The eager prime is safe in remote mode:
   *  a later re-fire when a phone pairs calls setupServices guarded by
   *  `if (manager) resyncState()` — a benign resync, not a re-setup. */
  private async bindLoopback(core: AgentCore, bus: MessageBus): Promise<void> {
    const token = randomBytes(32).toString("base64url");
    const listener = new LocalListener({
      bus,
      token,
      // `onHandshakeComplete` is called twice intentionally and is idempotent:
      // here per owner connection, and eagerly below to prime managers at startup
      // (the loopback socket + token is the trust boundary; there's no E2E
      // handshake to gate on for the local data plane).
      onOwnerConnected: () => {
        // A local owner now shares the bus — clear any suppression a prior
        // peer-offline latched while no owner was attached.
        core.connState.peerOnline = true;
        core.onHandshakeComplete();
      },
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

    // Promotion: intercept agent:enableRelay / agent:disableRelay in front of the
    // core dispatcher. attachTransport already installed the core inbound handler;
    // wrap it so promotion control messages are consumed and everything else falls
    // through unchanged.
    const coreInbound = bus.inboundHandler;
    const promotion = createRelayPromotion({
      core,
      bus,
      ensureMachineRelay: this.deps.ensureMachineRelay,
      attach: (remote) => this.attachLocalStreamForWizard(core, bus, remote),
    });
    this.promotion = promotion;
    bus.setInboundHandler((msg, channel, source) => {
      if (promotion.handleInbound(msg)) return;
      // Thread `source` through so the core's gate still distinguishes the
      // desktop's loopback frames from relay frames after promotion.
      coreInbound?.(msg, channel, source);
    });
  }

  private async startRemote(core: AgentCore, bus: MessageBus): Promise<void> {
    const remote = this.deps.remote;
    // Unreachable: start() already guards remote mode before building the core.
    // This narrows `remote` from optional to defined for the rest of the method.
    if (!remote) throw new Error("ProjectCore: remote mode requires remote deps");

    await this.bindLoopback(core, bus);

    const slot = this.attachRelayStream(core, bus, remote);
    this.streamHandle = slot.handle;
    this.relayPushUnsub = slot.unsubscribePush;
    this.relayFirstRegister = slot.firstRegister;
  }

  /** Attach an already-built core+bus as a stream on the machine socket and wire
   *  its plaintext (tunnel) sender, remote-peer provider, and fallback push
   *  path. The stream is an ADDITIVE bus subscriber, so the live loopback
   *  session is undisturbed. Shared by {@link startRemote} (fresh remote core)
   *  and {@link promote} (already-open local core); the caller owns the returned
   *  handle's lifetime. Encryption is NEVER optional — the machine socket owns
   *  the one E2E session every stream is sealed under (design §7). */
  private attachRelayStream(
    core: AgentCore,
    bus: MessageBus,
    remote: ProjectCoreRemoteDeps,
  ): { handle: StreamHandle; firstRegister: Promise<RegisterOutcome>; unsubscribePush: () => void } {
    // Settle on the FIRST admission outcome only (onPeerOnline re-fires on every
    // rekey; a recoverable state must not pre-empt a later success), so the host
    // can gate the running advert / surface a terminal rejection. Never rejects —
    // a stream rejection resolves `ok:false`; nothing else settles it.
    let settle!: (o: RegisterOutcome) => void;
    const firstRegister = new Promise<RegisterOutcome>((res) => { settle = res; });
    let settled = false;
    const settleOnce = (o: RegisterOutcome) => { if (!settled) { settled = true; settle(o); } };

    // Whether a phone is live on THIS stream. Starts false: a fresh stream has
    // no peer until one connects. `connState.peerOnline` cannot express that —
    // it defaults true (a local core must stream to its loopback owner
    // un-suppressed) and its peer-offline transition is deliberately skipped
    // while a desktop owner is attached, so it reads "online" for a phone that
    // has never dialled in.
    let peerConnected = false;

    const handle = remote.attachStream(bus, {
      // Outbound half of the mobile-access gate. The inbound half (agent-core's
      // currentPhoneAllowed) only stops the phone DRIVING this project; without
      // this one a core the phone cold-started keeps streaming its terminal, file
      // tree and git status to that phone after the machine switch is turned off,
      // because a remote-mode core holds no PromotionHandle for demoteAllPromoted
      // to tear down. Fail-closed, same as the inbound side.
      mayDeliver: () => this.deps.mobileAccessEnabled?.() ?? false,
      onAdmitted: () => { this.relayRegistered = true; settleOnce({ ok: true }); },
      onRejected: (code, message) => { this.relayRegistered = false; settleOnce({ ok: false, code, message }); },
      // Suppress the heavy stream while the phone is gone; it rebuilds from
      // snapshots on reconnect. connState gates ALL bus subscribers at the source,
      // so don't suppress while a desktop owner shares it over loopback — that
      // would freeze the live local session.
      onPeerOnline: () => { peerConnected = true; core.connState.peerOnline = true; },
      onPeerOffline: () => {
        // Unconditional, unlike the stream gate below: the loopback carve-out
        // keeps the DESKTOP's stream live, it doesn't make the phone reachable
        // in-band. Leaving this set would mute push on every promoted core.
        peerConnected = false;
        if (this.listener?.hasOwner) return;
        core.connState.peerOnline = false;
      },
      onTunnel: (raw) => core.handleTunnelMessage(raw),
    });

    core.setPlainHook((d) => handle.sendTunnel(d));
    // Mark this connection as REMOTE for the core's mobile-access gate (and name
    // the live device for push). Local mode never wires this, so loopback
    // control stays ungated.
    core.setPeerPubkeyProvider(() => remote.currentPeerPubkey());

    // Fallback push path: while the paired phone can't receive in-band (no live
    // peer on this stream OR the app is backgrounded), seal a notification to its
    // persistent push key and hand the ciphertext to the relay as a blind
    // FCM/APNs forward (push:deliver). This is an ADDITIVE bus subscriber — it
    // does NOT replace the stream's own live subscription (attachStream above);
    // the live path handles the online case and the dispatcher no-ops then.
    const dispatcher = createPushDispatcher({
      projectId: core.projectId,
      // Fire when the phone can't receive in-band: no live peer OR backgrounded
      // (`client:focus-state`). NOT connState.suppressed — that's the heavy-stream
      // gate, whose `peerOnline` defaults true, so it reads "can receive in-band"
      // for a phone that has never connected and mutes push after a host restart.
      shouldFallback: () => !peerConnected || core.connState.appFocusPaused,
      // A live peer names the exact device in session, so target only it. With no
      // live peer, fall back to the persisted phone registry: delivery never needs
      // the socket (the relay forwards to FCM/APNs blindly), and `currentPeerPubkey()`
      // stays null after a host restart until the phone dials in — which it may
      // never do while the user is away. Every registered phone is targeted then;
      // picking one by `lastSeenAt` would guess which device the user holds and
      // drop the notification when wrong, and `lastSeenAt` is stale in exactly
      // this window.
      resolveTargets: () => {
        // Push carries project activity off this machine, so it rides the same
        // machine switch as every inbound verb — a token+pubkey alone must not
        // leak notifications from a machine that isn't mobile-reachable.
        // Fail-closed: an unwired host provider means no push.
        if (!(this.deps.mobileAccessEnabled?.() ?? false)) return [];
        const peerPubkey = remote.currentPeerPubkey();
        const paired = core.pairedPhones.list();
        const candidates = peerPubkey ? paired.filter((p) => p.phonePubkey === peerPubkey) : paired;
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
            "push: no eligible phone for project %s (live peer: %s, paired: %d) — need a registered phone with a push token",
            core.projectId,
            peerPubkey ? "yes" : "none since agent start",
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

    return { handle, firstRegister, unsubscribePush };
  }

  /** Attach the local core as a stream for the desktop wizard promotion path,
   *  reusing {@link attachRelayStream}'s full wiring. Returns a `detach` that
   *  tears the stream + push subscriber down and clears the hooks — the machine
   *  socket itself is owned by the host control plane and stays up. */
  private attachLocalStreamForWizard(
    core: AgentCore,
    bus: MessageBus,
    remote: ProjectCoreRemoteDeps,
  ): { handle: StreamHandle; detach: () => void } {
    const { handle, unsubscribePush } = this.attachRelayStream(core, bus, remote);
    return {
      handle,
      detach: () => {
        try { unsubscribePush(); } catch { /* best-effort */ }
        try { handle.detach(); } catch { /* best-effort */ }
        try { core.setPlainHook(null); } catch { /* best-effort */ }
        try { core.setPeerPubkeyProvider(null); } catch { /* best-effort */ }
      },
    };
  }

  /** Promote an already-open (typically LOCAL) core onto the relay by adding a
   *  relay slot to its EXISTING bus — the live loopback session keeps running
   *  untouched. The phone here is machine-trusted (account inventory + the
   *  machine's mobile-access switch), NOT QR-paired per project, so this does NOT
   *  open a pairing window. `remoteDeps` MUST come from the host's ONE shared
   *  runtime (remoteDepsFor) — promote constructs no OAuthClient / token timer. */
  promote(remoteDeps: ProjectCoreRemoteDeps): PromotionHandle {
    // A remote-mode core's relay slot IS its primary session; promoting it would
    // wire a SECOND client whose PromotionHandle.stop() nulls setPlainHook/
    // setPeerPubkeyProvider, tearing down the live primary session's hooks. Only
    // a local-mode core (whose loopback session owns no relay hooks) is promotable.
    if (this.deps.mode === "remote") {
      throw new Error("ProjectCore.promote: cannot promote a remote-mode core (its relay slot is the primary session)");
    }
    const core = this.core;
    const bus = this.bus;
    if (!core || !bus) throw new Error("ProjectCore.promote: core not started (call start() first)");

    const { handle, firstRegister, unsubscribePush } = this.attachRelayStream(core, bus, remoteDeps);

    let stopped = false;
    return {
      firstRegister,
      stop: () => {
        if (stopped) return;
        stopped = true;
        // The stream is gone → no longer dialable; the advert reads not-running
        // again (a re-promote re-attaches and flips it back). Detach the push
        // dispatcher and the stream BEFORE clearing the hooks so the gate stays
        // active until the stream is gone.
        this.relayRegistered = false;
        try { unsubscribePush(); } catch {}
        try { handle.detach(); } catch {}
        try { core.setPlainHook(null); } catch {}
        try { core.setPeerPubkeyProvider(null); } catch {}
      },
    };
  }

  /** Tear down transport + subsystems. */
  async shutdown(reason?: string): Promise<void> {
    try { this.promotion?.stop(); } catch {}
    if (this.deps.mode === "remote" && this.streamHandle) {
      // Publish over the bus so the disconnecting notice rides this core's stream.
      try { this.bus?.publish(createMessage("agent:disconnecting", { reason }), "control"); } catch {}
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    try { this.core?.setPeerPubkeyProvider(null); } catch {}
    // Remove the primary stream's push dispatcher (additive bus subscriber) before
    // detaching — deliver() would otherwise hand a frame to a torn-down stream.
    try { this.relayPushUnsub?.(); } catch {}
    this.relayPushUnsub = null;
    try { await this.core?.shutdown(); } catch {}
    try { await this.listener?.stop(); } catch {}
    try { this.streamHandle?.detach(); } catch {}
  }
}
