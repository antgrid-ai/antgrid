import { sign, createPrivateKey, randomBytes } from "node:crypto";
import { logger } from "./logger";

import { rawSeedToPkcs8 } from "./e2e";

import { ServerMessage, buildHelloSigBody, normalizeRelayHost, type HelloMessage } from "antgrid-wire";

import { prunePushToken } from "./push/prune";
import { nextEpoch } from "./relay-epoch";
import { netwatch } from "./netwatch";

import type { PeerSessionOwnerOptions } from "./peer-session-owner";
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
export interface CentralControlOptions extends Pick<PeerSessionOwnerOptions, "identity" | "pairedPhones" | "onError" | "onDisconnected"> {
  onConnecting?: () => void;
  onControl?: (message: ServerMessage) => void;
  onBinary?: (bytes: Buffer) => void;
  consumePayloadError?: (message: RelayError) => boolean;
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

export interface RelayError { type: "error"; code: string; message: string; retryable: boolean; ref?: string; serverTime?: string; channel?: string; bytes?: number; }

export class CentralControlClient {

  ws: WebSocket | null = null;
  private generation = 0;

  intentionalClose = false;

  backoff = INITIAL_BACKOFF;

  heartbeatTimer: ReturnType<typeof setInterval> | null = null;

  /** True from the moment a heartbeat `ping` is sent until a reply (or any
   *  other inbound frame) proves the socket is still alive. */
  awaitingPong = false;

  /** When the outstanding probe went out; only meaningful while
   *  {@link awaitingPong}. */
  awaitingPongSince = 0;

  reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  authenticated = false;

  readonly epoch: number;

  /** Learned wall-clock correction from a clock-skew AUTH_FAILED. */
  clockOffsetMs = 0;

  clockOffsetApplied = false;

  /** The last relay `error` frame; its `retryable` decides reconnect on close. */
  lastError: { code: string; retryable: boolean } | null = null;

  constructor(private readonly opts: CentralControlOptions) {
    // Computed once per process and reused across every (re)connect: epoch
    // identifies this process INSTANCE, not this socket. A redial
    // presenting the same epoch relies on the relay's equal-epoch rule
    // (same key + equal epoch ⇒ newest socket wins) to evict its own
    // half-open zombie; minting per dial instead would let a stale process
    // out-epoch and displace a legitimately newer one via the shared counter.
    this.epoch = opts.abDir ? nextEpoch(opts.abDir) : Math.floor(Date.now() / 1000);
  }

  connect(): void {
    if (this.ws && this.ws.readyState <= WebSocket.OPEN) return;
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

  doConnect(): void {
    const generation = ++this.generation;
    this.cleanup();
    this.ws?.close();
    this.authenticated = false;
    this.lastError = null;
    this.opts.onConnecting?.();

    log.debug(`Connecting to ${this.opts.url}`);
    const ws = this.ws = new WebSocket(this.opts.url);

    ws.addEventListener("open", () => {
      if (generation !== this.generation || this.intentionalClose) return;
      log.info(`Connected to relay at ${this.opts.url}`);
      this.ws = ws;
      // Backoff is reset ONLY on `welcome`, never on socket open (a socket that
      // opens then fails auth must keep backing off — PR#49 carry-over).
      void this.sendHello();
    });

    ws.addEventListener("message", (event) => {
      if (generation !== this.generation || this.intentionalClose) return;
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
      if (generation !== this.generation || this.intentionalClose) return;
      this.authenticated = false;
      this.ws = null;
      this.cleanup();
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
      if (generation !== this.generation || this.intentionalClose) return;
      // Object-first: a bare trailing arg is dropped when the message has no
      // printf placeholder, so the actual error detail would be lost.
      log.error({ err }, "WebSocket error");
    });
  }

  async sendHello(): Promise<void> {
    const generation = this.generation;
    const { identity } = this.opts;
    let licenseToken: string;
    try {
      licenseToken = await this.opts.getLicenseToken();
    } catch (err) {
      if (generation !== this.generation || this.intentionalClose) return;
      log.error({ err }, "Failed to get license token");
      this.opts.onError?.("LICENSE_INVALID", String(err));
      this.ws?.close();
      return;
    }
    if (generation !== this.generation || this.intentionalClose) return;
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

  handleTextMessage(raw: string): void {
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
        this.opts.onControl?.(msg);
        log.info("Authenticated with relay as %s (epoch %d)", msg.deviceId, msg.epoch);
        this.opts.onAuthenticated?.();
        break;
      case "stream-opened":
      case "stream-closed":
      case "peer-online":
      case "peer-offline":
        this.opts.onControl?.(msg);
        break;
      case "peer-policy-changed":
        this.opts.onPeerPolicyChanged?.(msg.generation);
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

  handleErrorFrame(msg: { code: string; message: string; retryable: boolean; ref?: string; serverTime?: string; channel?: string; bytes?: number }): void {
    if (this.opts.consumePayloadError?.({ type: "error", ...msg })) return;
    this.lastError = { code: msg.code, retryable: msg.retryable };

    // Clock-skew self-heal: learn the offset and let the retryable reconnect
    // re-hello with a corrected `ts`.
    if (msg.code === "AUTH_FAILED" && msg.serverTime) this.applyClockOffset(msg.serverTime);

    log.error(
      `Relay error: device=${this.opts.identity.deviceId} ` +
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

  applyClockOffset(serverTime: string): void {
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

  handleBinaryFrame(buf: Buffer): void {
    this.opts.onBinary?.(buf);
  }

  /** Send a push:deliver control frame to the relay (blind FCM/APNs forward). A
   *  top-level control message on OUR socket — the relay itself consumes it. */
  sendPushDeliver(msg: { pushToken: string; provider: "fcm" | "apns"; blob: { epk: string; box: string } }): void {
    this.sendJson({ type: "push:deliver", ...msg });
  }

  sendBinary(frame: Uint8Array<ArrayBuffer>): boolean {
    if (this.ws?.readyState !== WebSocket.OPEN) return false;
    this.ws.send(frame);
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
  sendJson(data: object): void {
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
    this.generation++;
    this.authenticated = false;
    this.intentionalClose = true;
    this.cleanup();
    this.ws?.close();
    this.ws = null;
  }

  heartbeatTick(): void {
    if (this.ws?.readyState !== WebSocket.OPEN) return;
    if (this.awaitingPong) {
      // Half-open socket (e.g. after machine sleep): our previous probe went
      // unanswered for a full interval. Force-close rather than leaving it to
      // linger until OS TCP timeout; the close handler owns reconnection.
      log.warn(
        `relay socket unresponsive — ping unanswered for ${Date.now() - this.awaitingPongSince}ms ` +
        `(probe interval ${HEARTBEAT_INTERVAL}ms); closing to trigger reconnect`,
      );
      this.ws.close();
      return;
    }
    this.awaitingPong = true;
    this.awaitingPongSince = Date.now();
    this.sendJson({ type: "ping" });
  }

  startHeartbeat(): void {
    this.stopHeartbeat();
    this.awaitingPong = false;
    this.heartbeatTimer = setInterval(() => this.heartbeatTick(), HEARTBEAT_INTERVAL);
    this.heartbeatTimer?.unref?.();
  }

  stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  scheduleReconnect(): void {
    // Equal jitter (PR#49): the SCHEDULED DELAY is uniform in [backoff/2, backoff];
    // the stored `backoff` stays deterministic and doubles for the next attempt.
    const delay = this.backoff / 2 + Math.random() * (this.backoff / 2);
    log.info(`Reconnecting in ${Math.round(delay)}ms...`);
    this.reconnectTimer = setTimeout(() => {
      this.backoff = Math.min(this.backoff * 2, MAX_BACKOFF);
      this.doConnect();
    }, delay);
  }

  cleanup(): void {
    this.stopHeartbeat();
    this.awaitingPong = false;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

}
