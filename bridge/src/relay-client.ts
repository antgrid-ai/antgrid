import { sign, createPrivateKey, randomBytes } from "node:crypto";
import { logger } from "./logger";

import { rawSeedToPkcs8 } from "./e2e";
import { type EphemeralKeypair } from "./key-exchange";

import { encodeRouteFrame, decodeRouteFrame, FrameError, FrameKind, GLOBAL_REASSEMBLY_BUDGET, ServerMessage, buildHelloSigBody, normalizeRelayHost, type HelloMessage, type RouteHeader } from "antgrid-wire";
import type { Channel } from "./message-bus";

import { type SharedByteBudget } from "./frag-reassembler";
import { prunePushToken } from "./push/prune";
import { nextEpoch } from "./relay-epoch";
import { StreamMux } from "./stream-mux";
import { netwatch, frameIdFor } from "./netwatch";

import { PeerSessionOwner, PendingAttempt, PeerSession, OutboundFrameDiagnostic, RateLimitBurst, PeerSessionOwnerOptions, fragmentForSend } from "./peer-session-owner";
export { fragmentForSend, MAX_APP_SESSIONS, UNREACHABLE_SESSION_TTL_MS, type FragmentForSendResult, type PeerSessionOwnerOptions } from "./peer-session-owner";
const HEARTBEAT_INTERVAL = 25_000;
const INITIAL_BACKOFF = 1_000;
const MAX_BACKOFF = 30_000;
const LICENSE_AUTH_DEAD = new Set(["LICENSE_INVALID", "LICENSE_REVOKED"]);
const log = logger.child({ component: "relay-client" });

/**
 * The fields of a relay control verb worth keeping in a capture: the ones that
 * say WHY a socket stalled. Nothing here can leak app content — the relay is
 * zero-knowledge and these verbs carry none. Absent fields stay absent rather
 * than becoming `undefined` keys, so a capture line stays short.
 */
function netwatchControlDetail(
  msg: ServerMessage,
): Record<string, string | number | boolean> | undefined {
  const m = msg as {
    code?: string; retryable?: boolean; ref?: string; peerId?: string;
    streamId?: string; epoch?: number; ok?: boolean; reason?: string;
  };
  const detail: Record<string, string | number | boolean> = {};
  if (m.code !== undefined) detail.code = m.code;
  if (m.retryable !== undefined) detail.retryable = m.retryable;
  if (m.ref !== undefined) detail.ref = m.ref;
  if (m.peerId !== undefined) detail.peerId = m.peerId;
  if (m.streamId !== undefined) detail.streamId = m.streamId;
  if (m.epoch !== undefined) detail.epoch = m.epoch;
  if (m.ok !== undefined) detail.ok = m.ok;
  if (m.reason !== undefined) detail.reason = m.reason;
  return Object.keys(detail).length > 0 ? detail : undefined;
}

/** Ed25519 sign `data` with a raw 32-byte seed (base64). Shared by the hello
 *  proof and any signed frame. */
function signEd25519(seedB64: string, data: Uint8Array): string {
  const key = createPrivateKey({
    key: rawSeedToPkcs8(Buffer.from(seedB64, "base64")),
    format: "der",
    type: "pkcs8",
  });
  return sign(null, data, key).toString("base64");
}
export interface RelayClientOptions extends PeerSessionOwnerOptions {
  onPeerPolicyChanged?: (generation: string) => void;
  url: string;
  /** Machine dir for the persistent connection-epoch counter. */
  abDir?: string;
  /** Fired on `welcome` — the single 1-RTT authentication event. */
  onAuthenticated?: () => void;
  /** Fired only when the relay rejected our license with an
   *  identity-dead verdict (LICENSE_INVALID | LICENSE_REVOKED). LICENSE_EXPIRED
   *  is recoverable by time (see {@link redialWithFreshToken}) and does NOT fire
   *  this; SUPERSEDED must NEVER call it — re-enrolling would be
   *  wrong advice. */
  onAuthRevoked?: () => void;
  autoReconnect?: boolean;
  /**
   * Returns the license JWT to present in `hello`. Called per (re)connect so
   * refreshed tokens are picked up automatically. Required — the agent must
   * always present a token.
   */
  getLicenseToken: () => Promise<string> | string;
}

export class RelayClient extends PeerSessionOwner {
  protected centralControlsPeer(_peerId: string): boolean { return true; }
  declare protected opts: RelayClientOptions;

  protected ws: WebSocket | null = null;

  protected intentionalClose = false;

  protected backoff = INITIAL_BACKOFF;

  protected heartbeatTimer: ReturnType<typeof setInterval> | null = null;

  /** True from the moment a heartbeat `ping` is sent until a reply (or any
   *  other inbound frame) proves the socket is still alive. */
  protected awaitingPong = false;

  /** When the outstanding probe went out; only meaningful while
   *  {@link awaitingPong}. */
  protected awaitingPongSince = 0;

  protected reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  protected authenticated = false;

  protected readonly epoch: number;

  /** Learned wall-clock correction from a clock-skew AUTH_FAILED. */
  protected clockOffsetMs = 0;

  protected clockOffsetApplied = false;

  /** The last relay `error` frame; its `retryable` decides reconnect on close. */
  protected lastError: { code: string; retryable: boolean } | null = null;

  constructor(opts: RelayClientOptions) {
    super(opts);
    // Computed once per process and reused across every (re)connect: epoch
    // identifies this process INSTANCE, not this socket. A redial
    // presenting the same epoch relies on the relay's equal-epoch rule
    // (same key + equal epoch ⇒ newest socket wins) to evict its own
    // half-open zombie; minting per dial instead would let a stale process
    // out-epoch and displace a legitimately newer one via the shared counter.
    this.epoch = opts.abDir ? nextEpoch(opts.abDir) : Math.floor(Date.now() / 1000);
  }

  connect(): void {
    this.intentionalClose = false;
    this.doConnect();
  }

  /**
   * Redial after a LICENSE_EXPIRED stop, once a fresh token has minted. Expired
   * is recoverable by time (a lapsed-then-renewed subscription): unlike the
   * identity-dead verdicts it stops reconnecting but leaves token maintenance
   * running, so when maintenance reports a fresh mint the machine socket redials
   * WITHOUT a process restart. No-op unless we actually stopped on an expired
   * verdict — never broadens to other terminal stops (SUPERSEDED)
   * or a live/intentionally-closed socket.
   */
  redialWithFreshToken(): void {
    if (this.intentionalClose) return;
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return;
    if (this.lastError?.code !== "LICENSE_EXPIRED") return;
    this.lastError = null;
    this.backoff = INITIAL_BACKOFF;
    this.doConnect();
  }

  protected doConnect(): void {
    this.authenticated = false;
    this.lastError = null;
    this.resetE2eState();

    log.debug(`Connecting to ${this.opts.url}`);
    const ws = new WebSocket(this.opts.url);

    ws.addEventListener("open", () => {
      log.info(`Connected to relay at ${this.opts.url}`);
      this.ws = ws;
      // Backoff is reset ONLY on `welcome`, never on socket open (a socket that
      // opens then fails auth must keep backing off — PR#49 carry-over).
      void this.sendHello();
    });

    ws.addEventListener("message", (event) => {
      if (typeof event.data === "string") {
        this.handleTextMessage(event.data);
      } else {
        const buf =
          event.data instanceof ArrayBuffer
            ? Buffer.from(event.data)
            : Buffer.from(event.data as Uint8Array);
        this.handleBinaryFrame(buf);
      }
    });

    ws.addEventListener("close", () => {
      this.cleanup();
      // The peer is unreachable across the gap — suppress attached streams so
      // cores stop emitting into a torn-down session (they resume on the next
      // handshake-complete).
      if (![...this.sessions.values()].some((peer) => !this.centralControlsPeer(peer.peerId) && peer.reachable)) {
        this.mux.notifyPeerOffline();
      }
      this.opts.onDisconnected?.();
      // The v3 error contract decides reconnect: a terminal (retryable:false)
      // error frame preceded this close, so retrying is pointless. No error, or
      // a retryable one → jittered backoff.
      const terminal = this.lastError?.retryable === false;
      if (!this.intentionalClose && this.opts.autoReconnect !== false && !terminal) {
        this.scheduleReconnect();
      }
    });

    ws.addEventListener("error", (err) => {
      // Object-first: a bare trailing arg is dropped when the message has no
      // printf placeholder, so the actual error detail would be lost.
      log.error({ err }, "WebSocket error");
    });
  }

  protected async sendHello(): Promise<void> {
    const { identity } = this.opts;
    let licenseToken: string;
    try {
      licenseToken = await this.opts.getLicenseToken();
    } catch (err) {
      log.error({ err }, "Failed to get license token");
      this.opts.onError?.("LICENSE_INVALID", String(err));
      this.ws?.close();
      return;
    }
    if (!licenseToken) {
      // Do NOT fail closed: getLicenseToken is called per (re)connect to pick up
      // refreshed tokens, so an empty token may be transient — let reconnect fire.
      this.opts.onError?.(
        "LICENSE_INVALID",
        "No license token — sign in from the Antgrid app and relaunch the agent.",
      );
      this.ws?.close();
      return;
    }
    if (!identity.ed25519PublicKey || !identity.ed25519PrivateKey) {
      // A missing device keypair is PERMANENT (never gained at runtime) — fail
      // closed so we don't dial → fail hello → reconnect every second forever.
      log.error("No Ed25519 keypair available for hello");
      this.intentionalClose = true;
      this.opts.onError?.("AUTH_FAILED", "Missing device keypair");
      this.ws?.close();
      return;
    }

    const ts = new Date(Date.now() + this.clockOffsetMs).toISOString();
    const nonce = randomBytes(16).toString("base64");
    const relayHost = normalizeRelayHost(this.opts.url);
    const sigBody = buildHelloSigBody({
      relayHost,
      deviceType: "agent",
      deviceId: identity.deviceId,
      publicKey: identity.ed25519PublicKey,
      epoch: this.epoch,
      licenseToken,
      ts,
      nonce,
    });
    const sig = signEd25519(identity.ed25519PrivateKey, sigBody);
    const hello: HelloMessage = {
      type: "hello",
      protocolVersion: 3,
      deviceType: "agent",
      deviceId: identity.deviceId,
      name: identity.deviceName,
      publicKey: identity.ed25519PublicKey,
      epoch: this.epoch,
      licenseToken,
      ts,
      nonce,
      sig,
    };
    this.sendJson(hello);
  }

  protected handleTextMessage(raw: string): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      log.warn("Received non-JSON message from relay, dropping");
      netwatch.record({
        dir: "rx", kind: "drop", transport: "relay",
        reason: "control-not-json", bytes: Buffer.byteLength(raw, "utf8"),
      });
      return;
    }

    const result = ServerMessage.safeParse(parsed);
    if (!result.success) {
      log.warn("Received invalid relay message, dropping: %s", result.error.message);
      netwatch.record({
        dir: "rx", kind: "drop", transport: "relay",
        msgType: (parsed as { type?: string } | null)?.type,
        reason: "control-schema-invalid", bytes: Buffer.byteLength(raw, "utf8"),
      });
      return;
    }
    const msg = result.data;
    // The relay's own verbs are what explain a stalled socket — an `error` with
    // its code, a `peer-offline`, a supersession — and they are the half a
    // frame-only capture would miss entirely.
    netwatch.record({
      dir: "rx",
      kind: "control",
      transport: "relay",
      msgType: msg.type,
      bytes: Buffer.byteLength(raw, "utf8"),
      detail: netwatchControlDetail(msg),
    });
    // Any successfully parsed inbound frame proves the socket is alive, not
    // just an explicit `pong` — a chatty relay is as good a liveness signal.
    this.awaitingPong = false;

    switch (msg.type) {
      case "welcome":
        this.authenticated = true;
        this.backoff = INITIAL_BACKOFF; // reset ONLY here (PR#49 carry-over)
        this.clockOffsetApplied = false;
        this.startHeartbeat();
        // Re-admit every attached stream: the relay lost its openStreams on the
        // disconnect, so they must be re-opened before app traffic resumes.
        this.mux.reopenAll();
        log.info("Authenticated with relay as %s (epoch %d)", msg.deviceId, msg.epoch);
        this.opts.onAuthenticated?.();
        break;
      case "stream-opened":
        this.mux.onOpened(msg.streamId);
        break;
      case "stream-closed":
        // Idempotent accounting ack — nothing to do; the mux already forgot it.
        break;
      case "peer-online":
        if (!this.centralControlsPeer(msg.peerId)) break;
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
      case "peer-policy-changed":
        this.opts.onPeerPolicyChanged?.(msg.generation);
        break;
      case "peer-offline":
        if (!this.centralControlsPeer(msg.peerId)) break;
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
      case "push:result":
        if (!msg.ok && msg.reason === "unregistered" && this.opts.pairedPhones) {
          prunePushToken(this.opts.pairedPhones, msg.pushToken);
        } else if (!msg.ok) {
          // warn, not debug: a push that never lands has no other observable on
          // this side. At debug, a misconfigured relay (bad FCM key -> reason
          // "error", absent creds -> "unconfigured") is indistinguishable from
          // no push being attempted at all, which reads as an app bug.
          log.warn("push:result not ok (reason=%s)", msg.reason);
        }
        break;
      case "error":
        this.handleErrorFrame(msg);
        break;
      case "pong":
        // App-layer liveness reply to our heartbeat probe (already cleared
        // above; explicit for readability at the call site).
        this.awaitingPong = false;
        break;
      default: {
        const _exhaustive: never = msg;
        void _exhaustive;
      }
    }
  }

  protected handleErrorFrame(msg: { code: string; message: string; retryable: boolean; ref?: string; serverTime?: string; channel?: string; bytes?: number }): void {
    // A stream-open rejection (ref === a live streamId: STREAM_LIMIT_EXCEEDED
    // from a current relay, or the retired SESSION_LIMIT_EXCEEDED from an older
    // one): the socket and every other stream stay live, so it
    // must NOT be recorded as `lastError` — otherwise a later unrelated close
    // would read its retryable:false and wrongly stop reconnecting.
    if (msg.ref && this.mux.onError(msg.ref, msg.code, msg.message)) return;

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
      return;
    }

    // Clock-skew self-heal: learn the offset and let the retryable reconnect
    // re-hello with a corrected `ts`.
    if (msg.code === "AUTH_FAILED" && msg.serverTime) this.applyClockOffset(msg.serverTime);

    log.error(
      `Relay error: device=${this.opts.identity.deviceId} peers=${this.describePeers()} ` +
      `code=${msg.code} retryable=${msg.retryable} message="${msg.message}"`,
    );
    this.opts.onError?.(msg.code, msg.message);

    // Only an identity-dead LICENSE verdict tells the user
    // to re-enroll. LICENSE_EXPIRED is recoverable by time — it takes the plain
    // terminal path (retryable:false stops reconnect at the close handler) while
    // token maintenance keeps re-minting and redials on a fresh mint. SUPERSEDED
    // (a newer instance of OURSELVES) must never trigger this.
    if (LICENSE_AUTH_DEAD.has(msg.code)) this.opts.onAuthRevoked?.();
    if (msg.code === "SUPERSEDED") {
      log.info("Superseded by a newer connection of this device — stopping reconnect");
    }
  }

  protected applyClockOffset(serverTime: string): void {
    const server = Date.parse(serverTime);
    if (!Number.isFinite(server)) return;
    const offset = server - Date.now();
    // Apply once per offset value; a repeat skew with an already-applied offset
    // falls through to normal (retryable) reconnect without thrashing the clock.
    if (this.clockOffsetApplied && Math.abs(offset - this.clockOffsetMs) < 1000) return;
    this.clockOffsetMs = offset;
    this.clockOffsetApplied = true;
    log.warn("Relay clock skew detected; applying %dms offset to the next hello", offset);
  }

  // --- Binary frame receive path (kind-byte dispatch) ---

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

  /**
   * Every outbound relay control verb goes through here — `hello`, `ping`,
   * `stream-open`/`stream-close`, `push:deliver` — so it is recorded for the
   * same reason the inbound half is. A capture showing a `pong` with no `ping`,
   * or an `unknown-stream` drop with no `stream-open` to say whether this
   * bridge ever opened that stream, cannot answer the question the streamId
   * column exists for. Only the verb and its size are kept: `hello` carries
   * auth material and `push:deliver` carries a payload, and neither belongs in
   * a capture.
   */
  protected sendJson(data: object): void {
    const { type: msgType, streamId } = data as { type?: string; streamId?: string };
    if (this.ws?.readyState !== WebSocket.OPEN) {
      netwatch.record({
        dir: "tx", kind: "drop", transport: "relay",
        msgType, streamId, reason: "socket-not-open",
        detail: { readyState: this.ws?.readyState ?? -1 },
      });
      return;
    }
    const json = JSON.stringify(data);
    netwatch.record({
      dir: "tx", kind: "control", transport: "relay",
      msgType, streamId, bytes: Buffer.byteLength(json, "utf8"),
    });
    this.ws.send(json);
  }

  close(): void {
    this.clearBus();
    this.intentionalClose = true;
    this.mux.detachAll();
    this.stopFragSweep();
    this.cleanup();
    this.ws?.close();
    this.ws = null;
  }

  protected heartbeatTick(): void {
    if (this.ws?.readyState !== WebSocket.OPEN) return;
    if (this.awaitingPong) {
      // Half-open socket (e.g. after machine sleep): our previous probe went
      // unanswered for a full interval. Force-close rather than leaving it to
      // linger until OS TCP timeout; the close handler owns reconnection.
      log.warn(
        `relay socket unresponsive — ping unanswered for ${Date.now() - this.awaitingPongSince}ms ` +
        `(probe interval ${HEARTBEAT_INTERVAL}ms), peers=${[...this.sessions.keys()].join(",") || "none"} ` +
        `sealed=${this.sessions.size}; closing to trigger reconnect`,
      );
      this.ws.close();
      return;
    }
    this.awaitingPong = true;
    this.awaitingPongSince = Date.now();
    this.sendJson({ type: "ping" });
  }

  protected startHeartbeat(): void {
    this.stopHeartbeat();
    this.awaitingPong = false;
    this.heartbeatTimer = setInterval(() => this.heartbeatTick(), HEARTBEAT_INTERVAL);
    this.heartbeatTimer?.unref?.();
  }

  protected stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  protected scheduleReconnect(): void {
    // Equal jitter (PR#49): the SCHEDULED DELAY is uniform in [backoff/2, backoff];
    // the stored `backoff` stays deterministic and doubles for the next attempt.
    const delay = this.backoff / 2 + Math.random() * (this.backoff / 2);
    log.info(`Reconnecting in ${Math.round(delay)}ms...`);
    this.reconnectTimer = setTimeout(() => {
      this.backoff = Math.min(this.backoff * 2, MAX_BACKOFF);
      this.doConnect();
    }, delay);
  }

  protected cleanup(): void {
    // Cleared rather than carried across the redial, even though the outbox is
    // plaintext and could be re-sealed: after lazy hydration the backlog at a
    // drop is small, tier-3 view state (trees, snapshots, session list) is
    // re-pulled by the app's hydrators on the next establishment, and tier-2
    // replies are failed fast by the app's pending registry the moment the
    // session drops — so replaying it would only put stale bytes ahead of the
    // re-sync.
    for (const session of this.sessions.values()) {
      if (!this.centralControlsPeer(session.peerId)) continue;
      this.recordQueueDrop("socket-closed", session.scheduler.clear());
    }
    this.stopHeartbeat();
    this.awaitingPong = false;
    for (const attempt of this.pending.values()) {
      if (this.centralControlsPeer(attempt.peerId)) this.stopHalfOpenTimer(attempt);
    }
    if (![...this.sessions.keys()].some((id) => !this.centralControlsPeer(id))) this.stopLiveness();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.finishRateLimitBurst();
    this.outboundFrameDiagnostics.length = 0;
    this.droppedFrames = 0;
    this.droppedFramesAt = 0;
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
