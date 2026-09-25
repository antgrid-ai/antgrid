import { logger } from "./logger";
import type { DeviceIdentity } from "./device";
import { parseMessageFast, SessionHelloFrame, type AbMessage, type SessionHello } from "./protocol";
import { baseSlotDeviceId } from "./relay-slot";
import { MAX_TRANSFER_BYTES, type PeerFrameKind } from "antgrid-wire";
import type { MessageBus, Channel, TransportSubscriber } from "./message-bus";
import type { PairedPhonesStore } from "./paired-phones";

import {
  ProjectStreamRegistry,
  type AttachStreamOpts,
  type PeerSessionView,
  type SendTarget,
  type StreamHandle,
} from "./project-streams";
import { netwatch, frameIdFor, isRemoteIngestArmed } from "./netwatch";
import type { SendOutcome, PeerRecordFailure, StreamSendOutcome } from "./peer/stream-records";

const log = logger.child({ component: "native-session" });

export interface PeerSessionOwnerOptions {
  diagnostics?: Pick<typeof log, "debug" | "info" | "warn" | "error">;
  identity: DeviceIdentity;
  /** One app device's session established. Fires once per DEVICE, so a
   *  machine with two apps attached reports twice — `peerId` says which, and
   *  a joining device needs its own state replay even though its sibling is
   *  already up to date. */
  onHandshakeComplete?: (
    capabilities: { checkoutRouting: boolean; pullsTree: boolean; terminalFramesV1: boolean; peerId: string },
  ) => void;
  onMessage?: (msg: AbMessage) => void;
  onDisconnected?: () => void;
  onError?: (code: string, message: string) => void;
  /** Phone identity/push registry. Grants nothing — it is where `admitPeer`
   *  records the device: what `antgrid phones list` shows, what push
   *  targeting resolves tokens from. */
  pairedPhones?: PairedPhonesStore;
  /** Fail closed: absent => every project-stream open is refused NOT_ALLOWED. */
  remoteAccessEnabled?: () => boolean;
  /** host-server `seenProjects.has`. Absent => NOT_ALLOWED (fail closed). */
  projectCataloged?: (projectId: string) => boolean;
}

/** Send a ping after this much receive silence. */
const PING_SILENCE_MS = 20_000;

/** Consecutive unanswered pings before the session is declared dead. */
const MAX_MISSED_PONGS = 2;

/** How many app devices may hold a session on one machine at once. A ceiling,
 *  not a policy: real use is a desktop plus a phone or two, and each session
 *  costs a receive context and its own copy of every broadcast frame.
 *  Enforced in `NativePeerSessions.acceptPeer`, once the connecting device's
 *  identity is known. */
export const MAX_APP_SESSIONS = 4;

/** One session with one app device. Everything a session owns is here rather
 *  than on the client, because the client now holds several. */
export interface PeerSession {
  attemptId: string;
  /** The app's relay SLOT — the route address every frame for this session is
   *  addressed to. Anchoring outgoing addressing to the session is what keeps a
   *  sibling's bare presence from repointing frames away from their owner. */
  peerId: string;
  checkoutRouting: boolean;
  lastRecvAt: number;
  missedPongs: number;
  /** Whether THIS device pulls trees on demand. Per-session because the bridge
   *  may only stop pushing `tree:full` when every attached device pulls. */
  pullsTree: boolean;
  terminalFramesV1: boolean;
}

/** Owns the peer session and payload dispatch, independent of central
 * authentication and sockets. Confidentiality is QUIC/TLS between the
 * lease-authorized endpoints below this layer; remote carriers must enter
 * here only after validating their route and endpoint, and the application
 * dispatch retains relay-origin authorization semantics. */
export abstract class PeerSessionOwner {
  protected get diagnostics(): Pick<typeof log, "debug" | "info" | "warn" | "error"> {
    return this.opts.diagnostics ?? log;
  }

  /** Write one session-stream record to `peerId`. Returns null when that peer
   *  has no live session stream (nothing was queued); otherwise the writer's
   *  outcome. `signal` cancels only while the record is still queued. */
  protected abstract writeSessionRecord(
    peerId: string,
    kind: PeerFrameKind,
    payload: Buffer,
    diagnosticType: string,
    signal?: AbortSignal,
  ): Promise<StreamSendOutcome> | null;

  protected payloadTransport(_peerId?: string): "iroh" { return "iroh"; }

  protected recordDiagnostic(event: Parameters<typeof netwatch.record>[0]): void {
    try { netwatch.record(event); } catch { /* Observers cannot break admission or delivery. */ }
  }

  /**
   * The per-peer pre-establishment drop point. A frame is attributed only to
   * `this.sessions.get(from)` — never trial-attempted against another
   * session — so a peer that has not established one gets exactly one way in:
   * a `session`-kind `session:hello`. Everything else is dropped before it
   * can reach `handleSessionFrame`, `dispatchControlPlane`,
   * `bus.dispatchInbound` or a stream, and nothing is counted for a dropped
   * frame.
   */
  protected receivePeerFrame(payload: Uint8Array, from: string, kind: PeerFrameKind): void {
    const frameId = frameIdFor(payload);
    const bytes = payload.length;
    const session = this.sessions.get(from);
    if (!session) {
      if (kind === "session") {
        let obj: unknown;
        try { obj = JSON.parse(Buffer.from(payload).toString("utf8")); } catch { obj = null; }
        if (obj && typeof obj === "object" && (obj as { type?: unknown }).type === "session:hello") {
          this.recordDiagnostic({
            dir: "rx", kind: "frame", transport: this.payloadTransport(from), channel: "control",
            msgType: "session:hello", frameId, bytes,
          });
          const parsed = SessionHelloFrame.safeParse(obj);
          if (!parsed.success) { this.refusePeer(from, "protocol-violation"); return; }
          this.handleHello(parsed.data, from, frameId, bytes);
          return;
        }
      }
      this.recordDiagnostic({
        dir: "rx", kind: "drop", transport: this.payloadTransport(from), channel: "control",
        frameId, bytes, reason: "pre-establishment",
      });
      return;
    }
    session.lastRecvAt = Date.now();
    session.missedPongs = 0;
    const plaintext = Buffer.from(payload).toString("utf8");
    if (kind === "session") {
      this.onSessionFrame(plaintext, from, frameId, bytes);
    } else {
      this.onControlMessage(plaintext, from, frameId, bytes);
    }
  }

  // Session state, keyed by the app's relay SLOT (the route address) — one
  // entry per device, so tearing one down cannot disturb another's.
  protected readonly sessions = new Map<string, PeerSession>();

  /** One timer for every session: liveness is cheap per session and a timer
   *  each would be N unrefed intervals to leak. */
  protected livenessTimer: ReturnType<typeof setInterval> | null = null;

  // Phone Ed25519 pubkeys (standard base64, raw 32 bytes) resolved from the
  // account peers inventory at admission, keyed by the phone's deviceId (==
  // relay peer id).
  protected phoneEd25519ByDeviceId = new Map<string, string>();

  protected bus: MessageBus | null = null;

  protected busUnsub: (() => void) | null = null;

  protected readonly projectStreams: ProjectStreamRegistry;

  /** The bare device id this client authenticates as (machine deviceUuid). */
  get deviceId(): string {
    return this.opts.identity.deviceId;
  }

  /** Every established session, in the order the devices were admitted. The one
   *  way to enumerate attached apps; no key material is exposed. */
  establishedPeers(): PeerSessionView[] {
    return [...this.sessions.values()].map((s) => this.viewOf(s));
  }

  /** One session by its route address, or null when that device holds none. */
  peerSession(peerId: string): PeerSessionView | null {
    const session = this.sessions.get(peerId);
    return session ? this.viewOf(session) : null;
  }

  /** Whether ANY app device currently holds a session. */
  hasEstablishedSession(): boolean {
    return this.sessions.size > 0;
  }

  /** Whether at least one attached app can route checkout-scoped frames. The
   *  honest per-device answer is {@link peerSession}; this is for the coarse
   *  questions ("may this machine host an isolated session at all") that must
   *  not be decided by whichever device happened to connect first. */
  anySessionSupportsCheckoutRouting(): boolean {
    for (const session of this.sessions.values()) {
      if (session.checkoutRouting) return true;
    }
    return false;
  }

  /** The Ed25519 pubkey (standard base64) behind one route address, or null.
   *  Resolved from `phoneEd25519ByDeviceId`, which `admitPeer` sets from the
   *  lease on every accepted connection. */
  peerPubkeyFor(peerId: string): string | null {
    return this.phoneEd25519ByDeviceId.get(peerId) ?? null;
  }

  protected viewOf(session: PeerSession): PeerSessionView {
    return {
      peerId: session.peerId,
      peerPubkey: this.phoneEd25519ByDeviceId.get(session.peerId) ?? "",
      checkoutRouting: session.checkoutRouting,
      pullsTree: session.pullsTree,
      terminalFramesV1: session.terminalFramesV1,
    };
  }

  constructor(protected opts: PeerSessionOwnerOptions) {
    this.projectStreams = new ProjectStreamRegistry({
      remoteAccessEnabled: this.opts.remoteAccessEnabled,
      projectCataloged: this.opts.projectCataloged,
      peerSession: (peerId) => this.peerSession(peerId),
      sendSessionMessage: (peerId, msg) => void this.sendControlPlane(msg, "control", { kind: "peer", peerId }),
      onError: this.opts.onError,
      retirePeer: (peerId, reason) => this.retirePeerConnection(peerId, reason),
      // Late-bound over the protected hooks below (A2), so a subclass such as
      // NativePeerSessions can plug in a TerminalStreamRegistry without this
      // constructor knowing it exists. The base class's defaults are no-ops.
      routeTerminal: (peerId, msg, signal) => this.routeTerminalMessage(peerId, msg, signal),
      terminalHooks: {
        retired: (peerId, attachmentId) => this.terminalRetired(peerId, attachmentId),
        subscribeSettled: (peerId, requestId, attachmentId) => this.terminalSubscribeSettled(peerId, requestId, attachmentId),
      },
      projectDetached: (projectId) => this.terminalProjectDetached(projectId),
    });
  }

  /** Attach a project's bus to its own project stream. */
  attachStream(bus: MessageBus, opts: AttachStreamOpts): StreamHandle {
    return this.projectStreams.attach(bus, opts);
  }

  /** The connection-level failure hook the registries call: only "unauthorized"
   *  (a writer) or "protocol-violation" (a malformed length prefix). The base
   *  class has no connection to close, so it can only end the session;
   *  `NativePeerSessions` overrides this with its `retirePeer`, guarded on
   *  `nativePeers.has(peerId)` as the A2/A3 registries are. */
  protected retirePeerConnection(peerId: string, _reason: "unauthorized" | "protocol-violation"): void {
    this.dropSession(peerId);
  }

  /** A2 terminal-stream hooks: no-op on the base class. `NativePeerSessions`
   *  overrides all four to delegate to its `TerminalStreamRegistry`; a
   *  transport with no native stream support (or a test double) keeps every
   *  terminal message on the legacy session path. */
  protected routeTerminalMessage(
    _peerId: string,
    _msg: AbMessage,
    _signal?: AbortSignal,
  ): Promise<StreamSendOutcome> | undefined {
    return undefined;
  }

  protected terminalRetired(_peerId: string, _attachmentId: string): void {}

  protected terminalSubscribeSettled(_peerId: string, _requestId: string, _attachmentId: string | undefined): void {}

  protected terminalProjectDetached(_projectId: string): void {}

  /** An established peer's liveness/session-establishment traffic (header
   *  `type: "session"`): `session:hello`, `ping`, `pong`. Any other shape,
   *  including a stale `credit` frame or an `AbMessage` sent under this kind
   *  by mistake, falls through `handleSessionFrame`'s default arm and is
   *  dropped as `unknown-session-frame`. */
  protected onSessionFrame(plaintext: string, peerId: string, frameId?: string, bytes?: number): void {
    let obj: unknown;
    try {
      obj = JSON.parse(plaintext);
    } catch {
      this.diagnostics.warn("Dropping non-JSON session frame");
      this.recordDiagnostic({
        dir: "rx", kind: "drop", transport: this.payloadTransport(peerId), channel: "control",
        frameId, bytes, reason: "unknown-session-frame",
      });
      return;
    }
    if (!obj || typeof obj !== "object" || typeof (obj as { type?: unknown }).type !== "string") {
      this.diagnostics.warn("Dropping malformed session frame");
      this.recordDiagnostic({
        dir: "rx", kind: "drop", transport: this.payloadTransport(peerId), channel: "control",
        frameId, bytes, reason: "unknown-session-frame",
      });
      return;
    }
    this.recordDiagnostic({
      dir: "rx", kind: "frame", transport: this.payloadTransport(peerId), channel: "control",
      msgType: (obj as { type: string }).type, frameId, bytes,
    });
    this.handleSessionFrame(
      obj as {
        type: string; attemptId?: string;
        capabilities?: { checkoutRouting?: boolean; pullsTree?: boolean; terminalFramesV1?: boolean };
      },
      peerId,
    );
  }

  /** An established peer's control-plane traffic (header `type: "message"`):
   *  the bare JSON of exactly one `AbMessage`. A value that fails to parse as
   *  an object with a string `type` is dropped rather than guessed at. */
  protected onControlMessage(plaintext: string, peerId: string, frameId?: string, bytes?: number): void {
    let obj: unknown;
    try {
      obj = JSON.parse(plaintext);
    } catch {
      this.diagnostics.warn("Dropping non-JSON peer plaintext");
      this.recordDiagnostic({
        dir: "rx", kind: "drop", transport: this.payloadTransport(peerId), channel: "control",
        frameId, bytes, reason: "plaintext-not-json",
      });
      return;
    }
    if (!obj || typeof obj !== "object" || typeof (obj as { type?: unknown }).type !== "string") {
      this.diagnostics.warn("Dropping unrecognized peer plaintext");
      this.recordDiagnostic({
        dir: "rx", kind: "drop", transport: this.payloadTransport(peerId), channel: "control",
        frameId, bytes, reason: "unrecognized-plaintext",
      });
      return;
    }
    this.recordDiagnostic({
      dir: "rx", kind: "frame", transport: this.payloadTransport(peerId), channel: "control",
      msgType: (obj as { type: string }).type, frameId, bytes,
    });
    this.dispatchControlPlane(plaintext, "control", peerId);
  }

  protected dispatchControlPlane(mJson: string, channel: Channel, peerId: string): void {
    const msg = parseMessageFast(mJson);
    if (msg) {
      // Consumed here and never forwarded: a capture batch is diagnostics about
      // this socket, not a verb, and letting it reach `onMessage`/the bus would
      // hand every project core a message type it has no case for. The frame
      // that CARRIED it is already in the ring from the caller above, so the
      // batch's own arrival stays visible either way.
      if (msg.type === "netwatch:events") {
        // Dropped unless a `netwatch:remote` on this machine asked for it.
        // Account trust alone gets a peer to this line, and this line runs
        // BEFORE `bus.dispatchInbound` — the only place the machine's
        // remote-access switch is consulted for a relay frame — so an unarmed
        // ingest is a peer writing into host memory through the one plane that
        // is meant to be inert for it. Consumed either way: forwarding a
        // capture batch to the bus would be strictly worse than ignoring it.
        if (!isRemoteIngestArmed()) return;
        // parseMessageFast checks the `type` and nothing else, so `events` is
        // whatever the peer sent — an array only by convention until here.
        const skewMs = typeof msg.sentAt === "number" && Number.isFinite(msg.sentAt) ? Date.now() - msg.sentAt : 0;
        if (Array.isArray(msg.events)) netwatch.ingestRemote(msg.events, skewMs);
        if (typeof msg.dropped === "number" && msg.dropped > 0) {
          this.recordDiagnostic({
            dir: "tx", kind: "drop", transport: this.payloadTransport(peerId), channel,
            reason: "app-budget-exceeded", origin: "app",
            detail: { dropped: msg.dropped },
          });
        }
        return;
      }
      this.opts.onMessage?.(msg);
      this.bus?.dispatchInbound(msg, channel, "relay", peerId);
    }
  }

  // --- Session frames ---

  protected handleSessionFrame(
    obj: {
      type: string;
      attemptId?: string;
      capabilities?: { checkoutRouting?: boolean; pullsTree?: boolean; terminalFramesV1?: boolean };
    },
    peerId: string,
  ): void {
    switch (obj.type) {
      case "session:hello": {
        const parsed = SessionHelloFrame.safeParse(obj);
        if (!parsed.success) { this.refusePeer(peerId, "protocol-violation"); return; }
        this.handleHello(parsed.data, peerId);
        return;
      }
      case "ping": {
        if (this.sessions.has(peerId)) this.sendSessionFrame({ type: "pong" }, peerId);
        return;
      }
      case "pong":
        // Liveness reset already applied in receivePeerFrame on arrival.
        return;
      default:
        this.diagnostics.warn("Dropping unexpected peer session frame (type=%s)", obj.type);
        this.recordDiagnostic({
          dir: "rx", kind: "drop", transport: this.payloadTransport(peerId), channel: "control",
          msgType: obj.type, reason: "unknown-session-frame",
        });
    }
  }

  /**
   * Records the identity a lease-authorized connection presented:
   * `phoneEd25519ByDeviceId`, keyed by the route SLOT (matching every other
   * lookup in this file — `peerPubkeyFor`, `viewOf`), plus the `pairedPhones`
   * upsert/`touchLastSeen`, keyed by the ACCOUNT device (`baseSlotDeviceId`).
   * After it runs, `peerPubkeyFor(peerId)` returns `ed25519Pub`. It performs
   * no establishment — that is `handleHello`'s job, gated on this having run.
   */
  protected admitPeer(peerId: string, ed25519Pub: string): void {
    this.phoneEd25519ByDeviceId.set(peerId, ed25519Pub);

    // Account trust admits without a pair-request, so nothing else ever creates
    // this phone's row. The row grants NOTHING — authorization is the machine's
    // one mobile-access switch — it is the identity/push/last-seen record: what
    // `antgrid phones list` shows and what push targeting resolves tokens from.
    // Without it a fully connected phone is invisible to the operator and
    // unreachable by push.
    //
    // Creation only. A reconnect re-admits the same device, and rewriting the
    // row would flush the file — tripping its watcher's re-advertise — on
    // every one. An existing row instead takes `touchLastSeen`, which updates
    // memory and coalesces the write, so `last seen` tracks admissions without
    // that cost.
    const baseId = baseSlotDeviceId(peerId);
    if (this.opts.pairedPhones && !this.opts.pairedPhones.has(ed25519Pub)) {
      const now = new Date().toISOString();
      this.opts.pairedPhones.upsert({
        phonePubkey: ed25519Pub,
        // The ACCOUNT device, not the slot it happened to reach us on: trust is
        // machine-level and one row serves every socket this phone opens.
        phoneDeviceId: baseId,
        pairedAt: now,
        lastSeenAt: now,
      });
      this.diagnostics.info("Registered account-trusted phone %s", baseId);
    } else {
      this.opts.pairedPhones?.touchLastSeen(ed25519Pub);
    }
  }

  /**
   * The base establishment rule. `session:hello`/`established` are bare
   * frames — no `id`/`timestamp` envelope — because a hello precedes the
   * session `AbMessageSchema` traffic is scoped to, so they stay out of that
   * union and are handled here instead of `handleAbMessage`.
   *
   * A peer whose session already exists and whose hello names that same
   * `attemptId` is re-acked and nothing else changes; the app sends one hello
   * per connection and does not retransmit (`connection_handshake.dart`) — a
   * lost `established` surfaces as the app's handshake timeout and a fresh
   * dial. A different `attemptId` while established is a protocol violation.
   * A peer with no session must already be admitted (`admitPeer`) —
   * `peerPubkeyFor` is how this checks — or the hello is dropped as
   * `not-admitted` and nothing is established. `NativePeerSessions` overrides
   * this to run the lease re-check first and defer to this implementation
   * once it passes.
   */
  protected handleHello(hello: SessionHello, peerId: string, frameId?: string, bytes?: number): void {
    const { attemptId } = hello;
    const existing = this.sessions.get(peerId);
    if (existing) {
      if (existing.attemptId === attemptId) {
        this.sendSessionFrame({ type: "established", attemptId }, peerId);
        return;
      }
      this.refusePeer(peerId, "protocol-violation");
      return;
    }
    if (!this.peerPubkeyFor(peerId)) {
      this.recordDiagnostic({
        dir: "rx", kind: "drop", transport: this.payloadTransport(peerId), channel: "control",
        msgType: "session:hello", frameId, bytes, reason: "not-admitted",
      });
      return;
    }
    const session: PeerSession = {
      attemptId,
      peerId,
      checkoutRouting: hello.capabilities?.checkoutRouting === true,
      lastRecvAt: Date.now(),
      missedPongs: 0,
      pullsTree: hello.capabilities?.pullsTree === true,
      terminalFramesV1: hello.capabilities?.terminalFramesV1 === true,
    };
    // Must precede any send: the native hello timer reads `sessions` to decide
    // whether to close an idle connection, so a send before this line could
    // race a timer firing on a still-empty table.
    this.sessions.set(peerId, session);
    this.startLiveness();
    this.onSessionEstablished(peerId);
    this.sendSessionFrame({ type: "established", attemptId }, peerId);
    this.opts.onHandshakeComplete?.({
      checkoutRouting: session.checkoutRouting,
      pullsTree: session.pullsTree,
      terminalFramesV1: session.terminalFramesV1,
      peerId,
    });
    this.diagnostics.info("Session established with %s (attempt %s)", peerId, attemptId);
    this.projectStreams.notifyPeerOnline();
  }

  /** Refuse a peer for `reason`. The base has no connection to close, so it
   *  can only end the session; `NativePeerSessions` overrides this to close
   *  the underlying connection with the code {@link PeerRecordFailure} maps
   *  to (see `peer/stream-records.ts`). */
  protected refusePeer(peerId: string, _reason: PeerRecordFailure): void {
    this.dropSession(peerId);
  }

  protected onSessionEstablished(_peerId: string): void {}

  // --- Sending ---

  /** Send a AbMessage on the control channel to every established session (or
   *  the one `target` names). Always sent as the session's own frame; dropped
   *  (never broadcast) if no session is established. */
  send(msg: AbMessage, target?: SendTarget): void {
    void this.sendControlPlane(msg, "control", target);
  }

  /** Send a AbMessage on a specific channel (control plane). */
  sendOnChannel(msg: AbMessage, channel: Channel, target?: SendTarget): void {
    void this.sendControlPlane(msg, channel, target);
  }

  /**
   * Write `msg` as one bare record to every recipient `target` selects. A
   * message over `MAX_TRANSFER_BYTES` is refused locally before any writer is
   * reached. The returned promise settles once every recipient's write has
   * settled: "sent" only when all of them did, "dropped" the moment one did
   * not — so a caller pacing itself against this is throttled by the
   * SLOWEST recipient, which is the one that would fall behind first.
   */
  protected sendControlPlane(
    msg: unknown,
    channel: Channel,
    target: SendTarget = { kind: "broadcast" },
    signal?: AbortSignal,
    authorized?: () => boolean,
  ): Promise<SendOutcome> {
    if (signal?.aborted || authorized?.() === false) return Promise.resolve("dropped");
    const type = (msg as { type?: string } | null)?.type;
    const recipients = this.resolveRecipients(target);
    if (recipients.length === 0) {
      // Nothing to send to. During a reconnect window services may still
      // emit; dropping is correct — the phone re-syncs control state after
      // the next establishment.
      this.diagnostics.debug("Dropping outbound %s — no established session for it", type ?? "message");
      this.recordDiagnostic({
        dir: "tx", kind: "drop", transport: this.payloadTransport(target.kind === "peer" ? target.peerId : undefined), channel,
        msgType: type ?? "message", reason: "no-e2e-session",
      });
      return Promise.resolve<SendOutcome>("dropped");
    }

    const json = JSON.stringify(msg);
    const bytes = Buffer.byteLength(json, "utf8");
    if (bytes > MAX_TRANSFER_BYTES) {
      const message = `${type ?? "message"} exceeds MAX_TRANSFER_BYTES`;
      this.diagnostics.warn("%s", message);
      this.opts.onError?.("MESSAGE_TOO_LARGE", message);
      this.recordDiagnostic({
        dir: "tx", kind: "drop", transport: this.payloadTransport(target.kind === "peer" ? target.peerId : undefined), channel,
        msgType: type ?? "message", reason: "MESSAGE_TOO_LARGE", detail: { bytes },
      });
      return Promise.resolve<SendOutcome>("too-large");
    }

    const payload = Buffer.from(json, "utf8");
    return Promise.all(
      recipients.map(async (session) => {
        const outcome = await this.writeSessionRecord(session.peerId, "message", payload, type ?? "message", signal);
        return outcome ?? "dropped";
      }),
    ).then((outcomes) => (outcomes.every((o) => o === "sent") ? "sent" : "dropped"));
  }

  /** Which established sessions a {@link SendTarget} selects. */
  protected resolveRecipients(target: SendTarget): PeerSession[] {
    if (target.kind === "peer") {
      const session = this.sessions.get(target.peerId);
      return session ? [session] : [];
    }
    const out: PeerSession[] = [];
    for (const session of this.sessions.values()) {
      if (target.where && !target.where(this.viewOf(session))) continue;
      out.push(session);
    }
    return out;
  }

  /** Send one bare session/liveness frame to `to`, addressed to whichever
   *  session is live for that device right now. */
  protected sendSessionFrame(obj: object, to: string): void {
    const type = (obj as { type?: string }).type ?? "session";
    const payload = Buffer.from(JSON.stringify(obj), "utf8");
    void this.writeSessionRecord(to, "session", payload, type);
  }

  /** Attach a MessageBus as the CONTROL PLANE (s omitted). Streams attach via
   *  {@link attachStream}. */
  setBus(bus: MessageBus): void {
    this.busUnsub?.();
    this.bus = bus;
    const subscriber: TransportSubscriber = {
      deliver: (msg, channel) => this.sendOnChannel(msg, channel),
    };
    this.busUnsub = bus.subscribe(subscriber);
  }

  clearBus(): void {
    this.busUnsub?.();
    this.busUnsub = null;
    this.bus = null;
  }

  // --- Session teardown + timers ---

  /** End ONE device's session: tell the cores that device is gone. */
  protected dropSession(peerId: string): void {
    const session = this.sessions.get(peerId);
    if (!session) return;
    this.sessions.delete(peerId);
    if (this.sessions.size === 0) this.stopLiveness();
    this.projectStreams.dropPeer(peerId);
    this.projectStreams.notifyPeerSessionOffline(peerId);
    if (this.sessions.size === 0) this.projectStreams.notifyPeerOffline();
  }

  /** Every session is gone (socket close / redial): the relay has forgotten
   *  our routes, so nothing addressed to them could be delivered. */
  resetSessions(): void {
    for (const peerId of [...this.sessions.keys()]) this.dropSession(peerId);
    this.stopLiveness();
  }

  /** Idempotent: the one interval covers every session, so a second device
   *  establishing must not restart it (which would reset the whole sweep's
   *  phase and delay every other session's next probe). */
  protected startLiveness(): void {
    if (this.livenessTimer) return;
    this.livenessTimer = setInterval(() => this.checkLiveness(), PING_SILENCE_MS);
    this.livenessTimer?.unref?.();
  }

  protected stopLiveness(): void {
    if (this.livenessTimer) {
      clearInterval(this.livenessTimer);
      this.livenessTimer = null;
    }
  }

  protected checkLiveness(): void {
    const now = Date.now();
    for (const session of [...this.sessions.values()]) {
      // Recent traffic → healthy.
      if (now - session.lastRecvAt < PING_SILENCE_MS) continue;
      if (session.missedPongs >= MAX_MISSED_PONGS) {
        // Unresponsive: end this device's session and wait for a fresh
        // connection (the app owns retry pacing). Every sibling session
        // stays up.
        this.diagnostics.warn("Session with %s declared dead (%d missed pongs) — dropping", session.peerId, MAX_MISSED_PONGS);
        this.dropSession(session.peerId);
        continue;
      }
      session.missedPongs++;
      this.sendSessionFrame({ type: "ping" }, session.peerId);
    }
  }

  /** True once at least one session is established (test seam). */
  _handshakeComplete(): boolean {
    return this.sessions.size > 0;
  }
  disposeSessions(): void {
    this.clearBus();
    this.projectStreams.detachAll();
    this.resetSessions();
  }
}
