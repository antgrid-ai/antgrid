import { randomBytes } from "node:crypto";
import { generateEphemeralKeypair, deriveSharedSecret } from "../../bridge/src/key-exchange";
import {
  buildTranscript,
  deriveSessionKeys,
  agentConfirmTag,
  phoneConfirmTag,
  verifyConfirmTag,
  E2eTransport,
  verifyTranscriptSig,
  rawSeedToPkcs8,
} from "../../bridge/src/e2e";
import { sign as nodeSign } from "node:crypto";
import { createMessage, parseMessage, type AbMessage } from "../../bridge/src/protocol";
import {
  encodeRouteFrame,
  decodeRouteFrame,
  FrameKind,
  CONTROL_STREAM_ID,
  buildHelloSigBody,
  normalizeRelayHost,
  TRANSFER_TIMEOUT_MS,
  GLOBAL_REASSEMBLY_BUDGET,
} from "antgrid-wire";
import { FragReassembler } from "../../bridge/src/frag-reassembler";

/** The fake license token the eval relay gate (`fakeLicenseGate`) accepts. v3
 *  requires it for BOTH device types (design §4.2), so an app now sends it too.
 *  Duplicated (not imported from harness.ts) to avoid a helper import cycle. */
const TEST_LICENSE_TOKEN = "eval-license-token";

/** Monotonic per-launch epoch source (design §6.3). A client (re)started within
 *  one test presents a strictly higher epoch than its predecessor, so the newer
 *  connection supersedes the old on the relay. */
let epochCounter = 0;
function nextEpoch(): number {
  epochCounter = Math.max(epochCounter + 1, Math.floor(Date.now() / 1000));
  return epochCounter;
}

/** A reusable phone Ed25519 identity (sans relay deviceId), so multiple relay
 *  connections can present the same phone pubkey. */
export interface PhoneIdentity {
  publicKeyBase64: string;
  privateKey: CryptoKey;
  privateKeySeed: Buffer;
}

/** Opt-in forge hooks for the hello frame, consumed by relay-level (R) forge
 *  tests driven from evals. Each mutates exactly one field of an otherwise
 *  well-formed v3 hello so the relay's rejection path can be asserted. */
export interface HelloForgeOpts {
  /** Corrupt the Ed25519 signature so the relay's possession proof fails
   *  (→ AUTH_FAILED, socket closed). */
  corruptHelloSig?: boolean;
  /** Present this exact nonce instead of a fresh one — reuse a prior hello's
   *  `lastHelloNonce` to trip the replay cache (→ AUTH_FAILED). */
  reuseNonce?: string;
  /** Offset the signed `ts` by this many ms to land outside the relay's
   *  ±clockSkewMs window (→ AUTH_FAILED, retryable, carries serverTime). */
  skewTsMs?: number;
  /** Override the connection epoch (default: a monotonic module counter). */
  epoch?: number;
  /** Override the license token (default: TEST_LICENSE_TOKEN). */
  licenseToken?: string;
}

/** The current E2E receive/send context (confirmed session or a rekey candidate). */
interface E2eContext {
  attemptId: string;
  transport: E2eTransport;
  confirmKey: Buffer;
}

export class RelayClient {
  private ws: WebSocket | null = null;
  private messageQueue: any[] = [];
  private waiters: Array<{
    match: (msg: any) => boolean;
    resolve: (msg: any) => void;
    reject: (err: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }> = [];

  /** Set once the underlying socket closes (relay-initiated displacement/
   *  supersession, network drop, or our own disconnect). Drives `waitForClose`. */
  private wsClosed = false;
  private closeWaiters: Array<() => void> = [];
  /** WS close code from the most recent close event (e.g. 4002 for the
   *  relay's `/internal/revoke` — see `internal-routes.ts`'s `closeWithLicense`). */
  lastCloseCode: number | null = null;
  /** Bumped at the start of every `connectAndAuthenticate` call. The close
   *  listener captures its own value and compares before mutating shared
   *  state, so a STALE close event from a socket a later reconnect already
   *  superseded (e.g. `dropSocket()` immediately followed by a redial) can't
   *  clobber the fresh connection's `wsClosed`/`lastCloseCode`. */
  private wsGeneration = 0;

  readonly deviceId: string;
  /** The ACCOUNT device the E2E transcript binds — `deviceId` may be a
   *  per-machine SLOT (`<transcriptDeviceId>#<machineDeviceId>`), but the
   *  transcript (the HKDF salt) always binds the bare account device on both
   *  sides. Defaults to `deviceId`, so an unscoped connection is unaffected. */
  readonly transcriptDeviceId: string;
  readonly deviceType: "agent" | "app";
  readonly name: string;
  private publicKeyBase64: string;
  private privateKey: CryptoKey;
  /** Raw 32-byte Ed25519 seed — used for E2E transcript signing (node:crypto). */
  private privateKeySeed: Buffer;
  /** Tap for every outbound text-JSON frame (hello + raw control messages) —
   *  lets a caller assert a negative on the wire (e.g. "never sent pair-request"). */
  private onOutbound?: (raw: string) => void;

  /** Per-connection hello forge/override hooks. */
  private helloOpts: HelloForgeOpts = {};
  /** The nonce sent in the most recent hello — reuse it via `reuseNonce`. */
  lastHelloNonce = "";

  // --- E2E session state (design §6.1) ---
  /** The confirmed session (or, mid-initial-handshake, the derived candidate the
   *  phone confirms last). Make-before-break rekey keeps it live for RECEIVING
   *  until the pending attempt establishes. */
  private established: E2eContext | null = null;
  /** An in-flight rekey attempt whose keys receive-only until it establishes. */
  private pending: E2eContext | null = null;
  private e2eMode = false;
  /** True once the initial handshake's confirm is sent + established. */
  private sessionConfirmed = false;
  /** Sealed frames that failed to decrypt under all live contexts during a
   *  handshake/rekey (a candidate agent-ready racing ahead of key derivation).
   *  Replayed once the relevant transport is installed. */
  private pendingEncrypted: Uint8Array[] = [];

  // --- Multiplexed project streams (design §7.1) ---
  /** projectId → streamId, learned from control-plane `stream-ready`/`agent:projects`. */
  private streamByProject = new Map<string, string>();

  // --- Phone-side liveness (design §6.2 from the phone's perspective) ---
  private livenessTimer: ReturnType<typeof setInterval> | null = null;
  private lastSealedRecvAt = 0;
  private missedPongs = 0;
  private pingSilenceMs = 20_000;
  private maxMissedPongs = 2;
  /** Test lever: drop inbound sealed `pong`s so this client's liveness starves
   *  and it rekeys (design §6.2). The relay is zero-knowledge and cannot single
   *  out sealed pongs, so the "swallow pongs" lever lives at the endpoint. */
  private swallowPongs = false;
  private rekeyInFlight = false;

  private fragReassembler = new FragReassembler({
    timeoutMs: TRANSFER_TIMEOUT_MS,
    globalBudgetBytes: GLOBAL_REASSEMBLY_BUDGET,
    onComplete: (json) => this.routeReassembledEnvelope(json),
    onAbort: () => {},
  });

  private constructor(
    deviceId: string,
    transcriptDeviceId: string,
    deviceType: "agent" | "app",
    name: string,
    publicKeyBase64: string,
    privateKey: CryptoKey,
    privateKeySeed: Buffer,
    onOutbound: ((raw: string) => void) | undefined,
  ) {
    this.deviceId = deviceId;
    this.transcriptDeviceId = transcriptDeviceId;
    this.deviceType = deviceType;
    this.name = name;
    this.publicKeyBase64 = publicKeyBase64;
    this.privateKey = privateKey;
    this.privateKeySeed = privateKeySeed;
    this.onOutbound = onOutbound;
  }

  /** Create a relay client, connect, and authenticate with a single signed
   *  v3 `hello` (design §4). `licenseToken`/`epoch` default sensibly; the
   *  forge hooks let R-level tests drive rejection paths. */
  static async connectAndAuth(
    relayUrl: string,
    opts: {
      deviceType: "agent" | "app";
      name?: string;
      identity?: PhoneIdentity;
      deviceId?: string;
      /** ACCOUNT device the E2E transcript binds. Defaults to `deviceId` — only
       *  a slotted `deviceId` (`<transcriptDeviceId>#<machineDeviceId>`) needs
       *  this set separately. */
      transcriptDeviceId?: string;
      /** Tap for every outbound text-JSON frame this client sends. */
      onOutbound?: (raw: string) => void;
    } & HelloForgeOpts,
  ): Promise<RelayClient> {
    const deviceId = opts.deviceId ?? crypto.randomUUID();
    const transcriptDeviceId = opts.transcriptDeviceId ?? deviceId;
    const name = opts.name ?? `test-${opts.deviceType}`;

    let publicKeyBase64: string;
    let privateKey: CryptoKey;
    let privateKeySeed: Buffer;
    if (opts.identity) {
      // Reuse an existing Ed25519 identity (same phone pubkey) across multiple
      // relay connections. The agent's trust + per-project allowlist key off the
      // phone PUBKEY, so every connection presents the SAME key; only the relay
      // deviceId stays per-connection.
      ({ publicKeyBase64, privateKey, privateKeySeed } = opts.identity);
    } else {
      const keyPair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
      const pubRaw = await crypto.subtle.exportKey("raw", keyPair.publicKey as CryptoKey);
      publicKeyBase64 = Buffer.from(pubRaw).toString("base64");
      // PKCS8 DER for Ed25519 = 16-byte prefix + 32-byte seed.
      const pkcs8Der = Buffer.from(
        await crypto.subtle.exportKey("pkcs8", keyPair.privateKey as CryptoKey),
      );
      privateKeySeed = Buffer.from(pkcs8Der.subarray(pkcs8Der.length - 32));
      privateKey = keyPair.privateKey as CryptoKey;
    }

    const client = new RelayClient(
      deviceId,
      transcriptDeviceId,
      opts.deviceType,
      name,
      publicKeyBase64,
      privateKey,
      privateKeySeed,
      opts.onOutbound,
    );
    client.helloOpts = {
      corruptHelloSig: opts.corruptHelloSig,
      reuseNonce: opts.reuseNonce,
      skewTsMs: opts.skewTsMs,
      epoch: opts.epoch,
      licenseToken: opts.licenseToken,
    };
    await client.connectAndAuthenticate(relayUrl);
    return client;
  }

  /** Export this client's Ed25519 identity so a second connection can reuse the
   *  SAME phone pubkey (see `connectAndAuth({ identity })`). */
  exportIdentity(): PhoneIdentity {
    return {
      publicKeyBase64: this.publicKeyBase64,
      privateKey: this.privateKey,
      privateKeySeed: this.privateKeySeed,
    };
  }

  private connectAndAuthenticate(relayUrl: string): Promise<void> {
    const myGeneration = ++this.wsGeneration;
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(relayUrl);
      const timeout = setTimeout(() => reject(new Error("Auth timed out")), 10_000);
      let authDone = false;

      ws.addEventListener("open", () => {
        this.ws = ws;
        // Fresh socket — clear any close flag from a prior AGENT_OFFLINE.
        this.wsClosed = false;
        void this.sendHello(relayUrl).catch((err) => {
          clearTimeout(timeout);
          reject(err instanceof Error ? err : new Error(String(err)));
        });
      });

      ws.addEventListener("message", (event) => {
        if (event.data instanceof ArrayBuffer || event.data instanceof Uint8Array) {
          if (authDone) this.handleBinaryFrame(event.data);
          return;
        }
        const data = JSON.parse(typeof event.data === "string" ? event.data : String(event.data));

        if (!authDone) {
          if (data.type === "welcome") {
            authDone = true;
            clearTimeout(timeout);
            resolve();
            return;
          }
          if (data.type === "error") {
            clearTimeout(timeout);
            reject(new Error(`Auth error: ${data.code} ${data.message}`));
            return;
          }
          return;
        }

        // Post-auth text JSON: relay control messages (peer-online, peer-offline,
        // error, stream-* acks, …).
        this.deliver(data);
      });

      ws.addEventListener("error", () => reject(new Error("WebSocket error")));
      ws.addEventListener("close", (event: any) => {
        // A superseded generation's close (e.g. `dropSocket()` immediately
        // followed by a redial) must not clobber the fresh connection's state.
        if (myGeneration !== this.wsGeneration) return;
        this.wsClosed = true;
        this.lastCloseCode = typeof event?.code === "number" ? event.code : null;
        const waiters = this.closeWaiters.splice(0);
        for (const w of waiters) w();
        if (!authDone) reject(new Error("Closed during auth"));
      });
    });
  }

  /** Sign + send the single v3 `hello` (design §4.1). Honors the forge hooks. */
  private async sendHello(relayUrl: string): Promise<void> {
    const licenseToken = this.helloOpts.licenseToken ?? TEST_LICENSE_TOKEN;
    const epoch = this.helloOpts.epoch ?? nextEpoch();
    const ts = new Date(Date.now() + (this.helloOpts.skewTsMs ?? 0)).toISOString();
    const nonce = this.helloOpts.reuseNonce ?? randomBytes(16).toString("base64");
    this.lastHelloNonce = nonce;
    const relayHost = normalizeRelayHost(relayUrl);

    const sigBody = buildHelloSigBody({
      relayHost,
      deviceType: this.deviceType,
      deviceId: this.deviceId,
      publicKey: this.publicKeyBase64,
      epoch,
      licenseToken,
      ts,
      nonce,
    });
    const rawSig = await crypto.subtle.sign("Ed25519", this.privateKey, new Uint8Array(sigBody));
    let sig = Buffer.from(rawSig).toString("base64");
    if (this.helloOpts.corruptHelloSig) {
      const bad = Buffer.from(rawSig);
      bad[0] ^= 0xff;
      sig = bad.toString("base64");
    }

    const raw = JSON.stringify({
      type: "hello",
      protocolVersion: 3,
      deviceType: this.deviceType,
      deviceId: this.deviceId,
      name: this.name,
      publicKey: this.publicKeyBase64,
      epoch,
      licenseToken,
      ts,
      nonce,
      sig,
    });
    this.onOutbound?.(raw);
    this.ws?.send(raw);
  }

  /** Resolve once the underlying socket has closed (true), or false on timeout.
   *  Observes relay-initiated supersession/close. */
  waitForClose(timeoutMs = 5_000): Promise<boolean> {
    if (this.wsClosed) return Promise.resolve(true);
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        const idx = this.closeWaiters.indexOf(onClose);
        if (idx !== -1) this.closeWaiters.splice(idx, 1);
        resolve(false);
      }, timeoutMs);
      const onClose = () => {
        clearTimeout(timer);
        resolve(true);
      };
      this.closeWaiters.push(onClose);
    });
  }

  // --- Binary receive path (kind-byte dispatch, design §3.1) ---

  private handleBinaryFrame(data: ArrayBuffer | Uint8Array): void {
    const buf = Buffer.from(data as Uint8Array);
    let decoded: { header: unknown; payload: Uint8Array; kind: FrameKind };
    try {
      decoded = decodeRouteFrame(buf);
    } catch {
      return; // malformed frame — drop
    }
    const header = decoded.header as { type?: string; from?: string; channel?: string };
    if (header.type !== "message") return;
    const channel = header.channel === "preview" ? "preview" : "control";

    if (decoded.kind === FrameKind.handshake) {
      // Kind-1 plaintext admits exactly the handshake messages; the phone only
      // ever consumes agent-hello.
      let obj: any;
      try {
        obj = JSON.parse(Buffer.from(decoded.payload).toString("utf8"));
      } catch {
        return;
      }
      if (obj?.type === "handshake:agent-hello") this.deliver(obj);
      return;
    }
    // kind === sealed: decrypt-or-drop.
    this.handleSealedFrame(Buffer.from(decoded.payload), channel);
  }

  private handleSealedFrame(payload: Buffer, channel: "control" | "preview"): void {
    // Make-before-break: try the established context first, then a rekey candidate.
    if (this.established) {
      const pt = this.established.transport.open(payload);
      if (pt !== null) {
        this.onSealedPlaintext(pt, channel, false);
        return;
      }
    }
    if (this.pending) {
      const pt = this.pending.transport.open(payload);
      if (pt !== null) {
        this.onSealedPlaintext(pt, channel, true);
        return;
      }
    }
    // Undecryptable now: most likely a candidate agent-ready racing ahead of key
    // derivation — buffer for replay once the transport is installed.
    this.pendingEncrypted.push(new Uint8Array(payload));
  }

  private onSealedPlaintext(plaintext: string, channel: "control" | "preview", fromPending: boolean): void {
    // Fragmented app traffic → buffer; onComplete routes the reassembled envelope.
    if (this.fragReassembler.accept(plaintext)) {
      if (!fromPending) this.recordSealedRecv();
      return;
    }
    let obj: any;
    try {
      obj = JSON.parse(plaintext);
    } catch {
      return;
    }
    if (obj && typeof obj === "object" && typeof obj.type === "string") {
      // Bare session/liveness frame (top-level `type`). App traffic is always
      // wrapped in `{ s?, m }`, so a top-level `type` is unambiguously a session
      // frame (design §6.1 / §7.1).
      if (obj.type === "pong" && this.swallowPongs) return; // liveness lever — drop, don't record
      if (!fromPending) this.recordSealedRecv();
      this.handleSessionFrame(obj);
      return;
    }
    if (obj && typeof obj === "object" && "m" in obj) {
      if (!fromPending) this.recordSealedRecv();
      this.routeAppEnvelope(obj as { s?: string; m: unknown });
      return;
    }
  }

  private handleSessionFrame(obj: { type: string; attemptId?: string; confirm?: string }): void {
    switch (obj.type) {
      case "handshake:agent-ready":
        this.deliver(obj);
        return;
      case "established":
        // dropEstablished hook: swallow the FIRST established for the in-flight
        // attempt so the phone must retransmit app:ready to establish (design §6.1).
        if (this.dropEstablishedAttemptId && obj.attemptId === this.dropEstablishedAttemptId) {
          this.dropEstablishedAttemptId = null;
          return;
        }
        this.deliver(obj);
        return;
      case "ping": {
        // Answer sealed under whichever context is currently confirmed.
        const ctx = this.established;
        if (ctx) this.sendSealedFrame({ type: "pong" }, ctx.transport, "control");
        return;
      }
      case "pong":
        this.missedPongs = 0;
        return;
      case "session-takeover":
        // Sent by the bridge's single-active-phone takeover (spec 2026-07-24
        // §4.3) to the session it's about to tear down. Deliver it like any
        // other session frame so a test can `waitFor` the mechanism directly,
        // instead of only inferring it from a later dead round trip.
        this.deliver(obj);
        return;
      default:
        return; // unexpected session frame — drop
    }
  }

  private routeReassembledEnvelope(json: string): void {
    let env: { s?: string; m?: unknown };
    try {
      env = JSON.parse(json);
    } catch {
      return;
    }
    if (env && typeof env === "object" && "m" in env) this.routeAppEnvelope(env as { s?: string; m: unknown });
  }

  private routeAppEnvelope(env: { s?: string; m: unknown }): void {
    const s = env.s;
    const streamId = typeof s === "string" && s !== CONTROL_STREAM_ID ? s : undefined;
    this.dispatchAbMessage(JSON.stringify(env.m), streamId);
  }

  /** Parse a plaintext AbMessage (or tunnel frame) and route it to waiters/queue.
   *  `streamId` tags it so `waitForStreamAbType` can distinguish project streams
   *  from the control plane (design §7.1); control-plane messages carry none. */
  private dispatchAbMessage(json: string, streamId?: string): void {
    const msg = parseMessage(json);
    if (!msg) {
      // Tunnel-protocol frames aren't AbMessages — surface them raw by requestId.
      try {
        const raw = JSON.parse(json);
        if (typeof raw?.type === "string" && raw.type.startsWith("tunnel:")) {
          if (streamId) raw._streamId = streamId;
          this.deliver(raw);
        }
      } catch {
        /* not JSON — drop */
      }
      return;
    }
    // `stream-ready` teaches the phone the streamId for a project (design §7.4).
    if (msg.type === ("stream-ready" as AbMessage["type"])) {
      const anyMsg = msg as any;
      if (anyMsg.projectId && anyMsg.streamId) this.streamByProject.set(anyMsg.projectId, anyMsg.streamId);
    }
    if (streamId) (msg as any)._streamId = streamId;
    this.deliver(msg);
  }

  /** Match a delivered message against armed waiters, else queue it. */
  private deliver(msg: any): void {
    for (let i = 0; i < this.waiters.length; i++) {
      if (this.waiters[i].match(msg)) {
        const waiter = this.waiters.splice(i, 1)[0];
        clearTimeout(waiter.timer);
        waiter.resolve(msg);
        return;
      }
    }
    this.messageQueue.push(msg);
  }

  // --- E2E handshake (design §6.1) ---

  /** Set while a `dropEstablished` attempt is in flight (the attemptId whose
   *  first `established` must be swallowed). */
  private dropEstablishedAttemptId: string | null = null;

  /**
   * Perform the v3 acked E2E handshake with the agent through the relay.
   *
   * Phone perspective:
   *  1. Generate ephemeral X25519 keypair + phone-generated `attemptId` + nonce.
   *  2. Sign the PHONE-role transcript (pull-model: empty agentX25519Pub).
   *  3. Send kind-1 `client-hello { attemptId, pubkey, nonce, sig }`.
   *  4. Receive kind-1 `agent-hello { attemptId, pubkey, sig }`; verify against
   *     the pinned agent Ed25519 key when supplied.
   *  5. Derive directional keys; install as the (sole) receive context.
   *  6. Receive sealed `agent-ready { attemptId, confirm }`; verify confirm tag.
   *  7. Send sealed `app:ready { attemptId, confirm }`, retransmit every 2s until
   *     the agent's sealed `established { attemptId }` arrives; return only then.
   *
   * `attemptId` is correlation only — it never enters the transcript (the nonce
   * already binds the attempt cryptographically).
   */
  async performE2EHandshake(
    agentDeviceId: string,
    timeoutMs = 10_000,
    opts: {
      /** MITM: corrupt the received agent-hello pubkey before deriving. */
      corruptAgentHelloPubkey?: boolean;
      /** Omit the client-hello transcript signature (unsigned client). */
      omitClientHelloSig?: boolean;
      /** Replace agent-ready's confirm with random bytes before verifying. */
      corruptAgentReadyConfirm?: boolean;
      /** Pinned agent Ed25519 pubkey (raw 32 bytes, base64). When set, the phone
       *  verifies the agent-hello transcript signature and ABORTS on mismatch. */
      agentEd25519Pub?: string;
      /** Wedge-recovery hook: skip the FIRST app:ready send; the 2s retransmit
       *  then establishes the session (design §12 wedge recovery). */
      dropFirstAppReady?: boolean;
      /** Wedge-recovery hook: swallow the agent's first `established` so the phone
       *  retransmits app:ready and establishes on the agent's idempotent re-send. */
      dropEstablished?: boolean;
      /** Wedge-recovery hook: never retransmit app:ready. Combined with
       *  `dropFirstAppReady` the attempt times out (a FRESH attempt must recover
       *  — no permanent wedge state). */
      noRetransmit?: boolean;
    } = {},
  ): Promise<void> {
    this.e2eMode = true;

    // Reset partial state from a prior failed attempt. A CONFIRMED live session
    // is left intact (a failed re-attempt must not tear down a working session).
    if (!this.sessionConfirmed) {
      this.established?.transport.zeroize();
      this.established = null;
      this.pending?.transport.zeroize();
      this.pending = null;
      this.pendingEncrypted = [];
    }

    const keypair = generateEphemeralKeypair();
    const phoneX25519Pub = keypair.publicKey;
    const attemptId = randomBytes(8).toString("hex");
    const nonce = randomBytes(16);

    let sigB64 = "";
    if (!opts.omitClientHelloSig) {
      const phoneTranscript = buildTranscript({
        registrationId: agentDeviceId,
        role: "phone",
        agentDeviceId,
        phoneDeviceId: this.transcriptDeviceId,
        agentX25519Pub: Buffer.alloc(0),
        phoneX25519Pub,
        nonce,
      });
      const pkcs8 = rawSeedToPkcs8(this.privateKeySeed);
      sigB64 = nodeSign(null, phoneTranscript, { key: pkcs8, format: "der", type: "pkcs8" }).toString("base64");
    }

    // Step 3: kind-1 client-hello.
    this.sendHandshakePlaintext(agentDeviceId, {
      type: "handshake:client-hello",
      attemptId,
      pubkey: phoneX25519Pub.toString("base64"),
      nonce: nonce.toString("base64"),
      sig: sigB64,
    });

    // Step 4: agent-hello.
    const agentHello = await this.waitFor(
      (m: any) => m.type === "handshake:agent-hello" && m.attemptId === attemptId,
      timeoutMs,
    );
    let agentX25519Pub = Buffer.from(agentHello.pubkey, "base64");
    if (opts.corruptAgentHelloPubkey) {
      const corrupted = Buffer.from(agentX25519Pub);
      corrupted[0] ^= 0xff;
      agentX25519Pub = corrupted;
    }

    // Step 5: derive keys over the AGENT-role transcript (agent pub as received).
    const agentTranscript = buildTranscript({
      registrationId: agentDeviceId,
      role: "agent",
      agentDeviceId,
      phoneDeviceId: this.transcriptDeviceId,
      agentX25519Pub,
      phoneX25519Pub,
      nonce,
    });
    if (opts.agentEd25519Pub) {
      if (!verifyTranscriptSig(agentTranscript, opts.agentEd25519Pub, agentHello.sig ?? "")) {
        throw new Error("agent-hello sig invalid — aborting handshake (possible MITM)");
      }
    }
    const sharedSecret = deriveSharedSecret(keypair.privateKey, agentX25519Pub);
    keypair.privateKey.fill(0);
    const sessionKeys = deriveSessionKeys(sharedSecret, agentTranscript);
    // Phone transport: send = p2a (phone→agent), recv = a2p (agent→phone).
    const transport = new E2eTransport({ sendKey: sessionKeys.p2a, recvKey: sessionKeys.a2p });
    const ctx: E2eContext = { attemptId, transport, confirmKey: sessionKeys.confirm };
    this.established = ctx;
    this.replayPendingEncrypted();

    // Step 6: sealed agent-ready + confirm-tag verify.
    const agentReady = await this.waitFor(
      (m: any) => m.type === "handshake:agent-ready" && m.attemptId === attemptId,
      timeoutMs,
    );
    let agentConfirmB64: string = agentReady.confirm ?? "";
    if (opts.corruptAgentReadyConfirm) agentConfirmB64 = randomBytes(32).toString("base64");
    if (!verifyConfirmTag(agentConfirmTag(sessionKeys.confirm), Buffer.from(agentConfirmB64, "base64"))) {
      transport.zeroize();
      this.established = null;
      throw new Error("agent-ready confirm tag invalid — handshake rejected");
    }

    // Step 7: sealed app:ready with retransmit until established.
    const appReady = { type: "app:ready", attemptId, confirm: phoneConfirmTag(sessionKeys.confirm).toString("base64") };
    if (opts.dropEstablished) this.dropEstablishedAttemptId = attemptId;
    const establishedP = this.waitFor((m: any) => m.type === "established" && m.attemptId === attemptId, timeoutMs);
    if (!opts.dropFirstAppReady) this.sendSealedFrame(appReady, transport, "control");
    let retransmit: ReturnType<typeof setInterval> | null = null;
    if (!opts.noRetransmit) {
      retransmit = setInterval(() => this.sendSealedFrame(appReady, transport, "control"), 2_000);
      retransmit.unref?.();
    }
    try {
      await establishedP;
    } finally {
      if (retransmit) clearInterval(retransmit);
      this.dropEstablishedAttemptId = null;
    }
    this.sessionConfirmed = true;
    this.startLiveness();
  }

  /**
   * Make-before-break rekey on the LIVE socket (design §6.2): run a fresh
   * handshake while keeping the current session's keys live for receiving,
   * then atomically swap and zeroize the old keys. Used by the rekey gate test
   * (drive it directly, or let phone-side liveness auto-trigger it).
   */
  async rekey(agentDeviceId: string, agentEd25519Pub: string, timeoutMs = 10_000): Promise<void> {
    if (!this.established) throw new Error("rekey requires an established session");
    if (this.rekeyInFlight) return;
    this.rekeyInFlight = true;
    try {
      const keypair = generateEphemeralKeypair();
      const phoneX25519Pub = keypair.publicKey;
      const attemptId = randomBytes(8).toString("hex");
      const nonce = randomBytes(16);

      const phoneTranscript = buildTranscript({
        registrationId: agentDeviceId,
        role: "phone",
        agentDeviceId,
        phoneDeviceId: this.transcriptDeviceId,
        agentX25519Pub: Buffer.alloc(0),
        phoneX25519Pub,
        nonce,
      });
      const pkcs8 = rawSeedToPkcs8(this.privateKeySeed);
      const sigB64 = nodeSign(null, phoneTranscript, { key: pkcs8, format: "der", type: "pkcs8" }).toString("base64");
      this.sendHandshakePlaintext(agentDeviceId, {
        type: "handshake:client-hello",
        attemptId,
        pubkey: phoneX25519Pub.toString("base64"),
        nonce: nonce.toString("base64"),
        sig: sigB64,
      });

      const agentHello = await this.waitFor(
        (m: any) => m.type === "handshake:agent-hello" && m.attemptId === attemptId,
        timeoutMs,
      );
      const agentX25519Pub = Buffer.from(agentHello.pubkey, "base64");
      const agentTranscript = buildTranscript({
        registrationId: agentDeviceId,
        role: "agent",
        agentDeviceId,
        phoneDeviceId: this.transcriptDeviceId,
        agentX25519Pub,
        phoneX25519Pub,
        nonce,
      });
      if (!verifyTranscriptSig(agentTranscript, agentEd25519Pub, agentHello.sig ?? "")) {
        throw new Error("rekey agent-hello sig invalid");
      }
      const sharedSecret = deriveSharedSecret(keypair.privateKey, agentX25519Pub);
      keypair.privateKey.fill(0);
      const sessionKeys = deriveSessionKeys(sharedSecret, agentTranscript);
      const transport = new E2eTransport({ sendKey: sessionKeys.p2a, recvKey: sessionKeys.a2p });
      // Candidate: receive-only until established (old keys still decrypt traffic).
      this.pending = { attemptId, transport, confirmKey: sessionKeys.confirm };
      this.replayPendingEncrypted();

      const agentReady = await this.waitFor(
        (m: any) => m.type === "handshake:agent-ready" && m.attemptId === attemptId,
        timeoutMs,
      );
      if (!verifyConfirmTag(agentConfirmTag(sessionKeys.confirm), Buffer.from(agentReady.confirm ?? "", "base64"))) {
        transport.zeroize();
        this.pending = null;
        throw new Error("rekey agent-ready confirm invalid");
      }
      const appReady = { type: "app:ready", attemptId, confirm: phoneConfirmTag(sessionKeys.confirm).toString("base64") };
      const establishedP = this.waitFor((m: any) => m.type === "established" && m.attemptId === attemptId, timeoutMs);
      this.sendSealedFrame(appReady, transport, "control");
      const retransmit = setInterval(() => this.sendSealedFrame(appReady, transport, "control"), 2_000);
      retransmit.unref?.();
      try {
        await establishedP;
      } finally {
        clearInterval(retransmit);
      }
      // Swap: promote the candidate, zeroize the old keys.
      const old = this.established;
      this.established = this.pending;
      this.pending = null;
      old?.transport.zeroize();
      this.recordSealedRecv();
    } finally {
      this.rekeyInFlight = false;
    }
  }

  private replayPendingEncrypted(): void {
    if (this.pendingEncrypted.length === 0) return;
    const pending = this.pendingEncrypted.splice(0);
    for (const p of pending) this.handleSealedFrame(Buffer.from(p), "control");
  }

  // --- Streams (design §7) ---

  /**
   * Drill into a project: send control-plane `project:start`, await the sealed
   * `stream-ready { projectId, streamId }`, and return the streamId to tag
   * subsequent project traffic (design §7.4). No new socket, no pairing.
   */
  async openProjectStream(projectId: string, timeoutMs = 10_000): Promise<string> {
    const existing = this.streamByProject.get(projectId);
    if (existing) return existing;
    this.sendEncrypted(createMessage("project:start", { projectId } as any));
    const ready = await this.waitFor(
      (m: any) => m.type === "stream-ready" && m.projectId === projectId,
      timeoutMs,
    );
    const streamId = (ready as any).streamId as string;
    this.streamByProject.set(projectId, streamId);
    return streamId;
  }

  /** Send an AbMessage tagged with a project stream (`{ s: streamId, m }`). */
  sendOnStream(streamId: string, msg: AbMessage): void {
    this.sendAppEnvelope(streamId, msg, "control");
  }

  /** Await an AbMessage of `type` arriving on a specific project stream. */
  waitForStreamAbType<T extends AbMessage["type"]>(
    streamId: string,
    type: T,
    timeoutMs = 5_000,
  ): Promise<Extract<AbMessage, { type: T }>> {
    return this.waitFor((m: any) => m.type === type && m._streamId === streamId, timeoutMs);
  }

  // --- Sending ---

  /** Send an AbMessage on the machine CONTROL PLANE (`s` omitted), sealed. */
  sendEncrypted(msg: AbMessage): void {
    this.sendAppEnvelope(CONTROL_STREAM_ID, msg, "control");
  }

  /** Seal + send a tunnel-protocol message on the preview channel (control plane). */
  sendEncryptedTunnel(data: object): void {
    this.sendAppEnvelope(CONTROL_STREAM_ID, data, "preview");
  }

  /** Wrap `msg` in the `{ s?, m }` stream envelope (design §7.1), seal, and send.
   *  Control-plane traffic uses `CONTROL_STREAM_ID` (`s` omitted). */
  private sendAppEnvelope(streamId: string, msg: unknown, channel: "control" | "preview"): void {
    const ctx = this.established;
    if (!ctx || !this._pairedPeerId) throw new Error("Not paired or no E2E session");
    const envelope = streamId && streamId !== CONTROL_STREAM_ID ? { s: streamId, m: msg } : { m: msg };
    this.sendRelayPayload(this._pairedPeerId, ctx.transport.seal(JSON.stringify(envelope)), channel);
  }

  /** Seal one bare session/liveness frame under `transport` and send it kind-0. */
  private sendSealedFrame(obj: object, transport: E2eTransport, channel: "control" | "preview"): void {
    this.sendRelayPayload(this._pairedPeerId!, transport.seal(JSON.stringify(obj)), channel);
  }

  /** Send a kind-1 plaintext handshake frame to `to`. */
  private sendHandshakePlaintext(to: string, obj: object): void {
    const frame = encodeRouteFrame(
      { type: "message", to, channel: "control" },
      Buffer.from(JSON.stringify(obj), "utf8"),
      FrameKind.handshake,
    );
    this.sendBinary(frame);
  }

  private _pairedPeerId: string | null = null;

  /** Set the addressed peer id (the BARE agent deviceUuid) that outbound app
   *  traffic routes to. Admission is account-trust, not a pairing ceremony —
   *  this is local addressing bookkeeping only, never sent over the wire. */
  setPeerId(peerId: string): void {
    this._pairedPeerId = peerId;
  }

  /** Send a sealed binary payload as a route-message frame (kind-0). */
  private sendRelayPayload(to: string, payload: Uint8Array | Buffer, channel: "control" | "preview" = "control"): void {
    const bytes = payload instanceof Buffer ? payload : Buffer.from(payload);
    this.sendBinary(encodeRouteFrame({ type: "message", to, channel }, bytes, FrameKind.sealed));
  }

  /** Send an OPAQUE payload to a peer as a sealed-kind route frame. The relay
   *  forwards it verbatim; used by low-level routing/isolation tests (the payload
   *  is not real ciphertext, so the peer will drop it). */
  sendMessage(to: string, channel: string, payload: string | Uint8Array | Buffer): void {
    const payloadBytes =
      typeof payload === "string"
        ? Buffer.from(payload, "utf8")
        : payload instanceof Buffer
          ? payload
          : Buffer.from(payload);
    const ch = channel === "preview" ? "preview" : "control";
    this.sendBinary(encodeRouteFrame({ type: "message", to, channel: ch }, payloadBytes, FrameKind.sealed));
  }

  /** Send raw JSON to the relay (control messages, e.g. `stream-open`/`stream-close`). */
  sendRaw(data: any): void {
    if (!this.ws) throw new Error("Not connected");
    const raw = JSON.stringify(data);
    this.onOutbound?.(raw);
    this.ws.send(raw);
  }

  private sendBinary(data: Uint8Array): void {
    if (!this.ws) throw new Error("Not connected");
    this.ws.send(data);
  }

  // --- Phone-side liveness (design §6.2) ---

  private recordSealedRecv(): void {
    this.lastSealedRecvAt = Date.now();
    this.missedPongs = 0;
  }

  private startLiveness(): void {
    this.stopLiveness();
    this.lastSealedRecvAt = Date.now();
    this.missedPongs = 0;
  }

  private stopLiveness(): void {
    if (this.livenessTimer) {
      clearInterval(this.livenessTimer);
      this.livenessTimer = null;
    }
  }

  /**
   * Enable phone-side liveness: after `pingSilenceMs` of sealed-receive silence
   * send a sealed ping; after `maxMissedPongs` unanswered pings, auto-rekey on
   * the live socket (design §6.2). Off by default so short tests aren't
   * disturbed. Combine with {@link setSwallowPongs} to starve liveness on demand.
   */
  enableLiveness(
    agentDeviceId: string,
    agentEd25519Pub: string,
    opts: { pingSilenceMs?: number; maxMissedPongs?: number } = {},
  ): void {
    this.pingSilenceMs = opts.pingSilenceMs ?? this.pingSilenceMs;
    this.maxMissedPongs = opts.maxMissedPongs ?? this.maxMissedPongs;
    this.stopLiveness();
    this.lastSealedRecvAt = Date.now();
    this.missedPongs = 0;
    this.livenessTimer = setInterval(() => {
      if (!this.established || this.rekeyInFlight) return;
      if (Date.now() - this.lastSealedRecvAt < this.pingSilenceMs) return;
      if (this.missedPongs >= this.maxMissedPongs) {
        void this.rekey(agentDeviceId, agentEd25519Pub).catch(() => {});
        this.lastSealedRecvAt = Date.now();
        this.missedPongs = 0;
        return;
      }
      this.missedPongs++;
      this.sendSealedFrame({ type: "ping" }, this.established.transport, "control");
    }, Math.max(250, this.pingSilenceMs));
    this.livenessTimer.unref?.();
  }

  /** Test lever: when true, inbound sealed `pong`s are dropped (not counted), so
   *  phone-side liveness starves and rekeys (design §6.2). */
  setSwallowPongs(v: boolean): void {
    this.swallowPongs = v;
  }

  // --- Waiters ---

  waitFor(match: (msg: any) => boolean, timeoutMs = 5_000): Promise<any> {
    return this.waitForCancelable(match, timeoutMs).promise;
  }

  /** Drop already-queued messages of a type so a later `waitFor` binds to a
   *  FRESH occurrence, not a stale queued one. `waitForCancelable` scans the
   *  queue first, so without this a presence event emitted at an earlier
   *  connect can satisfy a waiter meant for a later one. Returns the count
   *  dropped. */
  drainQueued(type: string): number {
    const before = this.messageQueue.length;
    this.messageQueue = this.messageQueue.filter((m) => m?.type !== type);
    return before - this.messageQueue.length;
  }

  private waitForCancelable(
    match: (msg: any) => boolean,
    timeoutMs = 5_000,
  ): { promise: Promise<any>; cancel: () => void } {
    for (let i = 0; i < this.messageQueue.length; i++) {
      if (match(this.messageQueue[i])) {
        return { promise: Promise.resolve(this.messageQueue.splice(i, 1)[0]), cancel: () => {} };
      }
    }
    let entry: (typeof this.waiters)[number] | undefined;
    const promise = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const idx = this.waiters.findIndex((w) => w.timer === timer);
        if (idx !== -1) this.waiters.splice(idx, 1);
        reject(new Error(`Timed out waiting for message (${timeoutMs}ms)`));
      }, timeoutMs);
      entry = { match, resolve, reject, timer };
      this.waiters.push(entry);
    });
    const cancel = () => {
      if (!entry) return;
      clearTimeout(entry.timer);
      const idx = this.waiters.indexOf(entry);
      if (idx !== -1) this.waiters.splice(idx, 1);
    };
    return { promise, cancel };
  }

  waitForType(type: string, timeoutMs = 5_000): Promise<any> {
    return this.waitFor((msg) => msg.type === type, timeoutMs);
  }

  /** Await a control-plane AbMessage of a specific type (post-handshake). */
  waitForAbType<T extends AbMessage["type"]>(
    type: T,
    timeoutMs = 5_000,
  ): Promise<Extract<AbMessage, { type: T }>> {
    return this.waitFor((msg: any) => msg.type === type, timeoutMs);
  }

  waitForTunnelResponse(requestId: string, timeoutMs = 10_000): Promise<any> {
    return this.waitFor((m: any) => m?.type === "tunnel:http-response" && m.requestId === requestId, timeoutMs);
  }

  /**
   * Pull-then-replay welcome state — mirrors the app's `RelayTransport.connect()`.
   * Issues the `state.snapshot` RPC and replays the cached frames through the
   * normal dispatch path. A pre-RPC agent answers `ok:false` → we fall through to
   * live frames, exactly like the app's `on RpcException` branch.
   */
  async pullStateSnapshot(timeoutMs = 10_000): Promise<void> {
    const requestId = `snap-${randomBytes(6).toString("hex")}`;
    const responseP = this.waitFor((m) => m.type === "response" && m.requestId === requestId, timeoutMs).catch(
      () => null,
    );
    this.sendEncrypted(createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
    const res = await responseP;
    if (!res || !res.ok) return;
    const frames = ((res.result as { frames?: AbMessage[] } | undefined)?.frames ?? []) as AbMessage[];
    for (const frame of frames) this.dispatchAbMessage(JSON.stringify(frame));
  }

  get isClosed(): boolean {
    return this.wsClosed;
  }

  /** Re-establish a fresh authenticated socket under the SAME identity after an
   *  unpaired close (does NOT restore a paired peer id). */
  async reconnectAndAuth(relayUrl: string): Promise<void> {
    await this.connectAndAuthenticate(relayUrl);
  }

  /** Hard-close the socket WITHOUT touching E2E/session bookkeeping —
   *  simulates an unintentional network drop (unlike `disconnect()`, a
   *  deliberate app-side teardown that also resets E2E state and clears the
   *  paired peer id). Leaves `_pairedPeerId`/E2E context intact so a
   *  subsequent `reconnectAndAuth` + `performE2EHandshake` mirrors a real
   *  redial, not a fresh pairing. */
  dropSocket(): void {
    this.ws?.close();
    this.ws = null;
  }

  /** Override the `licenseToken` presented on the NEXT hello (a fresh
   *  `connectAndAuth`/`reconnectAndAuth`). Lets a caller simulate an app
   *  token that expires mid-session and recovers on the next mint (design §8
   *  token-expiry row) without a real JWT. Persists until overridden again. */
  setLicenseToken(token: string): void {
    this.helloOpts.licenseToken = token;
  }

  /** Reconnect with the SAME identity, restoring the paired peer id — the grant
   *  survives on the relay, so routing works immediately (design §5.1). Call
   *  `performE2EHandshake` again for a fresh session. */
  async reconnect(relayUrl: string, pairedPeerId: string): Promise<void> {
    this.resetE2e();
    this._pairedPeerId = pairedPeerId;
    await this.connectAndAuthenticate(relayUrl);
  }

  private resetE2e(): void {
    this.established?.transport.zeroize();
    this.established = null;
    this.pending?.transport.zeroize();
    this.pending = null;
    this.e2eMode = false;
    this.sessionConfirmed = false;
    this.pendingEncrypted = [];
    this.streamByProject.clear();
    this.stopLiveness();
  }

  async disconnect(): Promise<void> {
    this.stopLiveness();
    this.waiters.forEach((w) => {
      clearTimeout(w.timer);
      w.reject(new Error("Disconnected"));
    });
    this.waiters = [];
    this.messageQueue = [];
    this.resetE2e();
    this._pairedPeerId = null;
    this.ws?.close();
    this.ws = null;
  }
}
