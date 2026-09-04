import { sign, createPrivateKey, randomBytes } from "node:crypto";
import { logger } from "./logger";
const log = logger.child({ component: "relay-client" });
import type { DeviceIdentity } from "./device";
import {
  buildTranscript, deriveSessionKeys, agentConfirmTag, phoneConfirmTag,
  verifyConfirmTag, E2eTransport, signTranscript, verifyTranscriptSig,
  zeroizeSessionKeys, rawSeedToPkcs8, type SessionKeys,
} from "./e2e";
import { deriveSharedSecret, type EphemeralKeypair } from "./key-exchange";
import { parseMessageFast, type AbMessage } from "./protocol";
import { baseSlotDeviceId, slotMachineDeviceId } from "./relay-slot";
import { parseTunnelMessage } from "./tunnel-protocol";
import {
  encodeRouteFrame,
  decodeRouteFrame,
  FrameError,
  FrameKind,
  buildFragments,
  FRAG_THRESHOLD,
  MAX_TRANSFER_BYTES,
  TRANSFER_TIMEOUT_MS,
  GLOBAL_REASSEMBLY_BUDGET,
  ServerMessage,
  buildHelloSigBody,
  normalizeRelayHost,
  CONTROL_STREAM_ID,
  type HelloMessage,
  type RouteHeader,
} from "antgrid-wire";
import type { MessageBus, Channel, TransportSubscriber } from "./message-bus";
import type { PairedPhonesStore } from "./paired-phones";
import type { TrustedPeersProvider } from "./trusted-peers";
import { FragReassembler, type SharedByteBudget } from "./frag-reassembler";
import { prunePushToken } from "./push/prune";
import { nextEpoch } from "./relay-epoch";
import {
  StreamMux,
  type AttachStreamOpts,
  type PeerSessionView,
  type SendTarget,
  type StreamHandle,
} from "./stream-mux";

export interface RelayClientOptions {
  url: string;
  identity: DeviceIdentity;
  /** Machine dir for the persistent connection-epoch counter. */
  abDir?: string;
  /** Called on each (re)handshake to get a fresh ephemeral keypair for E2E. */
  generateKeypair: () => EphemeralKeypair;
  /** Fired on `welcome` — the single 1-RTT authentication event. */
  onAuthenticated?: () => void;
  /** Fired only when the relay rejected our license with an
   *  identity-dead verdict (LICENSE_INVALID | LICENSE_REVOKED). LICENSE_EXPIRED
   *  is recoverable by time (see {@link redialWithFreshToken}) and does NOT fire
   *  this; SUPERSEDED must NEVER call it — re-enrolling would be
   *  wrong advice. */
  onAuthRevoked?: () => void;
  onPeerOnline?: (peerId: string) => void;
  onPeerOffline?: (peerId: string) => void;
  /** One app device's E2E session established (its app:ready confirm verified).
   *  Fires once per DEVICE, so a machine with two apps attached reports twice —
   *  `peerId` says which, and a joining device needs its own state replay even
   *  though its sibling is already up to date. */
  onHandshakeComplete?: (capabilities: { checkoutRouting: boolean; peerId: string }) => void;
  onMessage?: (msg: AbMessage) => void;
  onTunnelMessage?: (msg: unknown, peerId: string) => void;
  onDisconnected?: () => void;
  onError?: (code: string, message: string) => void;
  autoReconnect?: boolean;
  /**
   * Returns the license JWT to present in `hello`. Called per (re)connect so
   * refreshed tokens are picked up automatically. Required — the agent must
   * always present a token.
   */
  getLicenseToken: () => Promise<string> | string;
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

const HEARTBEAT_INTERVAL = 25_000;
const INITIAL_BACKOFF = 1_000;
const MAX_BACKOFF = 30_000;
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
/** How long a session whose device the relay reports offline is kept before its
 *  keys are dropped. It is kept at all so a screen-lock or a tunnel flap comes
 *  back without a rekey, and so push targeting can still name the device; past
 *  this the app has plainly gone and the keys are dead weight. */
export const UNREACHABLE_SESSION_TTL_MS = 300_000;
// Relay rate limiting uses a one-second pair window. Keep a little extra local
// history so the diagnostic still includes the earliest sends after the error
// frame makes the round trip through a busy local event loop.
const RATE_DIAGNOSTIC_WINDOW_MS = 1_500;
const RATE_LIMIT_BURST_MS = 1_000;
const MAX_OUTBOUND_DIAGNOSTIC_FRAMES = 4_096;
const MAX_DIAGNOSTIC_TYPES = 8;
const FRAG_ID_SEED = randomBytes(8).toString("hex");
let fragIdCounter = 0;

/** Identity-dead license verdicts that trigger the kept `auth_revoked`
 *  exception. LICENSE_EXPIRED is deliberately NOT here: it is recoverable by
 *  time (a lapsed-then-renewed subscription), so it stops reconnecting but keeps
 *  token maintenance re-minting; a fresh mint redials (redialWithFreshToken). */
const LICENSE_AUTH_DEAD = new Set<string>(["LICENSE_INVALID", "LICENSE_REVOKED"]);

export type FragmentForSendResult =
  | { ok: true; frames: string[] }
  | { ok: false; error: { code: "MESSAGE_TOO_LARGE"; message: string } };

interface OutboundFrameDiagnostic {
  at: number;
  type: string;
  channel: Channel;
  bytes: number;
}

interface RateLimitBurst {
  startedAt: number;
  errors: number;
  timer: ReturnType<typeof setTimeout>;
  outboundAtOnset: string;
}

/** A half-open handshake attempt: keys derived, the app's confirm not yet seen.
 *  Receive-only until it is promoted (make-before-break). */
interface PendingAttempt {
  attemptId: string;
  transport: E2eTransport;
  sessionKeys: SessionKeys;
  /** The app's relay SLOT — the route address this attempt is answered on. */
  peerId: string;
  expiry: ReturnType<typeof setTimeout> | null;
}

/** One confirmed E2E session with one app device. Everything a session owns is
 *  here rather than on the client, because the client now holds several. */
interface PeerSession {
  attemptId: string;
  transport: E2eTransport;
  sessionKeys: SessionKeys;
  /** The app's relay SLOT — the route address every frame for this session is
   *  addressed to. Anchoring outgoing addressing to the session is what keeps a
   *  sibling's bare presence from repointing frames away from their owner. */
  peerId: string;
  /** Session-scoped: a rekey must not inherit the previous app's guarantee. */
  checkoutRouting: boolean;
  /** Relay presence. An unreachable session keeps its keys (see
   *  {@link UNREACHABLE_SESSION_TTL_MS}) but is not counted as live. */
  reachable: boolean;
  unreachableSince: number;
  lastSealedRecvAt: number;
  missedPongs: number;
  /** Fragments are per-session: two devices interleave transfers on one socket,
   *  and a shared reassembler would splice their streams together. */
  frag: FragReassembler;
}

function formatDiagnosticBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)}MiB`;
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

/**
 * The single machine↔relay connection. Authenticates with one signed
 * `hello`, then runs reactive/acked E2E sessions and multiplexes project
 * streams inside them.
 *
 * One session PER APP DEVICE, not one per machine: a phone and a desktop app
 * drive the same machine at the same time, each with its own keys, liveness and
 * fragment stream, all over this one socket. A verified client-hello from a
 * device we have no session with is ADMITTED ALONGSIDE the others — it never
 * displaces them. Only two things end a session: the same device rekeying
 * (make-before-break, which replaces its own session and nobody else's), and
 * capacity ({@link MAX_APP_SESSIONS}), which evicts the least useful session and
 * tells it so.
 *
 * Consequently nothing here may ask "who is the peer". Outbound sends name a
 * {@link SendTarget}; inbound frames carry the sending session's `peerId` all
 * the way to the bus, so read state and replies belong to the device that asked.
 */
export class RelayClient {
  private ws: WebSocket | null = null;
  private intentionalClose = false;
  private backoff = INITIAL_BACKOFF;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  /** True from the moment a heartbeat `ping` is sent until a reply (or any
   *  other inbound frame) proves the socket is still alive. */
  private awaitingPong = false;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private authenticated = false;
  private readonly epoch: number;
  /** Learned wall-clock correction from a clock-skew AUTH_FAILED. */
  private clockOffsetMs = 0;
  private clockOffsetApplied = false;
  /** The last relay `error` frame; its `retryable` decides reconnect on close. */
  private lastError: { code: string; retryable: boolean } | null = null;

  // E2E session state, keyed by the app's relay SLOT (the route address). A
  // device appears in `pending` while its candidate keys are receive-only, and
  // moves to `sessions` when its app:ready confirm verifies (make-before-break).
  // Both are keyed by device so one device's rekey cannot disturb another's.
  private readonly sessions = new Map<string, PeerSession>();
  private readonly pending = new Map<string, PendingAttempt>();
  /** One reassembly ceiling for the whole machine, shared by every session's
   *  reassembler — N devices must not each be handed the full budget. */
  private reassemblyBudget: SharedByteBudget = { used: 0, limit: GLOBAL_REASSEMBLY_BUDGET };
  /** One timer for every session: liveness is cheap per session and a timer
   *  each would be N unrefed intervals to leak. */
  private livenessTimer: ReturnType<typeof setInterval> | null = null;

  // Phone Ed25519 pubkeys (standard base64, raw 32 bytes) resolved from the
  // account peers inventory at handshake, keyed by the phone's deviceId (==
  // relay peer id).
  private phoneEd25519ByDeviceId = new Map<string, string>();

  private bus: MessageBus | null = null;
  private busUnsub: (() => void) | null = null;
  private readonly mux: StreamMux;
  private fragSweep: ReturnType<typeof setInterval> | null = null;
  private outboundFrameDiagnostics: OutboundFrameDiagnostic[] = [];
  private rateLimitBurst: RateLimitBurst | null = null;
  private droppedFrames = 0;
  private droppedFramesAt = 0;

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

  /** @deprecated One machine now has several attached apps, so "the" peer is not
   *  a question with an answer. Reads the FIRST established session, which is
   *  right only for callers asking "is anything remote attached at all"; every
   *  caller that acts on WHICH device must take the peerId threaded to it and
   *  use {@link peerPubkeyFor}. */
  currentPeerPubkey(): string | null {
    for (const session of this.sessions.values()) {
      const pub = this.phoneEd25519ByDeviceId.get(session.peerId);
      if (pub) return pub;
    }
    return null;
  }

  /** @deprecated Capability is per device — see
   *  {@link anySessionSupportsCheckoutRouting}, which this forwards to. */
  get peerSupportsCheckoutRouting(): boolean {
    return this.anySessionSupportsCheckoutRouting();
  }

  /** Attached devices for a diagnostic line. A relay error or a rate limit is
   *  now a question about several sessions, so naming only one would point the
   *  operator at the wrong device as often as not. */
  private describePeers(): string {
    if (this.sessions.size === 0) return "none";
    return [...this.sessions.values()]
      .map((s) => (s.reachable ? s.peerId : `${s.peerId}(offline)`))
      .join(",");
  }

  private viewOf(session: PeerSession): PeerSessionView {
    return {
      peerId: session.peerId,
      peerPubkey: this.phoneEd25519ByDeviceId.get(session.peerId) ?? "",
      checkoutRouting: session.checkoutRouting,
      reachable: session.reachable,
    };
  }

  /** True while at least one session's device is reachable over the relay. The
   *  coarse `peerOnline` the mux and the cores run on. */
  private hasReachableSession(): boolean {
    for (const session of this.sessions.values()) {
      if (session.reachable) return true;
    }
    return false;
  }

  /** Fire the coarse peer-offline exactly when the LAST reachable session goes.
   *  Idempotent in the mux, so every path that can lose a session calls it. */
  private notifyOfflineIfLast(): void {
    if (!this.hasReachableSession()) this.mux.notifyPeerOffline();
  }

  /** Ensure `phoneEd25519ByDeviceId` has an entry for `peerId` by recovering it
   *  from the persistent phone registry. Used on a trusted reconnect
   *  (peer-online with no fresh handshake) so `currentPeerPubkey()` still
   *  resolves after an agent restart — without it the control-plane dispatch
   *  drops every frame (`if (!pk) return`). No-op when already known or
   *  unregistered. */
  private backfillPeerPubkey(peerId: string): void {
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
  private isForeignSlot(peerId: string): boolean {
    const machine = slotMachineDeviceId(peerId);
    return machine !== null && machine !== this.opts.identity.deviceId;
  }

  constructor(private opts: RelayClientOptions) {
    // Computed once per process and reused across every (re)connect: epoch
    // identifies this process INSTANCE, not this socket. A redial
    // presenting the same epoch relies on the relay's equal-epoch rule
    // (same key + equal epoch ⇒ newest socket wins) to evict its own
    // half-open zombie; minting per dial instead would let a stale process
    // out-epoch and displace a legitimately newer one via the shared counter.
    this.epoch = opts.abDir ? nextEpoch(opts.abDir) : Math.floor(Date.now() / 1000);
    this.mux = new StreamMux({
      openStream: (id) => this.sendJson({ type: "stream-open", streamId: id }),
      closeStream: (id) => this.sendJson({ type: "stream-close", streamId: id }),
      sendEnvelope: (id, msg, channel, target) => this.sendAppEnvelope(id, msg, channel, target),
      peerSession: (peerId) => this.peerSession(peerId),
    });
    this.startFragSweep();
  }

  /** Attach a project's bus as a multiplexed stream on this machine socket. */
  attachStream(bus: MessageBus, opts: AttachStreamOpts): StreamHandle {
    return this.mux.attach(bus, opts);
  }

  /** A reassembler owned by one session. Its completions are tagged with that
   *  session's peerId, which is what keeps a reassembled transfer attributable
   *  to the device that requested it. */
  private newFragReassembler(peerId: string): FragReassembler {
    return new FragReassembler({
      timeoutMs: TRANSFER_TIMEOUT_MS,
      budget: this.reassemblyBudget,
      onComplete: (json) => this.routeReassembledEnvelope(json, peerId),
      onAbort: (hint) => {
        if (hint?.type === "file:content") {
          log.warn("Fragmented file content transfer interrupted for %s", hint.key);
          this.opts.onError?.("TRANSFER_INTERRUPTED", `Transfer interrupted for ${hint.key}`);
        }
      },
    });
  }

  private startFragSweep(): void {
    if (this.fragSweep) return;
    this.fragSweep = setInterval(() => {
      for (const session of this.sessions.values()) session.frag.sweep();
    }, 2000);
    this.fragSweep.unref?.();
  }

  private stopFragSweep(): void {
    if (!this.fragSweep) return;
    clearInterval(this.fragSweep);
    this.fragSweep = null;
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

  private doConnect(): void {
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
      this.mux.notifyPeerOffline();
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

  private async sendHello(): Promise<void> {
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

  private handleTextMessage(raw: string): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      log.warn("Received non-JSON message from relay, dropping");
      return;
    }

    const result = ServerMessage.safeParse(parsed);
    if (!result.success) {
      log.warn("Received invalid relay message, dropping: %s", result.error.message);
      return;
    }
    const msg = result.data;
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
        // UNREACHABLE_SESSION_TTL_MS is what eventually reaps it.
        {
          const session = this.sessions.get(msg.peerId);
          if (session && session.reachable) {
            session.reachable = false;
            session.unreachableSince = Date.now();
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

  private handleErrorFrame(msg: { code: string; message: string; retryable: boolean; ref?: string; serverTime?: string }): void {
    // A stream-open rejection (ref === a live streamId: STREAM_LIMIT_EXCEEDED
    // from a current relay, or the retired SESSION_LIMIT_EXCEEDED from an older
    // one): the socket and every other stream stay live, so it
    // must NOT be recorded as `lastError` — otherwise a later unrelated close
    // would read its retryable:false and wrongly stop reconnecting.
    if (msg.ref && this.mux.onError(msg.ref, msg.code, msg.message)) return;

    // Only socket-affecting errors decide reconnect on the next close.
    this.lastError = { code: msg.code, retryable: msg.retryable };

    if (msg.code === "MESSAGE_RATE_LIMITED") {
      this.handleMessageRateLimited(msg.message);
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

  private applyClockOffset(serverTime: string): void {
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

  private handleBinaryFrame(buf: Buffer): void {
    let decoded: { header: unknown; payload: Uint8Array; kind: FrameKind };
    try {
      decoded = decodeRouteFrame(buf);
    } catch (e) {
      if (e instanceof FrameError) {
        log.warn("Received malformed frame: %s", e.reason);
        return;
      }
      throw e;
    }
    const header = decoded.header as { type?: string; from?: string; channel?: string };
    if (header.type !== "message" || !header.from || !header.channel) {
      log.warn("Invalid route header on binary frame");
      return;
    }
    const channel: Channel = header.channel === "preview" ? "preview" : "control";
    // A structurally valid route frame proves the socket delivered real bytes —
    // sealed/binary E2E traffic (terminal, file data) must count as liveness
    // the same as a JSON pong, even if the sealed payload itself later fails to
    // decrypt (decrypt-or-drop). Mirrors handleTextMessage's clear-before-dispatch.
    this.awaitingPong = false;

    if (decoded.kind === FrameKind.handshake) {
      this.handleHandshakeFrame(decoded.payload, header.from);
      return;
    }
    // kind === sealed: decrypt-or-drop.
    this.handleSealedFrame(Buffer.from(decoded.payload), channel, header.from);
  }

  /** Kind-1 plaintext admits exactly the two handshake types; the agent only
   *  ever consumes client-hello. A frame that is not a signature-valid
   *  client-hello is dropped with a log. */
  private handleHandshakeFrame(payload: Uint8Array, from: string): void {
    let obj: { type?: string } | null = null;
    try {
      obj = JSON.parse(Buffer.from(payload).toString("utf8"));
    } catch {
      log.warn("Dropping non-JSON kind-1 handshake frame");
      return;
    }
    if (obj?.type === "handshake:client-hello") {
      this.handleClientHello(obj as { attemptId?: string; pubkey?: string; nonce?: string; sig?: string }, from);
      return;
    }
    log.warn("Dropping unexpected kind-1 handshake frame (type=%s)", obj?.type);
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
  private handleSealedFrame(payload: Buffer, channel: Channel, from: string): void {
    const hinted = this.sessions.get(from);
    if (hinted && this.tryOpenSession(hinted, payload, channel)) return;
    const hintedPending = this.pending.get(from);
    if (hintedPending && this.tryOpenPending(hintedPending, payload, channel)) return;

    for (const session of this.sessions.values()) {
      if (session === hinted) continue;
      if (this.tryOpenSession(session, payload, channel)) return;
    }
    for (const attempt of this.pending.values()) {
      if (attempt === hintedPending) continue;
      if (this.tryOpenPending(attempt, payload, channel)) return;
    }
    log.warn("Failed to open sealed frame (len=%d) from %s, dropping", payload.length, from);
  }

  private tryOpenSession(session: PeerSession, payload: Buffer, channel: Channel): boolean {
    const pt = session.transport.open(payload);
    if (pt === null) return false;
    session.lastSealedRecvAt = Date.now();
    session.missedPongs = 0;
    this.onSealedPlaintext(pt, channel, session.peerId, session);
    return true;
  }

  /** A candidate's keys are receive-only until its confirm verifies, so nothing
   *  it opens counts as liveness and it owns no reassembler — the only thing it
   *  can legitimately carry is the app:ready that promotes it. */
  private tryOpenPending(attempt: PendingAttempt, payload: Buffer, channel: Channel): boolean {
    const pt = attempt.transport.open(payload);
    if (pt === null) return false;
    this.onSealedPlaintext(pt, channel, attempt.peerId, null);
    return true;
  }

  private onSealedPlaintext(
    plaintext: string,
    channel: Channel,
    peerId: string,
    session: PeerSession | null,
  ): void {
    // Fragmented app traffic → buffer; onComplete routes the reassembled envelope.
    if (session?.frag.accept(plaintext)) return;

    let obj: unknown;
    try {
      obj = JSON.parse(plaintext);
    } catch {
      log.warn("Dropping non-JSON sealed plaintext");
      return;
    }
    if (obj && typeof obj === "object") {
      // Bare session frame (top-level `type`) vs app envelope (`{ s?, m }`). App
      // traffic is always wrapped, so a top-level `type` is unambiguously a
      // session/liveness frame.
      if (typeof (obj as { type?: unknown }).type === "string") {
        this.handleSessionFrame(obj as { type: string; attemptId?: string; confirm?: string }, peerId);
        return;
      }
      if ("m" in (obj as object)) {
        this.routeAppEnvelope(obj as { s?: string; m: unknown }, channel, peerId);
        return;
      }
    }
    log.warn("Dropping unrecognized sealed plaintext");
  }

  private routeReassembledEnvelope(json: string, peerId: string): void {
    let env: { s?: string; m?: unknown };
    try {
      env = JSON.parse(json);
    } catch {
      log.warn("Dropping non-JSON reassembled envelope");
      return;
    }
    if (!env || typeof env !== "object" || !("m" in env)) {
      log.warn("Dropping malformed reassembled envelope");
      return;
    }
    // Reassembled transfers are control-tier (file:content, diffs); the channel
    // only affects the AbMessage dispatch tag, which is control for these.
    this.routeAppEnvelope(env as { s?: string; m: unknown }, "control", peerId);
  }

  private routeAppEnvelope(env: { s?: string; m: unknown }, channel: Channel, peerId: string): void {
    const s = env.s;
    const streamId = typeof s === "string" && s !== CONTROL_STREAM_ID ? s : null;
    const mJson = JSON.stringify(env.m);
    if (streamId === null) {
      this.dispatchControlPlane(mJson, channel, peerId);
      return;
    }
    if (!this.mux.dispatchInbound(streamId, mJson, channel, peerId)) {
      log.warn("Dropping inbound frame for unknown streamId %s", streamId);
    }
  }

  private dispatchControlPlane(mJson: string, channel: Channel, peerId: string): void {
    const msg = parseMessageFast(mJson);
    if (msg) {
      this.opts.onMessage?.(msg);
      this.bus?.dispatchInbound(msg, channel, "relay", peerId);
      return;
    }
    const tunnel = parseTunnelMessage(mJson);
    if (tunnel) this.opts.onTunnelMessage?.(tunnel, peerId);
  }

  // --- E2E session frames ---

  private handleSessionFrame(
    obj: { type: string; attemptId?: string; confirm?: string; capabilities?: { checkoutRouting?: boolean } },
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
      default:
        log.warn("Dropping unexpected sealed session frame (type=%s)", obj.type);
    }
  }

  private handleClientHello(obj: { attemptId?: string; pubkey?: string; nonce?: string; sig?: string }, from: string): void {
    const { attemptId, pubkey, nonce, sig } = obj;
    if (!attemptId || !pubkey || !nonce || !sig) {
      log.warn("client-hello missing fields — dropping");
      return;
    }
    const peerId = from;
    if (!peerId) return;
    const seedB64 = this.opts.identity.ed25519PrivateKey;
    if (!seedB64) {
      log.warn("No Ed25519 seed to sign agent-hello — dropping client-hello");
      return;
    }
    const clientPubkey = Buffer.from(pubkey, "base64");
    if (clientPubkey.length !== 32) {
      log.warn("Invalid client pubkey length: %d", clientPubkey.length);
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
        log.warn("Rejecting client-hello: peer %s is unknown to every identity source (cache, account inventory, paired phones)", peerId);
      } else {
        log.warn("Rejecting client-hello: none of the %d known identities for peer %s verifies the transcript signature", resolved.known, peerId);
      }
      return;
    }
    const phoneEd25519PubB64 = resolved.pub;

    // Cache the verified identity for POST-handshake authorization
    // (currentPeerPubkey/backfillPeerPubkey): a trust-only phone (account
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
      log.info("Registered account-trusted phone %s", peerBaseId);
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
    this.sendPayload(
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
    log.info("E2E handshake keys derived for %s (attempt %s), waiting for app:ready", peerId, attemptId);
  }

  /** Make room for a device that holds neither a session nor a candidate. The
   *  unreachable go first (their device is already gone); otherwise the session
   *  that has been silent longest. Only a REACHABLE evictee is told — a
   *  session-takeover sealed for a device the relay says is offline reaches
   *  nobody, and the frame is the one thing that keeps a displaced app from
   *  rekeying straight back into the same eviction. */
  private evictForCapacity(peerId: string): void {
    if (this.sessions.has(peerId) || this.pending.has(peerId)) return;
    while (this.sessions.size + this.pending.size >= MAX_APP_SESSIONS) {
      // A half-open candidate has proved nothing yet, so it goes before any
      // confirmed session — and silently, since there is no session to end.
      const stale = [...this.pending.values()][0];
      if (stale) {
        log.info("Session capacity (%d) reached — discarding half-open attempt for %s", MAX_APP_SESSIONS, stale.peerId);
        this.tearDownPending(stale.peerId);
        continue;
      }
      const victim = this.pickEvictable();
      if (!victim) return;
      log.info(
        "Session capacity (%d) reached — evicting %s to admit %s",
        MAX_APP_SESSIONS,
        victim.peerId,
        peerId,
      );
      if (victim.reachable) {
        try {
          this.sendSessionFrame({ type: "session-takeover" }, victim.transport, victim.peerId);
        } catch {
          // evictee unreachable — teardown proceeds regardless
        }
      }
      this.dropSession(victim.peerId);
    }
  }

  /** Unreachable sessions first, then the least recently active. */
  private pickEvictable(): PeerSession | null {
    let worst: PeerSession | null = null;
    for (const session of this.sessions.values()) {
      if (!worst) { worst = session; continue; }
      if (worst.reachable !== session.reachable) {
        if (!session.reachable) worst = session;
        continue;
      }
      if (session.lastSealedRecvAt < worst.lastSealedRecvAt) worst = session;
    }
    return worst;
  }

  private handleAppReady(
    obj: { attemptId?: string; confirm?: string; capabilities?: { checkoutRouting?: boolean } },
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
        log.warn("app:ready confirm tag invalid (attempt %s) — dropping", attemptId);
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
        reachable: true,
        unreachableSince: 0,
        lastSealedRecvAt: now,
        missedPongs: 0,
        // Reuse the replaced session's reassembler: a rekey is the same device
        // continuing, and its in-flight transfers survive the key swap.
        frag: live?.frag ?? this.newFragReassembler(peerId),
      };
      this.pending.delete(peerId);
      this.stopHalfOpenTimer(attempt);
      this.sessions.set(peerId, session);
      if (live) {
        zeroizeSessionKeys(live.sessionKeys);
        live.transport.zeroize();
      }
      this.startLiveness();
      this.sendSessionFrame({ type: "established", attemptId }, session.transport, peerId);
      log.info("E2E session established with %s (attempt %s)", peerId, attemptId);
      this.opts.onHandshakeComplete?.({ checkoutRouting: session.checkoutRouting, peerId });
      this.mux.notifyPeerOnline();
      return;
    }

    log.warn("app:ready for unknown attempt %s — dropping", attemptId);
  }

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
  private resolvePhoneEd25519PubB64(
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
    this.sendAppEnvelope(CONTROL_STREAM_ID, msg, "control", target);
  }

  /** Send a AbMessage on a specific channel (control plane). */
  sendOnChannel(msg: AbMessage, channel: Channel, target?: SendTarget): void {
    this.sendAppEnvelope(CONTROL_STREAM_ID, msg, channel, target);
  }

  /** Send a tunnel-protocol message on the preview channel (control plane).
   *  `target` names the session whose request this answers. */
  sendTunnel(data: object, target?: SendTarget): void {
    this.sendAppEnvelope(CONTROL_STREAM_ID, data, "preview", target);
  }

  /** Send a push:deliver control frame to the relay (blind FCM/APNs forward). A
   *  top-level control message on OUR socket — the relay itself consumes it. */
  sendPushDeliver(msg: { pushToken: string; provider: "fcm" | "apns"; blob: { epk: string; box: string } }): void {
    this.sendJson({ type: "push:deliver", ...msg });
  }

  /**
   * Wrap `msg` in the `{ s?, m }` stream envelope, fragment the ENVELOPE json
   * (so `s` survives fragmentation), then seal and send it ONCE PER RECIPIENT
   * session — sealing is per-session by construction, since each device's keys
   * are its own. Control-plane traffic uses `CONTROL_STREAM_ID` (`s` omitted).
   * Dropped — never sent in cleartext — when no recipient has a session. A
   * too-large `tunnel:http-response` degrades to a sealed 413 so the phone's
   * preview request fails fast instead of hanging.
   *
   * Fragmenting once and sealing N times is deliberate: every device gets the
   * SAME transfer id, which is what lets an abort be reported the same way to
   * all of them, and the fragment ids stay unique process-wide either way.
   */
  private sendAppEnvelope(
    streamId: string,
    msg: unknown,
    channel: Channel,
    target: SendTarget = { kind: "broadcast" },
  ): "sent" | "dropped" | "too-large" {
    const type = (msg as { type?: string } | null)?.type;
    const recipients = this.resolveRecipients(target);
    if (recipients.length === 0) {
      // NEVER send app traffic in cleartext (the relay is zero-knowledge). During
      // a rekey window services may still emit; dropping is correct — the phone
      // re-syncs control state after the next establishment.
      log.debug("Dropping outbound %s — no established session to seal it for", type ?? "message");
      this.handleUndeliverableTunnel("dropped", channel, msg, target);
      return "dropped";
    }

    const envelope =
      streamId && streamId !== CONTROL_STREAM_ID ? { s: streamId, m: msg } : { m: msg };
    const json = JSON.stringify(envelope);
    const key = this.messageFragKey(msg);
    const fragmented = fragmentForSend(json, type, key);
    if (!fragmented.ok) {
      log.warn("%s", fragmented.error.message);
      this.opts.onError?.(fragmented.error.code, fragmented.error.message);
      const outcome = fragmented.error.code === "MESSAGE_TOO_LARGE" ? "too-large" : "dropped";
      this.handleUndeliverableTunnel(outcome, channel, msg, target);
      return outcome;
    }

    for (const session of recipients) {
      for (const frame of fragmented.frames) {
        this.sendPayload(session.transport.seal(frame), session.peerId, channel, FrameKind.sealed, type ?? "app");
      }
    }
    return "sent";
  }

  /** Which sessions a {@link SendTarget} selects. An unreachable session is
   *  still a recipient: the relay queues nothing, but a device coming back from
   *  a brief flap opens what it missed, and dropping the send instead is how a
   *  screen-lock used to lose an answer outright. */
  private resolveRecipients(target: SendTarget): PeerSession[] {
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
  private handleUndeliverableTunnel(
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
      log.warn(
        "Tunnel response %s dropped (E2E session not established) — preview request will time out",
        requestId,
      );
    }
  }

  private messageFragKey(msg: unknown): string | undefined {
    const path = (msg as { path?: unknown } | null)?.path;
    return typeof path === "string" ? path : undefined;
  }

  /** Seal one bare session/liveness frame under `transport` (candidate keys for
   *  agent-ready; established keys for established/ping/pong) and address it to
   *  `to`. Keys and address are passed together on purpose: sealing for one
   *  device and routing to another is the failure this file has hit before, and
   *  it surfaces only as silence. */
  private sendSessionFrame(obj: object, transport: E2eTransport | undefined, to: string): void {
    if (!transport) return;
    const type = (obj as { type?: string }).type ?? "session";
    this.sendPayload(transport.seal(JSON.stringify(obj)), to, "control", FrameKind.sealed, type);
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

  /** `to` is the route address of the session whose keys sealed `data`. It is a
   *  required argument rather than client state because there is no longer a
   *  single peer to fall back on. */
  private sendPayload(
    data: Buffer | string,
    to: string,
    channel: Channel = "control",
    kind: FrameKind = FrameKind.sealed,
    diagnosticType = "transport",
  ): void {
    if (!to) {
      log.warn("Cannot send payload — no destination");
      return;
    }
    if (this.ws?.readyState !== WebSocket.OPEN) return;

    const payloadBytes = typeof data === "string" ? Buffer.from(data, "utf8") : data;
    const header: RouteHeader = { type: "message", to, channel };
    // `frame` is a fresh ArrayBuffer-backed Buffer (never shared); the cast
    // satisfies the WebSocket.send BufferSource type under TS 6's generic
    // Uint8Array.
    const frame = encodeRouteFrame(header, payloadBytes, kind) as Uint8Array<ArrayBuffer>;
    this.ws.send(frame);
    this.recordOutboundFrame(diagnosticType, channel, payloadBytes.length);
  }

  private recordOutboundFrame(type: string, channel: Channel, bytes: number): void {
    const now = Date.now();
    const cutoff = now - RATE_DIAGNOSTIC_WINDOW_MS;
    let stale = 0;
    while (
      stale < this.outboundFrameDiagnostics.length &&
      this.outboundFrameDiagnostics[stale].at < cutoff
    ) {
      stale++;
    }
    if (stale > 0) this.outboundFrameDiagnostics.splice(0, stale);
    if (this.droppedFramesAt < cutoff) {
      this.droppedFrames = 0;
      this.droppedFramesAt = 0;
    }

    if (this.outboundFrameDiagnostics.length >= MAX_OUTBOUND_DIAGNOSTIC_FRAMES) {
      const discarded = this.outboundFrameDiagnostics.splice(0, MAX_OUTBOUND_DIAGNOSTIC_FRAMES / 2);
      this.droppedFrames += discarded.length;
      this.droppedFramesAt = discarded[discarded.length - 1]!.at;
    }
    this.outboundFrameDiagnostics.push({ at: now, type, channel, bytes });
  }

  private formatOutboundRateDiagnostic(now = Date.now()): string {
    const cutoff = now - RATE_DIAGNOSTIC_WINDOW_MS;
    const grouped = new Map<string, { type: string; channel: Channel; frames: number; bytes: number }>();
    let totalFrames = 0;
    let totalBytes = 0;

    for (const sample of this.outboundFrameDiagnostics) {
      if (sample.at < cutoff) continue;
      totalFrames++;
      totalBytes += sample.bytes;
      const key = `${sample.type}\u0000${sample.channel}`;
      const entry = grouped.get(key) ?? {
        type: sample.type,
        channel: sample.channel,
        frames: 0,
        bytes: 0,
      };
      entry.frames++;
      entry.bytes += sample.bytes;
      grouped.set(key, entry);
    }

    const dropped = this.droppedFramesAt >= cutoff ? this.droppedFrames : 0;
    if (totalFrames === 0 && dropped === 0) return "no outbound frames captured";

    const ranked = [...grouped.values()].sort(
      (a, b) => b.frames - a.frames || b.bytes - a.bytes,
    );
    const shown = ranked.slice(0, MAX_DIAGNOSTIC_TYPES);
    const byType = shown
      .map((entry) =>
        `${entry.type}/${entry.channel}=${entry.frames} frame(s),${formatDiagnosticBytes(entry.bytes)}`
      )
      .join("; ");
    const more = ranked.length - shown.length;
    const elided = more > 0 ? `; +${more} more type(s)` : "";
    const truncated = dropped > 0
      ? ` dropped=${dropped} frame(s) past the ${MAX_OUTBOUND_DIAGNOSTIC_FRAMES}-sample cap — counts below are a floor;`
      : "";
    return `total=${totalFrames} frame(s),${formatDiagnosticBytes(totalBytes)};${truncated} byType=[${byType}${elided}]`;
  }

  private handleMessageRateLimited(message: string): void {
    const now = Date.now();
    if (this.rateLimitBurst && now - this.rateLimitBurst.startedAt < RATE_LIMIT_BURST_MS) {
      this.rateLimitBurst.errors++;
      return;
    }
    if (this.rateLimitBurst) this.finishRateLimitBurst();

    const outboundAtOnset = this.formatOutboundRateDiagnostic(now);
    log.error(
      `Relay rate limit: device=${this.opts.identity.deviceId} peers=${this.describePeers()} ` +
      `message="${message}" recentOutbound(${RATE_DIAGNOSTIC_WINDOW_MS}ms)={${outboundAtOnset}}`,
    );

    const timer = setTimeout(() => this.finishRateLimitBurst(), RATE_LIMIT_BURST_MS);
    timer.unref?.();
    this.rateLimitBurst = { startedAt: now, errors: 1, timer, outboundAtOnset };

    this.opts.onError?.("MESSAGE_RATE_LIMITED", message);
  }

  private finishRateLimitBurst(): void {
    const burst = this.rateLimitBurst;
    if (!burst) return;
    clearTimeout(burst.timer);
    this.rateLimitBurst = null;
    if (burst.errors <= 1) return;

    log.error(
      `Relay rate-limit burst summary: device=${this.opts.identity.deviceId} ` +
      `rejectedFrames=${burst.errors} duplicateCallbacksSuppressed=${burst.errors - 1} ` +
      `durationMs=${Date.now() - burst.startedAt} ` +
      `outboundAtOnset(${RATE_DIAGNOSTIC_WINDOW_MS}ms)={${burst.outboundAtOnset}}`,
    );
  }

  private sendJson(data: object): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(data));
    }
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

  // --- E2E state teardown + timers ---

  /** End ONE device's session: zeroize its keys, release whatever it was
   *  reassembling, and tell the cores that device is gone. The coarse
   *  peer-offline follows only if it was the last reachable one. The socket and
   *  every other session are untouched. */
  private dropSession(peerId: string): void {
    const session = this.sessions.get(peerId);
    if (!session) return;
    this.sessions.delete(peerId);
    session.frag.dispose();
    zeroizeSessionKeys(session.sessionKeys);
    session.transport.zeroize();
    if (this.sessions.size === 0) this.stopLiveness();
    this.mux.notifyPeerSessionOffline(peerId);
    this.notifyOfflineIfLast();
  }

  private tearDownPending(peerId: string): void {
    const attempt = this.pending.get(peerId);
    if (!attempt) return;
    this.pending.delete(peerId);
    this.stopHalfOpenTimer(attempt);
    zeroizeSessionKeys(attempt.sessionKeys);
    attempt.transport.zeroize();
  }

  /** Every session and candidate is gone (socket close / redial): the relay has
   *  forgotten our routes, so nothing sealed for them could be delivered. */
  private resetE2eState(): void {
    for (const peerId of [...this.sessions.keys()]) this.dropSession(peerId);
    for (const peerId of [...this.pending.keys()]) this.tearDownPending(peerId);
    this.stopLiveness();
  }

  private startHalfOpenTimer(attempt: PendingAttempt): void {
    this.stopHalfOpenTimer(attempt);
    attempt.expiry = setTimeout(() => {
      // Per attempt, not per client: one device's candidate expiring must not
      // discard another device's, which may have started at any time.
      if (this.pending.get(attempt.peerId) !== attempt) return;
      log.warn("Half-open handshake attempt %s expired — discarding candidate keys", attempt.attemptId);
      this.tearDownPending(attempt.peerId);
    }, this.opts.halfOpenMs ?? HALF_OPEN_MS);
    attempt.expiry?.unref?.();
  }

  private stopHalfOpenTimer(attempt: PendingAttempt): void {
    if (attempt.expiry) {
      clearTimeout(attempt.expiry);
      attempt.expiry = null;
    }
  }

  /** Idempotent: the one interval covers every session, so a second device
   *  establishing must not restart it (which would reset the whole sweep's
   *  phase and delay every other session's next probe). */
  private startLiveness(): void {
    if (this.livenessTimer) return;
    this.livenessTimer = setInterval(() => this.checkLiveness(), PING_SILENCE_MS);
    this.livenessTimer?.unref?.();
  }

  private stopLiveness(): void {
    if (this.livenessTimer) {
      clearInterval(this.livenessTimer);
      this.livenessTimer = null;
    }
  }

  private checkLiveness(): void {
    const now = Date.now();
    for (const session of [...this.sessions.values()]) {
      if (!session.reachable) {
        // Pinging a device the relay says is offline probes nothing. Keep its
        // keys for the reconnect/push window, then let them go.
        if (now - session.unreachableSince >= UNREACHABLE_SESSION_TTL_MS) {
          log.info("Dropping keys for %s — offline past the session TTL", session.peerId);
          this.dropSession(session.peerId);
        }
        continue;
      }
      // Recent sealed traffic → healthy.
      if (now - session.lastSealedRecvAt < PING_SILENCE_MS) continue;
      if (session.missedPongs >= MAX_MISSED_PONGS) {
        // Unresponsive: drop this device's keys and wait for its rekey (the app
        // owns retry pacing). The socket and every sibling session stay up.
        log.warn("E2E session with %s declared dead (2 missed pongs) — dropping keys, awaiting rekey", session.peerId);
        this.dropSession(session.peerId);
        continue;
      }
      session.missedPongs++;
      this.sendSessionFrame({ type: "ping" }, session.transport, session.peerId);
    }
  }

  private heartbeatTick(): void {
    if (this.ws?.readyState !== WebSocket.OPEN) return;
    if (this.awaitingPong) {
      // Half-open socket (e.g. after machine sleep): our previous probe went
      // unanswered for a full interval. Force-close rather than leaving it to
      // linger until OS TCP timeout; the close handler owns reconnection.
      log.warn("relay socket unresponsive — closing to trigger reconnect");
      this.ws.close();
      return;
    }
    this.awaitingPong = true;
    this.sendJson({ type: "ping" });
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.awaitingPong = false;
    this.heartbeatTimer = setInterval(() => this.heartbeatTick(), HEARTBEAT_INTERVAL);
    this.heartbeatTimer?.unref?.();
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  private scheduleReconnect(): void {
    // Equal jitter (PR#49): the SCHEDULED DELAY is uniform in [backoff/2, backoff];
    // the stored `backoff` stays deterministic and doubles for the next attempt.
    const delay = this.backoff / 2 + Math.random() * (this.backoff / 2);
    log.info(`Reconnecting in ${Math.round(delay)}ms...`);
    this.reconnectTimer = setTimeout(() => {
      this.backoff = Math.min(this.backoff * 2, MAX_BACKOFF);
      this.doConnect();
    }, delay);
  }

  private cleanup(): void {
    this.stopHeartbeat();
    this.awaitingPong = false;
    for (const attempt of this.pending.values()) this.stopHalfOpenTimer(attempt);
    this.stopLiveness();
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
  }): RelayClient {
    const c = Object.create(RelayClient.prototype) as RelayClient;
    (c as unknown as { opts: Partial<RelayClientOptions> }).opts = {
      generateKeypair: opts.generateKeypair,
      identity: { deviceId: opts.deviceId ?? "test-device", deviceName: "test", createdAt: "", ed25519PrivateKey: opts.agentEd25519PrivB64 },
      halfOpenMs: opts.halfOpenMs,
    };
    (c as unknown as { sendPayload: (p: string | Buffer, ...rest: unknown[]) => void }).sendPayload = (p) => opts.sendPayload(p);
    (c as unknown as { sessions: Map<string, PeerSession> }).sessions = new Map();
    (c as unknown as { pending: Map<string, PendingAttempt> }).pending = new Map();
    (c as unknown as { reassemblyBudget: SharedByteBudget }).reassemblyBudget = {
      used: 0,
      limit: GLOBAL_REASSEMBLY_BUDGET,
    };
    (c as unknown as { phoneEd25519ByDeviceId: Map<string, string> }).phoneEd25519ByDeviceId = new Map();
    (c as unknown as { outboundFrameDiagnostics: OutboundFrameDiagnostic[] }).outboundFrameDiagnostics = [];
    (c as unknown as { rateLimitBurst: RateLimitBurst | null }).rateLimitBurst = null;
    (c as unknown as { droppedFrames: number }).droppedFrames = 0;
    (c as unknown as { droppedFramesAt: number }).droppedFramesAt = 0;
    (c as unknown as { mux: StreamMux }).mux = new StreamMux({ openStream: () => {}, closeStream: () => {}, sendEnvelope: () => {}, peerSession: () => null });
    if (opts.phoneEd25519PubB64) {
      (c as unknown as { phoneEd25519ByDeviceId: Map<string, string> }).phoneEd25519ByDeviceId.set(opts.peerId, opts.phoneEd25519PubB64);
    }
    return c;
  }

  /** True once at least one E2E session is established (test seam). */
  _handshakeComplete(): boolean {
    return this.sessions.size > 0;
  }
}
