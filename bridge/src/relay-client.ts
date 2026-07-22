import { sign, createPrivateKey, randomBytes } from "node:crypto";
import { logger } from "./logger";
import type { DeviceIdentity } from "./device";
import {
  buildTranscript, deriveSessionKeys, agentConfirmTag, phoneConfirmTag,
  verifyConfirmTag, E2eTransport, signTranscript, verifyTranscriptSig,
  zeroizeSessionKeys, type SessionKeys,
} from "./e2e";
import { deriveSharedSecret, type EphemeralKeypair } from "./key-exchange";
import { parseMessageFast, type AbMessage } from "./protocol";
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
  type PairApprovalMessage,
  type PairRejectedMessage,
  type RouteHeader,
} from "antgrid-wire";
import type { MessageBus, Channel, TransportSubscriber } from "./message-bus";
import { rawSeedToPkcs8, signPairApproval } from "./pair-approval";
import type { PairedPhonesStore } from "./paired-phones";
import type { PairingWindow } from "./pairing-window";
import { verifyPairRequest } from "./pair-request-verify";
import { verifyAccountMembershipSig } from "./account-membership-verify";
import { FragReassembler } from "./frag-reassembler";
import { prunePushToken } from "./push/prune";
import { nextEpoch } from "./relay-epoch";
import { StreamMux, type AttachStreamOpts, type StreamHandle } from "./stream-mux";

export interface HandlePairRequestArgs {
  msg: {
    type: "pair-request";
    agentDeviceId: string;
    phonePubkey: string;
    phoneDeviceId: string;
    nonce: string;
    requestedAt: string;
    phoneSignature: string;
    /** Relay-stamped rendezvous id; echoed in pair-approval / pair-rejected so
     *  the relay routes the response to the requesting phone (design §5.2). */
    pairId?: string;
    pairCode?: string;
    label?: string;
    /** Account-enrolled device Ed25519 pubkey (base64) the phone uses to prove
     *  account membership. Verified against the account's live peer-key set. */
    accountDevicePubkey?: string;
    /** Signature over the pair-request transcript by `accountDevicePubkey`,
     *  proving possession of an account-enrolled device key. */
    accountMembershipSig?: string;
  };
  pairedPhones: PairedPhonesStore;
  pairingWindow: PairingWindow;
  agentDeviceId: string;
  agentEd25519Priv: Uint8Array;
  /** Returns the caller account's live enrolled app-device Ed25519 key set.
   *  Fetched over the agent's own Bearer/TLS channel, so a malicious relay
   *  cannot forge membership. Absent when account-membership routing is off. */
  getAccountPeerKeys?: () => Promise<Set<string>>;
  sameAccountDefaultProjects?: () => string[];
  send: (msg: unknown) => void;
  /** Injectable clock for tests. */
  now?: () => number;
  /**
   * Called after a pair-request passes verification AND is admitted (trusted,
   * sameAccount, or window-matched), just before the approval is sent. Lets the
   * caller record the phone's Ed25519 pubkey + deviceId so the subsequent E2E
   * handshake can verify the phone's transcript signature.
   */
  onApproved?: (phone: { phonePubkey: string; phoneDeviceId: string }) => void;
}

/**
 * Handle a phone-side `pair-request` arriving over the relay.
 *
 * Trust admission rules:
 *  - If the phone's pubkey is already on the trust list (`pairedPhones`), the
 *    request is approved without needing a pair-window match. This handles
 *    silent reconnects.
 *  - If the request carries a valid account-membership proof — an Ed25519
 *    signature over the pair-request transcript by an `accountDevicePubkey`
 *    that is present in the account's live enrolled-device key set (fetched
 *    over the agent's own Bearer/TLS channel) — the request is approved without
 *    consuming a pair code. This REPLACES trust in the relay's `sameAccount`
 *    stamp: a malicious relay cannot forge the proof. The Ed25519
 *    phone-signature check still runs unconditionally.
 *  - Otherwise, the request must include a `pairCode` that consumes the
 *    currently-open pairing window. Window consumption is single-use.
 *  - Otherwise, the request is rejected with one of `UNKNOWN_PHONE` (no code
 *    presented at all) or `PAIRING_WINDOW_CLOSED` (a code was presented but
 *    the window was closed, expired, or did not match).
 *
 * On approval the trust list is upserted (fresh entry for window matches,
 * `lastSeenAt` bump for trusted reconnects) and a `pair-approval` message is
 * sent containing an Ed25519 signature over the canonical sigBody so the
 * phone can verify the agent's identity. Both the approval and rejection echo
 * the relay-stamped `pairId` so the relay can route the response.
 */
export async function handleInboundPairRequest(args: HandlePairRequestArgs): Promise<void> {
  const { msg, pairedPhones, pairingWindow } = args;
  const pairId = msg.pairId;
  if (!pairId) {
    // The relay always stamps pairId before forwarding; without it the response
    // is unroutable, so there is nothing to answer.
    logger.warn("pair-request missing relay-stamped pairId — dropping");
    return;
  }

  // Phone-side possession proof MUST be verified before any trust
  // decision. Without this check, a malicious client that knows a
  // trusted phone's pubkey could replay it and bypass pairing.
  const verifyResult = verifyPairRequest({
    phonePubkey: msg.phonePubkey,
    agentDeviceId: msg.agentDeviceId,
    phoneDeviceId: msg.phoneDeviceId,
    nonce: msg.nonce,
    requestedAt: msg.requestedAt,
    phoneSignature: msg.phoneSignature,
    now: args.now?.(),
  });
  if (!verifyResult.ok) {
    const rejected: PairRejectedMessage = {
      type: "pair-rejected",
      pairId,
      phonePubkey: msg.phonePubkey,
      reason: verifyResult.reason,
    };
    args.send(rejected);
    return;
  }

  const trusted = pairedPhones.has(msg.phonePubkey);

  // Account-membership proof replaces trust in the relay's sameAccount stamp.
  // The phone signs the pair-request transcript with its account-enrolled device
  // key (proof of possession) and presents that key; we admit only if the sig
  // verifies AND the key is in the account's live enrolled-app-device set fetched
  // over our own Bearer/TLS channel. A malicious relay cannot forge this.
  //
  // Skip entirely when the phone is already `trusted` (silent reconnect): trust
  // already admits it, so there is no reason to spend an Ed25519 verify + a
  // network fetch of the account peer-key set on every reconnect.
  let accountMember = false;
  if (!trusted && msg.accountDevicePubkey && msg.accountMembershipSig && args.getAccountPeerKeys) {
    const sigOk = verifyAccountMembershipSig({
      agentDeviceId: msg.agentDeviceId,
      phoneDeviceId: msg.phoneDeviceId,
      phonePubkey: msg.phonePubkey,
      accountDevicePubkey: msg.accountDevicePubkey,
      nonce: msg.nonce,
      sigB64: msg.accountMembershipSig,
    });
    if (sigOk) {
      try {
        const keys = await args.getAccountPeerKeys();
        accountMember = keys.has(msg.accountDevicePubkey);
      } catch (err) {
        logger.warn("account peer-key fetch failed during pair admission: %o", err);
      }
    }
  }

  // Gate consume() on !trusted && !accountMember so an already-admitted phone
  // that happens to carry a pairCode does NOT burn the single-use pairing window
  // as a side effect. (This tightens the previous behavior, which only excluded
  // sameAccount.)
  const windowMatches =
    !trusted && !accountMember && msg.pairCode != null && pairingWindow.consume(msg.pairCode);

  if (!trusted && !accountMember && !windowMatches) {
    const reason = msg.pairCode != null ? "PAIRING_WINDOW_CLOSED" : "UNKNOWN_PHONE";
    // The reject path is otherwise silent, which makes PAIRING_WINDOW_CLOSED
    // undiagnosable: a presented pairCode that doesn't admit means either the
    // window already expired/closed (no open window) or the code didn't match
    // the open one (stale/wrong URL). consume() already ran above and is
    // destructive, but isOpen() is not — so a still-open window here means the
    // code mismatched, while a closed one means it expired or was never opened.
    const detail =
      reason === "UNKNOWN_PHONE"
        ? "no pairCode presented"
        : pairingWindow.isOpen()
          ? "pairCode did not match the open window (stale/wrong URL)"
          : "no open pairing window (expired >60s, or wizard not on the pairing step)";
    logger.warn(
      "pair-request rejected: %s — %s (phone=%s, accountSig=%s)",
      reason,
      detail,
      msg.phoneDeviceId,
      msg.accountMembershipSig != null ? "present" : "absent",
    );
    const rejected: PairRejectedMessage = {
      type: "pair-rejected",
      pairId,
      phonePubkey: msg.phonePubkey,
      reason,
    };
    args.send(rejected);
    return;
  }

  const now = new Date().toISOString();
  if (accountMember) {
    pairedPhones.upsert({
      phonePubkey: msg.phonePubkey,
      phoneDeviceId: msg.phoneDeviceId,
      label: msg.label,
      pairedAt: now,
      lastSeenAt: now,
      admission: "same-account",
      allowedProjects: args.sameAccountDefaultProjects?.() ?? [],
    });
  } else if (windowMatches) {
    // Explicit pair-code admits fail-closed; allowlist changes happen separately.
    pairedPhones.upsert({
      phonePubkey: msg.phonePubkey,
      phoneDeviceId: msg.phoneDeviceId,
      label: msg.label,
      pairedAt: now,
      lastSeenAt: now,
      admission: "pair-code",
    });
  } else if (trusted) {
    // Trusted reconnect: spread preserves the existing allowedProjects allowlist.
    const existing = pairedPhones.get(msg.phonePubkey)!;
    pairedPhones.upsert({ ...existing, lastSeenAt: now });
  }

  // Admitted: record the phone's signing identity for the E2E handshake.
  args.onApproved?.({
    phonePubkey: msg.phonePubkey,
    phoneDeviceId: msg.phoneDeviceId,
  });

  const expiresAt = new Date(Date.now() + 30_000).toISOString();
  const { signature } = signPairApproval({
    agentEd25519Priv: args.agentEd25519Priv,
    agentDeviceId: args.agentDeviceId,
    phonePubkey: msg.phonePubkey,
    phoneDeviceId: msg.phoneDeviceId,
    nonce: msg.nonce,
    expiresAt,
  });

  const approval: PairApprovalMessage = {
    type: "pair-approval",
    pairId,
    phonePubkey: msg.phonePubkey,
    phoneDeviceId: msg.phoneDeviceId,
    nonce: msg.nonce,
    expiresAt,
    signature,
  };
  args.send(approval);
}

export interface RelayClientOptions {
  url: string;
  identity: DeviceIdentity;
  /** Machine dir for the persistent connection-epoch counter (design §6.3). */
  abDir?: string;
  /** Called on each (re)handshake to get a fresh ephemeral keypair for E2E. */
  generateKeypair: () => EphemeralKeypair;
  /** Fired on `welcome` — the single 1-RTT authentication event. */
  onAuthenticated?: () => void;
  /** Kept exception (design §B2): the relay rejected our license with a terminal
   *  verdict (LICENSE_INVALID | LICENSE_EXPIRED | LICENSE_REVOKED). SUPERSEDED /
   *  PAIR_REJECTED must NEVER call this — re-enrolling would be wrong advice. */
  onAuthRevoked?: () => void;
  onPaired?: (peerId: string, peerName: string) => void;
  onUnpaired?: (peerId: string) => void;
  onPeerOnline?: (peerId: string) => void;
  onPeerOffline?: (peerId: string) => void;
  /** The E2E session established (phone's app:ready confirm verified). */
  onHandshakeComplete?: () => void;
  onMessage?: (msg: AbMessage) => void;
  onTunnelMessage?: (msg: unknown) => void;
  onDisconnected?: () => void;
  onError?: (code: string, message: string) => void;
  autoReconnect?: boolean;
  /**
   * Returns the license JWT to present in `hello`. Called per (re)connect so
   * refreshed tokens are picked up automatically. Required — the agent must
   * always present a token.
   */
  getLicenseToken: () => Promise<string> | string;
  /** Trust list for paired phones; required to admit reconnects of known phones. */
  pairedPhones?: PairedPhonesStore;
  /** Single-use pairing window (opened on `agent:enableRelay`). */
  pairingWindow?: PairingWindow;
  /** Returns the caller account's live enrolled app-device Ed25519 key set,
   *  used to verify QR-less auto-pair account-membership proofs. */
  getAccountPeerKeys?: () => Promise<Set<string>>;
  sameAccountDefaultProjects?: () => string[];
  /** Test seam: overrides the half-open handshake-attempt expiry (design §6.2's
   *  30s default). Production never sets this. */
  halfOpenMs?: number;
}

const HEARTBEAT_INTERVAL = 25_000;
const INITIAL_BACKOFF = 1_000;
const MAX_BACKOFF = 30_000;
/** A half-open handshake attempt (client-hello seen, app:ready never arrived)
 *  is discarded after this (design §6.2). Live sessions are unaffected. */
const HALF_OPEN_MS = 30_000;
/** Send a sealed ping after this much sealed-receive silence (design §6.2). */
const PING_SILENCE_MS = 20_000;
/** Consecutive unanswered pings before the E2E session is declared dead. */
const MAX_MISSED_PONGS = 2;
// Relay rate limiting uses a one-second pair window. Keep a little extra local
// history so the diagnostic still includes the earliest sends after the error
// frame makes the round trip through a busy local event loop.
const RATE_DIAGNOSTIC_WINDOW_MS = 1_500;
const RATE_LIMIT_BURST_MS = 1_000;
const MAX_OUTBOUND_DIAGNOSTIC_FRAMES = 4_096;
const MAX_DIAGNOSTIC_TYPES = 8;
const FRAG_ID_SEED = randomBytes(8).toString("hex");
let fragIdCounter = 0;

/** Terminal license verdicts that trigger the kept `auth_revoked` exception. */
const LICENSE_TERMINAL = new Set<string>(["LICENSE_INVALID", "LICENSE_EXPIRED", "LICENSE_REVOKED"]);

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

/** The current E2E session (confirmed keys) or a half-open candidate attempt. */
interface E2eAttempt {
  attemptId: string;
  transport: E2eTransport;
  sessionKeys: SessionKeys;
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
 * The single machine↔relay connection (design §2). Authenticates with one signed
 * `hello`, then runs a reactive/acked E2E session (§6.1) and multiplexes project
 * streams inside it (§7). There is exactly one live phone session per machine.
 */
export class RelayClient {
  private ws: WebSocket | null = null;
  private intentionalClose = false;
  private backoff = INITIAL_BACKOFF;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private authenticated = false;
  private _peerId: string | null = null;
  private readonly epoch: number;
  /** Learned wall-clock correction from a clock-skew AUTH_FAILED (design §13.1). */
  private clockOffsetMs = 0;
  private clockOffsetApplied = false;
  /** The last relay `error` frame; its `retryable` decides reconnect on close. */
  private lastError: { code: string; retryable: boolean } | null = null;

  // E2E session state (design §6.1). `established` is the confirmed session;
  // `pending` is an in-flight (half-open) attempt whose candidate keys stay live
  // for receiving only, until its app:ready confirm verifies (make-before-break).
  private established: E2eAttempt | null = null;
  private pending: E2eAttempt | null = null;
  private halfOpenTimer: ReturnType<typeof setTimeout> | null = null;
  // Sealed-liveness bookkeeping.
  private lastSealedRecvAt = 0;
  private missedPongs = 0;
  private livenessTimer: ReturnType<typeof setInterval> | null = null;

  // Phone Ed25519 pubkeys (standard base64, raw 32 bytes) learned from verified
  // pair-requests, keyed by the phone's deviceId (== relay peer id).
  private phoneEd25519ByDeviceId = new Map<string, string>();

  private bus: MessageBus | null = null;
  private busUnsub: (() => void) | null = null;
  private readonly mux: StreamMux;
  private fragReassembler!: FragReassembler;
  private fragSweep: ReturnType<typeof setInterval> | null = null;
  private outboundFrameDiagnostics: OutboundFrameDiagnostic[] = [];
  private rateLimitBurst: RateLimitBurst | null = null;
  private droppedFrames = 0;
  private droppedFramesAt = 0;

  get peerId(): string | null {
    return this._peerId;
  }

  /** The bare device id this client authenticates as (machine deviceUuid). */
  get deviceId(): string {
    return this.opts.identity.deviceId;
  }

  /** The Ed25519 pubkey (standard base64) of the phone currently paired on this
   *  connection, or null. Resolves `_peerId` → pubkey via `phoneEd25519ByDeviceId`
   *  (populated at pair-approval). Used by the per-project allowlist gate. */
  currentPeerPubkey(): string | null {
    if (!this._peerId) return null;
    return this.phoneEd25519ByDeviceId.get(this._peerId) ?? null;
  }

  /** Ensure `phoneEd25519ByDeviceId` has an entry for `peerId` by recovering it
   *  from the persistent trust list. Used on a trusted reconnect (peer-online
   *  with no fresh pair-request) so the allowlist gate can still identify the
   *  phone after an agent restart. No-op when already known or not trusted. */
  private backfillPeerPubkey(peerId: string): void {
    if (this.phoneEd25519ByDeviceId.has(peerId)) return;
    const phone = this.opts.pairedPhones?.list().find((p) => p.phoneDeviceId === peerId);
    if (phone) this.phoneEd25519ByDeviceId.set(peerId, phone.phonePubkey);
  }

  constructor(private opts: RelayClientOptions) {
    // Computed once per process and reused across every (re)connect (design
    // §6.3): a reconnect must NOT out-epoch itself and lose to its own zombie.
    this.epoch = opts.abDir ? nextEpoch(opts.abDir) : Math.floor(Date.now() / 1000);
    this.mux = new StreamMux({
      openStream: (id) => this.sendJson({ type: "stream-open", streamId: id }),
      closeStream: (id) => this.sendJson({ type: "stream-close", streamId: id }),
      sendEnvelope: (id, msg, channel) => this.sendAppEnvelope(id, msg, channel),
    });
    this.initFragReassembler();
    this.startFragSweep();
  }

  /** Attach a project's bus as a multiplexed stream on this machine socket. */
  attachStream(bus: MessageBus, opts: AttachStreamOpts): StreamHandle {
    return this.mux.attach(bus, opts);
  }

  private initFragReassembler(): void {
    this.fragReassembler = new FragReassembler({
      timeoutMs: TRANSFER_TIMEOUT_MS,
      globalBudgetBytes: GLOBAL_REASSEMBLY_BUDGET,
      onComplete: (json) => this.routeReassembledEnvelope(json),
      onAbort: (hint) => {
        if (hint?.type === "file:content") {
          logger.warn("Fragmented file content transfer interrupted for %s", hint.key);
          this.opts.onError?.("TRANSFER_INTERRUPTED", `Transfer interrupted for ${hint.key}`);
        }
      },
    });
  }

  private startFragSweep(): void {
    if (this.fragSweep) return;
    this.fragSweep = setInterval(() => this.fragReassembler.sweep(), 2000);
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

  private doConnect(): void {
    this.authenticated = false;
    this._peerId = null;
    this.lastError = null;
    this.resetE2eState();

    logger.debug(`Connecting to ${this.opts.url}`);
    const ws = new WebSocket(this.opts.url);

    ws.addEventListener("open", () => {
      logger.info(`Connected to relay at ${this.opts.url}`);
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
      logger.error("WebSocket error", err);
    });
  }

  private async sendHello(): Promise<void> {
    const { identity } = this.opts;
    let licenseToken: string;
    try {
      licenseToken = await this.opts.getLicenseToken();
    } catch (err) {
      logger.error("Failed to get license token", err);
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
      logger.error("No Ed25519 keypair available for hello");
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
      logger.warn("Received non-JSON message from relay, dropping");
      return;
    }

    const result = ServerMessage.safeParse(parsed);
    if (!result.success) {
      logger.warn("Received invalid relay message, dropping: %s", result.error.message);
      return;
    }
    const msg = result.data;

    switch (msg.type) {
      case "welcome":
        this.authenticated = true;
        this.backoff = INITIAL_BACKOFF; // reset ONLY here (PR#49 carry-over)
        this.clockOffsetApplied = false;
        this.startHeartbeat();
        // Re-admit every attached stream: the relay lost its openStreams on the
        // disconnect, so re-count them (sessionLimit) before app traffic resumes.
        this.mux.reopenAll();
        logger.info("Authenticated with relay as %s (epoch %d)", msg.deviceId, msg.epoch);
        this.opts.onAuthenticated?.();
        break;
      case "stream-opened":
        this.mux.onOpened(msg.streamId);
        break;
      case "stream-closed":
        // Idempotent accounting ack — nothing to do; the mux already forgot it.
        break;
      case "pair-connected":
        this._peerId = msg.peerId;
        logger.info("Paired with %s (%s)", msg.peerName, msg.peerId);
        // Reactive: the phone drives the handshake — wait for its client-hello.
        this.opts.onPaired?.(msg.peerId, msg.peerName);
        break;
      case "grant-revoked":
        logger.info("Grant revoked by peer %s (%s)", msg.peerDeviceId, msg.reason);
        this._peerId = null;
        this.resetE2eState();
        this.mux.notifyUnpaired();
        this.opts.onUnpaired?.(msg.peerDeviceId);
        break;
      case "peer-online":
        logger.info("Peer online: %s", msg.peerId);
        this._peerId = msg.peerId;
        this.backfillPeerPubkey(msg.peerId);
        // Reactive: wait for the phone's fresh client-hello (its rekey). Stream
        // resume happens on handshake-complete, not here.
        this.opts.onPeerOnline?.(msg.peerId);
        break;
      case "peer-offline":
        logger.info("Peer offline: %s", msg.peerId);
        // Keep _peerId + the established session for push fallback and a quick
        // reconnect; suppress the heavy stream until the phone returns.
        this.mux.notifyPeerOffline();
        this.opts.onPeerOffline?.(msg.peerId);
        break;
      case "pair-request": {
        const phones = this.opts.pairedPhones;
        const window = this.opts.pairingWindow;
        const ed25519PrivB64 = this.opts.identity.ed25519PrivateKey;
        if (!phones || !window || !ed25519PrivB64) {
          logger.warn("pair-request received but agent is not configured for inbound pairing");
          break;
        }
        const ed25519Priv = Buffer.from(ed25519PrivB64, "base64");
        void handleInboundPairRequest({
          msg,
          pairedPhones: phones,
          pairingWindow: window,
          agentDeviceId: this.opts.identity.deviceId,
          agentEd25519Priv: ed25519Priv,
          getAccountPeerKeys: this.opts.getAccountPeerKeys,
          sameAccountDefaultProjects: this.opts.sameAccountDefaultProjects,
          send: (m) => this.sendJson(m as object),
          onApproved: ({ phonePubkey, phoneDeviceId }) => {
            this.phoneEd25519ByDeviceId.set(phoneDeviceId, phonePubkey);
          },
        });
        break;
      }
      case "push:result":
        if (!msg.ok && msg.reason === "unregistered" && this.opts.pairedPhones) {
          prunePushToken(this.opts.pairedPhones, msg.pushToken);
        } else if (!msg.ok) {
          // warn, not debug: a push that never lands has no other observable on
          // this side. At debug, a misconfigured relay (bad FCM key -> reason
          // "error", absent creds -> "unconfigured") is indistinguishable from
          // no push being attempted at all, which reads as an app bug.
          logger.warn("push:result not ok (reason=%s)", msg.reason);
        }
        break;
      case "error":
        this.handleErrorFrame(msg);
        break;
      default: {
        const _exhaustive: never = msg;
        void _exhaustive;
      }
    }
  }

  private handleErrorFrame(msg: { code: string; message: string; retryable: boolean; ref?: string; serverTime?: string }): void {
    // A stream-open rejection (ref === a live streamId, notably
    // SESSION_LIMIT_EXCEEDED): the socket and every other stream stay live, so it
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
    // re-hello with a corrected `ts` (design §13.1).
    if (msg.code === "AUTH_FAILED" && msg.serverTime) this.applyClockOffset(msg.serverTime);

    logger.error(
      `Relay error: device=${this.opts.identity.deviceId} peer=${this._peerId ?? "unpaired"} ` +
      `code=${msg.code} retryable=${msg.retryable} message="${msg.message}"`,
    );
    this.opts.onError?.(msg.code, msg.message);

    // Kept exception (B2): only a terminal LICENSE verdict tells the user to
    // re-enroll. SUPERSEDED (a newer instance of OURSELVES) and PAIR_REJECTED
    // must never trigger this — the relay closes the socket and the terminal
    // `retryable:false` stops reconnecting in the close handler.
    if (LICENSE_TERMINAL.has(msg.code)) this.opts.onAuthRevoked?.();
    if (msg.code === "SUPERSEDED") {
      logger.info("Superseded by a newer connection of this device — stopping reconnect");
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
    logger.warn("Relay clock skew detected; applying %dms offset to the next hello", offset);
  }

  // --- Binary frame receive path (kind-byte dispatch, design §3.1) ---

  private handleBinaryFrame(buf: Buffer): void {
    let decoded: { header: unknown; payload: Uint8Array; kind: FrameKind };
    try {
      decoded = decodeRouteFrame(buf);
    } catch (e) {
      if (e instanceof FrameError) {
        logger.warn("Received malformed frame: %s", e.reason);
        return;
      }
      throw e;
    }
    const header = decoded.header as { type?: string; from?: string; channel?: string };
    if (header.type !== "message" || !header.from || !header.channel) {
      logger.warn("Invalid route header on binary frame");
      return;
    }
    const channel: Channel = header.channel === "preview" ? "preview" : "control";

    if (decoded.kind === FrameKind.handshake) {
      this.handleHandshakeFrame(decoded.payload);
      return;
    }
    // kind === sealed: decrypt-or-drop.
    this.handleSealedFrame(Buffer.from(decoded.payload), channel);
  }

  /** Kind-1 plaintext admits exactly the two handshake types; the agent only
   *  ever consumes client-hello. A frame that is not a signature-valid
   *  client-hello is dropped with a log (design §3.1). */
  private handleHandshakeFrame(payload: Uint8Array): void {
    let obj: { type?: string } | null = null;
    try {
      obj = JSON.parse(Buffer.from(payload).toString("utf8"));
    } catch {
      logger.warn("Dropping non-JSON kind-1 handshake frame");
      return;
    }
    if (obj?.type === "handshake:client-hello") {
      this.handleClientHello(obj as { attemptId?: string; pubkey?: string; nonce?: string; sig?: string });
      return;
    }
    logger.warn("Dropping unexpected kind-1 handshake frame (type=%s)", obj?.type);
  }

  private handleSealedFrame(payload: Buffer, channel: Channel): void {
    // Make-before-break: at most two live receive contexts. Try the established
    // session first; during a pending rekey also try the candidate keys so the
    // new attempt's app:ready can be opened.
    if (this.established) {
      const pt = this.established.transport.open(payload);
      if (pt !== null) {
        this.recordSealedRecv();
        this.onSealedPlaintext(pt, channel);
        return;
      }
    }
    if (this.pending) {
      const pt = this.pending.transport.open(payload);
      if (pt !== null) {
        this.onSealedPlaintext(pt, channel);
        return;
      }
    }
    logger.warn("Failed to open sealed frame (len=%d), dropping", payload.length);
  }

  private onSealedPlaintext(plaintext: string, channel: Channel): void {
    // Fragmented app traffic → buffer; onComplete routes the reassembled envelope.
    if (this.fragReassembler.accept(plaintext)) return;

    let obj: unknown;
    try {
      obj = JSON.parse(plaintext);
    } catch {
      logger.warn("Dropping non-JSON sealed plaintext");
      return;
    }
    if (obj && typeof obj === "object") {
      // Bare session frame (top-level `type`) vs app envelope (`{ s?, m }`). App
      // traffic is always wrapped, so a top-level `type` is unambiguously a
      // session/liveness frame.
      if (typeof (obj as { type?: unknown }).type === "string") {
        this.handleSessionFrame(obj as { type: string; attemptId?: string; confirm?: string });
        return;
      }
      if ("m" in (obj as object)) {
        this.routeAppEnvelope(obj as { s?: string; m: unknown }, channel);
        return;
      }
    }
    logger.warn("Dropping unrecognized sealed plaintext");
  }

  private routeReassembledEnvelope(json: string): void {
    let env: { s?: string; m?: unknown };
    try {
      env = JSON.parse(json);
    } catch {
      logger.warn("Dropping non-JSON reassembled envelope");
      return;
    }
    if (!env || typeof env !== "object" || !("m" in env)) {
      logger.warn("Dropping malformed reassembled envelope");
      return;
    }
    // Reassembled transfers are control-tier (file:content, diffs); the channel
    // only affects the AbMessage dispatch tag, which is control for these.
    this.routeAppEnvelope(env as { s?: string; m: unknown }, "control");
  }

  private routeAppEnvelope(env: { s?: string; m: unknown }, channel: Channel): void {
    const s = env.s;
    const streamId = typeof s === "string" && s !== CONTROL_STREAM_ID ? s : null;
    const mJson = JSON.stringify(env.m);
    if (streamId === null) {
      this.dispatchControlPlane(mJson, channel);
      return;
    }
    if (!this.mux.dispatchInbound(streamId, mJson, channel)) {
      logger.warn("Dropping inbound frame for unknown streamId %s", streamId);
    }
  }

  private dispatchControlPlane(mJson: string, channel: Channel): void {
    const msg = parseMessageFast(mJson);
    if (msg) {
      this.opts.onMessage?.(msg);
      this.bus?.dispatchInbound(msg, channel, "relay");
      return;
    }
    const tunnel = parseTunnelMessage(mJson);
    if (tunnel) this.opts.onTunnelMessage?.(tunnel);
  }

  // --- E2E session frames (design §6.1) ---

  private handleSessionFrame(obj: { type: string; attemptId?: string; confirm?: string }): void {
    switch (obj.type) {
      case "app:ready":
        this.handleAppReady(obj);
        return;
      case "ping":
        // Liveness reset already done for the established transport; answer sealed.
        if (this.established) this.sendSessionFrame({ type: "pong" }, this.established.transport);
        return;
      case "pong":
        // Liveness reset done in handleSealedFrame's recordSealedRecv.
        return;
      default:
        logger.warn("Dropping unexpected sealed session frame (type=%s)", obj.type);
    }
  }

  private handleClientHello(obj: { attemptId?: string; pubkey?: string; nonce?: string; sig?: string }): void {
    const { attemptId, pubkey, nonce, sig } = obj;
    if (!attemptId || !pubkey || !nonce || !sig) {
      logger.warn("client-hello missing fields — dropping");
      return;
    }
    const peerId = this._peerId;
    if (!peerId) return;
    const phoneEd25519PubB64 = this.resolvePhoneEd25519PubB64(peerId);
    if (!phoneEd25519PubB64) {
      logger.warn("No pinned Ed25519 identity for peer %s; cannot verify handshake", peerId);
      return;
    }
    const seedB64 = this.opts.identity.ed25519PrivateKey;
    if (!seedB64) {
      logger.warn("No Ed25519 seed to sign agent-hello — dropping client-hello");
      return;
    }
    const clientPubkey = Buffer.from(pubkey, "base64");
    if (clientPubkey.length !== 32) {
      logger.warn("Invalid client pubkey length: %d", clientPubkey.length);
      return;
    }
    const nonceBuf = Buffer.from(nonce, "base64");
    const deviceId = this.opts.identity.deviceId;

    // SECURITY: verify the phone's transcript signature (empty agent-pub slot —
    // pull-model ordering) against the pinned key before deriving anything.
    const phoneTranscript = buildTranscript({
      registrationId: deviceId,
      role: "phone",
      agentDeviceId: deviceId,
      phoneDeviceId: peerId,
      agentX25519Pub: Buffer.alloc(0),
      phoneX25519Pub: clientPubkey,
      nonce: nonceBuf,
    });
    if (!verifyTranscriptSig(phoneTranscript, phoneEd25519PubB64, sig)) {
      logger.warn("Rejecting client-hello: transcript signature invalid");
      return;
    }

    // Fresh attempt: any prior half-open candidate is superseded.
    this.tearDownPending();

    const kp = this.opts.generateKeypair();
    const agentPubkey = kp.publicKey;
    const agentTranscript = buildTranscript({
      registrationId: deviceId,
      role: "agent",
      agentDeviceId: deviceId,
      phoneDeviceId: peerId,
      agentX25519Pub: agentPubkey,
      phoneX25519Pub: clientPubkey,
      nonce: nonceBuf,
    });
    const sharedSecret = deriveSharedSecret(kp.privateKey, clientPubkey);
    kp.privateKey.fill(0);
    const sessionKeys = deriveSessionKeys(sharedSecret, agentTranscript);
    const transport = new E2eTransport({ sendKey: sessionKeys.a2p, recvKey: sessionKeys.p2a });
    this.pending = { attemptId, transport, sessionKeys };
    this.startHalfOpenTimer();

    const agentSig = signTranscript(agentTranscript, Buffer.from(seedB64, "base64"));
    this.sendPayload(
      Buffer.from(JSON.stringify({ type: "handshake:agent-hello", attemptId, pubkey: agentPubkey.toString("base64"), sig: agentSig }), "utf8"),
      "control",
      FrameKind.handshake,
      "handshake:agent-hello",
    );
    // agent-ready is sealed under the CANDIDATE keys (the session isn't confirmed
    // yet) and carries the confirm tag.
    this.sendSessionFrame(
      { type: "handshake:agent-ready", attemptId, confirm: agentConfirmTag(sessionKeys.confirm).toString("base64") },
      transport,
    );
    logger.info("E2E handshake keys derived (attempt %s), waiting for app:ready", attemptId);
  }

  private handleAppReady(obj: { attemptId?: string; confirm?: string }): void {
    const attemptId = obj.attemptId;
    if (!attemptId) return;
    const tag = Buffer.from(obj.confirm ?? "", "base64");

    // Idempotent: the phone retransmits app:ready every 2s until it sees
    // `established` (design §6.1 step 5). A duplicate for the live session just
    // re-acks — no state change.
    if (this.established && this.established.attemptId === attemptId) {
      this.sendSessionFrame({ type: "established", attemptId }, this.established.transport);
      return;
    }

    if (this.pending && this.pending.attemptId === attemptId) {
      const expected = phoneConfirmTag(this.pending.sessionKeys.confirm);
      if (!verifyConfirmTag(expected, tag)) {
        logger.warn("app:ready confirm tag invalid (attempt %s) — dropping", attemptId);
        return;
      }
      // Make-before-break swap: promote the candidate, then zeroize the old set.
      const old = this.established;
      this.established = this.pending;
      this.pending = null;
      this.stopHalfOpenTimer();
      if (old) {
        zeroizeSessionKeys(old.sessionKeys);
        old.transport.zeroize();
      }
      this.startLiveness();
      this.sendSessionFrame({ type: "established", attemptId }, this.established.transport);
      logger.info("E2E session established (attempt %s)", attemptId);
      this.opts.onHandshakeComplete?.();
      this.mux.notifyPeerOnline();
      return;
    }

    logger.warn("app:ready for unknown attempt %s — dropping", attemptId);
  }

  private resolvePhoneEd25519PubB64(phoneDeviceId: string): string | undefined {
    const fromMap = this.phoneEd25519ByDeviceId.get(phoneDeviceId);
    if (fromMap) return fromMap;
    const store = this.opts.pairedPhones;
    if (!store) return undefined;
    return store.list().find((p) => p.phoneDeviceId === phoneDeviceId)?.phonePubkey;
  }

  // --- Sending ---

  /** Send a AbMessage on the control channel. Always sealed; dropped (never
   *  plaintext) if the E2E session is not established. */
  send(msg: AbMessage): void {
    this.sendAppEnvelope(CONTROL_STREAM_ID, msg, "control");
  }

  /** Send a AbMessage on a specific channel (control plane). */
  sendOnChannel(msg: AbMessage, channel: Channel): void {
    this.sendAppEnvelope(CONTROL_STREAM_ID, msg, channel);
  }

  /** Send a tunnel-protocol message on the preview channel (control plane). */
  sendTunnel(data: object): void {
    this.sendAppEnvelope(CONTROL_STREAM_ID, data, "preview");
  }

  /** Send a push:deliver control frame to the relay (blind FCM/APNs forward). A
   *  top-level control message on OUR socket — the relay itself consumes it. */
  sendPushDeliver(msg: { pushToken: string; provider: "fcm" | "apns"; blob: { epk: string; box: string } }): void {
    this.sendJson({ type: "push:deliver", ...msg });
  }

  /**
   * Wrap `msg` in the `{ s?, m }` stream envelope (design §7.1), fragment the
   * ENVELOPE json (so `s` survives fragmentation), seal each fragment under the
   * established session keys, and send. Control-plane traffic uses
   * `CONTROL_STREAM_ID` (`s` omitted). Dropped — never sent in cleartext — when
   * the session is not established. A too-large `tunnel:http-response` degrades
   * to a sealed 413 so the phone's preview request fails fast instead of hanging.
   */
  private sendAppEnvelope(streamId: string, msg: unknown, channel: Channel): "sent" | "dropped" | "too-large" {
    const type = (msg as { type?: string } | null)?.type;
    if (!this.established) {
      // NEVER send app traffic in cleartext (the relay is zero-knowledge). During
      // a rekey window services may still emit; dropping is correct — the phone
      // re-syncs control state after the next establishment.
      logger.debug("Dropping outbound %s — E2E session not established", type ?? "message");
      this.handleUndeliverableTunnel("dropped", channel, msg);
      return "dropped";
    }

    const envelope =
      streamId && streamId !== CONTROL_STREAM_ID ? { s: streamId, m: msg } : { m: msg };
    const json = JSON.stringify(envelope);
    const key = this.messageFragKey(msg);
    const fragmented = fragmentForSend(json, type, key);
    if (!fragmented.ok) {
      logger.warn("%s", fragmented.error.message);
      this.opts.onError?.(fragmented.error.code, fragmented.error.message);
      const outcome = fragmented.error.code === "MESSAGE_TOO_LARGE" ? "too-large" : "dropped";
      this.handleUndeliverableTunnel(outcome, channel, msg);
      return outcome;
    }

    for (const frame of fragmented.frames) {
      this.sendPayload(this.established.transport.seal(frame), channel, FrameKind.sealed, type ?? "app");
    }
    return "sent";
  }

  /** A tunnel HTTP response has no re-sync path (unlike control), so an
   *  undeliverable one must fail the phone's request fast: too-large → sealed
   *  413; torn-down transport → loud warn (the request will time out). */
  private handleUndeliverableTunnel(
    outcome: "dropped" | "too-large",
    channel: Channel,
    msg: unknown,
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
      );
    } else {
      logger.warn(
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
   *  agent-ready; established keys for established/ping/pong). */
  private sendSessionFrame(obj: object, transport: E2eTransport | undefined): void {
    if (!transport) return;
    const type = (obj as { type?: string }).type ?? "session";
    this.sendPayload(transport.seal(JSON.stringify(obj)), "control", FrameKind.sealed, type);
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

  private sendPayload(
    data: Buffer | string,
    channel: Channel = "control",
    kind: FrameKind = FrameKind.sealed,
    diagnosticType = "transport",
  ): void {
    if (!this._peerId) {
      logger.warn("Cannot send payload — not paired");
      return;
    }
    if (this.ws?.readyState !== WebSocket.OPEN) return;

    const payloadBytes = typeof data === "string" ? Buffer.from(data, "utf8") : data;
    const header: RouteHeader = { type: "message", to: this._peerId, channel };
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
    logger.error(
      `Relay rate limit: device=${this.opts.identity.deviceId} peer=${this._peerId ?? "unpaired"} ` +
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

    logger.error(
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

  private tearDownEstablished(): void {
    if (!this.established) return;
    zeroizeSessionKeys(this.established.sessionKeys);
    this.established.transport.zeroize();
    this.established = null;
  }

  private tearDownPending(): void {
    if (!this.pending) return;
    zeroizeSessionKeys(this.pending.sessionKeys);
    this.pending.transport.zeroize();
    this.pending = null;
  }

  private resetE2eState(): void {
    this.tearDownEstablished();
    this.tearDownPending();
    this.stopHalfOpenTimer();
    this.stopLiveness();
  }

  private startHalfOpenTimer(): void {
    this.stopHalfOpenTimer();
    this.halfOpenTimer = setTimeout(() => {
      if (this.pending) {
        logger.warn("Half-open handshake attempt %s expired — discarding candidate keys", this.pending.attemptId);
        this.tearDownPending();
      }
    }, this.opts.halfOpenMs ?? HALF_OPEN_MS);
    this.halfOpenTimer?.unref?.();
  }

  private stopHalfOpenTimer(): void {
    if (this.halfOpenTimer) {
      clearTimeout(this.halfOpenTimer);
      this.halfOpenTimer = null;
    }
  }

  private recordSealedRecv(): void {
    this.lastSealedRecvAt = Date.now();
    this.missedPongs = 0;
  }

  private startLiveness(): void {
    this.stopLiveness();
    this.lastSealedRecvAt = Date.now();
    this.missedPongs = 0;
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
    if (!this.established) return;
    // Recent sealed traffic → healthy.
    if (Date.now() - this.lastSealedRecvAt < PING_SILENCE_MS) return;
    if (this.missedPongs >= MAX_MISSED_PONGS) {
      this.declareSessionDead();
      return;
    }
    this.missedPongs++;
    this.sendSessionFrame({ type: "ping" }, this.established.transport);
  }

  /** The E2E session is unresponsive: drop keys and wait for the phone's rekey
   *  (it owns retry pacing — design §6.2). The socket is left intact. */
  private declareSessionDead(): void {
    logger.warn("E2E session declared dead (2 missed pongs) — dropping keys, awaiting rekey");
    this.tearDownEstablished();
    this.stopLiveness();
    this.mux.notifyPeerOffline();
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (this.ws?.readyState === WebSocket.OPEN) {
        const ws = this.ws as unknown as { ping?: () => void };
        if (typeof ws.ping === "function") ws.ping();
        else this.sendJson({ type: "ping" });
      }
    }, HEARTBEAT_INTERVAL);
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
    logger.info(`Reconnecting in ${Math.round(delay)}ms...`);
    this.reconnectTimer = setTimeout(() => {
      this.backoff = Math.min(this.backoff * 2, MAX_BACKOFF);
      this.doConnect();
    }, delay);
  }

  private cleanup(): void {
    this.stopHeartbeat();
    this.stopHalfOpenTimer();
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
    (c as unknown as { _peerId: string })._peerId = opts.peerId;
    (c as unknown as { established: E2eAttempt | null }).established = null;
    (c as unknown as { pending: E2eAttempt | null }).pending = null;
    (c as unknown as { phoneEd25519ByDeviceId: Map<string, string> }).phoneEd25519ByDeviceId = new Map();
    (c as unknown as { outboundFrameDiagnostics: OutboundFrameDiagnostic[] }).outboundFrameDiagnostics = [];
    (c as unknown as { rateLimitBurst: RateLimitBurst | null }).rateLimitBurst = null;
    (c as unknown as { droppedFrames: number }).droppedFrames = 0;
    (c as unknown as { droppedFramesAt: number }).droppedFramesAt = 0;
    (c as unknown as { mux: StreamMux }).mux = new StreamMux({ openStream: () => {}, closeStream: () => {}, sendEnvelope: () => {} });
    (c as unknown as { initFragReassembler: () => void }).initFragReassembler();
    if (opts.phoneEd25519PubB64) {
      (c as unknown as { phoneEd25519ByDeviceId: Map<string, string> }).phoneEd25519ByDeviceId.set(opts.peerId, opts.phoneEd25519PubB64);
    }
    return c;
  }

  /** True once the E2E session is established (test seam). */
  _handshakeComplete(): boolean {
    return this.established !== null;
  }
}
