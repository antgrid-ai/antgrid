import { generateKeyPairSync } from "node:crypto";
import { decodePeerFrame } from "antgrid-wire";
import type { Channel } from "../src/message-bus";
import type { RemoteHostConnection } from "../src/remote-host-connection";
import type { NativeHostOptions } from "../src/peer/native-host-connection";
import type { QueuedAppFrame, PendingSinkWrite } from "../src/send-scheduler";
import { FragReassembler } from "../src/frag-reassembler";
import { refuseStream, type AcceptedBiStream, type StreamRefusal } from "../src/peer/stream-dispatch";
import {
  PeerSessionOwner,
  type PeerSession,
  type PeerSessionOwnerOptions,
} from "../src/peer-session-owner";
import type { AbMessage } from "../src/protocol";
import type { StreamSendOutcome } from "../src/peer/stream-records";

function flush(times = 3): Promise<void> {
  return (async () => {
    for (let i = 0; i < times; i++) await new Promise<void>((resolve) => setTimeout(resolve, 0));
  })();
}

/** One fake project-stream `AcceptedBiStream` (docs/iroh-reduction/stage-A-A4-contract.md
 *  §5): the send half accumulates raw `writeAll` slices into complete
 *  `[u32 len][body]` records (the registry writes real slices through the
 *  real `StreamRecordWriter`, so this fake must reassemble them, unlike the
 *  A2 terminal fake which only inspects `writeAllCalls` directly), and the
 *  recv half is a chunk queue driven by `pushAppRecord`/`endWith`, mirroring
 *  the A2 terminal fixture. */
function createFakeProjectStream() {
  const priorities: number[] = [];
  const resets: bigint[] = [];
  const stops: bigint[] = [];
  const order: string[] = [];
  let finished = false;
  let sendBuf = Buffer.alloc(0);
  const allRecords: string[] = [];
  const afterFirst: string[] = [];
  let firstRecordText: string | undefined;
  let heldWrites: Array<() => void> | undefined;

  function absorb(bytes: number[]): void {
    sendBuf = Buffer.concat([sendBuf, Buffer.from(bytes)]);
    for (;;) {
      if (sendBuf.length < 4) return;
      const len = sendBuf.readUInt32BE(0);
      if (sendBuf.length < 4 + len) return;
      const body = sendBuf.subarray(4, 4 + len).toString("utf8");
      sendBuf = sendBuf.subarray(4 + len);
      allRecords.push(body);
      if (firstRecordText === undefined) firstRecordText = body;
      else afterFirst.push(body);
    }
  }

  const send: AcceptedBiStream["send"] = {
    writeAll: (bytes) => {
      if (heldWrites) return new Promise<void>((resolve) => heldWrites!.push(() => { order.push("writeAll"); absorb(bytes); resolve(); }));
      return Promise.resolve().then(() => { order.push("writeAll"); absorb(bytes); });
    },
    setPriority: (p) => Promise.resolve().then(() => { order.push("setPriority"); priorities.push(p); }),
    reset: (code) => Promise.resolve().then(() => { order.push("reset"); resets.push(code); }),
    finish: () => Promise.resolve().then(() => { order.push("finish"); finished = true; }),
  };

  const recvQueue: number[][] = [];
  const waiters: Array<{ resolve: (v: number[]) => void; reject: (e: unknown) => void }> = [];
  let endError: unknown = null;
  function pump(): void {
    while (waiters.length && (recvQueue.length || endError !== null)) {
      const waiter = waiters.shift()!;
      if (recvQueue.length) waiter.resolve(recvQueue.shift()!);
      else waiter.reject(endError);
    }
  }
  const recv: AcceptedBiStream["recv"] = {
    readExact: (size) => {
      void size;
      return new Promise<number[]>((resolve, reject) => { waiters.push({ resolve, reject }); pump(); });
    },
    stop: (code) => Promise.resolve().then(() => { stops.push(code); }),
  };

  function pushBytes(body: Buffer): void {
    const prefix = Buffer.alloc(4);
    prefix.writeUInt32BE(body.length);
    recvQueue.push(Array.from(prefix));
    recvQueue.push(Array.from(body));
    pump();
  }

  return {
    stream: { send, recv } as AcceptedBiStream,
    priorities, resets, stops, order,
    isFinished: () => finished,
    allRecords, afterFirst,
    firstRecordText: () => firstRecordText,
    holdWrites(): void { heldWrites ??= []; },
    releaseWrites(): void {
      const held = heldWrites ?? [];
      heldWrites = undefined;
      for (const write of held) write();
    },
    pushAppRecord(obj: unknown): void {
      pushBytes(Buffer.from(typeof obj === "string" ? obj : JSON.stringify(obj), "utf8"));
    },
    endWith(error: unknown = new Error("app ended")): void {
      endError = error;
      pump();
    },
  };
}

/** The `TestProjectStream` seam (contract §5): drives the real
 *  `ProjectStreamRegistry.handler` with a fake `AcceptedBiStream`, standing
 *  in for the `PeerStreamAcceptor` admission this session never runs — a
 *  refusal is written the same way `PeerStreamAcceptor.refuse` would. */
export interface TestProjectStream {
  refusal(): { code: string; message: string } | undefined;
  read(): any;
  written(): ReadonlyArray<any>;
  send(obj: unknown): Promise<void>;
  finish(): Promise<void>;
  reset(): Promise<void>;
  readonly resets: bigint[];
  readonly stops: bigint[];
  readonly finished: boolean;
  readonly priorities: number[];
  /** Parks every later `writeAll` until `releaseWrites()`: a peer whose
   *  QUIC send window is full. */
  holdWrites(): void;
  releaseWrites(): void;
}

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

  // --- A2/A4 protected-hook seams ---
  //
  // `PeerSessionOwner` wires these into `ProjectStreamRegistry`'s constructor
  // (routeTerminal, projectDetached), not into `attachStream`'s per-project
  // `opts` (docs/iroh-reduction/stage-A-A4-contract.md §3.5), so a suite that
  // wants row 16/17 behavior overrides them here rather than passing them to
  // `attachStream`.
  private routeTerminalFn: ((peerId: string, msg: AbMessage, signal?: AbortSignal) =>
    Promise<StreamSendOutcome> | undefined) | undefined;
  private projectDetachedFn: ((projectId: string) => void) | undefined;

  setRouteTerminal(fn: (peerId: string, msg: AbMessage, signal?: AbortSignal) =>
    Promise<StreamSendOutcome> | undefined): void {
    this.routeTerminalFn = fn;
  }

  setProjectDetached(fn: (projectId: string) => void): void {
    this.projectDetachedFn = fn;
  }

  protected override routeTerminalMessage(peerId: string, msg: AbMessage, signal?: AbortSignal):
    Promise<StreamSendOutcome> | undefined {
    return this.routeTerminalFn?.(peerId, msg, signal);
  }

  protected override terminalProjectDetached(projectId: string): void {
    this.projectDetachedFn?.(projectId);
  }

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

  markPeerOffline(peerId: string): void {
    // A4 deletes isForeignSlot with the rest of the mux's slot bookkeeping
    // (docs/iroh-reduction/stage-A-A4-contract.md §7): this seam's only other
    // caller was the guard itself, so it now just drops the session.
    this.dropSession(peerId);
  }

  /** Drives `ProjectStreamRegistry.handler` directly with a fake
   *  `AcceptedBiStream`, standing in for the `PeerStreamAcceptor` admission
   *  this session never runs (session-established, pending cap, open-frame
   *  parse — those are `native-host-connection.test.ts`'s to cover). A
   *  refusal is written exactly as the real acceptor would. */
  async openProjectStream(peerId: string, projectId: string, opts: {
    authorized?: () => boolean;
  } = {}): Promise<TestProjectStream & { readonly order: readonly string[] }> {
    const authorized = opts.authorized ?? (() => true);
    const fake = createFakeProjectStream();
    const admission = { peerId, open: { kind: "project" as const, projectId }, stream: fake.stream, authorized };
    const refusal: StreamRefusal | undefined = await this.projectStreams.handler(admission);
    if (refusal) refuseStream(fake.stream, refusal, authorized, () => {});
    await flush();

    let reassembler: FragReassembler | undefined;
    return {
      order: fake.order,
      refusal: () => {
        const text = fake.firstRecordText();
        if (text === undefined) return undefined;
        const parsed = JSON.parse(text) as { type?: string; code?: string; message?: string };
        return parsed.type === "stream:refused"
          ? { code: parsed.code!, message: parsed.message! }
          : undefined;
      },
      written: () => fake.allRecords.map((text) => JSON.parse(text)),
      read: () => {
        // `out` must live OUTSIDE the loop: the reassembler is built once (on
        // the first fragment) and its `onComplete` closure captures whichever
        // binding existed at that moment. A `let out` re-declared per
        // iteration shadows that binding on every later pass, so a completion
        // that lands on fragment 2+ sets a variable this loop never reads
        // again and the next `afterFirst.shift()` finds nothing queued.
        let out: string | undefined;
        for (;;) {
          const text = fake.afterFirst.shift();
          if (text === undefined) throw new Error(`openProjectStream(${peerId}, ${projectId}).read(): nothing queued`);
          if (!text.startsWith('{"__frag"')) return JSON.parse(text);
          reassembler ??= new FragReassembler({
            timeoutMs: Number.MAX_SAFE_INTEGER,
            globalBudgetBytes: Number.MAX_SAFE_INTEGER,
            onComplete: (json) => { out = json; },
            onAbort: () => {},
          });
          reassembler.accept(text);
          if (out !== undefined) return JSON.parse(out);
        }
      },
      send: async (obj) => { fake.pushAppRecord(obj); await flush(); },
      finish: async () => { fake.endWith(); await flush(); },
      reset: async () => { fake.endWith(new Error("app reset")); await flush(); },
      resets: fake.resets,
      stops: fake.stops,
      get finished() { return fake.isFinished(); },
      priorities: fake.priorities,
      holdWrites: () => fake.holdWrites(),
      releaseWrites: () => { fake.releaseWrites(); },
    };
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
      // Admission's own steps 3-4 (remote access, seenProjects) default open
      // so a caller driving only the registry's project logic doesn't have to
      // wire two more callbacks; a suite testing THOSE steps overrides them.
      remoteAccessEnabled: () => true,
      projectCataloged: () => true,
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
