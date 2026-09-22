import { logger } from "./logger";

import { type EphemeralKeypair } from "./key-exchange";

import { encodeRouteFrame, decodeRouteFrame, FrameError, FrameKind, GLOBAL_REASSEMBLY_BUDGET, ServerMessage, type RouteHeader } from "antgrid-wire";
import type { Channel } from "./message-bus";

import { type SharedByteBudget } from "./frag-reassembler";
import { StreamMux } from "./stream-mux";
const log = logger.child({ component: "relay-client" });
import { netwatch, frameIdFor } from "./netwatch";

import { PeerSessionOwner, PendingAttempt, PeerSession, OutboundFrameDiagnostic, RateLimitBurst, PeerSessionOwnerOptions } from "./peer-session-owner";
export { fragmentForSend, MAX_APP_SESSIONS, UNREACHABLE_SESSION_TTL_MS, type FragmentForSendResult, type PeerSessionOwnerOptions } from "./peer-session-owner";

import { CentralControlClient, type CentralControlOptions, type RelayError } from "./central-control-client";
export interface RelayClientOptions extends PeerSessionOwnerOptions, CentralControlOptions {}

/** WebSocket payload adapter retained for protocol and legacy evaluation fixtures. */
export class RelayClient extends PeerSessionOwner {
  declare protected opts: RelayClientOptions;
  private _central?: CentralControlClient;
  protected get central(): CentralControlClient {
    return this._central ??= new CentralControlClient({ ...this.opts,
      onConnecting: () => this.resetE2eState(),
      onDisconnected: () => { this.cleanupSessions(); this.mux.notifyPeerOffline(); this.opts.onDisconnected?.(); },
      onControl: (msg) => this.handleControl(msg),
      onBinary: (bytes) => this.handleBinaryFrame(bytes),
      consumePayloadError: (msg) => this.consumePayloadError(msg),
    });
  }
  connect(): void { this.central.connect(); }
  redialWithFreshToken(): void { this.central.redialWithFreshToken(); }
  protected doConnect(): void { this.central.doConnect(); }
  protected handleTextMessage(raw: string): void { this.central.handleTextMessage(raw); }
  protected handleErrorFrame(msg: Omit<RelayError, "type">): void { this.central.handleErrorFrame(msg); }
  protected sendHello(): Promise<void> { return this.central.sendHello(); }
  protected sendJson(data: object): void { this.central.sendJson(data); }
  protected heartbeatTick(): void { this.central.heartbeatTick(); }
  protected scheduleReconnect(): void { this.central.scheduleReconnect(); }
  protected get ws(): WebSocket | null { return this.central.ws; }
  protected set ws(value: WebSocket | null) { this.central.ws = value; }
  protected get backoff() { return this.central.backoff; }
  protected set backoff(value: CentralControlClient["backoff"]) { this.central.backoff = value; }
  protected get clockOffsetMs() { return this.central.clockOffsetMs; }
  protected set clockOffsetMs(value: CentralControlClient["clockOffsetMs"]) { this.central.clockOffsetMs = value; }
  protected get clockOffsetApplied() { return this.central.clockOffsetApplied; }
  protected set clockOffsetApplied(value: CentralControlClient["clockOffsetApplied"]) { this.central.clockOffsetApplied = value; }
  protected get lastError() { return this.central.lastError; }
  protected set lastError(value: CentralControlClient["lastError"]) { this.central.lastError = value; }
  protected get intentionalClose() { return this.central.intentionalClose; }
  protected set intentionalClose(value: CentralControlClient["intentionalClose"]) { this.central.intentionalClose = value; }
  protected get awaitingPong() { return this.central.awaitingPong; }
  protected set awaitingPong(value: CentralControlClient["awaitingPong"]) { this.central.awaitingPong = value; }
  protected get awaitingPongSince() { return this.central.awaitingPongSince; }
  protected set awaitingPongSince(value: CentralControlClient["awaitingPongSince"]) { this.central.awaitingPongSince = value; }
  protected get authenticated() { return this.central.authenticated; }
  protected set authenticated(value: CentralControlClient["authenticated"]) { this.central.authenticated = value; }
  protected get reconnectTimer() { return this.central.reconnectTimer; }
  protected set reconnectTimer(value: CentralControlClient["reconnectTimer"]) { this.central.reconnectTimer = value; }
  protected get heartbeatTimer() { return this.central.heartbeatTimer; }
  protected set heartbeatTimer(value: CentralControlClient["heartbeatTimer"]) { this.central.heartbeatTimer = value; }
  protected get epoch() { return this.central.epoch; }
  constructor(opts: RelayClientOptions) {
    super(opts);
    opts.streamRegistration = { open: (id) => this.sendJson({ type: "stream-open", streamId: id }),
      close: (id) => this.sendJson({ type: "stream-close", streamId: id }) };
  }
  private handleControl(msg: ServerMessage): void {
    switch (msg.type) {
      case "welcome": this.mux.reopenAll(); break;
      case "stream-opened": this.mux.onOpened(msg.streamId); break;
      case "peer-online":
        log.info("Peer online: %s", msg.peerId);
        if (this.isForeignSlot(msg.peerId)) {
          log.debug("Ignoring peer-online for %s — scoped at another machine", msg.peerId);
          break;
        }
        // Bare presence is not a handshake and creates no session: it only
        // revives one this device already holds. Every reply address comes from
        // a session, so a sibling coming online can no longer repoint anything.
        this.backfillPeerPubkey(msg.peerId);
        {
          const session = this.sessions.get(msg.peerId);
          if (session) {
            session.reachable = true;
            session.unreachableSince = 0;
            // Silence is expected across an absence; don't let the gap it left
            // count as missed pongs the moment the device is back.
            session.lastSealedRecvAt = Date.now();
            session.missedPongs = 0;
            this.mux.notifyPeerOnline();
          }
        }
        // Reactive: wait for the phone's fresh client-hello (its rekey). Stream
        // resume happens on handshake-complete, not here.
        this.opts.onPeerOnline?.(msg.peerId);
        break;
      case "peer-offline":
        log.info("Peer offline: %s", msg.peerId);
        if (this.isForeignSlot(msg.peerId)) {
          log.debug("Ignoring peer-offline for %s — scoped at another machine", msg.peerId);
          break;
        }
        // Keep this device's session (keys included) for push fallback and a
        // quick reconnect — only its reachability changes, and
        // UNREACHABLE_SESSION_TTL_MS is what eventually reaps it. Its backlog
        // does NOT survive: an app whose socket drops returns through a fresh
        // handshake, and a retained queue would only sit ahead of the adverts
        // and snapshot it needs first. A sibling's queue is untouched.
        {
          const session = this.sessions.get(msg.peerId);
          if (session) {
            this.recordQueueDrop("peer-offline", session.scheduler.clear());
            if (session.reachable) {
              session.reachable = false;
              session.unreachableSince = Date.now();
            }
          }
        }
        // Per-session first — a sibling device still driving the machine must
        // not have this one's focus and unread state left standing — then the
        // coarse suppression only if nobody reachable is left.
        this.mux.notifyPeerSessionOffline(msg.peerId);
        this.notifyOfflineIfLast();
        this.opts.onPeerOffline?.(msg.peerId);
        break;
      default: break;
    }
  }
  private consumePayloadError(msg: RelayError): boolean {
    // A stream-open rejection (ref === a live streamId: STREAM_LIMIT_EXCEEDED
    // from a current relay, or the retired SESSION_LIMIT_EXCEEDED from an older
    // one): the socket and every other stream stay live, so it
    // must NOT be recorded as `lastError` — otherwise a later unrelated close
    // would read its retryable:false and wrongly stop reconnecting.
    if (msg.ref && this.mux.onError(msg.ref, msg.code, msg.message)) return true;

    // Only socket-affecting errors decide reconnect on the next close.
    this.lastError = { code: msg.code, retryable: msg.retryable };

    // The relay discarded a frame this side already charged its window for.
    // Those bytes can never reach the peer's consumed total, so without the
    // un-charge every drop shrinks that channel for the rest of the session.
    if ((msg.channel === "control" || msg.channel === "preview") && typeof msg.bytes === "number") {
      // The relay names the discarded frame's channel but not who it was for,
      // so with two devices attached this un-charges both. Deliberately the
      // loose direction: over-crediting costs a transient overshoot of one
      // frame's bytes, while under-crediting shrinks a window for the rest of
      // the session — the permanent stall this accounting exists to prevent.
      // TODO(bharath): carry the destination on the drop report to make this exact.
      for (const s of this.sessions.values()) s.scheduler.uncharge(msg.channel, msg.bytes);
      this.drain();
    }

    if (msg.code === "MESSAGE_RATE_LIMITED" || msg.code === "ROUTE_FAILED") {
      this.handleDroppedFrameError(msg.code, msg.message);
      return true;
    }

    return false;
  }
  protected handleBinaryFrame(buf: Buffer): void {
    let decoded: { header: unknown; payload: Uint8Array; kind: FrameKind };
    try {
      decoded = decodeRouteFrame(buf);
    } catch (e) {
      if (e instanceof FrameError) {
        log.warn("Received malformed frame: %s", e.reason);
        netwatch.record({
          dir: "rx", kind: "drop", transport: "relay",
          reason: e.reason, bytes: buf.length,
        });
        return;
      }
      throw e;
    }
    const header = decoded.header as { type?: string; from?: string; channel?: string };
    if (header.type !== "message" || !header.from || !header.channel) {
      log.warn("Invalid route header on binary frame");
      netwatch.record({
        dir: "rx", kind: "drop", transport: "relay",
        reason: "bad-route-header", bytes: buf.length,
      });
      return;
    }
    const channel: Channel = header.channel === "preview" ? "preview" : "control";
    // A structurally valid route frame proves the socket delivered real bytes —
    // sealed/binary E2E traffic (terminal, file data) must count as liveness
    // the same as a JSON pong, even if the sealed payload itself later fails to
    // decrypt (decrypt-or-drop). Mirrors handleTextMessage's clear-before-dispatch.
    this.awaitingPong = false;

    this.receiveRoutedFrame(decoded.payload, header.from, channel, decoded.kind);
  }

  /** Send a push:deliver control frame to the relay (blind FCM/APNs forward). A
   *  top-level control message on OUR socket — the relay itself consumes it. */
  sendPushDeliver(msg: { pushToken: string; provider: "fcm" | "apns"; blob: { epk: string; box: string } }): void {
    this.sendJson({ type: "push:deliver", ...msg });
  }

  /** `to` is the route address of the session whose keys sealed `data`. It is a
   *  required argument rather than client state because there is no longer a
   *  single peer to fall back on. Returns whether the frame reached the socket;
   *  a scheduler charges only what actually went out. */
  protected sendPayload(
    data: Buffer | string,
    to: string,
    channel: Channel = "control",
    kind: FrameKind = FrameKind.sealed,
    diagnosticType = "transport",
    streamId?: string,
  ): boolean {
    if (!to) {
      log.warn("Cannot send payload — no destination");
      netwatch.record({
        dir: "tx", kind: "drop", transport: "relay", channel,
        msgType: diagnosticType, streamId, reason: "no-destination",
      });
      return false;
    }
    if (this.ws?.readyState !== WebSocket.OPEN) {
      // Recorded because nothing else observes it: this return logs nothing at
      // any level, so a frame sent across a reconnect window vanishes leaving
      // no trace on either side.
      netwatch.record({
        dir: "tx", kind: "drop", transport: "relay", channel,
        msgType: diagnosticType, streamId, reason: "socket-not-open",
        detail: { readyState: this.ws?.readyState ?? -1 },
      });
      return false;
    }

    const payloadBytes = typeof data === "string" ? Buffer.from(data, "utf8") : data;
    const header: RouteHeader = { type: "message", to, channel };
    // `frame` is a fresh ArrayBuffer-backed Buffer (never shared); the cast
    // satisfies the WebSocket.send BufferSource type under TS 6's generic
    // Uint8Array.
    const frame = encodeRouteFrame(header, payloadBytes, kind) as Uint8Array<ArrayBuffer>;
    this.ws.send(frame);
    this.recordOutboundFrame(diagnosticType, channel, payloadBytes.length);
    netwatch.record({
      dir: "tx",
      kind: kind === FrameKind.handshake ? "handshake" : "sealed",
      transport: "relay",
      channel,
      streamId,
      msgType: diagnosticType,
      bytes: payloadBytes.length,
      frameId: frameIdFor(payloadBytes, kind === FrameKind.sealed),
    });
    return true;
  }

  private cleanupSessions(): void {
    for (const session of this.sessions.values()) this.recordQueueDrop("socket-closed", session.scheduler.clear());
    for (const attempt of this.pending.values()) this.stopHalfOpenTimer(attempt);
    this.stopLiveness(); this.finishRateLimitBurst(); this.outboundFrameDiagnostics.length = 0;
    this.droppedFrames = 0; this.droppedFramesAt = 0;
  }
  close(): void {
    this.disposeSessions();
    this._central?.close();
  }
  // ---------------------------------------------------------------------------
  // Test hooks — no production impact; only callable from tests.
  // ---------------------------------------------------------------------------

  static forTest(opts: {
    generateKeypair: () => EphemeralKeypair;
    sendPayload: (p: string | Buffer) => void;
    /** The route address the test's default app device reaches us on. Seeds the
     *  pubkey cache only — a session exists solely once a handshake completes. */
    peerId: string;
    /** Agent device id used as `agentDeviceId` in the handshake transcript. */
    deviceId?: string;
    agentEd25519PrivB64?: string;
    phoneEd25519PubB64?: string;
    /** Test seam: overrides the half-open handshake-attempt expiry so rekey/expiry
     *  tests don't wait out the real 30s default. */
    halfOpenMs?: number;
    /** Test seam: shrinks the consumed-byte threshold that triggers a credit so
     *  a window test does not have to push 512 KiB through the receive path. */
    creditBatchBytes?: number;
  }): RelayClient {
    const c = Object.create(RelayClient.prototype) as RelayClient;
    (c as unknown as { opts: Partial<RelayClientOptions> }).opts = {
      generateKeypair: opts.generateKeypair,
      identity: { deviceId: opts.deviceId ?? "test-device", deviceName: "test", createdAt: "", ed25519PrivateKey: opts.agentEd25519PrivB64 },
      halfOpenMs: opts.halfOpenMs,
    };
    (c as unknown as { sendPayload: (p: string | Buffer, ...rest: unknown[]) => boolean }).sendPayload = (p) => {
      opts.sendPayload(p);
      return true;
    };
    (c as unknown as { sessions: Map<string, PeerSession> }).sessions = new Map();
    (c as unknown as { pending: Map<string, PendingAttempt> }).pending = new Map();
    (c as unknown as { reassemblyBudget: SharedByteBudget }).reassemblyBudget = {
      used: 0,
      limit: GLOBAL_REASSEMBLY_BUDGET,
    };
    (c as unknown as { phoneEd25519ByDeviceId: Map<string, string> }).phoneEd25519ByDeviceId = new Map();
    (c as unknown as { outboundFrameDiagnostics: OutboundFrameDiagnostic[] }).outboundFrameDiagnostics = [];
    (c as unknown as { rateLimitBurst: RateLimitBurst | null }).rateLimitBurst = null;
    (c as unknown as { unknownStreamLoggedAt: Map<string, number> }).unknownStreamLoggedAt = new Map();
    (c as unknown as { unknownStreamSuppressed: Map<string, number> }).unknownStreamSuppressed = new Map();
    (c as unknown as { droppedFrames: number }).droppedFrames = 0;
    (c as unknown as { droppedFramesAt: number }).droppedFramesAt = 0;
    (c as unknown as { mux: StreamMux }).mux = new StreamMux({
      openStream: () => {},
      closeStream: () => {},
      sendEnvelope: () => Promise.resolve("sent"),
      peerSession: () => null,
    });
    // The scheduler and the reassembler are per-session now, built by
    // `newSendScheduler`/`newFragReassembler` as each device establishes, so
    // there is nothing client-wide left for a test to initialize.
    if (opts.creditBatchBytes !== undefined) {
      (c as unknown as { creditBatchBytes: number }).creditBatchBytes = opts.creditBatchBytes;
    }
    if (opts.phoneEd25519PubB64) {
      (c as unknown as { phoneEd25519ByDeviceId: Map<string, string> }).phoneEd25519ByDeviceId.set(opts.peerId, opts.phoneEd25519PubB64);
    }
    return c;
  }
}
