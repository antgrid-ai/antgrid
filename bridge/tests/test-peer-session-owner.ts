import { decodeRouteFrame, FrameKind } from "antgrid-wire";
import type { Channel } from "../src/message-bus";
import type { RemoteHostConnection } from "../src/remote-host-connection";
import type { NativeHostOptions } from "../src/peer/native-host-connection";
import type { EphemeralKeypair } from "../src/key-exchange";
import type { QueuedAppFrame, PendingSinkWrite } from "../src/send-scheduler";
import {
  PeerSessionOwner,
  type PeerSession,
  type PendingAttempt,
  type PeerSessionOwnerOptions,
} from "../src/peer-session-owner";

/** Native-neutral E2E fixture. It exercises the payload/session layer directly;
 * central WebSocket behavior belongs in CentralControlClient tests. */
export class TestPeerSessionOwner extends PeerSessionOwner {
  private writer: ((payload: string | Buffer, to: string, channel?: Channel, kind?: FrameKind,
    diagnosticType?: string, streamId?: string) => boolean) = () => false;

  constructor(opts: PeerSessionOwnerOptions) { super(opts); }

  protected override sendNativePayload(payload: string | Buffer, to: string, channel?: Channel, kind?: FrameKind,
    diagnosticType?: string, streamId?: string): boolean {
    return this.writer(payload, to, channel, kind, diagnosticType, streamId);
  }

  protected override sendNativeScheduled(sealed: Buffer, peerId: string, _frame: QueuedAppFrame): number | null | PendingSinkWrite {
    return this.writer(sealed, peerId, _frame.channel, FrameKind.sealed, _frame.type, _frame.streamId)
      ? sealed.length : null;
  }

  setNativeWriter(writer: (payload: string | Buffer, to: string, channel?: Channel, kind?: FrameKind,
    diagnosticType?: string, streamId?: string) => boolean): void {
    this.writer = writer;
  }

  injectRoutedFrame(
    payload: Uint8Array,
    from: string,
    channel: Channel = "control",
    kind: FrameKind = FrameKind.sealed,
  ): void {
    this.receiveRoutedFrame(payload, from, channel, kind);
  }

  injectRouteFrame(frame: Uint8Array): void {
    const decoded = decodeRouteFrame(frame);
    const header = decoded.header as { type?: string; from?: string; channel?: string };
    if (header.type !== "message" || !header.from || !header.channel) return;
    this.receiveRoutedFrame(
      decoded.payload,
      header.from,
      header.channel === "preview" ? "preview" : "control",
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
