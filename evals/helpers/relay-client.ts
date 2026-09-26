import { randomBytes } from "node:crypto";
import { Endpoint, EndpointAddr, EndpointId, type Connection } from "@number0/iroh/index.js";
import { EndpointEnrollment } from "../../bridge/src/peer/enrollment";
import { createMessage, parseMessage, type AbMessage } from "../../bridge/src/protocol";
import { CONTROL_HANDLE } from "../support/stream";
import {
  encodePeerFrame,
  decodePeerFrame,
  encodeStreamOpen,
  PEER_ALPN,
  PEER_MAX_BRIDGE_RECORD_BYTES,
  type PeerAuthorizationSnapshot,
  type PeerFrameKind,
  buildHelloSigBody,
  normalizeRelayHost,
  STREAM_PROJECT_APP_RECORD_MAX_BYTES,
  STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES,
  STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES,
  STREAM_TUNNEL_RECORD_MAX_BYTES,
  STREAM_UPLOAD_BRIDGE_RECORD_MAX_BYTES,
  TUNNEL_RECORD_TAG_WS_TEXT,
  TUNNEL_RECORD_TAG_WS_BINARY,
  encodeTunnelDataRecord,
  decodeTunnelRecord,
} from "antgrid-wire";
import { StreamRecordReader, StreamRecordWriter, STREAM_RECORD_SLICE_BYTES } from "../../bridge/src/peer/stream-records";

/** Fits two max-size control-plane records on the session stream — the same
 *  per-stream bound as `SESSION_STREAM_MAX_QUEUED_BYTES` in
 *  `native-host-connection.ts`, which this eval client does not import. */
const SESSION_STREAM_MAX_QUEUED_BYTES = 64 * 1024 * 1024;

/** The fake license token the eval relay gate (`fakeLicenseGate`) accepts. v3
 *  requires it for BOTH device types, so an app now sends it too.
 *  Duplicated (not imported from harness.ts) to avoid a helper import cycle. */
const TEST_LICENSE_TOKEN = "eval-license-token";

/** Mirrors the bridge's own `STREAM_RAW_READ_BYTES` (`bridge/src/peer/stream-records.ts`)
 *  — kept in lockstep by hand, since this client reads the raw upload and
 *  tunnel-http bodies directly off the wire rather than through that module.
 *  Exported so a test can assert a lower bound on how many raw reads a body
 *  of a given size must have taken. */
export const RAW_READ_BYTES = 65_536;

/** Monotonic per-launch epoch source. A client (re)started within
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

/** One tunneled HTTP response, reassembled from a dedicated `tunnel-http`
 *  QUIC stream (Stage A wave A3). The body rides the stream as raw bytes with
 *  no per-record framing, so `chunks` counts only how many separate reads it
 *  took to drain — a diagnostic on read granularity, not a wire record count. */
export interface TunnelHttpResult {
  status: number;
  headers: Record<string, string>;
  setCookies: string[];
  body: Buffer;
  chunks: number;
}

/** A `tunnel-http` stream driven directly, mirroring the app's own
 *  `StreamTransport.openTunnelHttp` without its retry or queueing policy —
 *  see `openTerminalStream`'s header comment for why this exists beside the
 *  Dart client at all. */
export interface TunnelHttpStreamClient {
  readonly requestId: string;
  /** The `tunnel:http-head` record, or rejects with an Error carrying
   *  `.refusal` (the `stream:refused` record) when the open was refused. */
  head(timeoutMs?: number): Promise<Record<string, any>>;
  /** Head + the raw response body, read to a clean FIN; rejects on refusal
   *  or a status other than `"end"`. */
  response(timeoutMs?: number): Promise<TunnelHttpResult>;
  bodyBytesSoFar(): number;
  /** Stops/restarts issuing reads, so QUIC flow control pushes back on the
   *  bridge's writer instead of this client draining as fast as it can. */
  pauseReading(): void;
  resumeReading(): void;
  /** Resets the send half only; the receive half keeps draining (D4: the app
   *  cancels the same way, and the bridge learns of it through its own
   *  pending read). */
  cancel(): void;
  readonly ended: Promise<"end" | "truncated" | "refused" | "reset-before-head">;
}

/** An `upload` stream driven directly: the open frame, then the file's raw
 *  bytes with no framing, then (by default) FIN — mirroring
 *  `StreamTransport.openUpload` without its slot semaphore or progress
 *  callback, the same relationship `openTerminalStream` has to the Dart
 *  client. */
export interface UploadStreamClient {
  readonly requestId: string;
  /** Bytes handed to the native `writeAll` calls so far, across the initial
   *  write and any `writeMore`. */
  bytesWritten(): number;
  /** The bridge's `file:upload-result`, or rejects with an Error carrying
   *  `.refusal` (a `stream:refused`) or a plain message when the stream ended
   *  with no result at all. */
  result(timeoutMs?: number): Promise<Record<string, any>>;
  /** `"reset"` and `"fin-without-result"` are both "no result arrived", kept
   *  distinct because a raw read (unlike `readExact`) can tell a clean FIN
   *  from a reset apart — useful for pinning which one a given row produced. */
  readonly ended: Promise<"result" | "refused" | "reset" | "fin-without-result">;
  readonly refusal: Record<string, any> | null;
  /** Writes more raw bytes on the still-open send half — only meaningful when
   *  the stream was opened with `finish: false`. */
  writeMore(bytes: Uint8Array): Promise<void>;
  /** Resets the send half only, mirroring the app's own cancel (D4). */
  cancel(): void;
}

export type TunnelWsRecord =
  | { kind: "text"; text: string }
  | { kind: "binary"; bytes: Buffer }
  | { kind: "close"; code?: number; reason?: string }
  | { kind: "refused"; refusal: Record<string, any> };

/** A `tunnel-ws` stream driven directly. `records`/`next` see every record in
 *  arrival order; the caller narrows by `kind`. */
export interface TunnelWsStreamClient {
  readonly tunnelId: string;
  readonly records: TunnelWsRecord[];
  next(predicate: (r: TunnelWsRecord) => boolean, timeoutMs?: number): Promise<TunnelWsRecord>;
  sendText(text: string): Promise<void>;
  sendBinary(bytes: Uint8Array): Promise<void>;
  /** Writes `tunnel:ws-close` after every queued frame, then `finish()`. */
  close(code?: number, reason?: string): Promise<void>;
  /** `reset()` with no close record. */
  reset(): void;
  readonly ended: Promise<void>;
}

/** A terminal-kind native stream driven directly, without the app's own
 *  subscribe/re-sync logic — the test sends `terminal:subscribe` itself so it
 *  can assert on the raw record sequence (hazards A and B, §1 of the A2
 *  contract). `records` and `next` see every record (AbMessage bodies AND a
 *  `stream:refused`) as plain parsed JSON; the caller narrows by `type`. */
export interface TerminalStreamClient {
  readonly records: Array<Record<string, any>>;
  next(predicate: (record: Record<string, any>) => boolean, timeoutMs?: number): Promise<Record<string, any>>;
  send(msg: AbMessage | Record<string, unknown>): Promise<void>;
  finish(): Promise<void>;
  reset(): void;
  readonly ended: Promise<void>;
}

/** One project's admitted QUIC stream (Stage A wave A4: project streams
 *  replace the mux). `open` is true only between the bound `stream-ready` and
 *  this half's end. `closingLocally` distinguishes a clean local close from a
 *  bridge-initiated FIN/reset for `ended`'s classification — the two are
 *  otherwise wire-indistinguishable (D4: `stopped()`/`receivedReset()` are
 *  never awaited, mirroring the binding-constraint hard rule bridge-src and
 *  Dart both follow). */
interface ProjectStreamState {
  readonly projectId: string;
  readonly stream: Awaited<ReturnType<Connection["openBi"]>>;
  open: boolean;
  closingLocally: boolean;
  refusal?: { code: string; message: string };
  readonly ended: Promise<"fin" | "error">;
  /** Writes are chained through this so `sendOnStream` calls land on the wire
   *  in call order even though each write is itself async. */
  writeChain: Promise<void>;
}

export class NativeAuthorizationNotReadyError extends Error {
  constructor(readonly machineDeviceId: string, cause: unknown) {
    super(`Native authorization for ${machineDeviceId} is not ready: ${String(cause)}`);
    this.name = "NativeAuthorizationNotReadyError";
  }
}

/** Races `promise` against `timeoutMs` without cancelling it — `promise`
 *  itself still settles exactly once, so a caller that times out and a later
 *  caller awaiting the same promise both see its real outcome. */
function withTimeout<T>(promise: Promise<T>, timeoutMs: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${label} (${timeoutMs}ms)`)), timeoutMs);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (err) => {
        clearTimeout(timer);
        reject(err);
      },
    );
  });
}

/** `[u32 BE len][bytes]`, the framing every stream-open and refusal record uses. */
function prefixWithLength(bytes: Uint8Array): Uint8Array {
  const out = Buffer.alloc(4 + bytes.length);
  out.writeUInt32BE(bytes.length, 0);
  Buffer.from(bytes.buffer, bytes.byteOffset, bytes.length).copy(out, 4);
  return out;
}

/** Splits a byte stream into `[u32 BE len][body]` records, stopping at the
 *  first short or truncated prefix (the tail of a raw readToEnd is never a
 *  partial record in a well-formed reply, but a probe's hand-built input can
 *  be anything). */
function splitLengthPrefixedRecords(buf: Buffer): Uint8Array[] {
  const records: Uint8Array[] = [];
  let offset = 0;
  while (offset + 4 <= buf.length) {
    const len = buf.readUInt32BE(offset);
    offset += 4;
    if (offset + len > buf.length) break;
    records.push(new Uint8Array(buf.subarray(offset, offset + len)));
    offset += len;
  }
  return records;
}

/** One outcome of `readOneRawRecord`: a well-formed `[u32 BE len][JSON]`
 *  record, a clean FIN before any byte of it arrived, or anything else
 *  (a reset mid-record, a reset before the length prefix, or a malformed
 *  length) — the last two are collapsed together because neither is a state
 *  a caller needs to tell apart from a genuine reset. */
type RawRecordOutcome =
  | { kind: "record"; bytes: Uint8Array }
  | { kind: "fin" }
  | { kind: "reset" };

/** Reads exactly one length-prefixed JSON record off a RAW receive half
 *  (`recv.read`, not `StreamRecordReader`'s `readExact`): the upload and
 *  tunnel-http admission replies are each a single such record, and only a
 *  raw read can tell a clean FIN apart from a reset (`readExact` rejects on
 *  both, so it collapses the two the caller here wants distinguished). */
async function readOneRawRecord(
  recv: { read(maxLen: number): Promise<number[]> },
  maxBytes: number,
): Promise<RawRecordOutcome> {
  let buf = Buffer.alloc(0);
  // Resolves once `buf` holds at least `n` bytes, or false on a clean FIN
  // strictly short of it.
  const need = async (n: number): Promise<boolean> => {
    while (buf.length < n) {
      const piece = await recv.read(n - buf.length);
      if (piece.length === 0) return false;
      buf = Buffer.concat([buf, Buffer.from(piece)]);
    }
    return true;
  };
  try {
    if (!(await need(4))) return buf.length === 0 ? { kind: "fin" } : { kind: "reset" };
    const length = buf.readUInt32BE(0);
    if (length === 0 || length > maxBytes) return { kind: "reset" };
    if (!(await need(4 + length))) return { kind: "reset" };
    return { kind: "record", bytes: new Uint8Array(buf.subarray(4, 4 + length)) };
  } catch {
    return { kind: "reset" };
  }
}

export class RelayClient {
  private nativeEndpoint: Endpoint | null = null;
  private nativeConnection: Connection | null = null;
  private sessionWriter: StreamRecordWriter | null = null;
  private nativeTarget: { endpointId: string; addresses: string[] } | null = null;
  private nativePeerId: string | null = null;
  private nativeGeneration = 0;
  private e2eGeneration = 0;
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
  /** The ACCOUNT device the peer enrollment binds — `deviceId` may be a
   *  per-machine SLOT (`<transcriptDeviceId>#<machineDeviceId>`). Defaults to
   *  `deviceId`, so an unscoped connection is unaffected. */
  readonly transcriptDeviceId: string;
  readonly deviceType: "agent" | "app";
  readonly name: string;
  private publicKeyBase64: string;
  private privateKey: CryptoKey;
  /** Raw 32-byte Ed25519 seed — used for the native endpoint's enrollment identity. */
  private privateKeySeed: Buffer;
  /** Tap for every outbound text-JSON frame (hello + raw control messages) —
   *  lets a caller assert a negative on the wire (e.g. "never sent pair-request"). */
  private onOutbound?: (raw: string) => void;

  /** Per-connection hello forge/override hooks. */
  private helloOpts: HelloForgeOpts = {};
  /** The nonce sent in the most recent hello — reuse it via `reuseNonce`. */
  lastHelloNonce = "";

  // --- Native session state ---
  // After the flip, QUIC/TLS between the lease-authorized endpoints is the
  // confidentiality layer, so this only tracks whether a `session:hello` has
  // established — no key material lives here.
  private established: { attemptId: string } | null = null;
  /** True once the hello resolves `established`. */
  private sessionConfirmed = false;

  // --- Project streams (Stage A wave A4: project streams replace the mux) ---
  /** projectId → the project's admitted QUIC stream, once bound. Absent for a
   *  project that was never opened, or whose stream has ended. */
  private projectStreams = new Map<string, ProjectStreamState>();
  /** Projects with a live ready notice (session-stream `stream-ready`, or an
   *  `agent:projects` entry with `running:true`) since the last establishment
   *  or this project's last stream end — mirrors `MachineSession`'s
   *  `_readyProjects` so `openProjectStream` skips a redundant `project:start`. */
  private readyProjects = new Set<string>();

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
   *  v3 `hello`. `licenseToken`/`epoch` default sensibly; the
   *  forge hooks let R-level tests drive rejection paths. */
  static async connectAndAuth(
    relayUrl: string,
    opts: {
      deviceType: "agent" | "app";
      name?: string;
      identity?: PhoneIdentity;
      deviceId?: string;
      /** ACCOUNT device the peer enrollment binds. Defaults to `deviceId` —
       *  only a slotted `deviceId` (`<transcriptDeviceId>#<machineDeviceId>`)
       *  needs this set separately. */
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

  /** Sign + send the single v3 `hello`. Honors the forge hooks. */
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

  /** Enroll this app endpoint and dial the machine over a real Iroh connection.
   *  The central socket remains control-only; all peer frames use this link. */
  async connectNative(options: {
    licenseApiUrl: string;
    accountId: string;
    enrollmentId: string;
    clientSecret: string;
    endpointSecret: string;
    machineDeviceId: string;
    addresses: string[];
  }): Promise<void> {
    const token = async (): Promise<string> => {
      const response = await fetch(`${options.licenseApiUrl.replace(/\/$/, "")}/api/auth/oauth2/token`, {
        method: "POST",
        headers: { authorization: `Basic ${Buffer.from(`${options.enrollmentId}:${options.clientSecret}`).toString("base64")}` },
      });
      if (!response.ok) throw new Error(`Eval endpoint token failed: ${response.status}`);
      const body = await response.json() as { access_token?: string };
      if (!body.access_token) throw new Error("Eval endpoint token response omitted access_token");
      return body.access_token;
    };
    const enrollment = new EndpointEnrollment({
      accountId: options.accountId,
      deviceId: this.transcriptDeviceId,
      enrollmentId: options.enrollmentId,
    }, options.endpointSecret, this.privateKeySeed.toString("base64"), options.licenseApiUrl, token);
    try {
      await enrollment.register();
      let target: { endpointId: string; generation: string } | null = null;
      for (let attempt = 0; attempt < 100 && !target; attempt++) {
        const snapshot = await enrollment.authorization() as PeerAuthorizationSnapshot;
        target = snapshot.peers.find((peer) => peer.deviceId === options.machineDeviceId)?.endpoint ?? null;
        if (!target) await Bun.sleep(100);
      }
      if (!target) throw new Error(`Machine ${options.machineDeviceId} did not publish a native endpoint`);
      const builder = Endpoint.builder();
      builder.applyMinimal();
      builder.secretKey(enrollment.seedBytes());
      builder.bindAddr("127.0.0.1:0");
      this.nativeEndpoint = await builder.bind();
      this.nativeTarget = { endpointId: target.endpointId, addresses: options.addresses };
      await this.dialNative();
      this.nativePeerId = options.machineDeviceId;
    } finally {
      enrollment.close();
    }
  }

  private async dialNative(): Promise<void> {
    const endpoint = this.nativeEndpoint;
    const target = this.nativeTarget;
    if (!endpoint || !target) throw new Error("Native endpoint is not configured");
    const generation = ++this.nativeGeneration;
    this.sessionWriter?.abort();
    this.nativeConnection?.close(1n, []);
    let connection: Connection | null = null;
    let lastError: unknown;
    for (let attempt = 0; attempt < 50 && !connection; attempt++) {
      try {
        connection = await endpoint.connect(
          new EndpointAddr(EndpointId.fromString(target.endpointId), undefined, target.addresses),
          Array.from(Buffer.from(PEER_ALPN)),
        );
      } catch (error) {
        lastError = error;
        await Bun.sleep(100);
      }
    }
    if (!connection) throw new Error(`Native dial failed: ${String(lastError)}`);
    const stream = await connection.openBi();
    const writer = new StreamRecordWriter(
      { send: stream.send },
      () => generation === this.nativeGeneration,
      () => connection.close(1n, []),
      SESSION_STREAM_MAX_QUEUED_BYTES,
    );
    const reader = new StreamRecordReader(
      { recv: stream.recv },
      PEER_MAX_BRIDGE_RECORD_BYTES,
      () => connection.close(1n, []),
    );
    // The first record on every native stream, session included, declares
    // its kind before anything else — StreamRecordWriter queues in order, so
    // this goes out ahead of the hello.
    void writer.send(encodeStreamOpen({ kind: "session" }));
    this.nativeConnection = connection;
    this.sessionWriter = writer;
    void (async () => {
      try {
        while (generation === this.nativeGeneration) this.handleBinaryFrame(await reader.read());
      } catch {
        if (generation === this.nativeGeneration) this.sessionWriter = null;
      }
    })();
  }

  /** Redial the configured native endpoint with fresh session state after peer failure. */
  async reconnectNative(): Promise<void> {
    this.resetE2e();
    await this.dialNative();
  }
  /** Interrupt only the native payload path; the central control socket stays authenticated. */
  dropNative(): void {
    this.nativeGeneration++;
    this.sessionWriter?.abort();
    this.sessionWriter = null;
    // Closing the connection ends every project stream on it (bridge-observed
    // FIN/reset); marking closingLocally first classifies that as "fin" for
    // anyone awaiting `ended`, since this is our own teardown, not a fault.
    for (const state of this.projectStreams.values()) state.closingLocally = true;
    this.projectStreams.clear();
    this.readyProjects.clear();
    this.nativeConnection?.close(1n, []);
    this.nativeConnection = null;
  }

  /** `connection.stableId()` of the live native connection, or null. */
  get nativeConnectionId(): number | null {
    return this.nativeConnection?.stableId() ?? null;
  }

  /** Opens one extra bidi stream on the live native connection, writes `bytes`
   *  (length-prefixed by default, or verbatim for a hand-built oversize
   *  prefix), then reads whatever the peer sends back and splits it into
   *  `[u32 len]`-framed records. Drives streams the session protocol never
   *  opens, for the stream-admission gate. */
  async openNativeStreamRaw(
    bytes: Uint8Array,
    opts?: { framed?: boolean; timeoutMs?: number },
  ): Promise<{ records: Uint8Array[]; ended: "fin" | "error" | "timeout" }> {
    const connection = this.nativeConnection;
    if (!connection) throw new Error("Native connection is not established");
    const framed = opts?.framed ?? true;
    const timeoutMs = opts?.timeoutMs ?? 5_000;
    const stream = await connection.openBi();
    const outgoing = framed ? prefixWithLength(bytes) : bytes;
    await stream.send.writeAll(Array.from(outgoing));

    let ended: "fin" | "error" | "timeout";
    let raw: Buffer = Buffer.alloc(0);
    const read = stream.recv.readToEnd(65_536);
    const timedOut = Bun.sleep(timeoutMs).then(() => "timeout" as const);
    const settled = await Promise.race([
      read.then((data) => ({ kind: "data" as const, data }), () => ({ kind: "error" as const })),
      timedOut.then((kind) => ({ kind })),
    ]);
    if (settled.kind === "timeout") {
      ended = "timeout";
    } else if (settled.kind === "error") {
      ended = "error";
    } else {
      ended = "fin";
      raw = Buffer.from(settled.data);
    }
    stream.send.reset(0n).catch(() => {});
    return { records: splitLengthPrefixedRecords(raw), ended };
  }

  /** Opens a `kind:"terminal"` stream on the live native connection and writes
   *  the open frame as the first record (openBi + write is one call, per the
   *  binding constraint that a Dart-side stream is invisible until its first
   *  write — mirrored here for parity, though this side has no such limit).
   *  It does NOT send `terminal:subscribe`: the caller does, as the contract
   *  requires it be the first record. Records are read with the same
   *  `StreamRecordReader` the bridge uses, capped at the bridge's own
   *  outbound record cap, so an oversize or malformed body fails the same way
   *  production code would. */
  async openTerminalStream(open: { projectId: string; requestId: string; checkoutId?: string }): Promise<TerminalStreamClient> {
    const connection = this.nativeConnection;
    if (!connection) throw new Error("Native connection is not established");
    const stream = await connection.openBi();
    const openFrame = prefixWithLength(
      encodeStreamOpen({
        kind: "terminal",
        projectId: open.projectId,
        requestId: open.requestId,
        checkoutId: open.checkoutId,
      }),
    );
    await stream.send.writeAll(Array.from(openFrame));

    const records: Array<Record<string, any>> = [];
    const waiters: Array<{
      match: (record: Record<string, any>) => boolean;
      resolve: (record: Record<string, any>) => void;
      timer: ReturnType<typeof setTimeout>;
    }> = [];
    let settleEnded = () => {};
    const ended = new Promise<void>((resolve) => {
      settleEnded = resolve;
    });

    const reader = new StreamRecordReader({ recv: stream.recv }, STREAM_TERMINAL_BRIDGE_RECORD_MAX_BYTES, () => {});
    void (async () => {
      try {
        while (true) {
          const bytes = await reader.read();
          let obj: Record<string, any>;
          try {
            obj = JSON.parse(Buffer.from(bytes).toString("utf8"));
          } catch {
            continue;
          }
          let delivered = false;
          for (let i = 0; i < waiters.length; i++) {
            if (waiters[i].match(obj)) {
              const waiter = waiters.splice(i, 1)[0];
              clearTimeout(waiter.timer);
              waiter.resolve(obj);
              delivered = true;
              break;
            }
          }
          if (!delivered) records.push(obj);
        }
      } catch {
        // The bridge's half ended — FIN (orderly retirement/refusal) or reset
        // (overflow, stream-lost) look the same from here; `ended` doesn't
        // distinguish them (D4: Dart can't either).
      } finally {
        settleEnded();
      }
    })();

    return {
      records,
      next(predicate, timeoutMs = 10_000): Promise<Record<string, any>> {
        for (let i = 0; i < records.length; i++) {
          if (predicate(records[i]!)) return Promise.resolve(records.splice(i, 1)[0]!);
        }
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => {
            const idx = waiters.findIndex((w) => w.timer === timer);
            if (idx !== -1) waiters.splice(idx, 1);
            reject(new Error(`Timed out waiting for terminal-stream record (${timeoutMs}ms)`));
          }, timeoutMs);
          waiters.push({ match: predicate, resolve, timer });
        });
      },
      async send(msg): Promise<void> {
        const body = prefixWithLength(Buffer.from(JSON.stringify(msg), "utf8"));
        await stream.send.writeAll(Array.from(body));
      },
      async finish(): Promise<void> {
        await stream.send.finish();
      },
      reset(): void {
        void stream.send.reset(0n).catch(() => {});
      },
      ended,
    };
  }

  /** Opens a `kind:"tunnel-http"` stream: the open frame, the
   *  `tunnel:http-request` head (with `bodyLength` stamped from `body`), then
   *  `body` itself as raw bytes in `≤STREAM_RECORD_SLICE_BYTES` slices (§3).
   *  The send half stays open after that — a clean response FIN is what
   *  triggers this side's own `finish()`, since a QUIC reset issued after
   *  `finish()` is unreliable and that is otherwise the only way left to
   *  cancel. `opts.head` may set its own `requestId` to build a deliberate
   *  open/head mismatch for a refusal-path row; otherwise it takes the open
   *  frame's id. */
  async openTunnelHttpStream(opts: {
    projectId: string;
    requestId?: string;
    head: Record<string, unknown>;
    body?: Uint8Array;
  }): Promise<TunnelHttpStreamClient> {
    const connection = this.nativeConnection;
    if (!connection) throw new Error("Native connection is not established");
    const openRequestId = opts.requestId ?? crypto.randomUUID();
    const body = opts.body ?? new Uint8Array(0);
    const stream = await connection.openBi();

    const openFrame = prefixWithLength(
      encodeStreamOpen({ kind: "tunnel-http", projectId: opts.projectId, requestId: openRequestId }),
    );
    await stream.send.writeAll(Array.from(openFrame));

    const head: Record<string, unknown> = {
      ...opts.head,
      requestId: (opts.head as { requestId?: unknown }).requestId ?? openRequestId,
      bodyLength: body.length,
      checkoutId: (opts.head as { checkoutId?: unknown }).checkoutId ?? "main",
    };
    await stream.send.writeAll(Array.from(prefixWithLength(Buffer.from(JSON.stringify(head), "utf8"))));

    for (let offset = 0; offset < body.length; offset += STREAM_RECORD_SLICE_BYTES) {
      const slice = body.subarray(offset, Math.min(offset + STREAM_RECORD_SLICE_BYTES, body.length));
      await stream.send.writeAll(Array.from(slice));
    }

    let gotHead = false;
    let refusal: Record<string, any> | null = null;
    let bodyBytes = 0;
    let chunkCount = 0;
    const bodyChunks: Buffer[] = [];

    let headResolve!: (h: Record<string, any>) => void;
    let headReject!: (e: Error) => void;
    const headPromise = new Promise<Record<string, any>>((resolve, reject) => {
      headResolve = resolve;
      headReject = reject;
    });
    // Nobody may ever call `head()`/`response()` (a cap-refused row, say) —
    // without this, that rejection surfaces as an unhandled rejection instead
    // of the `ended` status the row actually asserts on.
    headPromise.catch(() => {});

    let endedResolve!: (v: "end" | "truncated" | "refused" | "reset-before-head") => void;
    const ended = new Promise<"end" | "truncated" | "refused" | "reset-before-head">((resolve) => {
      endedResolve = resolve;
    });

    let paused = false;
    let resumeWaiters: Array<() => void> = [];
    const waitIfPaused = async (): Promise<void> => {
      if (!paused) return;
      await new Promise<void>((resolve) => resumeWaiters.push(resolve));
    };

    void (async () => {
      // "finish" once a clean response FIN is seen, "reset" for anything
      // else (a reset mid-body, or the stream ending before a head ever
      // arrived) — that decision is also what closes this side's own send
      // half (it stays open until the response has ended, so a reset stays a cancel).
      let sendOutcome: "finish" | "reset" = "reset";
      try {
        // The head/refusal record is still length-prefixed JSON, so a normal
        // record read is enough here — the app can't do anything differently
        // for a clean FIN before it than for a reset before it, and this
        // stream never carries more than the one record before the head.
        const reader = new StreamRecordReader({ recv: stream.recv }, STREAM_TUNNEL_RECORD_MAX_BYTES, () => {});
        const bytes = await reader.read();
        const text = Buffer.from(bytes).toString("utf8");
        let obj: any;
        try {
          obj = JSON.parse(text);
        } catch {
          obj = null;
        }
        if (obj?.type === "stream:refused") {
          refusal = obj;
          headReject(
            Object.assign(new Error(`tunnel-http stream refused: ${obj.code} ${obj.message}`), { refusal: obj }),
          );
          return;
        }
        if (obj?.type !== "tunnel:http-head") {
          headReject(new Error(`unexpected tunnel-http head record: ${text.slice(0, 200)}`));
          return;
        }
        gotHead = true;
        headResolve(obj);

        // Everything after the head is the raw body, with no framing — a
        // clean FIN (an empty read) is the response's orderly end; a reset
        // rejects.
        while (true) {
          await waitIfPaused();
          const raw = await stream.recv.read(RAW_READ_BYTES);
          if (raw.length === 0) {
            sendOutcome = "finish";
            return;
          }
          chunkCount++;
          const chunk = Buffer.from(raw);
          bodyChunks.push(chunk);
          bodyBytes += chunk.length;
        }
      } catch {
        // A reset after the head is an aborted response; before it, the
        // stream ended without ever producing one (both fold into
        // `sendOutcome`'s default above).
      } finally {
        if (sendOutcome === "finish") void stream.send.finish().catch(() => {});
        else void stream.send.reset(0n).catch(() => {});
        endedResolve(refusal ? "refused" : !gotHead ? "reset-before-head" : sendOutcome === "finish" ? "end" : "truncated");
      }
    })();

    return {
      requestId: openRequestId,
      head(timeoutMs = 10_000): Promise<Record<string, any>> {
        return withTimeout(headPromise, timeoutMs, `tunnel-http head for ${openRequestId}`);
      },
      async response(timeoutMs = 10_000): Promise<TunnelHttpResult> {
        const h = await withTimeout(headPromise, timeoutMs, `tunnel-http head for ${openRequestId}`);
        const status = await withTimeout(ended, timeoutMs, `tunnel-http end for ${openRequestId}`);
        if (status !== "end") {
          throw new Error(`tunnel-http stream ${openRequestId} ended "${status}" instead of "end"`);
        }
        return {
          status: h.status,
          headers: (h.headers ?? {}) as Record<string, string>,
          setCookies: (h.setCookies ?? []) as string[],
          body: Buffer.concat(bodyChunks),
          chunks: chunkCount,
        };
      },
      bodyBytesSoFar(): number {
        return bodyBytes;
      },
      pauseReading(): void {
        paused = true;
      },
      resumeReading(): void {
        paused = false;
        const waiters = resumeWaiters.splice(0);
        for (const w of waiters) w();
      },
      cancel(): void {
        void stream.send.reset(0n).catch(() => {});
      },
      ended,
    };
  }

  /** Opens a `kind:"upload"` stream: the open frame, then `opts.bytes` as raw
   *  bytes in `≤sliceBytes` slices (default `STREAM_RECORD_SLICE_BYTES`), then
   *  FIN unless `opts.finish` is `false` — a caller building a cancel-mid-body
   *  or an over/under-declared-size row passes `finish: false` and drives the
   *  send half itself with `writeMore`/`cancel`. `size` defaults to
   *  `bytes.length`; passing a different value is how a row declares more or
   *  less than it actually sends. */
  async openUploadStream(opts: {
    projectId: string;
    checkoutId?: string;
    requestId?: string;
    fileName: string;
    size?: number;
    mimeType?: string;
    bytes: Uint8Array;
    finish?: boolean;
    sliceBytes?: number;
  }): Promise<UploadStreamClient> {
    const connection = this.nativeConnection;
    if (!connection) throw new Error("Native connection is not established");
    const requestId = opts.requestId ?? crypto.randomUUID();
    const size = opts.size ?? opts.bytes.length;
    const sliceBytes = opts.sliceBytes ?? STREAM_RECORD_SLICE_BYTES;
    const stream = await connection.openBi();

    const openFrame = prefixWithLength(
      encodeStreamOpen({
        kind: "upload",
        projectId: opts.projectId,
        checkoutId: opts.checkoutId,
        requestId,
        fileName: opts.fileName,
        size,
        mimeType: opts.mimeType,
      }),
    );
    await stream.send.writeAll(Array.from(openFrame));

    let written = 0;
    const writeChunk = async (bytes: Uint8Array): Promise<void> => {
      for (let offset = 0; offset < bytes.length; offset += sliceBytes) {
        const slice = bytes.subarray(offset, Math.min(offset + sliceBytes, bytes.length));
        await stream.send.writeAll(Array.from(slice));
        written += slice.length;
      }
    };
    await writeChunk(opts.bytes);
    if (opts.finish ?? true) await stream.send.finish();

    let refusal: Record<string, any> | null = null;
    let resultResolve!: (r: Record<string, any>) => void;
    let resultReject!: (e: Error) => void;
    const resultPromise = new Promise<Record<string, any>>((resolve, reject) => {
      resultResolve = resolve;
      resultReject = reject;
    });
    resultPromise.catch(() => {});

    let endedResolve!: (v: "result" | "refused" | "reset" | "fin-without-result") => void;
    const ended = new Promise<"result" | "refused" | "reset" | "fin-without-result">((resolve) => {
      endedResolve = resolve;
    });

    void (async () => {
      const outcome = await readOneRawRecord(stream.recv, STREAM_UPLOAD_BRIDGE_RECORD_MAX_BYTES);
      if (outcome.kind === "fin") {
        resultReject(new Error(`upload stream ${requestId} ended with no result`));
        endedResolve("fin-without-result");
        return;
      }
      if (outcome.kind === "reset") {
        resultReject(new Error(`upload stream ${requestId} was reset before any result`));
        endedResolve("reset");
        return;
      }
      const text = Buffer.from(outcome.bytes).toString("utf8");
      let obj: any;
      try {
        obj = JSON.parse(text);
      } catch {
        obj = null;
      }
      if (obj?.type === "stream:refused") {
        refusal = obj;
        resultReject(Object.assign(new Error(`upload stream refused: ${obj.code} ${obj.message}`), { refusal: obj }));
        endedResolve("refused");
        return;
      }
      if (obj?.type === "file:upload-result") {
        resultResolve(obj);
        endedResolve("result");
        return;
      }
      resultReject(new Error(`unexpected upload-stream record: ${text.slice(0, 200)}`));
      void stream.send.reset(0n).catch(() => {});
      endedResolve("reset");
    })();

    return {
      requestId,
      bytesWritten(): number {
        return written;
      },
      result(timeoutMs = 15_000): Promise<Record<string, any>> {
        return withTimeout(resultPromise, timeoutMs, `upload result for ${requestId}`);
      },
      ended,
      get refusal() {
        return refusal;
      },
      writeMore(bytes: Uint8Array): Promise<void> {
        return writeChunk(bytes);
      },
      cancel(): void {
        void stream.send.reset(0n).catch(() => {});
      },
    };
  }

  /** Opens a `kind:"tunnel-ws"` stream: the open frame, then the
   *  `tunnel:ws-open` head. `opts.tunnelId` (falling back to the open frame's
   *  own id) is what `close`/records key on; `opts.open` supplies the rest of
   *  the head (`port`, `path`, …). */
  async openTunnelWsStream(opts: {
    projectId: string;
    tunnelId?: string;
    open: Record<string, unknown>;
  }): Promise<TunnelWsStreamClient> {
    const connection = this.nativeConnection;
    if (!connection) throw new Error("Native connection is not established");
    const tunnelId = opts.tunnelId ?? crypto.randomUUID();
    const checkoutId = (opts.open as { checkoutId?: unknown }).checkoutId ?? "main";
    const stream = await connection.openBi();

    const openFrame = prefixWithLength(
      encodeStreamOpen({ kind: "tunnel-ws", projectId: opts.projectId, wsId: tunnelId }),
    );
    await stream.send.writeAll(Array.from(openFrame));

    const head = { ...opts.open, type: "tunnel:ws-open", tunnelId, checkoutId };
    await stream.send.writeAll(Array.from(prefixWithLength(Buffer.from(JSON.stringify(head), "utf8"))));

    const records: TunnelWsRecord[] = [];
    const waiters: Array<{
      match: (r: TunnelWsRecord) => boolean;
      resolve: (r: TunnelWsRecord) => void;
      timer: ReturnType<typeof setTimeout>;
    }> = [];
    let settleEnded = () => {};
    const ended = new Promise<void>((resolve) => {
      settleEnded = resolve;
    });

    const deliver = (record: TunnelWsRecord): void => {
      for (let i = 0; i < waiters.length; i++) {
        if (waiters[i]!.match(record)) {
          const waiter = waiters.splice(i, 1)[0]!;
          clearTimeout(waiter.timer);
          waiter.resolve(record);
          return;
        }
      }
      records.push(record);
    };

    const reader = new StreamRecordReader({ recv: stream.recv }, STREAM_TUNNEL_RECORD_MAX_BYTES, () => {});
    void (async () => {
      try {
        while (true) {
          const bytes = await reader.read();
          const decoded = decodeTunnelRecord(bytes);
          if (!decoded) continue;
          if (decoded.kind === "json") {
            let obj: any;
            try {
              obj = JSON.parse(decoded.text);
            } catch {
              continue;
            }
            if (obj?.type === "stream:refused") {
              deliver({ kind: "refused", refusal: obj });
              continue;
            }
            if (obj?.type === "tunnel:ws-close") {
              deliver({ kind: "close", code: obj.code, reason: obj.reason });
              continue;
            }
            continue;
          }
          if (decoded.tag === TUNNEL_RECORD_TAG_WS_TEXT) {
            deliver({ kind: "text", text: Buffer.from(decoded.payload).toString("utf8") });
          } else if (decoded.tag === TUNNEL_RECORD_TAG_WS_BINARY) {
            deliver({ kind: "binary", bytes: Buffer.from(decoded.payload) });
          }
        }
      } catch {
        // bridge half ended — FIN or reset look the same from here.
      } finally {
        settleEnded();
      }
    })();

    return {
      tunnelId,
      records,
      next(predicate, timeoutMs = 10_000): Promise<TunnelWsRecord> {
        for (let i = 0; i < records.length; i++) {
          if (predicate(records[i]!)) return Promise.resolve(records.splice(i, 1)[0]!);
        }
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => {
            const idx = waiters.findIndex((w) => w.timer === timer);
            if (idx !== -1) waiters.splice(idx, 1);
            reject(new Error(`Timed out waiting for tunnel-ws record (${timeoutMs}ms)`));
          }, timeoutMs);
          waiters.push({ match: predicate, resolve, timer });
        });
      },
      async sendText(text: string): Promise<void> {
        const record = encodeTunnelDataRecord(TUNNEL_RECORD_TAG_WS_TEXT, Buffer.from(text, "utf8"));
        await stream.send.writeAll(Array.from(prefixWithLength(record)));
      },
      async sendBinary(bytes: Uint8Array): Promise<void> {
        const record = encodeTunnelDataRecord(TUNNEL_RECORD_TAG_WS_BINARY, bytes);
        await stream.send.writeAll(Array.from(prefixWithLength(record)));
      },
      async close(code?: number, reason?: string): Promise<void> {
        const record = Buffer.from(
          JSON.stringify({ type: "tunnel:ws-close", tunnelId, code, reason, checkoutId }),
          "utf8",
        );
        await stream.send.writeAll(Array.from(prefixWithLength(record)));
        await stream.send.finish();
      },
      reset(): void {
        void stream.send.reset(0n).catch(() => {});
      },
      ended,
    };
  }

  /** Connects from the configured native endpoint to the configured target
   *  with `alpn`. Returns "refused" if connect rejects or the connection
   *  closes within `timeoutMs`, otherwise "connected" (and closes it). */
  async probeNativeAlpn(alpn: string, timeoutMs = 5_000): Promise<"refused" | "connected"> {
    const endpoint = this.nativeEndpoint;
    const target = this.nativeTarget;
    if (!endpoint || !target) throw new Error("Native endpoint is not configured");
    let connection: Connection;
    try {
      connection = await endpoint.connect(
        new EndpointAddr(EndpointId.fromString(target.endpointId), undefined, target.addresses),
        Array.from(Buffer.from(alpn)),
      );
    } catch {
      return "refused";
    }
    const outcome = await Promise.race([
      connection.closed().then(() => "closed" as const, () => "closed" as const),
      Bun.sleep(timeoutMs).then(() => "open" as const),
    ]);
    if (outcome === "closed") return "refused";
    connection.close(1n, []);
    return "connected";
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

  // --- Binary receive path (plaintext; QUIC/TLS between leased endpoints is
  //     the confidentiality layer, so a frame's payload is consumed directly) ---

  private handleBinaryFrame(data: ArrayBuffer | Uint8Array): void {
    const buf = Buffer.from(data as Uint8Array);
    let decoded: { header: { type: PeerFrameKind }; payload: Uint8Array };
    try {
      decoded = decodePeerFrame(buf) as { header: { type: PeerFrameKind }; payload: Uint8Array };
    } catch {
      return; // malformed frame — drop
    }
    let obj: any;
    try {
      obj = JSON.parse(Buffer.from(decoded.payload).toString("utf8"));
    } catch {
      return; // "plaintext-not-json"
    }
    if (!(obj && typeof obj === "object" && typeof obj.type === "string")) return; // "unrecognized-plaintext"
    // The header `type` is the discriminator, not the JSON body —
    // `ping`/`pong`/`session:*` exist as control-plane AbMessage literals too,
    // so the body alone cannot tell a liveness frame from a control message.
    if (decoded.header.type === "session") {
      this.handleSessionFrame(obj);
    } else if (decoded.header.type === "message") {
      this.dispatchAbMessage(JSON.stringify(obj));
    }
  }

  private handleSessionFrame(obj: { type: string; attemptId?: string }): void {
    switch (obj.type) {
      case "established":
        this.deliver(obj);
        return;
      case "ping":
        if (this.established) this.sendSessionFrame({ type: "pong" });
        return;
      case "pong":
        return;
      case "session-takeover":
        // Sent by the bridge to a session it is about to tear down. A bridge
        // now keeps one session per app device, so the only producer left is
        // capacity eviction past that cap. Deliver it like any other session
        // frame so a test can `waitFor` the mechanism directly, instead of
        // only inferring it from a later dead round trip.
        this.deliver(obj);
        return;
      default:
        return; // unexpected session frame — drop (covers a stale "credit")
    }
  }

  /** Parse a plaintext AbMessage and route it to waiters/queue. `streamId`
   *  tags it so `waitForStreamAbType` can distinguish project-stream traffic
   *  from the control plane; control-plane messages carry none. Anything that
   *  fails to parse as an AbMessage is dropped, matching the bridge's own
   *  handling of a stray one. */
  private dispatchAbMessage(json: string, streamId?: string): void {
    const msg = parseMessage(json);
    if (!msg) return;
    // Ready-notice bookkeeping (mirrors MachineSession's `_readyProjects`):
    // `stream-ready` no longer carries a streamId (A4) — it is only ever this
    // project's readiness signal now. An `agent:projects` advert is the other
    // source, keyed on `running`.
    const anyMsg = msg as any;
    if (msg.type === ("stream-ready" as AbMessage["type"])) {
      if (anyMsg.projectId) this.readyProjects.add(anyMsg.projectId);
    } else if (msg.type === ("agent:projects" as AbMessage["type"])) {
      for (const p of anyMsg.projects ?? []) {
        if (p.running) this.readyProjects.add(p.projectId);
        else this.readyProjects.delete(p.projectId);
      }
    }
    if (streamId) anyMsg._streamId = streamId;
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

  // --- Session establishment ---

  /**
   * Establish the native session with the agent through the peer connection.
   *
   * Phone perspective: send a plaintext `session:hello { attemptId,
   * capabilities }` on the control channel and resolve once `established
   * { attemptId }` comes back with a matching id. QUIC/TLS between the
   * lease-authorized endpoints is the confidentiality layer now, so there is
   * no key derivation or confirm tag — the bridge's lease re-check on the
   * hello is what authorizes this session.
   */
  async performE2EHandshake(
    agentDeviceId: string,
    timeoutMs = 10_000,
    opts: {
      /** Play a pre-`pullsTree` app: omit the capability so the bridge keeps
       *  pushing the file tree on re-sync (gate-lazy-hydration's legacy row). */
      omitPullsTree?: boolean;
      /** Play a pre-`terminalFramesV1` app: omit the capability so the bridge
       *  keeps this client on the legacy raw-output display path (old-app
       *  compatibility eval). */
      omitTerminalFramesV1?: boolean;
      /** Play a stale, pre-worktree app: omit `checkoutRouting` so the bridge
       *  refuses a project stream open for any project holding a managed
       *  worktree session (`UPDATE_REQUIRED` — gate-project-streams row 3). */
      omitCheckoutRouting?: boolean;
    } = {},
  ): Promise<void> {
    if (!this.nativePeerId) throw new Error("Native peer is not connected");
    if (agentDeviceId !== this.nativePeerId) {
      throw new Error(
        `Handshake peer ${agentDeviceId} does not match authenticated native peer ${this.nativePeerId}`,
      );
    }
    const attemptId = randomBytes(8).toString("hex");
    // `capabilities` mirrors the production Dart client (connection_handshake.dart):
    // without checkoutRouting the bridge treats this app as pre-worktree and
    // refuses to stream any project holding a managed session; `pullsTree` tells
    // it the app fetches its own file tree, so the re-sync need not push one;
    // `terminalFramesV1` opts this client into rendered-frame terminal display —
    // omitting it must fail CLOSED to the legacy raw-output path (never assumed).
    const capabilities: Record<string, true> = {};
    if (!opts.omitCheckoutRouting) capabilities.checkoutRouting = true;
    if (!opts.omitPullsTree) capabilities.pullsTree = true;
    if (!opts.omitTerminalFramesV1) capabilities.terminalFramesV1 = true;

    const establishedP = this.waitFor(
      (m: any) => m.type === "established" && m.attemptId === attemptId,
      timeoutMs,
    );
    this.sendSessionFrame({ type: "session:hello", attemptId, capabilities });
    try {
      await establishedP;
    } catch (error) {
      if (!(error instanceof Error) || !error.message.startsWith("Timed out waiting for message")) {
        throw error;
      }
      throw new NativeAuthorizationNotReadyError(agentDeviceId, error);
    }
    this.established = { attemptId };
    this.sessionConfirmed = true;
    this.e2eGeneration++;
  }

  // --- Streams ---

  /**
   * Opens `projectId`'s own QUIC stream (Stage A wave A4: project streams
   * replace the mux). Drives control-plane `project:start` and waits for the
   * ready notice UNLESS one has already been seen since establishment or
   * since this project's last stream end (mirrors `MachineSession.openProject`
   * step 2). Then `openBi`s `{kind:"project", projectId}` and awaits the first
   * record. Resolves to the handle, which IS `projectId` (D-8: every helper
   * that took a bridge-minted streamId keeps its signature; the handle no
   * longer leaks a bridge-internal id). Idempotent while the stream is open.
   */
  async openProjectStream(projectId: string, timeoutMs = 10_000): Promise<string> {
    const existing = this.projectStreams.get(projectId);
    if (existing?.open) return projectId;
    const deadline = Date.now() + timeoutMs;
    if (!this.readyProjects.has(projectId)) {
      this.sendEncrypted(createMessage("project:start", { projectId } as any));
      await this.awaitProjectReady(projectId, Math.max(1, deadline - Date.now()));
    }
    const { first } = await this.openProjectBiStream(projectId, Math.max(1, deadline - Date.now()));
    if (first.refusal) {
      throw Object.assign(
        new Error(`project stream ${projectId} refused: ${first.refusal.code} ${first.refusal.message}`),
        { refusal: first.refusal },
      );
    }
    return projectId;
  }

  /** Admission probe: opens `projectId`'s QUIC stream directly, with no ready
   *  wait and no `project:start`. Surfaces the outcome as data instead of
   *  throwing — a refusal here is the row under test, not a failure. */
  async openProjectStreamRaw(projectId: string, timeoutMs = 10_000): Promise<{
    refusal?: { code: string; message: string };
    first?: Record<string, any>;
    ended: Promise<"fin" | "error">;
  }> {
    const { state, first } = await this.openProjectBiStream(projectId, timeoutMs);
    return { refusal: first.refusal, first: first.record, ended: state.ended };
  }

  /** Waits for `projectId`'s ready notice: a live `stream-ready {projectId}`
   *  on the session stream, or a `control:result {ok:false, verb:"project:start"}`
   *  naming it (which fails with that error's code). A no-op if the project is
   *  already in `readyProjects`. */
  private awaitProjectReady(projectId: string, timeoutMs: number): Promise<void> {
    if (this.readyProjects.has(projectId)) return Promise.resolve();
    const ready = this.waitForCancelable(
      (m: any) => m.type === "stream-ready" && m.projectId === projectId,
      timeoutMs,
    );
    const failed = this.waitForCancelable(
      (m: any) => m.type === "control:result" && m.ok === false && m.verb === "project:start" && m.projectId === projectId,
      timeoutMs,
    );
    return Promise.race([
      ready.promise.then(() => {
        failed.cancel();
      }),
      failed.promise.then((m: any) => {
        ready.cancel();
        const code = m.error?.code ?? "PROJECT_START_FAILED";
        throw Object.assign(new Error(`project:start ${projectId} failed: ${code} ${m.error?.message ?? ""}`), { code });
      }),
    ]);
  }

  /** Opens `projectId`'s bi-directional QUIC stream, writes the A0b open
   *  frame, and classifies the first record (§1.1: `stream:refused` then FIN,
   *  or `stream-ready` naming this project). Registers the binding into
   *  `projectStreams`/`readyProjects` only once admitted. Every record after
   *  the first is one bare `AbMessage`, with no reassembly — dispatched with
   *  `_streamId = projectId` — the same shape `openProjectStream`/
   *  `openProjectStreamRaw` both build on. */
  private async openProjectBiStream(
    projectId: string,
    timeoutMs: number,
  ): Promise<{ state: ProjectStreamState; first: { refusal?: { code: string; message: string }; record?: Record<string, any> } }> {
    const connection = this.nativeConnection;
    if (!connection) throw new Error("Native connection is not established");
    const stream = await connection.openBi();
    const openFrame = prefixWithLength(encodeStreamOpen({ kind: "project", projectId }));
    await stream.send.writeAll(Array.from(openFrame));

    let endedResolve!: (v: "fin" | "error") => void;
    const ended = new Promise<"fin" | "error">((resolve) => {
      endedResolve = resolve;
    });
    const state: ProjectStreamState = {
      projectId,
      stream,
      open: false,
      closingLocally: false,
      ended,
      writeChain: Promise.resolve(),
    };

    let firstResolve!: (v: { refusal?: { code: string; message: string }; record?: Record<string, any> }) => void;
    const firstP = new Promise<{ refusal?: { code: string; message: string }; record?: Record<string, any> }>((resolve) => {
      firstResolve = resolve;
    });

    const reader = new StreamRecordReader({ recv: stream.recv }, STREAM_PROJECT_BRIDGE_RECORD_MAX_BYTES, () => {});

    let gotFirst = false;
    let cleanRefusal = false;

    void (async () => {
      try {
        while (true) {
          const bytes = await reader.read();
          const text = Buffer.from(bytes).toString("utf8");
          if (!gotFirst) {
            gotFirst = true;
            let obj: any;
            try {
              obj = JSON.parse(text);
            } catch {
              obj = null;
            }
            if (obj?.type === "stream:refused") {
              cleanRefusal = true;
              state.refusal = { code: obj.code, message: obj.message };
              firstResolve({ refusal: state.refusal });
              continue; // §1.1: a clean FIN follows a refusal (D4)
            }
            if (obj?.type === "stream-ready" && obj.projectId === projectId) {
              state.open = true;
              this.readyProjects.add(projectId);
              this.projectStreams.set(projectId, state);
              firstResolve({ record: obj });
              continue;
            }
            // Protocol error (§1.1): neither refused nor a matching stream-ready.
            firstResolve({ refusal: { code: "INVALID_RECORD", message: `unexpected first record: ${text.slice(0, 200)}` } });
            void stream.send.reset(0n).catch(() => {});
            continue;
          }
          // A stale `__frag` piece has no string `type`; `dispatchAbMessage`
          // drops it the same way it drops any other unparseable record.
          this.dispatchAbMessage(text, projectId);
        }
      } catch {
        // The bridge's half ended — FIN (orderly close/refusal) or reset
        // (overflow, stream-lost) are wire-indistinguishable here (D4).
      } finally {
        state.open = false;
        this.readyProjects.delete(projectId);
        if (this.projectStreams.get(projectId) === state) this.projectStreams.delete(projectId);
        if (!gotFirst) firstResolve({ refusal: { code: "STREAM_ENDED", message: "project stream ended before any record" } });
        endedResolve(cleanRefusal || state.closingLocally ? "fin" : "error");
      }
    })();

    const first = await withTimeout(firstP, timeoutMs, `project-stream first record for ${projectId}`);
    return { state, first };
  }

  /** Send a message on `handle`: `"0"`/`CONTROL_HANDLE` rides the session
   *  stream unchanged; any other handle is that project's own QUIC stream,
   *  written as exactly one record — one `AbMessage` is always one record.
   *  `channel` is vestigial on both paths: the session stream has no channels
   *  (D2 — only the loopback JSON keeps the label) and a project record
   *  carries no envelope to label. Throws if the project stream is not open. */
  sendOnStream(handle: string, msg: object, _channel: "control" | "preview" = "control"): void {
    if (handle === CONTROL_HANDLE) {
      this.sendControlMessage(msg);
      return;
    }
    const state = this.projectStreams.get(handle);
    if (!state?.open) throw new Error(`Project stream ${handle} is not open`);
    this.writeProjectRecord(state, msg);
  }

  /** Encodes `msg` as exactly one record and chains it onto the binding's
   *  write order. Throws synchronously past the app's outbound cap
   *  (`STREAM_PROJECT_APP_RECORD_MAX_BYTES` — mirrors the bridge's read-side
   *  refusal and Dart's `message-too-large` drop; nothing is written). A
   *  write failure surfaces as a delivered `error` message, matching
   *  `sendBinary`'s handling on the session stream. */
  private writeProjectRecord(state: ProjectStreamState, msg: object): void {
    const json = JSON.stringify(msg);
    const byteLen = Buffer.byteLength(json, "utf8");
    if (byteLen > STREAM_PROJECT_APP_RECORD_MAX_BYTES) {
      throw new Error(
        `project-stream record for ${state.projectId} exceeds STREAM_PROJECT_APP_RECORD_MAX_BYTES (${byteLen} bytes)`,
      );
    }
    const bytes = prefixWithLength(Buffer.from(json, "utf8"));
    state.writeChain = state.writeChain.then(() => state.stream.send.writeAll(Array.from(bytes)));
    state.writeChain.catch((error) =>
      this.deliver({ type: "error", code: "PROJECT_STREAM_SEND_FAILED", message: String(error) }),
    );
  }

  /** Finishes our half of `handle`'s project stream and awaits the bridge's
   *  end. A no-op if the handle names no open stream. */
  async closeProjectStream(handle: string): Promise<void> {
    const state = this.projectStreams.get(handle);
    if (!state) return;
    state.closingLocally = true;
    await state.writeChain.catch(() => {});
    await state.stream.send.finish().catch(() => {});
    await state.ended;
  }

  /** Resolves once `handle`'s project stream has ended, `"fin"` for a clean
   *  close (ours or a refusal's) and `"error"` otherwise (D4: reset and
   *  stream-lost are wire-indistinguishable from here). Throws if `handle`
   *  was never opened. */
  projectStreamEnded(handle: string): Promise<"fin" | "error"> {
    const state = this.projectStreams.get(handle);
    if (!state) throw new Error(`Project stream ${handle} was never opened`);
    return state.ended;
  }

  /** True iff `handle` names a project whose stream is currently bound. */
  isProjectStreamOpen(handle: string): boolean {
    return this.projectStreams.get(handle)?.open ?? false;
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

  /** Send an AbMessage on the machine CONTROL PLANE (`s` omitted). */
  sendEncrypted(msg: AbMessage): void {
    this.sendControlMessage(msg);
  }

  /** Write the bare JSON of one control-plane `AbMessage` as a `"message"`-kind
   *  peer frame, with no envelope. Project traffic never shares this path
   *  (Stage A wave A4): it rides its own QUIC stream via `sendOnStream`/
   *  `writeProjectRecord`. */
  private sendControlMessage(msg: unknown): void {
    if (!this.established || !this.nativePeerId) throw new Error("Native session is not established");
    this.sendBinary(encodePeerFrame({ type: "message" }, Buffer.from(JSON.stringify(msg), "utf8")));
  }

  /** Send one bare session frame (`session:hello`, `ping`, `pong`, …) as a
   *  `"session"`-kind peer frame. */
  private sendSessionFrame(obj: object): void {
    this.sendBinary(encodePeerFrame({ type: "session" }, Buffer.from(JSON.stringify(obj), "utf8")));
  }

  /** Send raw JSON to the central relay, including retired verbs in rejection tests. */
  sendRaw(data: any): void {
    if (!this.ws) throw new Error("Not connected");
    const raw = JSON.stringify(data);
    this.onOutbound?.(raw);
    this.ws.send(raw);
  }

  private sendBinary(data: Uint8Array): void {
    if (!this.sessionWriter) throw new Error("Native payload is not connected");
    void this.sessionWriter.send(data).catch((error) =>
      this.deliver({ type: "error", code: "NATIVE_SEND_FAILED", message: String(error) }));
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

  /** How many queued messages match, WITHOUT consuming any of them. Every other
   *  accessor takes what it matches, so a test that samples "how much of this
   *  stream has arrived so far" twice would consume the very frames it is
   *  measuring. */
  queuedCount(match: (msg: any) => boolean): number {
    return this.messageQueue.filter(match).length;
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

  get lifecycleGenerations(): Readonly<{
    control: number;
    native: number;
    e2e: number;
  }> {
    return {
      control: this.wsGeneration,
      native: this.nativeGeneration,
      e2e: this.e2eGeneration,
    };
  }

  /** Re-establish the central control socket under the same account identity. */
  async reconnectAndAuth(relayUrl: string): Promise<void> {
    await this.connectAndAuthenticate(relayUrl);
  }

  /** Hard-close central control without touching the native session. */
  dropSocket(): void {
    this.ws?.close();
    this.ws = null;
  }

  /** Override the `licenseToken` presented on the NEXT hello (a fresh
   *  `connectAndAuth`/`reconnectAndAuth`). Lets a caller simulate an app
   *  token that expires mid-session and recovers on the next mint, without a
   *  real JWT. Persists until overridden again. */
  setLicenseToken(token: string): void {
    this.helloOpts.licenseToken = token;
  }

  private resetE2e(): void {
    this.established = null;
    this.sessionConfirmed = false;
    for (const state of this.projectStreams.values()) state.closingLocally = true;
    this.projectStreams.clear();
    this.readyProjects.clear();
  }

  async disconnect(): Promise<void> {
    this.waiters.forEach((w) => {
      clearTimeout(w.timer);
      w.reject(new Error("Disconnected"));
    });
    this.waiters = [];
    this.messageQueue = [];
    this.resetE2e();
    this.nativePeerId = null;
    this.ws?.close();
    this.ws = null;
    this.dropNative();
    await this.nativeEndpoint?.close();
    this.nativeEndpoint = null;
    this.nativeTarget = null;
  }
}
