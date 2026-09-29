// The one fake bidi stream every bridge stream test drives a real registry
// against. It stands in for `@number0/iroh`'s `BiStream`: the send half
// records everything written (both framed records and raw slices) so a test
// can assert on either shape, and the recv half is a byte queue fed by
// `pushRecord`/`pushRaw`/`pushOverlongPrefix`/`endWith`, served to whichever
// read style (`readExact` for framed kinds, `read` for raw ones) the
// registry under test actually calls.
import type { AcceptedBiStream, Schedule, StreamRefusal } from "../../src/peer/stream-dispatch";
import { decodeStreamRefused } from "antgrid-wire";
import type { AbMessage } from "../../src/protocol";
import type { ProjectBinding } from "../../src/project-streams";
import type { TunnelStreamServer } from "../../src/tunnel-manager";
import type { UploadStreamServer } from "../../src/file-upload";

export function flush(times = 3): Promise<void> {
  return (async () => {
    for (let i = 0; i < times; i++) await new Promise<void>((resolve) => setTimeout(resolve, 0));
  })();
}

const encoder = new TextEncoder();

function u32be(n: number): Uint8Array {
  const buf = new Uint8Array(4);
  new DataView(buf.buffer).setUint32(0, n, false);
  return buf;
}

export interface FakeBiStream {
  stream: AcceptedBiStream;
  priorities: number[];
  resets: bigint[];
  stops: bigint[];
  order: string[];
  writeAllLengths: number[];
  isFinished(): boolean;
  /** Complete `[u32][body]` records reassembled from every `writeAll` call, in
   *  commit order — for a kind that writes framed records (project, terminal,
   *  tunnel head, refusals). */
  records(): string[];
  /** Every byte written, concatenated and unframed — for a kind that writes
   *  raw slices (tunnel-tcp payload, `sendRaw`). */
  rawWritten(): Uint8Array;
  firstRecord(): string | undefined;
  afterFirst: string[];
  /** Parks every future `writeAll` until released — a peer whose QUIC send
   *  window is full. */
  holdWrites(): void;
  releaseWrites(): void;
  /** Parks exactly the next `writeAll` call; returns the release function. */
  gateNextWrite(): () => void;
  /** Makes exactly the next `writeAll` call reject. */
  failNextWrite(e?: unknown): void;
  /** Queues a length-prefixed record onto the recv side, for a
   *  `readExact`-based (framed) reader: JSON-encoded unless `obj` is already
   *  a `Uint8Array` (a non-JSON record). */
  pushRecord(obj: unknown): void;
  /** Queues raw, unframed bytes onto the recv side, for a `read`-based (raw)
   *  reader. */
  pushRaw(bytes: Uint8Array): void;
  /** Queues a bare over-large length prefix with no body: enough on its own
   *  to trip a `StreamRecordReader`'s bound check, which rejects on the
   *  prefix before ever asking for the body. */
  pushOverlongPrefix(len: number): void;
  /** Ends the recv side: FIN (undefined) or a rejection every pending and
   *  future read sees. */
  endWith(error?: unknown): void;
  /** Reads on the recv side not yet settled — asserts a `stop()` never races
   *  an outstanding read. */
  pendingReads(): number;
  /** Every size requested via `readExact`, in call order. */
  readExactSizes: number[];
  /** Every size limit requested via `read` (the raw path), in call order —
   *  proves a raw reader never asks for more than the bytes still owed. */
  readSizes: number[];
}

export function createFakeBiStream(): FakeBiStream {
  // ---- send half --------------------------------------------------------
  const priorities: number[] = [];
  const resets: bigint[] = [];
  const stops: bigint[] = [];
  const order: string[] = [];
  const writeAllLengths: number[] = [];
  let finished = false;
  let sendBuf: number[] = [];
  const afterFirst: string[] = [];
  let firstRecordText: string | undefined;
  let heldWrites: Array<() => void> | undefined;
  let gatedNext: Array<() => Promise<void>> = [];
  let failNext: unknown[] = [];

  function absorbFramed(bytes: number[]): void {
    sendBuf = sendBuf.concat(bytes);
    for (;;) {
      if (sendBuf.length < 4) return;
      const len = Buffer.from(sendBuf.slice(0, 4)).readUInt32BE(0);
      if (sendBuf.length < 4 + len) return;
      const body = Buffer.from(sendBuf.slice(4, 4 + len)).toString("utf8");
      sendBuf = sendBuf.slice(4 + len);
      if (firstRecordText === undefined) firstRecordText = body;
      else afterFirst.push(body);
    }
  }

  async function doWrite(bytes: number[]): Promise<void> {
    absorbFramed(bytes);
    if (failNext.length) {
      const error = failNext.shift();
      throw error;
    }
  }

  const send: AcceptedBiStream["send"] = {
    writeAll: async (bytes) => {
      // Recorded at invocation, not completion: a write parked behind a hold
      // or a gate has still reached the wire attempt a real QUIC send makes
      // the instant it's this stream's turn, which is what a queued-but-not-
      // yet-flushed frame needs to prove (e.g. one dropped by an abort while
      // queued behind it never shows up here at all).
      order.push("writeAll");
      writeAllLengths.push((bytes as number[]).length);
      if (heldWrites) await new Promise<void>((resolve) => heldWrites!.push(resolve));
      const gate = gatedNext.shift();
      if (gate) await gate();
      await doWrite(bytes as number[]);
    },
    setPriority: async (p) => { order.push("setPriority"); priorities.push(p); },
    reset: async (code) => { order.push("reset"); resets.push(code); },
    finish: async () => { order.push("finish"); finished = true; },
  };

  // ---- recv half ---------------------------------------------------------
  let buffer: number[] = [];
  let ended = false;
  let endError: unknown = undefined;
  const FIN = Symbol("fin");
  if (endError === undefined) endError = FIN;
  interface Waiter { exact: number | null; limit: number; resolve: (v: number[]) => void; reject: (e: unknown) => void }
  const waiters: Waiter[] = [];
  const readExactSizes: number[] = [];
  const readSizes: number[] = [];

  function tryDrain(): void {
    while (waiters.length) {
      const w = waiters[0]!;
      if (w.exact !== null) {
        if (buffer.length >= w.exact) {
          const out = buffer.splice(0, w.exact);
          waiters.shift();
          w.resolve(out);
          continue;
        }
        if (ended) {
          waiters.shift();
          w.reject(endError === FIN ? new Error("stream ended before requested bytes") : endError);
          continue;
        }
        return; // still waiting on more bytes
      } else {
        if (buffer.length > 0) {
          const take = Math.min(w.limit, buffer.length);
          const out = buffer.splice(0, take);
          waiters.shift();
          w.resolve(out);
          continue;
        }
        if (ended) {
          waiters.shift();
          if (endError === FIN) w.resolve([]);
          else w.reject(endError);
          continue;
        }
        return;
      }
    }
  }

  const recv: AcceptedBiStream["recv"] = {
    readExact: (size) => {
      readExactSizes.push(size);
      return new Promise<number[]>((resolve, reject) => {
        waiters.push({ exact: size, limit: size, resolve, reject });
        tryDrain();
      });
    },
    read: (sizeLimit) => {
      readSizes.push(sizeLimit);
      return new Promise<number[]>((resolve, reject) => {
        waiters.push({ exact: null, limit: sizeLimit, resolve, reject });
        tryDrain();
      });
    },
    stop: async (code) => { stops.push(code); },
  };

  function appendBytes(bytes: Uint8Array): void {
    buffer = buffer.concat(Array.from(bytes));
    tryDrain();
  }

  return {
    stream: { send, recv },
    priorities, resets, stops, order, writeAllLengths,
    afterFirst,
    isFinished: () => finished,
    records: () => (firstRecordText === undefined ? [] : [firstRecordText, ...afterFirst]),
    // Whatever a complete framed parse never consumed: for a kind that writes
    // one framed head then raw slices (tunnel-tcp), the head is fully
    // absorbed above and this tail is exactly the raw bytes after it.
    rawWritten: () => Uint8Array.from(sendBuf),
    firstRecord: () => firstRecordText,
    holdWrites(): void { heldWrites ??= []; },
    releaseWrites(): void {
      const held = heldWrites ?? [];
      heldWrites = undefined;
      for (const release of held) release();
    },
    gateNextWrite(): () => void {
      let release!: () => void;
      const gate = new Promise<void>((resolve) => { release = resolve; });
      gatedNext.push(() => gate);
      return release;
    },
    failNextWrite(e: unknown = new Error("write failed")): void {
      failNext.push(e);
    },
    pushRecord(obj: unknown): void {
      const body = obj instanceof Uint8Array ? obj : encoder.encode(typeof obj === "string" ? obj : JSON.stringify(obj));
      const framed = new Uint8Array(4 + body.length);
      framed.set(u32be(body.length), 0);
      framed.set(body, 4);
      appendBytes(framed);
    },
    pushRaw(bytes: Uint8Array): void {
      appendBytes(bytes);
    },
    pushOverlongPrefix(len: number): void {
      appendBytes(u32be(len));
    },
    endWith(error?: unknown): void {
      ended = true;
      endError = error === undefined ? FIN : error;
      tryDrain();
    },
    pendingReads(): number { return waiters.length; },
    readExactSizes, readSizes,
  };
}

export interface FakeProjectBinding extends ProjectBinding {
  setHasOpenStream(peerId: string, v: boolean): void;
  setRefusal(r?: StreamRefusal): void;
  setMayDeliver(v: boolean): void;
  setTunnels(s: TunnelStreamServer | null): void;
  setUploads(s: UploadStreamServer | null): void;
  /** Every projectId the surrounding test's own `projectBinding(id)` lookup
   *  closure was called with — pushed by that closure, not by this object. */
  lookups: string[];
  dispatched: Array<{ msg: AbMessage; peerId: string }>;
}

export function createFakeProjectBinding(): FakeProjectBinding {
  // Every peer has an open project stream by default (the project-stream
  // admission gate), so a test targeting some OTHER admission step doesn't
  // also have to wire this one; a test of that gate itself opts a peer out.
  const closedStreams = new Set<string>();
  let refusal: StreamRefusal | undefined;
  let mayDeliver = true;
  let tunnels: TunnelStreamServer | null = null;
  let uploads: UploadStreamServer | null = null;
  const dispatched: Array<{ msg: AbMessage; peerId: string }> = [];
  return {
    lookups: [],
    dispatched,
    hasOpenStream: (peerId) => !closedStreams.has(peerId),
    // Cast: ScopedProjectBinding's own contract is `StreamRefusal | undefined`;
    // `ProjectBinding.refusalFor` predates that and still declares `| null`.
    refusalFor: (() => refusal) as ProjectBinding["refusalFor"],
    mayDeliverTo: () => mayDeliver,
    dispatch: (msg, peerId) => { dispatched.push({ msg, peerId }); return true; },
    tunnels: () => tunnels,
    uploads: () => uploads,
    setHasOpenStream(peerId: string, v: boolean): void { if (v) closedStreams.delete(peerId); else closedStreams.add(peerId); },
    setRefusal(r?: StreamRefusal): void { refusal = r; },
    setMayDeliver(v: boolean): void { mayDeliver = v; },
    setTunnels(s: TunnelStreamServer | null): void { tunnels = s; },
    setUploads(s: UploadStreamServer | null): void { uploads = s; },
  };
}

/** A `Schedule` a test fires by hand instead of waiting on a real timer;
 *  `timers` keeps each delay so a test can fire one deadline by its length. */
export function manualSchedule() {
  const timers: Array<{ ms: number; fire: () => void; cancelled: boolean }> = [];
  const schedule: Schedule = (callback, ms) => {
    const timer = { ms, fire: () => { if (!timer.cancelled) { timer.cancelled = true; callback(); } }, cancelled: false };
    timers.push(timer);
    return () => { timer.cancelled = true; };
  };
  return {
    schedule,
    timers,
    fire(): void { for (const t of timers.splice(0)) t.fire(); },
  };
}

export async function until(condition: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition not met in time");
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

export function lengthPrefix(length: number): number[] {
  return Array.from(u32be(length));
}

/** The `stream:refused` record a registry wrote as this stream's first
 *  record, if it refused. */
export function refusalOf(fake: FakeBiStream): { code: string; message: string } | undefined {
  const text = fake.firstRecord();
  if (text === undefined) return undefined;
  return decodeStreamRefused(encoder.encode(text)) ?? undefined;
}
