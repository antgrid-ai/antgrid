import { generateKeyPairSync } from "node:crypto";
import { decodePeerFrame } from "antgrid-wire";
import type { Channel } from "../src/message-bus";
import type { RemoteHostConnection } from "../src/remote-host-connection";
import type { NativeHostOptions } from "../src/peer/native-host-connection";
import type { QueuedAppFrame, PendingSinkWrite } from "../src/send-scheduler";
import {
  PeerSessionOwner,
  type PeerSession,
  type PeerSessionOwnerOptions,
} from "../src/peer-session-owner";

/** A phone-side Ed25519 identity for tests: raw 32-byte seed + pubkey, both
 *  base64. Exported so suites that need a specific identity (wrong-key, slot
 *  tests) don't each hand-roll the DER unwrap. */
export interface PeerIdentity { seedB64: string; pubB64: string }

export function ed25519Pair(): PeerIdentity {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    seedB64: Buffer.from(privateKey.export({ format: "der", type: "pkcs8" }).subarray(-32)).toString("base64"),
    pubB64: Buffer.from(publicKey.export({ format: "der", type: "spki" }).subarray(-32)).toString("base64"),
  };
}

let establishCounter = 0;

/** Native-neutral peer-session fixture. It exercises the payload/session layer
 * directly; central WebSocket behavior belongs in CentralControlClient tests. */
export class TestPeerSessionOwner extends PeerSessionOwner {
  private writer: ((payload: string | Buffer, to: string, channel?: Channel,
    diagnosticType?: string, streamId?: string) => boolean) = () => false;

  constructor(opts: PeerSessionOwnerOptions) { super(opts); }

  protected override sendNativePayload(payload: string | Buffer, to: string, channel?: Channel,
    diagnosticType?: string, streamId?: string): boolean {
    const ok = this.writer(payload, to, channel, diagnosticType, streamId);
    if (ok) this.recordOutbound(to, payload);
    return ok;
  }

  protected override sendNativeScheduled(payload: Buffer, peerId: string, frame: QueuedAppFrame): number | null | PendingSinkWrite {
    const ok = this.writer(payload, peerId, frame.channel, frame.type, frame.streamId);
    if (ok) this.recordOutbound(peerId, payload);
    return ok ? payload.length : null;
  }

  // --- The establish/sendFromPeer/readToPeer seam ---
  //
  // One place every suite gets from zero to an established session and drives
  // traffic across it, so a future wire change touches these methods instead
  // of every suite that calls them. `installFakeSession` (fake-session.ts) is
  // the only OTHER way to put a session on a client, for suites that need one
  // instantly and never touch the wire.

  /** Frames this client wrote, queued per addressee in send order, for
   *  `readToPeer`/`sentTo`. */
  private outbox = new Map<string, Array<string | Buffer>>();

  private recordOutbound(to: string, payload: string | Buffer): void {
    const list = this.outbox.get(to);
    if (list) list.push(payload); else this.outbox.set(to, [payload]);
  }

  /** Admit `peerId`'s identity and drive a real plaintext `session:hello` ->
   *  `established` through the production code. Throws if establishment does
   *  not land — a test that wants to see a REFUSED hello drives
   *  `injectPeerPayload`/`sendFromPeer` directly instead, since this seam only
   *  speaks for a hello that succeeds. */
  establish(peerId: string, opts: {
    capabilities?: { checkoutRouting?: boolean; pullsTree?: boolean; terminalFramesV1?: boolean };
    identity?: PeerIdentity;
    attemptId?: string;
  } = {}): { attemptId: string; identity: PeerIdentity } {
    const identity = opts.identity ?? ed25519Pair();
    const attemptId = opts.attemptId ?? `attempt-${peerId}-${++establishCounter}`;
    this.admitPeer(peerId, identity.pubB64);
    this.injectPeerPayload(
      Buffer.from(JSON.stringify({
        type: "session:hello", attemptId,
        ...(opts.capabilities ? { capabilities: opts.capabilities } : {}),
      })),
      peerId,
    );
    const session = this.sessions.get(peerId);
    if (!session || session.attemptId !== attemptId) {
      throw new Error(`establish(${peerId}): session:hello did not promote to an established session`);
    }
    // The hello's own `established` reply is this seam's own traffic, not
    // application traffic — drop it so a caller's first readToPeer/sentTo
    // sees only what it sends afterward.
    this.outbox.delete(peerId);
    return { attemptId, identity };
  }

  /** Inject `obj` exactly as a real app's frame from `peerId` would arrive:
   *  plaintext JSON on the given channel. `obj` may be a pre-serialized string
   *  (a raw fragment envelope, or a deliberately malformed body) or any
   *  JSON-able value. */
  sendFromPeer(peerId: string, obj: unknown, channel: Channel = "control"): void {
    const payload = typeof obj === "string" ? obj : JSON.stringify(obj);
    this.injectPeerPayload(Buffer.from(payload, "utf8"), peerId, channel);
  }

  /** Pop and parse the next frame this client sent to `peerId`. Throws on an
   *  empty queue — a test expecting silence should check `sentTo` instead. */
  readToPeer(peerId: string): unknown {
    const list = this.outbox.get(peerId);
    const next = list?.shift();
    if (next === undefined) throw new Error(`readToPeer(${peerId}): nothing queued`);
    return JSON.parse(typeof next === "string" ? next : next.toString("utf8"));
  }

  /** Everything queued for `peerId` so far, without consuming it. */
  sentTo(peerId: string): ReadonlyArray<string | Buffer> {
    return this.outbox.get(peerId) ?? [];
  }

  setNativeWriter(writer: (payload: string | Buffer, to: string, channel?: Channel,
    diagnosticType?: string, streamId?: string) => boolean): void {
    this.writer = writer;
  }

  injectPeerPayload(
    payload: Uint8Array,
    from: string,
    channel: Channel = "control",
  ): void {
    this.receivePeerFrame(payload, from, channel);
  }

  injectPeerFrame(frame: Uint8Array, authenticatedPeerId: string): void {
    const decoded = decodePeerFrame(frame);
    this.receivePeerFrame(
      decoded.payload,
      authenticatedPeerId,
      decoded.header.channel,
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
    sendPayload: (payload: string | Buffer, to?: string) => void;
    peerId: string;
    deviceId?: string;
    agentEd25519PrivB64?: string;
    phoneEd25519PubB64?: string;
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
export type { PeerSession };
