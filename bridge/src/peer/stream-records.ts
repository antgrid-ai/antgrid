/**
 * Per-stream record I/O over one native Iroh QUIC bidirectional stream
 * (`@number0/iroh` `BiStream`). Knows nothing about stream kinds, dispatch
 * or admission; those belong to whoever accepted the stream.
 *
 * The binding's `SendStream`/`RecvStream` are each `Arc<Mutex<..>>` on the
 * Rust side (docs/iroh-reduction/stage-A-waves.md §1.1): every method —
 * `write`, `writeAll`, `reset`, `setPriority`, `stopped` — takes the SAME
 * lock and holds it across its await. A write in flight therefore blocks
 * `reset` until that write's slice completes; there is no way to preempt it.
 * Two consequences shape everything below:
 *   - writes are sliced to a bounded size, so an overflow reset waits at
 *     most one slice, never a whole multi-megabyte record;
 *   - `stopped`/`receivedReset` are never awaited — doing so on a live
 *     stream would wedge every later write or read on it, and the only
 *     thing that would then free it is closing the whole connection.
 */

/** ≤256 KiB per native call, both directions — the bound that keeps a
 *  stream's `reset()` (or the next inbound record) waiting on at most one
 *  in-flight slice instead of an entire queued transfer. */
export const STREAM_RECORD_SLICE_BYTES = 262_144;

/** Cap on one raw (unframed) read, both directions — allocated per call by
 *  `read(sizeLimit)`, so callers that only need a handful of bytes (an
 *  overrun probe, a cancel watcher) never pay for a full 256 KiB buffer. */
export const STREAM_RAW_READ_BYTES = 65_536;

const LENGTH_PREFIX_BYTES = 4;

/** The write half of a native bidirectional stream. Deliberately narrower
 *  than the real `SendStream`: it has no `stopped`/`receivedReset`, so
 *  nothing in this file can be tempted to await them. */
export interface StreamSend {
  writeAll(bytes: number[]): Promise<void>;
  setPriority(p: number): Promise<void>;
  reset(errorCode: bigint): Promise<void>;
  finish(): Promise<void>;
}

/** The read half of a native bidirectional stream. */
export interface StreamRecv {
  readExact(size: number): Promise<number[]>;
}

/** The read half needed for unframed streams: resolves `[]` at FIN and
 *  rejects (same as `readExact`) on a peer reset or connection loss. */
export interface RawStreamRecv extends StreamRecv {
  read(sizeLimit: number): Promise<number[]>;
}

/** Why a writer stopped for good. Only `unauthorized` retires the whole
 *  connection; the other two mean only this stream is dead and the owner
 *  unbinds it (D3, docs/iroh-reduction/ledger.md: a slow or stopped stream
 *  never costs the connection). A native write rejection is `stream-lost`
 *  rather than connection-fatal because the binding reports a peer's
 *  STOP_SENDING on this one stream the same way it reports a dead connection,
 *  and a real connection loss is already surfaced by the connection itself. */
export type StreamWriteFailure = "unauthorized" | "overflow" | "stream-lost";

export type StreamSendOutcome = "sent" | "dropped";

/** What a bus-facing send reports: `StreamSendOutcome` plus the two refusals
 *  decided before any writer is reached. `"too-large"` is a message over the
 *  sender's cap (MESSAGE_TOO_LARGE); `"gated"` is an outbound authorization
 *  hook (`mayDeliver`/`mayDeliverTo`) saying no. */
export type SendOutcome = StreamSendOutcome | "too-large" | "gated";

/** Why a peer's whole connection is retired. Mapped to a QUIC close code by
 *  `native-host-connection.ts`: unauthorized 3, protocol-violation 2, else 1. */
export type PeerRecordFailure = "connection-lost" | "protocol-violation" | "queue-full" | "unauthorized" | "superseded";

/** Thrown by `StreamRecordReader.read()` for a malformed length prefix.
 *  Distinct from a plain rejection out of the native `readExact` (a peer
 *  reset or FIN on this one stream, which is routine and not a connection
 *  fault) — only THIS is a protocol violation, and per D3 it is the
 *  reader's one connection-fatal signal. */
export class StreamProtocolViolation extends Error {
  constructor(message: string) {
    super(message);
    this.name = "StreamProtocolViolation";
  }
}

interface PendingWrite {
  bytes: Buffer;
  settle: (outcome: StreamSendOutcome) => void;
  /** Removes the abort listener once the record leaves the queue by any path,
   *  so a signal that outlives the record (or the whole stream) never fires
   *  into a settled promise. */
  cleanup?: () => void;
}

/**
 * Writes `[u32 len][frame]` records onto one stream's send half, queuing
 * ahead of the native binding (which exposes no observable write buffer of
 * its own).
 */
export class StreamRecordWriter {
  private readonly queue: PendingWrite[] = [];
  private writing = false;
  private stopped = false;
  private queuedBytes = 0;
  private prioritySet = false;
  // `finishing` gates new sends the instant `finish()` is called; `finished`
  // marks that `send.finish()` has actually been issued. They are distinct so
  // a `finish()` racing an overflow/unauthorized failure still resolves (see
  // `resolveFinishWaiters`) without ever having reached the native call.
  private finishing = false;
  private finished = false;
  private finishWaiters: Array<() => void> = [];

  constructor(
    private readonly stream: { send: StreamSend },
    private readonly authorized: () => boolean,
    private readonly onFailure: (reason: StreamWriteFailure) => void,
    private readonly maxQueuedBytes: number,
    private readonly priority = 0,
    private readonly resetCode = 0n,
  ) {}

  /** `signal`, when given, cancels the record only while it is still queued
   *  (§"Binding constraints": once a slice has reached `writeAll`, a partial
   *  record would corrupt the framing, so it always completes from there). */
  send(frame: Uint8Array, signal?: AbortSignal): Promise<StreamSendOutcome> {
    const bytes = Buffer.allocUnsafe(frame.length + LENGTH_PREFIX_BYTES);
    bytes.writeUInt32BE(frame.length);
    bytes.set(frame, LENGTH_PREFIX_BYTES);
    return this.enqueue(bytes, signal);
  }

  /** Raw bytes, no length prefix, through the same queue, overflow bound and
   *  per-slice `authorized()` check as `send()`. A zero-length call still
   *  passes through the queue (so it observes the same authorization and
   *  overflow checks) but reaches no native write, since `writeInSlices`'s
   *  loop never executes for an empty buffer. */
  sendRaw(bytes: Uint8Array, signal?: AbortSignal): Promise<StreamSendOutcome> {
    return this.enqueue(Buffer.from(bytes), signal);
  }

  private enqueue(bytes: Buffer, signal?: AbortSignal): Promise<StreamSendOutcome> {
    if (this.stopped || this.finishing) return Promise.resolve("dropped");
    if (signal?.aborted) return Promise.resolve("dropped");
    if (!this.authorized()) {
      this.failConnection("unauthorized");
      return Promise.resolve("dropped");
    }
    if (this.queuedBytes + bytes.length > this.maxQueuedBytes) {
      this.stopStream("overflow");
      return Promise.resolve("dropped");
    }
    return new Promise((settle) => {
      const record: PendingWrite = { bytes, settle };
      if (signal) {
        const onAbort = () => {
          const idx = this.queue.indexOf(record);
          if (idx === -1) return; // already dequeued for writing: completes regardless
          this.queue.splice(idx, 1);
          this.queuedBytes -= record.bytes.length;
          record.cleanup = undefined;
          record.bytes.fill(0);
          record.settle("dropped");
        };
        signal.addEventListener("abort", onAbort, { once: true });
        record.cleanup = () => signal.removeEventListener("abort", onAbort);
      }
      this.queue.push(record);
      this.queuedBytes += bytes.length;
      void this.drain();
    });
  }

  /** Stops the writer without treating it as a failure: for a stream the
   *  owner is unbinding on purpose (the app FIN'd or reset its half), not one
   *  that misbehaved. Drops the queue so every waiter resolves `"dropped"`,
   *  resolves `finish()` waiters, and resets the native send half — never
   *  awaited, and never calling `onFailure`, which is reserved for the writer
   *  discovering its own failure. A no-op once the writer has stopped or
   *  `finish()` has been issued, matching `send()`'s own `finishing` guard. */
  abort(): void {
    if (this.stopped || this.finishing) return;
    this.stopped = true;
    this.dropQueue();
    this.resolveFinishWaiters();
    void this.stream.send.reset(this.resetCode).catch(() => {});
  }

  private async drain(): Promise<void> {
    if (this.writing || this.stopped) return;
    this.writing = true;
    try {
      while (!this.stopped && this.queue.length) {
        if (!this.authorized()) {
          this.failConnection("unauthorized");
          return;
        }
        const record = this.queue.shift()!;
        this.queuedBytes -= record.bytes.length;
        record.cleanup?.();
        let outcome: "complete" | "aborted";
        try {
          if (!this.prioritySet) {
            // Must land before the first write ever reaches the wire, or the
            // binding has nothing to reorder ahead of (spec §"Binding constraints").
            this.prioritySet = true;
            await this.stream.send.setPriority(this.priority);
          }
          outcome = this.stopped ? "aborted" : await this.writeInSlices(record.bytes);
        } catch {
          record.bytes.fill(0);
          record.settle("dropped");
          this.stopStream("stream-lost");
          return;
        }
        record.bytes.fill(0);
        record.settle(outcome === "complete" ? "sent" : "dropped");
      }
      // The queue this `finish()` promised to drain is empty now, and nothing
      // can have re-queued behind it: `send()` already refuses once
      // `finishing` is set, so this check and the native call are atomic with
      // respect to any caller still on this microtask queue.
      if (this.finishing && !this.finished && !this.stopped && !this.queue.length) {
        await this.stream.send.finish().catch(() => {});
        this.finished = true;
        this.resolveFinishWaiters();
      }
    } finally {
      this.writing = false;
    }
  }

  /** Resolves once every record queued before the call has been written and
   *  `send.finish()` has been issued. A no-op if the writer already stopped
   *  (overflow, stream-lost, unauthorized) or `finish()` already ran. */
  finish(): Promise<void> {
    if (this.stopped || this.finished) return Promise.resolve();
    if (!this.finishing) {
      this.finishing = true;
      void this.drain();
    }
    return new Promise((resolve) => {
      if (this.finished) resolve();
      else this.finishWaiters.push(resolve);
    });
  }

  private resolveFinishWaiters(): void {
    const waiters = this.finishWaiters;
    this.finishWaiters = [];
    for (const resolve of waiters) resolve();
  }

  /** Checks `stopped` between slices, not just before the record starts, so
   *  an overflow (or a failure) noticed mid-record aborts after the slice
   *  already handed to the native binding rather than after the whole
   *  record — the reset that follows then waits on at most that one slice.
   *  Authorization is rechecked per slice too, so turning remote access off
   *  mid-transfer stops a 32 MiB record within one slice, not at its end. */
  private async writeInSlices(bytes: Buffer): Promise<"complete" | "aborted"> {
    for (let offset = 0; offset < bytes.length; offset += STREAM_RECORD_SLICE_BYTES) {
      if (this.stopped) return "aborted";
      if (!this.authorized()) {
        this.failConnection("unauthorized");
        return "aborted";
      }
      const end = Math.min(offset + STREAM_RECORD_SLICE_BYTES, bytes.length);
      await this.stream.send.writeAll(Array.from(bytes.subarray(offset, end)));
    }
    return "complete";
  }

  /** Resets only this stream — the app reopens and resyncs (D3). Queued
   *  records are dropped up front so no caller waits on a reset that, per the
   *  shared mutex, can only run after the in-flight slice returns. The reset
   *  is explicit because a dropped native SendStream FINs, which would hand
   *  the peer a truncated record followed by a clean end. */
  private stopStream(reason: "overflow" | "stream-lost"): void {
    if (this.stopped) return;
    this.stopped = true;
    this.dropQueue();
    this.resolveFinishWaiters();
    // Never awaited: the stream (or connection) may already be gone.
    this.stream.send.reset(this.resetCode).catch(() => {});
    this.onFailure(reason);
  }

  private failConnection(reason: "unauthorized"): void {
    if (this.stopped) return;
    this.stopped = true;
    this.dropQueue();
    this.resolveFinishWaiters();
    this.onFailure(reason);
  }

  private dropQueue(): void {
    for (const record of this.queue) {
      record.cleanup?.();
      record.bytes.fill(0);
      record.settle("dropped");
    }
    this.queue.length = 0;
    this.queuedBytes = 0;
  }
}

export type StreamReadFailure = "protocol-violation";

/**
 * Reads `[u32 len][frame]` records off one stream's receive half. A native
 * `readExact` rejection (peer reset or FIN on this one stream) is rethrown
 * as-is — routine, and for the caller to interpret — while a malformed
 * length prefix is the reader's own protocol violation and retires the
 * connection (D3).
 */
export class StreamRecordReader {
  constructor(
    private readonly stream: { recv: StreamRecv },
    private readonly maxRecordBytes: number,
    private readonly onFailure: (reason: StreamReadFailure) => void,
  ) {}

  async read(): Promise<Uint8Array> {
    const prefix = Buffer.from(await this.stream.recv.readExact(LENGTH_PREFIX_BYTES));
    if (prefix.length !== LENGTH_PREFIX_BYTES) return this.violate("short length prefix");
    const length = prefix.readUInt32BE();
    if (length === 0 || length > this.maxRecordBytes) {
      return this.violate(`record length ${length} out of bounds`);
    }
    const body = Buffer.allocUnsafe(length);
    let offset = 0;
    while (offset < length) {
      const want = Math.min(STREAM_RECORD_SLICE_BYTES, length - offset);
      const piece = await this.stream.recv.readExact(want);
      if (piece.length !== want) return this.violate("short read");
      body.set(piece, offset);
      offset += want;
    }
    return new Uint8Array(body.buffer, body.byteOffset, body.byteLength);
  }

  private violate(message: string): never {
    this.onFailure("protocol-violation");
    throw new StreamProtocolViolation(message);
  }
}

/**
 * Reads unframed bytes off one stream's receive half — no length prefix, so
 * the caller (not this class) knows how much a record is worth reading.
 */
export class StreamRawReader {
  constructor(private readonly stream: { recv: RawStreamRecv }) {}

  /** `null` at FIN; rejects on reset or connection loss (rethrown as-is, same
   *  as `StreamRecordReader`). `maxBytes` is clamped to
   *  `[1, STREAM_RAW_READ_BYTES]` so a caller cannot over-allocate the native
   *  read buffer, and the clamp's floor of 1 keeps this from ever resolving
   *  an empty (non-null) array. */
  async read(maxBytes: number): Promise<Uint8Array | null> {
    const size = Math.max(1, Math.min(maxBytes, STREAM_RAW_READ_BYTES));
    const bytes = await this.stream.recv.read(size);
    return bytes.length === 0 ? null : new Uint8Array(bytes);
  }
}

/** Stops a stream's receive half once whatever read is currently outstanding
 *  on it has settled, or immediately if none is — never before, since
 *  `recv.stop()` would otherwise queue behind that read on the binding's
 *  shared per-stream mutex. The outcome of `pending` (resolve or reject)
 *  never matters here: either way the mutex is free once it settles. */
export function stopRecvWhenSettled(pending: Promise<unknown> | null, stop: () => void): void {
  if (pending) void pending.then(() => {}, () => {}).then(stop);
  else stop();
}
