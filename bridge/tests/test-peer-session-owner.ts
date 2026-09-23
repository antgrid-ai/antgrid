import { generateKeyPairSync, randomBytes } from "node:crypto";
import { decodePeerFrame, encodePeerFrame, FrameKind } from "antgrid-wire";
import type { Channel } from "../src/message-bus";
import type { RemoteHostConnection } from "../src/remote-host-connection";
import type { NativeHostOptions } from "../src/peer/native-host-connection";
import { generateEphemeralKeypair, type EphemeralKeypair } from "../src/key-exchange";
import { baseSlotDeviceId } from "../src/relay-slot";
import { buildTranscript, signTranscript, phoneConfirmTag, E2eTransport, type SessionKeys } from "../src/e2e";
import type { QueuedAppFrame, PendingSinkWrite } from "../src/send-scheduler";
import {
  PeerSessionOwner,
  type PeerSession,
  type PendingAttempt,
  type PeerSessionOwnerOptions,
} from "../src/peer-session-owner";

/** A phone-side Ed25519 identity for tests: raw 32-byte seed + pubkey, both
 *  base64. Exported so suites that need a specific identity (rekey, wrong-key,
 *  slot tests) don't each hand-roll the DER unwrap. */
export interface PeerIdentity { seedB64: string; pubB64: string }

export function ed25519Pair(): PeerIdentity {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    seedB64: Buffer.from(privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32)).toString("base64"),
    pubB64: Buffer.from(publicKey.export({ format: "der", type: "spki" }).subarray(-32)).toString("base64"),
  };
}

let establishCounter = 0;

/** Native-neutral E2E fixture. It exercises the payload/session layer directly;
 * central WebSocket behavior belongs in CentralControlClient tests. */
export class TestPeerSessionOwner extends PeerSessionOwner {
  private writer: ((payload: string | Buffer, to: string, channel?: Channel, kind?: FrameKind,
    diagnosticType?: string, streamId?: string) => boolean) = () => false;

  constructor(opts: PeerSessionOwnerOptions) { super(opts); }

  protected override sendNativePayload(payload: string | Buffer, to: string, channel?: Channel, kind?: FrameKind,
    diagnosticType?: string, streamId?: string): boolean {
    const ok = this.writer(payload, to, channel, kind, diagnosticType, streamId);
    if (ok) this.recordOutbound(to, payload);
    return ok;
  }

  protected override sendNativeScheduled(sealed: Buffer, peerId: string, _frame: QueuedAppFrame): number | null | PendingSinkWrite {
    const ok = this.writer(sealed, peerId, _frame.channel, FrameKind.sealed, _frame.type, _frame.streamId);
    if (ok) this.recordOutbound(peerId, sealed);
    return ok ? sealed.length : null;
  }

  // --- The establish/sendFromPeer/readToPeer seam ---
  //
  // One place every suite gets from zero to an established session and drives
  // traffic across it, so the wire flip (Stage B, plaintext hello) changes
  // these methods instead of every suite that calls them. `installFakeSession`
  // (fake-session.ts) is the only OTHER way to put a session on a client, for
  // suites that need one instantly and never touch the wire.

  /** Peer-side transports this client can seal outbound traffic under, keyed
   *  by peerId — populated by `establish` (a real handshake) or
   *  `adoptPeerTransport` (a caller-driven one). */
  private peerCrypto = new Map<string, { transport: E2eTransport; sessionKeys: SessionKeys; attemptId: string }>();

  /** Frames this client wrote, queued per addressee in send order, for
   *  `readToPeer`/`sentTo`. */
  private outbox = new Map<string, Array<string | Buffer>>();

  private recordOutbound(to: string, payload: string | Buffer): void {
    const list = this.outbox.get(to);
    if (list) list.push(payload); else this.outbox.set(to, [payload]);
  }

  /** Drive a full, real client-hello -> agent-hello -> agent-ready -> app:ready
   *  -> established handshake for `peerId` through the production code, then
   *  register the resulting phone-side transport for `sendFromPeer`/
   *  `readToPeer`. Throws if admission or promotion fails — a test that wants
   *  to see a REJECTED handshake drives `injectPeerFrame` directly instead,
   *  since this seam only speaks for a handshake that succeeds. */
  establish(peerId: string, opts: {
    capabilities?: { checkoutRouting?: boolean; pullsTree?: boolean; terminalFramesV1?: boolean };
    identity?: PeerIdentity;
    attemptId?: string;
    nonce?: Buffer;
  } = {}): { attemptId: string; identity: PeerIdentity } {
    const identity = opts.identity ?? ed25519Pair();
    const attemptId = opts.attemptId ?? `attempt-${peerId}-${++establishCounter}`;
    const nonce = opts.nonce ?? randomBytes(8);
    this.phoneEd25519ByDeviceId.set(peerId, identity.pubB64);

    const app = generateEphemeralKeypair();
    const deviceId = this.deviceId;
    const phoneDeviceId = baseSlotDeviceId(peerId);
    const phoneTranscript = buildTranscript({
      registrationId: deviceId, role: "phone", agentDeviceId: deviceId, phoneDeviceId,
      agentX25519Pub: Buffer.alloc(0), phoneX25519Pub: app.publicKey, nonce,
    });
    const sig = signTranscript(phoneTranscript, Buffer.from(identity.seedB64, "base64"));
    this.injectPeerFrame(
      encodePeerFrame(
        { type: "message", channel: "control" },
        Buffer.from(JSON.stringify({
          type: "handshake:client-hello", attemptId,
          pubkey: app.publicKey.toString("base64"), nonce: nonce.toString("base64"), sig,
        })),
        FrameKind.handshake,
      ),
      peerId,
    );

    const attempt = this.pending.get(peerId);
    if (!attempt || attempt.attemptId !== attemptId) {
      throw new Error(`establish(${peerId}): client-hello was not admitted — is the identity trusted?`);
    }
    const sessionKeys = attempt.sessionKeys;
    // The phone's mirror of the agent's transport: same keys, sendKey/recvKey
    // swapped, exactly as a real app derives independently from its own
    // ephemeral private key and the same transcript.
    const transport = new E2eTransport({ sendKey: sessionKeys.p2a, recvKey: sessionKeys.a2p });

    const appReady = JSON.stringify({
      type: "app:ready", attemptId, confirm: phoneConfirmTag(sessionKeys.confirm).toString("base64"),
      ...(opts.capabilities ? { capabilities: opts.capabilities } : {}),
    });
    this.injectPeerFrame(
      encodePeerFrame({ type: "message", channel: "control" }, transport.seal(appReady), FrameKind.sealed),
      peerId,
    );

    const session = this.sessions.get(peerId);
    if (!session || session.attemptId !== attemptId) {
      throw new Error(`establish(${peerId}): app:ready did not promote to an established session`);
    }
    this.peerCrypto.set(peerId, { transport, sessionKeys, attemptId });
    // Handshake artifacts (agent-hello, agent-ready, established) are this
    // seam's own traffic, not application traffic — drop them so a caller's
    // first readToPeer/sentTo sees only what it sends afterward.
    this.outbox.delete(peerId);
    return { attemptId, identity };
  }

  /** Register a peer-side transport a caller derived by hand (suites that
   *  assert the handshake mechanics themselves and so must keep driving
   *  client-hello/app:ready directly) so `sendFromPeer`/`readToPeer` still
   *  work for whatever application traffic they exchange afterward. */
  adoptPeerTransport(peerId: string, transport: E2eTransport, sessionKeys: SessionKeys, attemptId: string): void {
    this.peerCrypto.set(peerId, { transport, sessionKeys, attemptId });
  }

  /** Inject `obj` exactly as a real app's frame from `peerId` would arrive.
   *  `obj` may be a pre-serialized string (a raw fragment envelope, or a
   *  deliberately malformed body) or any JSON-able value.
   *
   *  By default it is sealed under the peer's registered transport, or — for a
   *  session `installFakeSession` put there — under that session's identity
   *  seal. `handshake: true` sends it as a plaintext pre-session frame instead,
   *  for the suites that assert handshake behaviour and so must write the
   *  hello themselves. */
  sendFromPeer(peerId: string, obj: unknown, channel: Channel = "control", opts: { handshake?: boolean } = {}): void {
    const payload = typeof obj === "string" ? obj : JSON.stringify(obj);
    let body: Buffer;
    let kind: FrameKind;
    if (opts.handshake) {
      body = Buffer.from(payload, "utf8");
      kind = FrameKind.handshake;
    } else {
      body = this.sealAsPeer(peerId, payload, "sendFromPeer");
      kind = FrameKind.sealed;
    }
    this.injectPeerFrame(encodePeerFrame({ type: "message", channel }, body, kind), peerId);
  }

  /** A fake session's transport is not an E2eTransport, and its seal is the
   *  identity — so the peer's side of it is too. A REAL session with no
   *  registered peer transport throws rather than falling back: an identity
   *  frame against real keys would only ever read as decrypt-failed. */
  private fakeSessionFor(peerId: string): boolean {
    const session = this.sessions.get(peerId);
    return !!session && !(session.transport instanceof E2eTransport);
  }

  private sealAsPeer(peerId: string, payload: string, caller: string): Buffer {
    const crypto = this.peerCrypto.get(peerId);
    if (crypto) return crypto.transport.seal(payload);
    if (this.fakeSessionFor(peerId)) return Buffer.from(payload, "utf8");
    throw new Error(`${caller}(${peerId}): no peer transport — call establish(), adoptPeerTransport() or installFakeSession() first`);
  }

  /** Pop and open the next frame this client sent to `peerId`. A still-
   *  plaintext frame (string payload) is parsed as-is; a sealed one is opened
   *  under the registered peer transport. Throws on an empty queue or an
   *  unopenable frame — a test expecting silence should check `sentTo`
   *  instead. */
  readToPeer(peerId: string): unknown {
    const list = this.outbox.get(peerId);
    const next = list?.shift();
    if (next === undefined) throw new Error(`readToPeer(${peerId}): nothing queued`);
    if (typeof next === "string") return JSON.parse(next);
    const crypto = this.peerCrypto.get(peerId);
    if (!crypto) {
      if (this.fakeSessionFor(peerId)) return JSON.parse(next.toString("utf8"));
      throw new Error(`readToPeer(${peerId}): no peer transport to open a sealed frame`);
    }
    const opened = crypto.transport.open(next);
    if (opened === null) throw new Error(`readToPeer(${peerId}): the registered transport could not open this frame`);
    return JSON.parse(opened);
  }

  /** Everything queued for `peerId` so far, without consuming it. */
  sentTo(peerId: string): ReadonlyArray<string | Buffer> {
    return this.outbox.get(peerId) ?? [];
  }

  /** The registered peer-side transport for `peerId` (from `establish` or
   *  `adoptPeerTransport`), for a test that needs to `.open()`/`.seal()` a
   *  specific frame directly rather than through `sendFromPeer`/`readToPeer`. */
  peerTransport(peerId: string): E2eTransport | null {
    return this.peerCrypto.get(peerId)?.transport ?? null;
  }

  setNativeWriter(writer: (payload: string | Buffer, to: string, channel?: Channel, kind?: FrameKind,
    diagnosticType?: string, streamId?: string) => boolean): void {
    this.writer = writer;
  }

  injectPeerPayload(
    payload: Uint8Array,
    from: string,
    channel: Channel = "control",
    kind: FrameKind = FrameKind.sealed,
  ): void {
    this.receivePeerFrame(payload, from, channel, kind);
  }

  injectPeerFrame(frame: Uint8Array, authenticatedPeerId: string): void {
    const decoded = decodePeerFrame(frame);
    this.receivePeerFrame(
      decoded.payload,
      authenticatedPeerId,
      decoded.header.channel,
      decoded.kind,
    );
  }

  markPeerOnline(peerId: string): void {
    if (this.isForeignSlot(peerId)) return;
    this.backfillPeerPubkey(peerId);
  }

  markPeerOffline(peerId: string): void {
    if (this.isForeignSlot(peerId)) return;
    this.dropSession(peerId);
  }

  async close(): Promise<void> { this.disposeSessions(); }

  static forTest(opts: {
    generateKeypair: () => EphemeralKeypair;
    sendPayload: (payload: string | Buffer, to?: string) => void;
    peerId: string;
    deviceId?: string;
    agentEd25519PrivB64?: string;
    phoneEd25519PubB64?: string;
    halfOpenMs?: number;
    creditBatchBytes?: number;
    options?: Partial<PeerSessionOwnerOptions>;
  }): TestPeerSessionOwner {
    const client = new TestPeerSessionOwner({
      identity: {
        deviceId: opts.deviceId ?? "test-device",
        deviceName: "test",
        createdAt: "",
        ed25519PrivateKey: opts.agentEd25519PrivB64,
      },
      generateKeypair: opts.generateKeypair,
      halfOpenMs: opts.halfOpenMs,
      ...opts.options,
    });
    client.setNativeWriter((payload, to) => { opts.sendPayload(payload, to); return true; });
    if (opts.creditBatchBytes !== undefined) {
      (client as unknown as { creditBatchBytes: number }).creditBatchBytes = opts.creditBatchBytes;
    }
    if (opts.phoneEd25519PubB64) {
      (client as unknown as { phoneEd25519ByDeviceId: Map<string, string> })
        .phoneEd25519ByDeviceId.set(opts.peerId, opts.phoneEd25519PubB64);
    }
    return client;
  }
}


export class TestRemoteHostConnection extends TestPeerSessionOwner implements RemoteHostConnection {
  readonly hostOptions?: NativeHostOptions;

  constructor(options: PeerSessionOwnerOptions | NativeHostOptions) {
    super("native" in options ? options.native : options);
    if ("native" in options) this.hostOptions = options;
  }

  connect(): void {}
  redialWithFreshToken(): void {}
  sendPushDeliver(): void {}
  noteResume(): Promise<boolean> { return Promise.resolve(false); }
  recheckAuthorization(): void {}
}
export { fragmentForSend, MAX_APP_SESSIONS } from "../src/peer-session-owner";
export type { PeerSession, PendingAttempt };
