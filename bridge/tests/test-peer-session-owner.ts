import { generateKeyPairSync } from "node:crypto";
import type { RemoteHostConnection } from "../src/remote-host-connection";
import type { NativeHostOptions } from "../src/peer/native-host-connection";
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

/** One fake project-stream `AcceptedBiStream`: the send half accumulates raw
 *  `writeAll` slices into complete `[u32 len][body]` records (the registry
 *  writes real slices through the real `StreamRecordWriter`, so this fake
 *  must reassemble them, unlike the terminal fake which only inspects
 *  `writeAllCalls` directly), and the recv half is a chunk queue driven by
 *  `pushAppRecord`/`endWith`, mirroring the terminal fixture. */
function createFakeProjectStream() {
  const priorities: number[] = [];
  const resets: bigint[] = [];
  const stops: bigint[] = [];
  const order: string[] = [];
  const writeAllLengths: number[] = [];
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
      if (heldWrites) return new Promise<void>((resolve) => heldWrites!.push(() => { order.push("writeAll"); writeAllLengths.push(bytes.length); absorb(bytes); resolve(); }));
      return Promise.resolve().then(() => { order.push("writeAll"); writeAllLengths.push(bytes.length); absorb(bytes); });
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
    read: () => new Promise<number[]>((resolve, reject) => { waiters.push({ resolve, reject }); pump(); }),
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
    priorities, resets, stops, order, writeAllLengths,
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
    /** Pushes a bare length prefix with no matching body: enough on its own
     *  to trip `StreamRecordReader`'s bound check, which reads the prefix
     *  before ever asking for a body. */
    pushOverlongPrefix(length: number): void {
      const prefix = Buffer.alloc(4);
      prefix.writeUInt32BE(length);
      recvQueue.push(Array.from(prefix));
      pump();
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
  /** Pushes a bare overlong length prefix with no body: the shape a real
   *  `STREAM_PROJECT_APP_RECORD_MAX_BYTES` overflow takes on the wire. */
  sendOverlongPrefix(length: number): Promise<void>;
  finish(): Promise<void>;
  reset(): Promise<void>;
  readonly resets: bigint[];
  readonly stops: bigint[];
  readonly finished: boolean;
  readonly priorities: number[];
  /** The byte length of every `writeAll` call on this stream's send half, in
   *  order — how P3 (project-streams.test.ts) checks that a large record is
   *  sliced rather than written as one array. */
  readonly writeAllLengths: number[];
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
  private writer: ((payload: Buffer, to: string, diagnosticType: string) => boolean) = () => false;

  constructor(opts: PeerSessionOwnerOptions) { super(opts); }

  // --- Protected-hook seams ---
  //
  // `PeerSessionOwner` wires these into `ProjectStreamRegistry`'s constructor
  // (routeTerminal, projectDetached), not into `attachStream`'s per-project
  // `opts`, so a suite that wants terminal-routing or detach behavior
  // overrides them here rather than passing them to `attachStream`.
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

  protected override writeSessionRecord(peerId: string, payload: Buffer,
    diagnosticType: string): Promise<StreamSendOutcome> | null {
    const ok = this.writer(payload, peerId, diagnosticType);
    if (!ok) return null;
    this.recordOutbound(peerId, payload);
    return Promise.resolve("sent");
  }

  // --- The establish/sendFromPeer/readToPeer seam ---
  //
  // One place every suite gets from zero to an established session and drives
  // traffic across it, so a future wire change touches these methods instead
  // of every suite that calls them. `installFakeSession` (fake-session.ts) is
  // the only OTHER way to put a session on a client, for suites that need one
  // instantly and never touch the wire.

  /** Records this client wrote, queued per addressee in send order, for
   *  `readToPeer`/`sentTo`/`readFrameToPeer`/`sentFramesTo`. A record is
   *  just its payload; there is no header kind to carry alongside it. */
  private outbox = new Map<string, Buffer[]>();

  private recordOutbound(to: string, payload: Buffer): void {
    const list = this.outbox.get(to);
    if (list) list.push(payload); else this.outbox.set(to, [payload]);
  }

  /** Admit `peerId`'s identity and drive a real plaintext `session:hello` ->
   *  `established` through the production code. Throws if establishment does
   *  not land — a test that wants to see a REFUSED hello drives
   *  `injectPeerPayload`/`sendFromPeer` directly instead, since this seam only
   *  speaks for a hello that succeeds. */
  establish(peerId: string, opts: {
    identity?: PeerIdentity;
    attemptId?: string;
  } = {}): { attemptId: string; identity: PeerIdentity } {
    const identity = opts.identity ?? ed25519Pair();
    const attemptId = opts.attemptId ?? `attempt-${peerId}-${++establishCounter}`;
    this.admitPeer(peerId, identity.pubB64);
    this.sendFromPeer(peerId, { type: "session:hello", attemptId });
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
   *  plaintext JSON, no envelope. `obj` may be a pre-serialized string (a
   *  deliberately malformed body) or any JSON-able value. */
  sendFromPeer(peerId: string, obj: unknown): void {
    const payload = typeof obj === "string" ? obj : JSON.stringify(obj);
    this.injectPeerPayload(Buffer.from(payload, "utf8"), peerId);
  }

  /** Pop and parse the next frame this client sent to `peerId`: a bare
   *  `AbMessage` or session frame, never wrapped. Throws on an empty queue —
   *  a test expecting silence should check `sentTo` instead. */
  readToPeer(peerId: string): unknown {
    return this.readFrameToPeer(peerId).body;
  }

  /** Like `readToPeer`, but returns `{ body }` for call sites that
   *  destructure the frame. */
  readFrameToPeer(peerId: string): { body: unknown } {
    const list = this.outbox.get(peerId);
    const next = list?.shift();
    if (next === undefined) throw new Error(`readFrameToPeer(${peerId}): nothing queued`);
    return { body: JSON.parse(next.toString("utf8")) };
  }

  /** Every payload queued for `peerId` so far, without consuming it. */
  sentTo(peerId: string): ReadonlyArray<Buffer> {
    return this.outbox.get(peerId) ?? [];
  }

  /** Like `sentTo`, but parsed. */
  sentFramesTo(peerId: string): ReadonlyArray<unknown> {
    return (this.outbox.get(peerId) ?? []).map((payload) => JSON.parse(payload.toString("utf8")));
  }

  setNativeWriter(writer: (payload: Buffer, to: string, diagnosticType: string) => boolean): void {
    this.writer = writer;
  }

  /** Deliver `payload` on the session stream exactly as the native layer
   *  would: a bare record, no envelope to decode. */
  injectPeerPayload(payload: Uint8Array, from: string): void {
    this.receiveSessionRecord(payload, from);
  }

  markPeerOffline(peerId: string): void {
    // isForeignSlot and the rest of the mux's slot bookkeeping are gone; this
    // seam's only other caller was that guard itself, so it now just drops
    // the session.
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
      // One AbMessage is always exactly one record.
      read: () => {
        const text = fake.afterFirst.shift();
        if (text === undefined) throw new Error(`openProjectStream(${peerId}, ${projectId}).read(): nothing queued`);
        return JSON.parse(text);
      },
      send: async (obj) => { fake.pushAppRecord(obj); await flush(); },
      sendOverlongPrefix: async (length) => { fake.pushOverlongPrefix(length); await flush(); },
      finish: async () => { fake.endWith(); await flush(); },
      reset: async () => { fake.endWith(new Error("app reset")); await flush(); },
      resets: fake.resets,
      stops: fake.stops,
      get finished() { return fake.isFinished(); },
      priorities: fake.priorities,
      writeAllLengths: fake.writeAllLengths,
      holdWrites: () => fake.holdWrites(),
      releaseWrites: () => { fake.releaseWrites(); },
    };
  }

  async close(): Promise<void> { this.disposeSessions(); }

  static forTest(opts: {
    sendPayload: (payload: Buffer, to?: string) => void;
    peerId: string;
    deviceId?: string;
    agentEd25519PrivB64?: string;
    phoneEd25519PubB64?: string;
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
export { MAX_APP_SESSIONS } from "../src/peer-session-owner";
export type { PeerSession };
