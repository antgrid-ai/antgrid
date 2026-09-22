import { randomBytes } from "node:crypto";
import { logger } from "./logger";
import type { DeviceIdentity } from "./device";
import { buildTranscript, deriveSessionKeys, agentConfirmTag, phoneConfirmTag, verifyConfirmTag, E2eTransport, signTranscript, verifyTranscriptSig, zeroizeSessionKeys, type SessionKeys } from "./e2e";
import { deriveSharedSecret, type EphemeralKeypair } from "./key-exchange";
import { parseMessageFast, type AbMessage } from "./protocol";
import { baseSlotDeviceId, slotMachineDeviceId } from "./relay-slot";
import { parseTunnelMessage } from "./tunnel-protocol";
import { FrameKind, buildFragments, FRAG_THRESHOLD, MAX_TRANSFER_BYTES, TRANSFER_TIMEOUT_MS, GLOBAL_REASSEMBLY_BUDGET, CONTROL_STREAM_ID, CREDIT_BATCH_BYTES, WINDOW_STALL_WARN_MS } from "antgrid-wire";
import type { MessageBus, Channel, TransportSubscriber } from "./message-bus";
import type { PairedPhonesStore } from "./paired-phones";
import type { TrustedPeersProvider } from "./trusted-peers";
import { FragReassembler, type SharedByteBudget } from "./frag-reassembler";

import { StreamMux, type AttachStreamOpts, type PeerSessionView, type SendTarget, type StreamHandle } from "./stream-mux";
import { netwatch, frameIdFor, isRemoteIngestArmed } from "./netwatch";
import { SendScheduler, type QueuedAppFrame, type SendOutcome, type PendingSinkWrite } from "./send-scheduler";

const log = logger.child({ component: "native-session" });

export interface PeerSessionOwnerOptions {
  diagnostics?: Pick<typeof log, "debug" | "info" | "warn" | "error">;
  identity: DeviceIdentity;
  /** Called on each (re)handshake to get a fresh ephemeral keypair for E2E. */
  generateKeypair: () => EphemeralKeypair;
  /** One app device's E2E session established (its app:ready confirm verified).
   *  Fires once per DEVICE, so a machine with two apps attached reports twice —
   *  `peerId` says which, and a joining device needs its own state replay even
   *  though its sibling is already up to date. */
  onHandshakeComplete?: (
    capabilities: { checkoutRouting: boolean; pullsTree: boolean; terminalFramesV1: boolean; peerId: string },
  ) => void;
  onMessage?: (msg: AbMessage) => void;
  onTunnelMessage?: (msg: unknown, peerId: string) => void;
  onDisconnected?: () => void;
  onError?: (code: string, message: string) => void;
  /** Phone identity/push registry. Grants nothing — it is where a verified
   *  client-hello records the device, and where `backfillPeerPubkey` recovers a
   *  reconnecting phone's pubkey after an agent restart. */
  pairedPhones?: PairedPhonesStore;
  /** Account device inventory; consulted before the
   *  paired-phones store when resolving a phone's Ed25519 pubkey. */
  trustedPeers?: TrustedPeersProvider;
  /** Test seam: overrides the half-open handshake-attempt expiry (see
   *  `HALF_OPEN_MS`). Production never sets this. */
  halfOpenMs?: number;
}

/** A half-open handshake attempt (client-hello seen, app:ready never arrived)
 *  is discarded after this. Live sessions are unaffected. */
const HALF_OPEN_MS = 30_000;

/** Send a sealed ping after this much sealed-receive silence. */
const PING_SILENCE_MS = 20_000;

/** Consecutive unanswered pings before the E2E session is declared dead. */
const MAX_MISSED_PONGS = 2;

/** How many app devices may hold a session on one machine at once. A ceiling,
 *  not a policy: real use is a desktop plus a phone or two, and each session
 *  costs a receive context and its own copy of every broadcast frame. Past it
 *  the least useful session is evicted so a device can always get in. */
export const MAX_APP_SESSIONS = 4;

/** At most one unknown-streamId warn per stream per this interval. */
const UNKNOWN_STREAM_LOG_INTERVAL_MS = 30_000;

/** Ceiling on the unknown-stream throttle maps before they are cleared whole. */
const MAX_TRACKED_UNKNOWN_STREAMS = 64;

const FRAG_ID_SEED = randomBytes(8).toString("hex");

let fragIdCounter = 0;

export type FragmentForSendResult =
  | { ok: true; frames: string[] }
  | { ok: false; error: { code: "MESSAGE_TOO_LARGE"; message: string } };

/** A half-open handshake attempt: keys derived, the app's confirm not yet seen.
 *  Receive-only until it is promoted (make-before-break). */
export interface PendingAttempt {
  attemptId: string;
  transport: E2eTransport;
  sessionKeys: SessionKeys;
  /** The app's relay SLOT — the route address this attempt is answered on. */
  peerId: string;
  expiry: ReturnType<typeof setTimeout> | null;
}

/** One confirmed E2E session with one app device. Everything a session owns is
 *  here rather than on the client, because the client now holds several. */
export interface PeerSession {
  attemptId: string;
  transport: E2eTransport;
  sessionKeys: SessionKeys;
  /** The app's relay SLOT — the route address every frame for this session is
   *  addressed to. Anchoring outgoing addressing to the session is what keeps a
   *  sibling's bare presence from repointing frames away from their owner. */
  peerId: string;
  /** Session-scoped: a rekey must not inherit the previous app's guarantee. */
  checkoutRouting: boolean;
  lastSealedRecvAt: number;
  missedPongs: number;
  /** Fragments are per-session: two devices interleave transfers on one socket,
   *  and a shared reassembler would splice their streams together. */
  frag: FragReassembler;
  /** Outbound queue + credit windows for THIS device. Per-session for the same
   *  reason the keys are: a frame is sealed at dequeue under whichever session
   *  is live then, and each app credits only what it consumed — one shared
   *  window would let a busy device stall a quiet one. */
  scheduler: SendScheduler;
  /** Inbound half of the credit windows: cumulative sealed payload bytes read
   *  from this device per channel, and how much of that has been credited back
   *  to it. */
  rxFlow: { consumed: Record<Channel, number>; credited: Record<Channel, number> };
  /** One stall log per stalled channel, cleared when a credit advances. */
  stallWarned: Partial<Record<Channel, true>>;
  /** Whether THIS device pulls trees on demand. Per-session because the bridge
   *  may only stop pushing `tree:full` when every attached device pulls. */
  pullsTree: boolean;
  terminalFramesV1: boolean;
}

export function fragmentForSend(json: string, type?: string, key?: string): FragmentForSendResult {
  const bytes = Buffer.byteLength(json, "utf8");
  if (bytes <= FRAG_THRESHOLD) return { ok: true, frames: [json] };
  if (bytes > MAX_TRANSFER_BYTES) {
    return {
      ok: false,
      error: {
        code: "MESSAGE_TOO_LARGE",
        message: `${type ?? "message"} exceeds MAX_TRANSFER_BYTES`,
      },
    };
  }

  // Tag every path-keyed transfer (file:content, git:diff-content, …) so the app
  // can recover the right pane on abort — not just file:content (the type carries
  // which response aborted; the app maps it back to a re-request).
  // The process-global counter is unique across streams, so the reassembler
  // keying by bare id stays safe even though many streams share this seam.
  const hint = type && key ? { type, key } : undefined;
  const id = `${FRAG_ID_SEED}-${fragIdCounter++}`;
  return { ok: true, frames: buildFragments(json, id, hint) };
}
/** Owns application encryption independently of central authentication and sockets.
 * Remote carriers must enter here after validating their route and endpoint;
 * the application dispatch retains relay-origin authorization semantics. */
export abstract class PeerSessionOwner {
  protected get diagnostics(): Pick<typeof log, "debug" | "info" | "warn" | "error"> {
    return this.opts.diagnostics ?? log;
  }

  protected abstract sendNativePayload(
    data: Buffer | string,
    to: string,
    channel?: Channel,
    kind?: FrameKind,
    diagnosticType?: string,
    streamId?: string,
  ): boolean;

  protected abstract sendNativeScheduled(
    sealed: Buffer,
    peerId: string,
    frame: QueuedAppFrame,
  ): number | null | PendingSinkWrite;

  protected payloadTransport(_peerId?: string): "iroh" { return "iroh"; }

  protected recordDiagnostic(event: Parameters<typeof netwatch.record>[0]): void {
    try { netwatch.record(event); } catch { /* Observers cannot break admission or delivery. */ }
  }

  protected receivePeerFrame(payload: Uint8Array, from: string, channel: Channel, kind: FrameKind): void {
    const frameId = frameIdFor(payload, kind === FrameKind.sealed);
    if (kind === FrameKind.handshake) {
      this.handleHandshakeFrame(payload, from, frameId, payload.length);
      return;
    }
    this.handleSealedFrame(Buffer.from(payload), channel, from, frameId, payload.length);
  }

  // E2E session state, keyed by the app's relay SLOT (the route address). A
  // device appears in `pending` while its candidate keys are receive-only, and
  // moves to `sessions` when its app:ready confirm verifies (make-before-break).
  // Both are keyed by device so one device's rekey cannot disturb another's.
  protected readonly sessions = new Map<string, PeerSession>();

  protected readonly pending = new Map<string, PendingAttempt>();

  /** One reassembly ceiling for the whole machine, shared by every session's
   *  reassembler — N devices must not each be handed the full budget. */
  protected reassemblyBudget: SharedByteBudget = { used: 0, limit: GLOBAL_REASSEMBLY_BUDGET };

  /** Consumed bytes between byte-triggered credits; a test seam shrinks it. */
  protected creditBatchBytes!: number;

  /** One timer for every session: liveness is cheap per session and a timer
   *  each would be N unrefed intervals to leak. */
  protected livenessTimer: ReturnType<typeof setInterval> | null = null;

  // Phone Ed25519 pubkeys (standard base64, raw 32 bytes) resolved from the
  // account peers inventory at handshake, keyed by the phone's deviceId (==
  // relay peer id).
  protected phoneEd25519ByDeviceId = new Map<string, string>();

  protected bus: MessageBus | null = null;

  protected busUnsub: (() => void) | null = null;

  protected readonly mux: StreamMux;

  protected fragSweep: ReturnType<typeof setInterval> | null = null;

  /** Unknown-stream drop throttle: last log time and frames suppressed since,
   *  per streamId (see {@link logUnknownStreamDrop}). */
  protected unknownStreamLoggedAt = new Map<string, number>();

  protected unknownStreamSuppressed = new Map<string, number>();

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
   *  Resolved from `phoneEd25519ByDeviceId` — populated by a client-hello's
   *  verified identity, or backfilled from the paired-phones store on a trusted
   *  reconnect. */
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

  /** Ensure `phoneEd25519ByDeviceId` has an entry for `peerId` by recovering it
   *  from the persistent phone registry. Used on a trusted reconnect
   *  after a trusted reconnect so per-peer authorization still
   *  resolves after an agent restart — without it the control-plane dispatch
   *  drops every frame (`if (!pk) return`). No-op when already known or
   *  unregistered. */
  protected backfillPeerPubkey(peerId: string): void {
    if (this.phoneEd25519ByDeviceId.has(peerId)) return;
    // Cache under the route id we were given, look up under the account device
    // the store is keyed by — see `relay-slot.ts`.
    const baseId = baseSlotDeviceId(peerId);
    const phone = this.opts.pairedPhones?.list().find((p) => p.phoneDeviceId === baseId);
    if (phone) this.phoneEd25519ByDeviceId.set(peerId, phone.phonePubkey);
  }

  /** True when `peerId` is an app relay slot scoped at a DIFFERENT machine.
   *
   *  The relay fans presence to every same-account peer of the opposite type,
   *  so one phone holding N machines open reaches us once per SLOT — and all
   *  but one of those name a machine that isn't us. Acting on a sibling's would
   *  point our reply address at a socket whose E2E session cannot open our
   *  frames (peer-online), or suppress our heavy stream because a DIFFERENT
   *  machine's socket closed (peer-offline).
   *
   *  Unscoped ids are never foreign — they carry no claim about who they are
   *  for, and every pre-slot client sends one. */
  protected isForeignSlot(peerId: string): boolean {
    const machine = slotMachineDeviceId(peerId);
    return machine !== null && machine !== this.opts.identity.deviceId;
  }

  constructor(protected opts: PeerSessionOwnerOptions) {
    this.mux = new StreamMux({
      closeStream: (id) => {
        // A detached stream's backlog must not sit in the send queue occupying
        // room the streams that are still live need — in every device's queue,
        // since the stream was fanned out to all of them.
        for (const s of this.sessions.values()) {
          this.recordQueueDrop("stream-detached", s.scheduler.dropStream(id), s.peerId);
        }
      },
      sendEnvelope: (id, msg, channel, target, signal, authorized) => this.sendAppEnvelope(id, msg, channel, target, signal, authorized),
      peerSession: (peerId) => this.peerSession(peerId),
    });
    this.creditBatchBytes = CREDIT_BATCH_BYTES;
    this.startFragSweep();
  }

  /** Attach a project's bus as a multiplexed stream on this machine socket. */
  attachStream(bus: MessageBus, opts: AttachStreamOpts): StreamHandle {
    return this.mux.attach(bus, opts);
  }

  /** A reassembler owned by one session. Its completions are tagged with that
   *  session's peerId, which is what keeps a reassembled transfer attributable
   *  to the device that requested it. */
  protected newFragReassembler(peerId: string): FragReassembler {
    return new FragReassembler({
      timeoutMs: TRANSFER_TIMEOUT_MS,
      budget: this.reassemblyBudget,
      onComplete: (json) => this.routeReassembledEnvelope(json, peerId),
      onAbort: (hint) => {
        if (hint?.type === "file:content") {
          this.diagnostics.warn("Fragmented file content transfer interrupted for %s", hint.key);
          this.opts.onError?.("TRANSFER_INTERRUPTED", `Transfer interrupted for ${hint.key}`);
        }
      },
    });
  }

  /** We just told the app which stream a project is on (`stream-ready`), so any
   *  `stream-unbound` mute on it is answered. Call it BEFORE publishing, or the
   *  frames the re-advert is meant to unblock ride out while still muted. */
  noteStreamBound(streamId: string): void {
    this.mux.markBound(streamId);
  }

  /**
   * Outbound app frames go through one queue per channel PER DEVICE, so that
   * per-channel order is the queue's order and nothing else, and so a frame is
   * sealed only once it is actually being written — under whatever session is
   * live at that moment, not the one that was live when the caller handed it
   * over. The sink resolves the session by id rather than closing over it: a
   * rekey replaces the struct, and a captured one would seal under retired keys.
   */
  protected newSendScheduler(peerId: string): SendScheduler {
    return new SendScheduler({
      send: (f) => {
        const session = this.sessions.get(peerId);
        if (!session) {
          this.recordDiagnostic({
            dir: "tx", kind: "drop", transport: this.payloadTransport(peerId), channel: f.channel,
            msgType: f.type, streamId: f.streamId, reason: "no-e2e-session",
          });
          return null;
        }
        const sealed = session.transport.seal(f.plaintext);
        return this.sendNativeScheduled(sealed, peerId, f);
      },
    }, (m) => this.diagnostics.warn(m));
  }

  /** The single place a queued frame reaches the wire. */
  protected drain(session?: PeerSession): void {
    for (const s of session ? [session] : this.sessions.values()) {
      if (s.scheduler.drain() === "blocked") this.noteWindowStall(s);
    }
  }

  /** A peer that stops crediting is alive and silent, which every other
   *  observable reads as a healthy socket. Nothing was dropped, so this is a
   *  log and not a netwatch record; once per stall so a wedged channel does
   *  not bury the rest of the log. */
  protected noteWindowStall(session: PeerSession): void {
    const now = Date.now();
    for (const ch of ["control", "preview"] as const) {
      const since = session.scheduler.blockedSince[ch];
      if (since === undefined || now - since < WINDOW_STALL_WARN_MS) continue;
      if (session.stallWarned[ch]) continue;
      session.stallWarned[ch] = true;
      const queued = session.scheduler.queued(ch);
      this.diagnostics.warn(
        "Send gate stalled on %s to %s for %ds: unacked=%d totalUnacked=%d queued=%d frame(s)/%d bytes",
        ch, session.peerId, Math.round((now - since) / 1000), session.scheduler.unacked(ch),
        session.scheduler.totalUnacked(), queued.frames, queued.bytes,
      );
    }
  }

  /** A new session forgets both halves of the accounting, the stall flags
   *  included: a flag carried across would suppress the first real stall
   *  warning of the session that follows. */
  protected static freshRxFlow(): PeerSession["rxFlow"] {
    return {
      consumed: { control: 0, preview: 0 },
      credited: { control: 0, preview: 0 },
    };
  }

  /** Count what the peer charged its window for. Credits go out in batches so
   *  a busy channel costs one small frame per {@link creditBatchBytes} rather
   *  than one per received frame. */
  protected noteConsumed(session: PeerSession, channel: Channel, bytes: number): void {
    session.rxFlow.consumed[channel] += bytes;
    const uncredited = session.rxFlow.consumed[channel] - session.rxFlow.credited[channel];
    if (uncredited >= this.creditBatchBytes) this.sendCredit(session, channel);
  }

  /** Cumulative, so a credit lost in transit costs nothing: the next one
   *  carries the same ground truth and releases the whole backlog. */
  protected sendCredit(session: PeerSession, channel: Channel): void {
    session.rxFlow.credited[channel] = session.rxFlow.consumed[channel];
    this.sendSessionFrame(
      { type: "credit", channel, consumed: session.rxFlow.consumed[channel] },
      session.transport,
      session.peerId,
    );
  }

  protected recordQueueDrop(reason: string, frames: QueuedAppFrame[], peerId?: string,
    transport = this.payloadTransport(peerId)): void {
    if (frames.length === 0) return;
    for (const f of frames) {
      this.recordDiagnostic({
        dir: "tx", kind: "drop", transport, channel: f.channel,
        msgType: f.type, streamId: f.streamId, reason: "queue-dropped",
        detail: { why: reason },
      });
    }
    this.diagnostics.info("Dropped %d queued frame(s): %s", frames.length, reason);
  }

  protected startFragSweep(): void {
    if (this.fragSweep) return;
    this.fragSweep = setInterval(() => {
      for (const session of this.sessions.values()) session.frag.sweep();
    }, 2000);
    this.fragSweep.unref?.();
  }

  protected stopFragSweep(): void {
    if (!this.fragSweep) return;
    clearInterval(this.fragSweep);
    this.fragSweep = null;
  }

  /** Kind-1 plaintext admits exactly the two handshake types; the agent only
   *  ever consumes client-hello. A frame that is not a signature-valid
   *  client-hello is dropped with a this.diagnostics. */
  protected handleHandshakeFrame(payload: Uint8Array, from: string, frameId?: string, bytes?: number): void {
    let obj: { type?: string } | null = null;
    try {
      obj = JSON.parse(Buffer.from(payload).toString("utf8"));
    } catch {
      this.diagnostics.warn("Dropping non-JSON kind-1 handshake frame");
      this.recordDiagnostic({
        dir: "rx", kind: "drop", transport: this.payloadTransport(from),
        frameId, bytes, reason: "handshake-not-json",
      });
      return;
    }
    if (obj?.type === "handshake:client-hello") {
      this.recordDiagnostic({
        dir: "rx", kind: "handshake", transport: this.payloadTransport(from), channel: "control",
        msgType: obj.type, frameId, bytes, detail: { from },
      });
      this.handleClientHello(obj as { attemptId?: string; pubkey?: string; nonce?: string; sig?: string }, from);
      return;
    }
    this.diagnostics.warn("Dropping unexpected kind-1 handshake frame (type=%s)", obj?.type);
    this.recordDiagnostic({
      dir: "rx", kind: "drop", transport: this.payloadTransport(from),
      msgType: obj?.type, frameId, bytes, reason: "unexpected-handshake-type",
    });
  }

  /**
   * Decrypt-or-drop, and name the session that sent it. `from` is the relay's
   * routing address and is only a HINT: it picks which keys to try first, and
   * nothing is believed on its word — the frame's identity is whichever key
   * actually opens it (AES-GCM's tag is the proof). The trial across the other
   * sessions is what covers a frame whose `from` we do not recognise; it costs
   * one failed open per attached device, and there are at most
   * {@link MAX_APP_SESSIONS} of them.
   *
   * Each device keeps at most two receive contexts (make-before-break): its
   * established session, and its own in-flight rekey candidate.
   */
  protected handleSealedFrame(
    payload: Buffer,
    channel: Channel,
    from: string,
    frameId?: string,
    bytes?: number,
  ): void {
    const sealedBytes = bytes ?? payload.length;
    const hinted = this.sessions.get(from);
    if (hinted && this.tryOpenSession(hinted, payload, channel, sealedBytes, frameId, bytes)) return;
    const hintedPending = this.pending.get(from);
    if (hintedPending && this.tryOpenPending(hintedPending, payload, channel, frameId, bytes)) return;

    for (const session of this.sessions.values()) {
      if (session === hinted) continue;
      if (this.tryOpenSession(session, payload, channel, sealedBytes, frameId, bytes)) return;
    }
    for (const attempt of this.pending.values()) {
      if (attempt === hintedPending) continue;
      if (this.tryOpenPending(attempt, payload, channel, frameId, bytes)) return;
    }
    // Undecryptable, but the sender charged it. Credited to the ROUTING HINT:
    // no key opened the frame, so nothing better names its sender, and crediting
    // the wrong window is bounded while crediting none stalls the right one for
    // the rest of the session. Accounting only — admission is still the tag.
    if (hinted) this.noteConsumed(hinted, channel, sealedBytes);
    this.diagnostics.warn("Failed to open sealed frame (len=%d) from %s, dropping", payload.length, from);
    this.recordDiagnostic({
      dir: "rx", kind: "drop", transport: this.payloadTransport(from), channel,
      frameId, bytes, reason: "decrypt-failed",
      detail: { sessions: this.sessions.size, pending: this.pending.size },
    });
  }

  protected tryOpenSession(
    session: PeerSession,
    payload: Buffer,
    channel: Channel,
    sealedBytes: number,
    frameId?: string,
    bytes?: number,
  ): boolean {
    const pt = session.transport.open(payload);
    if (pt === null) return false;
    session.lastSealedRecvAt = Date.now();
    session.missedPongs = 0;
    this.noteConsumed(session, channel, sealedBytes);
    this.onSealedPlaintext(pt, channel, session.peerId, session, frameId, bytes);
    return true;
  }

  /** A candidate's keys are receive-only until its confirm verifies, so nothing
   *  it opens counts as liveness and it owns no reassembler — the only thing it
   *  can legitimately carry is the app:ready that promotes it. */
  protected tryOpenPending(
    attempt: PendingAttempt,
    payload: Buffer,
    channel: Channel,
    frameId?: string,
    bytes?: number,
  ): boolean {
    const pt = attempt.transport.open(payload);
    if (pt === null) return false;
    // Candidate keys precede the peer's window reset by definition, so the
    // sender never charged these bytes and crediting them would inflate it.
    this.onSealedPlaintext(pt, channel, attempt.peerId, null, frameId, bytes);
    return true;
  }

  protected onSealedPlaintext(
    plaintext: string,
    channel: Channel,
    peerId: string,
    session: PeerSession | null,
    frameId?: string,
    bytes?: number,
  ): void {
    // Fragmented app traffic → buffer; onComplete routes the reassembled envelope.
    if (session?.frag.accept(plaintext)) {
      this.recordDiagnostic({
        dir: "rx", kind: "sealed", transport: this.payloadTransport(peerId), channel,
        msgType: "__frag", frameId, bytes,
      });
      return;
    }

    let obj: unknown;
    try {
      obj = JSON.parse(plaintext);
    } catch {
      this.diagnostics.warn("Dropping non-JSON sealed plaintext");
      this.recordDiagnostic({
        dir: "rx", kind: "drop", transport: this.payloadTransport(peerId), channel,
        frameId, bytes, reason: "plaintext-not-json",
      });
      return;
    }
    if (obj && typeof obj === "object") {
      // Bare session frame (top-level `type`) vs app envelope (`{ s?, m }`). App
      // traffic is always wrapped, so a top-level `type` is unambiguously a
      // session/liveness frame.
      if (typeof (obj as { type?: unknown }).type === "string") {
        this.recordDiagnostic({
          dir: "rx", kind: "sealed", transport: this.payloadTransport(peerId), channel,
          msgType: (obj as { type: string }).type, frameId, bytes,
        });
        this.handleSessionFrame(
          obj as { type: string; attemptId?: string; confirm?: string; channel?: unknown; consumed?: unknown },
          peerId,
        );
        return;
      }
      if ("m" in (obj as object)) {
        this.routeAppEnvelope(obj as { s?: string; m: unknown }, channel, peerId, frameId, bytes);
        return;
      }
    }
    this.diagnostics.warn("Dropping unrecognized sealed plaintext");
    this.recordDiagnostic({
      dir: "rx", kind: "drop", transport: this.payloadTransport(peerId), channel,
      frameId, bytes, reason: "unrecognized-plaintext",
    });
  }

  protected routeReassembledEnvelope(json: string, peerId: string): void {
    let env: { s?: string; m?: unknown };
    try {
      env = JSON.parse(json);
    } catch {
      this.diagnostics.warn("Dropping non-JSON reassembled envelope");
      this.recordDiagnostic({
        dir: "rx", kind: "drop", transport: this.payloadTransport(peerId), channel: "control",
        reason: "reassembled-not-json", bytes: Buffer.byteLength(json, "utf8"),
      });
      return;
    }
    if (!env || typeof env !== "object" || !("m" in env)) {
      this.diagnostics.warn("Dropping malformed reassembled envelope");
      this.recordDiagnostic({
        dir: "rx", kind: "drop", transport: this.payloadTransport(peerId), channel: "control",
        reason: "reassembled-malformed", bytes: Buffer.byteLength(json, "utf8"),
      });
      return;
    }
    // Reassembled transfers are control-tier (file:content, diffs); the channel
    // only affects the AbMessage dispatch tag, which is control for these.
    // No frameId: a reassembled transfer spans N sealed frames, each with its
    // own nonce, so nothing here maps to a single frame on the peer's capture.
    this.routeAppEnvelope(
      env as { s?: string; m: unknown },
      "control",
      peerId,
      undefined,
      Buffer.byteLength(json, "utf8"),
      true,
    );
  }

  protected routeAppEnvelope(
    env: { s?: string; m: unknown },
    channel: Channel,
    peerId: string,
    frameId?: string,
    bytes?: number,
    reassembled = false,
  ): void {
    const s = env.s;
    const streamId = typeof s === "string" && s !== CONTROL_STREAM_ID ? s : null;
    const mJson = JSON.stringify(env.m);
    const msgType = (env.m as { type?: string } | null)?.type;
    this.recordDiagnostic({
      dir: "rx", kind: "sealed", transport: this.payloadTransport(peerId), channel,
      streamId: streamId ?? undefined, msgType, frameId, bytes,
      ...(reassembled ? { detail: { reassembled: true } } : {}),
    });
    if (streamId === null) {
      this.dispatchControlPlane(mJson, channel, peerId);
      return;
    }
    if (!this.mux.dispatchInbound(streamId, mJson, channel, peerId)) {
      this.logUnknownStreamDrop(streamId, msgType, frameId);
      this.recordDiagnostic({
        dir: "rx", kind: "drop", transport: this.payloadTransport(peerId), channel,
        streamId, msgType, frameId, bytes, reason: "unknown-stream",
      });
    }
  }

  /**
   * One warn per stream per {@link UNKNOWN_STREAM_LOG_INTERVAL_MS}, carrying how
   * many frames it stands for in `framesDropped`. Sum that field to get the
   * loss — counting LINES gives the throttle's rate, not the drop rate.
   *
   * The unbound-stream drop is not self-limiting: nothing in the protocol heals
   * a peer pushing onto an id this side holds no stream for, so a live PTY on an
   * unbound stream drops one frame per frame, indefinitely — measured at ~13/sec
   * for 20+ minutes on the app side, which left 5,976 of the last 6,000 lines of
   * one log saying this and nothing else. Unthrottled, the line added to make
   * the loss visible is what buries every other clue about it.
   *
   * `frameId` names only the one frame this line was emitted for, not the
   * `framesDropped` frames it stands for, so it is evidence in a single
   * direction: an id recurring across lines is a frame being re-delivered, a
   * non-recurring one rules nothing out. Absent for a reassembled transfer,
   * which spans N sealed frames with N ids.
   *
   * The netwatch tap at the call site is deliberately NOT throttled — a capture
   * is opened to see every frame, and is bounded by how long it runs.
   */
  protected logUnknownStreamDrop(
    streamId: string,
    msgType: string | undefined,
    frameId: string | undefined,
  ): void {
    const now = Date.now();
    const last = this.unknownStreamLoggedAt.get(streamId);
    if (last !== undefined && now - last < UNKNOWN_STREAM_LOG_INTERVAL_MS) {
      this.unknownStreamSuppressed.set(streamId, (this.unknownStreamSuppressed.get(streamId) ?? 0) + 1);
      return;
    }
    // Bounded against a peer that sprays ids: the maps exist to rate-limit a
    // handful of stale streams, not to accumulate one entry per id ever seen.
    if (this.unknownStreamLoggedAt.size > MAX_TRACKED_UNKNOWN_STREAMS) {
      this.unknownStreamLoggedAt.clear();
      this.unknownStreamSuppressed.clear();
    }
    this.unknownStreamLoggedAt.set(streamId, now);
    // Always present, and counts this frame as well as the ones it stands for.
    // Omitting it at 1 would leave a reader summing LINES for a loss rate, and
    // one line here can stand for hundreds of frames.
    const framesDropped = (this.unknownStreamSuppressed.get(streamId) ?? 0) + 1;
    this.unknownStreamSuppressed.delete(streamId);
    this.diagnostics.warn(
      `Dropping inbound frame for unknown streamId ${streamId}: ` +
      `framesDropped=${framesDropped} msgType=${msgType ?? "unknown"} ` +
      `frameId=${frameId ?? "none"}`,
    );
  }

  protected dispatchControlPlane(mJson: string, channel: Channel, peerId: string): void {
    const msg = parseMessageFast(mJson);
    if (msg) {
      // Consumed here like `netwatch:events` below: this is a statement about
      // the SOCKET's stream table, not a verb, and the bus it would reach is
      // the one whose stream the app just said it cannot receive.
      if (msg.type === "stream-unbound") {
        this.mux.markUnbound(msg.streamId);
        return;
      }
      // Consumed here and never forwarded: a capture batch is diagnostics about
      // this socket, not a verb, and letting it reach `onMessage`/the bus would
      // hand every project core a message type it has no case for. The frame
      // that CARRIED it is already in the ring from routeAppEnvelope above, so
      // the batch's own arrival stays visible either way.
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
      return;
    }
    const tunnel = parseTunnelMessage(mJson);
    if (tunnel) this.opts.onTunnelMessage?.(tunnel, peerId);
  }

  // --- E2E session frames ---

  protected handleSessionFrame(
    obj: {
      type: string;
      attemptId?: string;
      confirm?: string;
      capabilities?: { checkoutRouting?: boolean; pullsTree?: boolean; terminalFramesV1?: boolean };
      channel?: unknown;
      consumed?: unknown;
    },
    peerId: string,
  ): void {
    switch (obj.type) {
      case "app:ready":
        this.handleAppReady(obj, peerId);
        return;
      case "ping": {
        // Answer under the ASKING session's keys — a pong sealed for anyone else
        // is a frame the asker cannot open, so its liveness check fails anyway.
        const session = this.sessions.get(peerId);
        if (session) this.sendSessionFrame({ type: "pong" }, session.transport, peerId);
        return;
      }
      case "pong":
        // Liveness reset done when the frame opened, in tryOpenSession.
        return;
      case "credit": {
        // Hand-validated like every other session frame: these never carry a
        // Zod schema, and a malformed `consumed` would corrupt the window.
        const ch = obj.channel;
        const consumed = obj.consumed;
        if (
          (ch !== "control" && ch !== "preview") ||
          typeof consumed !== "number" || !Number.isSafeInteger(consumed) || consumed < 0
        ) {
          this.diagnostics.warn("Dropping malformed credit frame");
          return;
        }
        const session = this.sessions.get(peerId);
        if (!session) return;
        if (session.scheduler.credit(ch, consumed)) {
          delete session.stallWarned[ch];
          this.drain(session);
        }
        return;
      }
      default:
        this.diagnostics.warn("Dropping unexpected sealed session frame (type=%s)", obj.type);
    }
  }

  protected handleClientHello(obj: { attemptId?: string; pubkey?: string; nonce?: string; sig?: string }, from: string): void {
    const { attemptId, pubkey, nonce, sig } = obj;
    if (!attemptId || !pubkey || !nonce || !sig) {
      this.diagnostics.warn("client-hello missing fields — dropping");
      return;
    }
    const peerId = from;
    if (!peerId) return;
    const seedB64 = this.opts.identity.ed25519PrivateKey;
    if (!seedB64) {
      this.diagnostics.warn("No Ed25519 seed to sign agent-hello — dropping client-hello");
      return;
    }
    const clientPubkey = Buffer.from(pubkey, "base64");
    if (clientPubkey.length !== 32) {
      this.diagnostics.warn("Invalid client pubkey length: %d", clientPubkey.length);
      return;
    }
    const nonceBuf = Buffer.from(nonce, "base64");
    const deviceId = this.opts.identity.deviceId;
    // `peerId` is the phone's per-machine relay SLOT — a transport address. The
    // transcript and every identity lookup below are keyed by the ACCOUNT
    // device, which is what the phone signs as and what the inventory holds.
    const peerBaseId = baseSlotDeviceId(peerId);

    // SECURITY: verify the phone's transcript signature (empty agent-pub slot —
    // pull-model ordering) against a pinned key before deriving anything.
    const phoneTranscript = buildTranscript({
      registrationId: deviceId,
      role: "phone",
      agentDeviceId: deviceId,
      phoneDeviceId: peerBaseId,
      agentX25519Pub: Buffer.alloc(0),
      phoneX25519Pub: clientPubkey,
      nonce: nonceBuf,
    });
    // Tries every known identity source, not just the first hit: a cached key
    // that no longer verifies (device re-registered under a new Ed25519 key —
    // web updates `publicKey` in place) must fall through to the inventory
    // instead of dead-ending admission until process restart.
    const resolved = this.resolvePhoneEd25519PubB64(peerId, (candidate) =>
      verifyTranscriptSig(phoneTranscript, candidate, sig),
    );
    if (!resolved.pub) {
      // Two very different admission failures, and the operator needs to tell
      // them apart: nobody has ever heard of this device (enrolment/inventory
      // lag) versus a device we DO know presenting a signature that doesn't
      // verify (stale pin after a re-key — or a forgery).
      if (resolved.known === 0) {
        this.diagnostics.warn("Rejecting client-hello: peer %s is unknown to every identity source (cache, account inventory, paired phones)", peerId);
      } else {
        this.diagnostics.warn("Rejecting client-hello: none of the %d known identities for peer %s verifies the transcript signature", resolved.known, peerId);
      }
      return;
    }
    const phoneEd25519PubB64 = resolved.pub;

    // Cache the verified identity for POST-handshake authorization
    // (including backfillPeerPubkey): a trust-only phone (account
    // inventory, no pair-request ever sent) has no paired-phones row for
    // backfillPeerPubkey to recover from, so without this the control-plane
    // dispatch gate (`if (!pk) return`) drops every frame from it forever.
    this.phoneEd25519ByDeviceId.set(peerId, phoneEd25519PubB64);

    // Account trust admits without a pair-request, so nothing else ever creates
    // this phone's row. The row grants NOTHING — authorization is the machine's
    // one mobile-access switch — it is the identity/push/last-seen record: what
    // `antgrid phones list` shows, what push targeting resolves tokens from, and
    // what `backfillPeerPubkey` recovers from after a reconnect. Without it a
    // fully connected phone is invisible to the operator and unreachable by push.
    //
    // Creation only. A rekey re-runs this hello, and rewriting the row would
    // flush the file — tripping its watcher's re-advertise — on every one.
    // An existing row instead takes `touchLastSeen`, which updates memory and
    // coalesces the write, so `last seen` tracks admissions without that cost.
    if (this.opts.pairedPhones && !this.opts.pairedPhones.has(phoneEd25519PubB64)) {
      const now = new Date().toISOString();
      this.opts.pairedPhones.upsert({
        phonePubkey: phoneEd25519PubB64,
        // The ACCOUNT device, not the slot it happened to reach us on: trust is
        // machine-level and one row serves every socket this phone opens. A
        // slot here would also be invisible to the base-keyed lookups in
        // `resolvePhoneEd25519PubB64`/`backfillPeerPubkey`.
        phoneDeviceId: peerBaseId,
        pairedAt: now,
        lastSeenAt: now,
      });
      this.diagnostics.info("Registered account-trusted phone %s", peerBaseId);
    } else {
      this.opts.pairedPhones?.touchLastSeen(phoneEd25519PubB64);
    }

    // A device we have no session with is ADMITTED ALONGSIDE the others: a
    // phone and a desktop app drive the same machine at once, so a verified
    // client-hello is never grounds to displace anyone. Same-device rekey still
    // keeps make-before-break — the device's established session survives below
    // until its own new app:ready confirms.
    this.evictForCapacity(peerId);

    // Fresh attempt: this device's own prior half-open candidate is superseded.
    // Other devices' candidates are untouched.
    this.tearDownPending(peerId);

    const kp = this.opts.generateKeypair();
    const agentPubkey = kp.publicKey;
    const agentTranscript = buildTranscript({
      registrationId: deviceId,
      role: "agent",
      agentDeviceId: deviceId,
      // Base id, matching the phone transcript above: this transcript is the
      // HKDF salt, so a slot id here would derive keys the app cannot open.
      phoneDeviceId: peerBaseId,
      agentX25519Pub: agentPubkey,
      phoneX25519Pub: clientPubkey,
      nonce: nonceBuf,
    });
    const sharedSecret = deriveSharedSecret(kp.privateKey, clientPubkey);
    kp.privateKey.fill(0);
    const sessionKeys = deriveSessionKeys(sharedSecret, agentTranscript);
    const transport = new E2eTransport({ sendKey: sessionKeys.a2p, recvKey: sessionKeys.p2a });
    const attempt: PendingAttempt = { attemptId, transport, sessionKeys, peerId, expiry: null };
    this.pending.set(peerId, attempt);
    this.startHalfOpenTimer(attempt);

    const agentSig = signTranscript(agentTranscript, Buffer.from(seedB64, "base64"));
    this.sendNativePayload(
      Buffer.from(JSON.stringify({ type: "handshake:agent-hello", attemptId, pubkey: agentPubkey.toString("base64"), sig: agentSig }), "utf8"),
      peerId,
      "control",
      FrameKind.handshake,
      "handshake:agent-hello",
    );
    // agent-ready is sealed under the CANDIDATE keys (the session isn't confirmed
    // yet) and carries the confirm tag.
    this.sendSessionFrame(
      { type: "handshake:agent-ready", attemptId, confirm: agentConfirmTag(sessionKeys.confirm).toString("base64") },
      transport,
      peerId,
    );
    this.diagnostics.info("E2E handshake keys derived for %s (attempt %s), waiting for app:ready", peerId, attemptId);
  }

  /** Make room for a device that holds neither a session nor a candidate. */
  protected evictForCapacity(peerId: string): void {
    if (this.sessions.has(peerId) || this.pending.has(peerId)) return;
    while (this.sessions.size + this.pending.size >= MAX_APP_SESSIONS) {
      // A half-open candidate has proved nothing yet, so it goes before any
      // confirmed session — and silently, since there is no session to end.
      const stale = [...this.pending.values()][0];
      if (stale) {
        this.diagnostics.info("Session capacity (%d) reached — discarding half-open attempt for %s", MAX_APP_SESSIONS, stale.peerId);
        this.tearDownPending(stale.peerId);
        continue;
      }
      const victim = this.pickEvictable();
      if (!victim) return;
      this.diagnostics.info(
        "Session capacity (%d) reached — evicting %s to admit %s",
        MAX_APP_SESSIONS,
        victim.peerId,
        peerId,
      );
      try { this.sendSessionFrame({ type: "session-takeover" }, victim.transport, victim.peerId); }
      catch { /* Teardown is authoritative even when the carrier is already gone. */ }
      this.dropSession(victim.peerId);
    }
  }

  /** Evict the least recently active established session. */
  protected pickEvictable(): PeerSession | null {
    let worst: PeerSession | null = null;
    for (const session of this.sessions.values()) {
      if (!worst) { worst = session; continue; }
      if (session.lastSealedRecvAt < worst.lastSealedRecvAt) worst = session;
    }
    return worst;
  }

  protected handleAppReady(
    obj: {
      attemptId?: string;
      confirm?: string;
      capabilities?: { checkoutRouting?: boolean; pullsTree?: boolean; terminalFramesV1?: boolean };
    },
    peerId: string,
  ): void {
    const attemptId = obj.attemptId;
    if (!attemptId) return;
    const tag = Buffer.from(obj.confirm ?? "", "base64");

    // Idempotent: the phone retransmits app:ready every 2s until it sees
    // `established`. A duplicate for this device's live session just re-acks —
    // no state change.
    const live = this.sessions.get(peerId);
    if (live && live.attemptId === attemptId) {
      this.sendSessionFrame({ type: "established", attemptId }, live.transport, peerId);
      return;
    }

    const attempt = this.pending.get(peerId);
    if (attempt && attempt.attemptId === attemptId) {
      const expected = phoneConfirmTag(attempt.sessionKeys.confirm);
      if (!verifyConfirmTag(expected, tag)) {
        this.diagnostics.warn("app:ready confirm tag invalid (attempt %s) — dropping", attemptId);
        return;
      }
      // Make-before-break swap, scoped to THIS device: promote its candidate,
      // then zeroize the keys it replaces. Every other device is untouched.
      const now = Date.now();
      const session: PeerSession = {
        attemptId,
        transport: attempt.transport,
        sessionKeys: attempt.sessionKeys,
        peerId,
        checkoutRouting: obj.capabilities?.checkoutRouting === true,
        lastSealedRecvAt: now,
        missedPongs: 0,
        // Reuse the replaced session's reassembler: a rekey is the same device
        // continuing, and its in-flight transfers survive the key swap.
        frag: live?.frag ?? this.newFragReassembler(peerId),
        // The queue and both windows start empty. Anything the replaced session
        // still held is dropped rather than re-sealed under the promoted keys:
        // the app captures its own key set several awaits after `established`
        // reaches its socket, so a frame written behind the ack races that swap.
        scheduler: this.newSendScheduler(peerId),
        rxFlow: PeerSessionOwner.freshRxFlow(),
        stallWarned: {},
        pullsTree: obj.capabilities?.pullsTree === true,
        terminalFramesV1: obj.capabilities?.terminalFramesV1 === true,
      };
      this.pending.delete(peerId);
      this.stopHalfOpenTimer(attempt);
      this.sessions.set(peerId, session);
      if (live) {
        this.mux.notifyPeerSessionOffline(peerId);
        this.recordQueueDrop("rekey", live.scheduler.clear(), live.peerId);
        zeroizeSessionKeys(live.sessionKeys);
        live.transport.zeroize();
      }
      this.startLiveness();
      this.sendSessionFrame({ type: "established", attemptId }, session.transport, peerId);
      this.diagnostics.info("E2E session established with %s (attempt %s)", peerId, attemptId);
      this.onSessionEstablished(peerId);
      this.opts.onHandshakeComplete?.({
        checkoutRouting: session.checkoutRouting,
        pullsTree: session.pullsTree,
        terminalFramesV1: session.terminalFramesV1,
        peerId,
      });
      this.mux.notifyPeerOnline();
      this.drain();
      return;
    }

    this.diagnostics.warn("app:ready for unknown attempt %s — dropping", attemptId);
  }

  protected onSessionEstablished(_peerId: string): void {}

  /** Try each known identity source in priority order — verified cache →
   *  account inventory → paired-phones store (a parallel path) — returning
   *  the first one `verify` accepts. A cache
   *  hit is preferred for the hot path but does NOT short-circuit: if it fails
   *  verification the loop falls through to the inventory rather than
   *  dead-ending on a stale key. Warms a throttled inventory refresh when
   *  nothing verifies, covering both "never seen" and "cache went stale".
   *
   *  A rejection carries how many identities were actually tried, because those
   *  two cases are diagnostically distinct on the admission path. */
  protected resolvePhoneEd25519PubB64(
    phoneDeviceId: string,
    verify: (candidate: string) => boolean,
  ): { pub: string | undefined; known: number } {
    // Route id for the local cache (it is keyed by reply address), account
    // device id for the two persistent stores — neither has ever heard of a
    // per-machine slot. Widening the candidate list is not widening admission:
    // `verify` still has to pass on whatever comes back.
    const baseId = baseSlotDeviceId(phoneDeviceId);
    const candidates = [
      this.phoneEd25519ByDeviceId.get(phoneDeviceId),
      this.opts.trustedPeers?.lookup(baseId),
      this.opts.pairedPhones?.list().find((p) => p.phoneDeviceId === baseId)?.phonePubkey,
    ].filter((c): c is string => !!c);
    for (const candidate of candidates) {
      if (verify(candidate)) return { pub: candidate, known: candidates.length };
    }
    this.opts.trustedPeers?.noteMiss();
    return { pub: undefined, known: candidates.length };
  }

  // --- Sending ---

  /** Send a AbMessage on the control channel to every established session (or
   *  the one `target` names). Always sealed; dropped (never plaintext) if no
   *  session is established. */
  send(msg: AbMessage, target?: SendTarget): void {
    void this.sendAppEnvelope(CONTROL_STREAM_ID, msg, "control", target);
  }

  /** Send a AbMessage on a specific channel (control plane). */
  sendOnChannel(msg: AbMessage, channel: Channel, target?: SendTarget): void {
    void this.sendAppEnvelope(CONTROL_STREAM_ID, msg, channel, target);
  }

  /** Send a tunnel-protocol message on the preview channel (control plane).
   *  `target` names the session whose request this answers. The promise settles
   *  when the message left the send queue — see {@link sendAppEnvelope}. */
  sendTunnel(data: object, target?: SendTarget): Promise<SendOutcome> {
    return this.sendAppEnvelope(CONTROL_STREAM_ID, data, "preview", target);
  }

  /**
   * Wrap `msg` in the `{ s?, m }` stream envelope, fragment the ENVELOPE json
   * (so `s` survives fragmentation), then hand every fragment to the send
   * scheduler OF EACH RECIPIENT SESSION, which seals and writes them in order —
   * sealing is per-session by construction, since each device's keys are its
   * own. Control-plane traffic uses `CONTROL_STREAM_ID` (`s` omitted).
   * Dropped — never sent in cleartext — when no recipient has a session. A
   * too-large `tunnel:http-response` degrades to a sealed 413 so the phone's
   * preview request fails fast instead of hanging.
   *
   * Fragmenting once and queueing N times is deliberate: every device gets the
   * SAME transfer id, which is what lets an abort be reported the same way to
   * all of them, and the fragment ids stay unique process-wide either way.
   *
   * The returned promise settles when the message LEFT every recipient's queue:
   * "sent" once every fragment of every copy was sealed and written, "dropped"
   * the moment one is discarded. A caller that paces itself against this (the
   * tunnel's chunk loop) is therefore throttled by the TIGHTEST of the
   * recipients' credit windows, which is the one that would overflow first.
   */
  protected sendAppEnvelope(
    streamId: string,
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
      // NEVER send app traffic in cleartext (the relay is zero-knowledge). During
      // a rekey window services may still emit; dropping is correct — the phone
      // re-syncs control state after the next establishment.
      this.diagnostics.debug("Dropping outbound %s — no established session to seal it for", type ?? "message");
      // Only visible at debug today, which is the level nobody is running when
      // the report is "my message never arrived".
      this.recordDiagnostic({
        dir: "tx", kind: "drop", transport: this.payloadTransport(target.kind === "peer" ? target.peerId : undefined), channel,
        msgType: type ?? "message", streamId, reason: "no-e2e-session",
      });
      this.handleUndeliverableTunnel("dropped", channel, msg, target);
      return Promise.resolve<SendOutcome>("dropped");
    }

    const envelope =
      streamId && streamId !== CONTROL_STREAM_ID ? { s: streamId, m: msg } : { m: msg };
    const json = JSON.stringify(envelope);
    const key = this.messageFragKey(msg);
    const fragmented = fragmentForSend(json, type, key);
    if (!fragmented.ok) {
      this.diagnostics.warn("%s", fragmented.error.message);
      this.opts.onError?.(fragmented.error.code, fragmented.error.message);
      const outcome: SendOutcome =
        fragmented.error.code === "MESSAGE_TOO_LARGE" ? "too-large" : "dropped";
      this.recordDiagnostic({
        dir: "tx", kind: "drop", transport: this.payloadTransport(target.kind === "peer" ? target.peerId : undefined), channel,
        msgType: type ?? "message", streamId, reason: fragmented.error.code,
        detail: { bytes: Buffer.byteLength(json, "utf8") },
      });
      this.handleUndeliverableTunnel(outcome, channel, msg, target);
      return Promise.resolve(outcome);
    }

    // One settle per FRAGMENT PER RECIPIENT, one resolution per message: the
    // first drop wins and the rest are ignored, so a fragment set that half
    // lands — or one recipient of several that does not — still reports the
    // message as undelivered.
    let pending = 0;
    let failed = false;
    let resolveOutcome!: (o: SendOutcome) => void;
    const settled = new Promise<SendOutcome>((resolve) => { resolveOutcome = resolve; });
    const perRecipient: { session: PeerSession; frames: QueuedAppFrame[] }[] = [];
    for (const session of recipients) {
      const frames: QueuedAppFrame[] = fragmented.frames.map((plaintext) => ({
        signal,
        authorized,
        channel,
        streamId,
        plaintext,
        plaintextBytes: Buffer.byteLength(plaintext, "utf8"),
        type: type ?? "app",
        settle: (o) => {
          if (failed) return;
          if (o === "dropped") { failed = true; resolveOutcome("dropped"); return; }
          if (--pending === 0) resolveOutcome("sent");
        },
      }));
      pending += frames.length;
      perRecipient.push({ session, frames });
    }
    for (const { session, frames } of perRecipient) {
      if (session.scheduler.enqueue(frames)) continue;
      this.diagnostics.warn(
        "Send queue full on %s to %s — dropping %s (%d frame(s))",
        channel, session.peerId, type ?? "message", frames.length,
      );
      this.recordDiagnostic({
        dir: "tx", kind: "drop", transport: this.payloadTransport(session.peerId), channel,
        msgType: type ?? "message", streamId, reason: "send-queue-full",
        detail: { frames: frames.length, queued: session.scheduler.queued(channel).bytes },
      });
      // enqueue() refused the whole batch, so no settle of this recipient's
      // frames will ever run — report the drop for the message here.
      if (!failed) { failed = true; resolveOutcome("dropped"); }
    }
    const abort = () => { for (const { session } of perRecipient) session.scheduler.dropAborted(); };
    signal?.addEventListener("abort", abort, { once: true });
    this.drain();
    return settled.finally(() => signal?.removeEventListener("abort", abort));
  }

  /** Which established native sessions a {@link SendTarget} selects. */
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

  /** A tunnel HTTP response has no re-sync path (unlike control), so an
   *  undeliverable one must fail the phone's request fast: too-large → sealed
   *  413; torn-down transport → loud warn (the request will time out). */
  protected handleUndeliverableTunnel(
    outcome: "dropped" | "too-large",
    channel: Channel,
    msg: unknown,
    target: SendTarget,
  ): void {
    if (channel !== "preview") return;
    const type = (msg as { type?: string } | null)?.type;
    const requestId = (msg as { requestId?: string } | null)?.requestId;
    if (type !== "tunnel:http-response" || typeof requestId !== "string") return;
    if (outcome === "too-large") {
      // Guarded against recursion: the 413 body is tiny (never too-large).
      this.sendAppEnvelope(
        CONTROL_STREAM_ID,
        {
          type: "tunnel:http-response",
          requestId,
          status: 413,
          headers: {},
          body: "Preview response too large to tunnel",
          bodyEncoding: "utf8",
        },
        "preview",
        // Same addressing as the response it replaces: only the device that
        // made the request is waiting on it.
        target,
      );
    } else {
      this.diagnostics.warn(
        "Tunnel response %s dropped (E2E session not established) — preview request will time out",
        requestId,
      );
    }
  }

  protected messageFragKey(msg: unknown): string | undefined {
    const path = (msg as { path?: unknown } | null)?.path;
    return typeof path === "string" ? path : undefined;
  }

  /** Seal one bare session/liveness frame under `transport` (candidate keys for
   *  agent-ready; established keys for established/ping/pong) and address it to
   *  `to`. Keys and address are passed together on purpose: sealing for one
   *  device and routing to another is the failure this file has hit before, and
   *  it surfaces only as silence. */
  protected sendSessionFrame(obj: object, transport: E2eTransport | undefined, to: string): void {
    if (!transport) return;
    const type = (obj as { type?: string }).type ?? "session";
    const sealed = transport.seal(JSON.stringify(obj));
    if (!this.sendNativePayload(sealed, to, "control", FrameKind.sealed, type)) return;
    // Exempt from the gate, not from the accounting: a relay drop report names
    // only a channel and a length, so bytes written outside the window would
    // un-charge something that was never charged. Charge the session whose keys
    // sealed it — a candidate's frames precede the peer's reset and stay
    // uncounted on both ends, and so do a sibling device's.
    const session = this.sessions.get(to);
    if (session && transport === session.transport) session.scheduler.charge("control", sealed.length);
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

  // --- E2E state teardown + timers ---

  /** End ONE device's session: zeroize its keys, release whatever it was
   *  reassembling, and tell the cores that device is gone. */
  protected dropSession(peerId: string, transport = this.payloadTransport(peerId)): void {
    const session = this.sessions.get(peerId);
    if (!session) return;
    this.sessions.delete(peerId);
    // The choke point for every session end (reconnect, cross-device hello,
    // liveness death): queued frames would otherwise be sealed under a session
    // the peer has already forgotten. The windows die with the struct.
    this.recordQueueDrop("session-torn-down", session.scheduler.clear(), session.peerId, transport);
    session.frag.dispose();
    zeroizeSessionKeys(session.sessionKeys);
    session.transport.zeroize();
    if (this.sessions.size === 0) this.stopLiveness();
    this.mux.notifyPeerSessionOffline(peerId);
    if (this.sessions.size === 0) this.mux.notifyPeerOffline();
  }

  protected tearDownPending(peerId: string): void {
    const attempt = this.pending.get(peerId);
    if (!attempt) return;
    this.pending.delete(peerId);
    this.stopHalfOpenTimer(attempt);
    zeroizeSessionKeys(attempt.sessionKeys);
    attempt.transport.zeroize();
  }

  /** Every session and candidate is gone (socket close / redial): the relay has
   *  forgotten our routes, so nothing sealed for them could be delivered. */
  protected resetE2eState(): void {
    for (const peerId of [...this.sessions.keys()]) this.dropSession(peerId);
    for (const peerId of [...this.pending.keys()]) this.tearDownPending(peerId);
    this.stopLiveness();
  }

  protected startHalfOpenTimer(attempt: PendingAttempt): void {
    this.stopHalfOpenTimer(attempt);
    attempt.expiry = setTimeout(() => {
      // Per attempt, not per client: one device's candidate expiring must not
      // discard another device's, which may have started at any time.
      if (this.pending.get(attempt.peerId) !== attempt) return;
      this.diagnostics.warn("Half-open handshake attempt %s expired — discarding candidate keys", attempt.attemptId);
      this.tearDownPending(attempt.peerId);
    }, this.opts.halfOpenMs ?? HALF_OPEN_MS);
    attempt.expiry?.unref?.();
  }

  protected stopHalfOpenTimer(attempt: PendingAttempt): void {
    if (attempt.expiry) {
      clearTimeout(attempt.expiry);
      attempt.expiry = null;
    }
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
      // Unconditional, every tick: a credit the relay dropped is re-sent within
      // one silence window carrying the same cumulative ground truth, and since
      // it is a sealed frame under this session's keys it also refreshes the
      // device's liveness while bulk drains on a slow uplink.
      for (const ch of ["control", "preview"] as const) this.sendCredit(session, ch);
      // Recent sealed traffic → healthy.
      if (now - session.lastSealedRecvAt < PING_SILENCE_MS) continue;
      if (session.missedPongs >= MAX_MISSED_PONGS) {
        // Unresponsive: drop this device's keys and wait for its rekey (the app
        // owns retry pacing). The socket and every sibling session stay up.
        this.diagnostics.warn("E2E session with %s declared dead (%d missed pongs) — dropping keys, awaiting rekey", session.peerId, MAX_MISSED_PONGS);
        this.dropSession(session.peerId);
        continue;
      }
      session.missedPongs++;
      this.sendSessionFrame({ type: "ping" }, session.transport, session.peerId);
    }
  }

  /** True once at least one E2E session is established (test seam). */
  _handshakeComplete(): boolean {
    return this.sessions.size > 0;
  }
  disposeSessions(): void {
    this.clearBus();
    this.mux.detachAll();
    this.resetE2eState();
    this.stopFragSweep();
  }
}
