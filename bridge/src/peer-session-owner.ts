import { randomBytes } from "node:crypto";
import { logger } from "./logger";
import type { DeviceIdentity } from "./device";
import { parseMessageFast, SessionHelloFrame, type AbMessage, type SessionHello } from "./protocol";
import { baseSlotDeviceId, slotMachineDeviceId } from "./relay-slot";
import { parseTunnelMessage } from "./tunnel-protocol";
import { buildFragments, FRAG_THRESHOLD, MAX_TRANSFER_BYTES, TRANSFER_TIMEOUT_MS, GLOBAL_REASSEMBLY_BUDGET, CONTROL_STREAM_ID, CREDIT_BATCH_BYTES, WINDOW_STALL_WARN_MS } from "antgrid-wire";
import type { MessageBus, Channel, TransportSubscriber } from "./message-bus";
import type { PairedPhonesStore } from "./paired-phones";
import { FragReassembler, type SharedByteBudget } from "./frag-reassembler";

import {
  StreamMux,
  type AttachStreamOpts,
  type PeerSessionView,
  type SendTarget,
  type StreamHandle,
} from "./stream-mux";
import { netwatch, frameIdFor, isRemoteIngestArmed } from "./netwatch";
import { SendScheduler, type QueuedAppFrame, type SendOutcome, type PendingSinkWrite } from "./send-scheduler";
import type { PeerRecordFailure } from "./peer/records";
import type { StreamSendOutcome } from "./peer/stream-records";

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
  onTunnelMessage?: (msg: unknown, peerId: string) => void;
  onDisconnected?: () => void;
  onError?: (code: string, message: string) => void;
  /** Phone identity/push registry. Grants nothing — it is where `admitPeer`
   *  records the device: what `antgrid phones list` shows, what push
   *  targeting resolves tokens from. */
  pairedPhones?: PairedPhonesStore;
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

/** At most one unknown-streamId warn per stream per this interval. */
const UNKNOWN_STREAM_LOG_INTERVAL_MS = 30_000;

/** Ceiling on the unknown-stream throttle maps before they are cleared whole. */
const MAX_TRACKED_UNKNOWN_STREAMS = 64;

const FRAG_ID_SEED = randomBytes(8).toString("hex");

let fragIdCounter = 0;

export type FragmentForSendResult =
  | { ok: true; frames: string[] }
  | { ok: false; error: { code: "MESSAGE_TOO_LARGE"; message: string } };

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
  /** Fragments are per-session: two devices interleave transfers on one socket,
   *  and a shared reassembler would splice their streams together. */
  frag: FragReassembler;
  /** Outbound queue + credit windows for THIS device. Per-session so a busy
   *  device cannot stall a quiet one, and each app credits only what it
   *  consumed. */
  scheduler: SendScheduler;
  /** Inbound half of the credit windows: cumulative payload bytes read from
   *  this device per channel, and how much of that has been credited back to
   *  it. */
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
/** Owns the peer session and payload dispatch, independent of central
 * authentication and sockets. Confidentiality is QUIC/TLS between the
 * lease-authorized endpoints below this layer; remote carriers must enter
 * here only after validating their route and endpoint, and the application
 * dispatch retains relay-origin authorization semantics. */
export abstract class PeerSessionOwner {
  protected get diagnostics(): Pick<typeof log, "debug" | "info" | "warn" | "error"> {
    return this.opts.diagnostics ?? log;
  }

  protected abstract sendNativePayload(
    data: Buffer | string,
    to: string,
    channel?: Channel,
    diagnosticType?: string,
    streamId?: string,
  ): boolean;

  protected abstract sendNativeScheduled(
    payload: Buffer,
    peerId: string,
    frame: QueuedAppFrame,
  ): number | null | PendingSinkWrite;

  protected payloadTransport(_peerId?: string): "iroh" { return "iroh"; }

  protected recordDiagnostic(event: Parameters<typeof netwatch.record>[0]): void {
    try { netwatch.record(event); } catch { /* Observers cannot break admission or delivery. */ }
  }

  /**
   * The per-peer pre-establishment drop point. A frame is attributed only to
   * `this.sessions.get(from)` — never trial-attempted against another
   * session — so a peer that has not established one gets exactly one way in:
   * a control-channel `session:hello`. Everything else is dropped before it
   * can reach `onPeerPlaintext`, frag reassembly, `routeAppEnvelope`,
   * `dispatchControlPlane`, `bus.dispatchInbound` or a stream, and nothing is
   * counted for a dropped frame.
   */
  protected receivePeerFrame(payload: Uint8Array, from: string, channel: Channel): void {
    const frameId = frameIdFor(payload);
    const bytes = payload.length;
    const session = this.sessions.get(from);
    if (session) {
      session.lastRecvAt = Date.now();
      session.missedPongs = 0;
      this.noteConsumed(session, channel, bytes);
      this.onPeerPlaintext(Buffer.from(payload).toString("utf8"), channel, from, session, frameId, bytes);
      return;
    }
    if (channel === "control") {
      let obj: unknown;
      try { obj = JSON.parse(Buffer.from(payload).toString("utf8")); } catch { obj = null; }
      if (obj && typeof obj === "object" && (obj as { type?: unknown }).type === "session:hello") {
        this.recordDiagnostic({
          dir: "rx", kind: "frame", transport: this.payloadTransport(from), channel,
          msgType: "session:hello", frameId, bytes,
        });
        const parsed = SessionHelloFrame.safeParse(obj);
        if (!parsed.success) { this.refusePeer(from, "protocol-violation"); return; }
        this.handleHello(parsed.data, from, frameId, bytes);
        return;
      }
    }
    this.recordDiagnostic({
      dir: "rx", kind: "drop", transport: this.payloadTransport(from), channel,
      frameId, bytes, reason: "pre-establishment",
    });
  }

  // Session state, keyed by the app's relay SLOT (the route address) — one
  // entry per device, so tearing one down cannot disturb another's.
  protected readonly sessions = new Map<string, PeerSession>();

  /** One reassembly ceiling for the whole machine, shared by every session's
   *  reassembler — N devices must not each be handed the full budget. */
  protected reassemblyBudget: SharedByteBudget = { used: 0, limit: GLOBAL_REASSEMBLY_BUDGET };

  /** Consumed bytes between byte-triggered credits; a test seam shrinks it. */
  protected creditBatchBytes!: number;

  /** One timer for every session: liveness is cheap per session and a timer
   *  each would be N unrefed intervals to leak. */
  protected livenessTimer: ReturnType<typeof setInterval> | null = null;

  // Phone Ed25519 pubkeys (standard base64, raw 32 bytes) resolved from the
  // account peers inventory at admission, keyed by the phone's deviceId (==
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

  /** True when `peerId` is an app relay slot scoped at a DIFFERENT machine.
   *
   *  The relay fans presence to every same-account peer of the opposite type,
   *  so one phone holding N machines open reaches us once per SLOT — and all
   *  but one of those name a machine that isn't us. Acting on a sibling's would
   *  point our reply address at a socket whose session cannot open our frames
   *  (peer-online), or suppress our heavy stream because a DIFFERENT machine's
   *  socket closed (peer-offline).
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
    this.creditBatchBytes = CREDIT_BATCH_BYTES;
    this.startFragSweep();
  }

  /** Attach a project's bus as a multiplexed stream on this machine socket. */
  attachStream(bus: MessageBus, opts: AttachStreamOpts): StreamHandle {
    return this.mux.attach(bus, opts);
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
   * written only once it is actually being sent — under whatever session is
   * live at that moment, not the one that was live when the caller handed it
   * over. The sink resolves the session by id rather than closing over it: a
   * reconnect replaces the struct, and a captured one would address a peer
   * that has already forgotten it.
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
        return this.sendNativeScheduled(Buffer.from(f.plaintext, "utf8"), peerId, f);
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

  protected onPeerPlaintext(
    plaintext: string,
    channel: Channel,
    peerId: string,
    session: PeerSession,
    frameId?: string,
    bytes?: number,
  ): void {
    // Fragmented app traffic → buffer; onComplete routes the reassembled envelope.
    if (session.frag.accept(plaintext)) {
      this.recordDiagnostic({
        dir: "rx", kind: "frame", transport: this.payloadTransport(peerId), channel,
        msgType: "__frag", frameId, bytes,
      });
      return;
    }

    let obj: unknown;
    try {
      obj = JSON.parse(plaintext);
    } catch {
      this.diagnostics.warn("Dropping non-JSON peer plaintext");
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
          dir: "rx", kind: "frame", transport: this.payloadTransport(peerId), channel,
          msgType: (obj as { type: string }).type, frameId, bytes,
        });
        this.handleSessionFrame(
          obj as {
            type: string; attemptId?: string;
            capabilities?: { checkoutRouting?: boolean; pullsTree?: boolean; terminalFramesV1?: boolean };
            channel?: unknown; consumed?: unknown;
          },
          peerId,
        );
        return;
      }
      if ("m" in (obj as object)) {
        this.routeAppEnvelope(obj as { s?: string; m: unknown }, channel, peerId, frameId, bytes);
        return;
      }
    }
    this.diagnostics.warn("Dropping unrecognized peer plaintext");
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
    // No frameId: a reassembled transfer spans N frames, each with its own
    // id, so nothing here maps to a single frame on the peer's capture.
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
      dir: "rx", kind: "frame", transport: this.payloadTransport(peerId), channel,
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
   * which spans N frames with N ids.
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

  // --- Session frames ---

  protected handleSessionFrame(
    obj: {
      type: string;
      attemptId?: string;
      capabilities?: { checkoutRouting?: boolean; pullsTree?: boolean; terminalFramesV1?: boolean };
      channel?: unknown;
      consumed?: unknown;
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
        this.diagnostics.warn("Dropping unexpected peer session frame (type=%s)", obj.type);
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
   * `attemptId` is re-acked and nothing else changes (the app retransmits
   * until it sees `established`); a different `attemptId` while established
   * is a protocol violation. A peer with no session must already be admitted
   * (`admitPeer`) — `peerPubkeyFor` is how this checks — or the hello is
   * dropped as `not-admitted` and nothing is established. `NativePeerSessions`
   * overrides this to run the lease re-check first and defer to this
   * implementation once it passes.
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
      frag: this.newFragReassembler(peerId),
      scheduler: this.newSendScheduler(peerId),
      rxFlow: PeerSessionOwner.freshRxFlow(),
      stallWarned: {},
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
    this.mux.notifyPeerOnline();
    this.drain();
  }

  /** Refuse a peer for `reason`. The base has no connection to close, so it
   *  can only end the session; `NativePeerSessions` overrides this to close
   *  the underlying connection with the code {@link PeerRecordFailure} maps
   *  to (see `peer/records.ts`). */
  protected refusePeer(peerId: string, _reason: PeerRecordFailure): void {
    this.dropSession(peerId);
  }

  protected onSessionEstablished(_peerId: string): void {}

  // --- Sending ---

  /** Send a AbMessage on the control channel to every established session (or
   *  the one `target` names). Always sent as the session's own frame; dropped
   *  (never broadcast) if no session is established. */
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
   * scheduler OF EACH RECIPIENT SESSION, which writes them in order — per
   * session by construction, since each device has its own queue and window.
   * Control-plane traffic uses `CONTROL_STREAM_ID` (`s` omitted).
   * Dropped when no recipient has a session. A too-large `tunnel:http-response`
   * degrades to a 413 so the phone's preview request fails fast instead of
   * hanging.
   *
   * Fragmenting once and queueing N times is deliberate: every device gets the
   * SAME transfer id, which is what lets an abort be reported the same way to
   * all of them, and the fragment ids stay unique process-wide either way.
   *
   * The returned promise settles when the message LEFT every recipient's queue:
   * "sent" once every fragment of every copy was written, "dropped" the moment
   * one is discarded. A caller that paces itself against this (the tunnel's
   * chunk loop) is therefore throttled by the TIGHTEST of the recipients'
   * credit windows, which is the one that would overflow first.
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
      // Nothing to send to. During a reconnect window services may still
      // emit; dropping is correct — the phone re-syncs control state after
      // the next establishment.
      this.diagnostics.debug("Dropping outbound %s — no established session for it", type ?? "message");
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

  /** A tunnel HTTP response has no re-sync path (unlike control), so an
   *  undeliverable one must fail the phone's request fast: too-large → a
   *  413; no session → loud warn (the request will time out). */
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
        "Tunnel response %s dropped (no session established) — preview request will time out",
        requestId,
      );
    }
  }

  protected messageFragKey(msg: unknown): string | undefined {
    const path = (msg as { path?: unknown } | null)?.path;
    return typeof path === "string" ? path : undefined;
  }

  /** Send one bare session/liveness frame to `to`, addressed to whichever
   *  session is live for that device right now. */
  protected sendSessionFrame(obj: object, to: string): void {
    const type = (obj as { type?: string }).type ?? "session";
    const payload = Buffer.from(JSON.stringify(obj), "utf8");
    if (!this.sendNativePayload(payload, to, "control", type)) return;
    // Exempt from the gate, not from the accounting: a relay drop report names
    // only a channel and a length, so bytes written outside the window would
    // un-charge something that was never charged.
    const session = this.sessions.get(to);
    if (session) session.scheduler.charge("control", payload.length);
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

  /** End ONE device's session: release whatever it was reassembling, and tell
   *  the cores that device is gone. */
  protected dropSession(peerId: string, transport = this.payloadTransport(peerId)): void {
    const session = this.sessions.get(peerId);
    if (!session) return;
    this.sessions.delete(peerId);
    // The choke point for every session end (reconnect, cross-device hello,
    // liveness death): queued frames would otherwise be addressed to a
    // session the peer has already forgotten. The windows die with the struct.
    this.recordQueueDrop("session-torn-down", session.scheduler.clear(), session.peerId, transport);
    session.frag.dispose();
    if (this.sessions.size === 0) this.stopLiveness();
    this.mux.notifyPeerSessionOffline(peerId);
    if (this.sessions.size === 0) this.mux.notifyPeerOffline();
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
      // Unconditional, every tick: a credit the relay dropped is re-sent within
      // one silence window carrying the same cumulative ground truth, and since
      // it is a frame under this session's id it also refreshes the device's
      // liveness while bulk drains on a slow uplink.
      for (const ch of ["control", "preview"] as const) this.sendCredit(session, ch);
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
    this.mux.detachAll();
    this.resetSessions();
    this.stopFragSweep();
  }
}
