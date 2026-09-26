import { expect, test } from "bun:test";
import {
  STREAM_RAW_READ_BYTES,
  STREAM_RECORD_SLICE_BYTES,
  StreamProtocolViolation,
  StreamRawReader,
  StreamRecordReader,
  StreamRecordWriter,
  type RawStreamRecv,
  type StreamReadFailure,
  type StreamRecv,
  type StreamSend,
  type StreamWriteFailure,
} from "../src/peer/stream-records";

/** Serializes calls exactly like the real binding's `Arc<Mutex<..>>` (see the
 *  module comment): a call queued behind another does not even START running
 *  its body until the prior one's promise settles. A fake without this would
 *  let `reset()` "succeed" instantly under a stuck `writeAll`, hiding the
 *  deadlock the slicing in stream-records.ts exists to avoid. */
class FakeMutex {
  private tail: Promise<unknown> = Promise.resolve();

  run<T>(fn: () => Promise<T>): Promise<T> {
    const result = this.tail.then(fn);
    this.tail = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }
}

function flush(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function createFakeSendStream() {
  const mutex = new FakeMutex();
  const writeAllCalls: number[][] = [];
  const setPriorityCalls: number[] = [];
  const resetCalls: bigint[] = [];
  const order: string[] = [];
  let finishCalls = 0;
  let pendingGate: Promise<void> | null = null;
  let pendingError: Error | null = null;
  const send: StreamSend = {
    writeAll: (bytes) =>
      mutex.run(async () => {
        order.push("writeAll");
        writeAllCalls.push(bytes);
        const gate = pendingGate;
        pendingGate = null;
        if (gate) await gate;
        const error = pendingError;
        pendingError = null;
        if (error) throw error;
      }),
    setPriority: (p) => mutex.run(async () => { order.push("setPriority"); setPriorityCalls.push(p); }),
    reset: (code) => mutex.run(async () => { order.push("reset"); resetCalls.push(code); }),
    finish: () => mutex.run(async () => { order.push("finish"); finishCalls++; }),
  };
  return {
    stream: { send },
    writeAllCalls,
    setPriorityCalls,
    resetCalls,
    finishCalls: () => finishCalls,
    order,
    /** Makes the NEXT `writeAll` reject, as the binding does when the peer
     *  sends STOP_SENDING on this stream. One-shot. */
    failNextWrite(error: Error): void {
      pendingError = error;
    },
    /** Blocks the NEXT `writeAll` call (through the shared lock, like a real
     *  stalled peer) until `release()` is called. One-shot. */
    gateNextWrite(): { release: () => void } {
      const { promise, resolve } = Promise.withResolvers<void>();
      pendingGate = promise;
      return { release: () => resolve() };
    },
  };
}

function createFakeRecvStream(chunks: number[][]) {
  const queue = [...chunks];
  const requested: number[] = [];
  const recv: StreamRecv = {
    readExact: async (size) => {
      requested.push(size);
      const next = queue.shift();
      if (next === undefined) throw new Error("fake recv stream exhausted");
      return next;
    },
  };
  return { stream: { recv }, requested };
}

/** A `RawStreamRecv` fake for `StreamRawReader`: `read(sizeLimit)` resolves
 *  each queued step in order, then (once `atEnd` is armed) `[]` forever, as
 *  the binding does at FIN. A queued `Error` rejects instead, as the binding
 *  does on a peer reset — the trap `StreamRawReader` exists to distinguish
 *  from a plain empty read. */
function createFakeRawRecvStream(steps: Array<number[] | Error>, opts: { atEnd?: boolean } = {}) {
  const queue = [...steps];
  const requested: number[] = [];
  const recv: RawStreamRecv = {
    readExact: async () => { throw new Error("StreamRawReader must use read(), never readExact()"); },
    read: async (sizeLimit) => {
      requested.push(sizeLimit);
      const next = queue.shift();
      if (next === undefined) {
        if (opts.atEnd ?? true) return [];
        return new Promise<number[]>(() => {}); // hangs, like a stream with nothing more queued
      }
      if (next instanceof Error) throw next;
      return next;
    },
  };
  return { stream: { recv }, requested };
}

// --- StreamRecordWriter -----------------------------------------------

test("writes a single-slice record whose bytes equal the framed record", async () => {
  const fake = createFakeSendStream();
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 1_000_000, 7);
  const frame = new Uint8Array([9, 9, 9, 9]);
  const outcome = await writer.send(frame);
  expect(outcome).toBe("sent");
  const written = Buffer.from(fake.writeAllCalls[0]!);
  expect(written.readUInt32BE(0)).toBe(frame.length);
  expect(Array.from(written.subarray(4))).toEqual(Array.from(frame));
});

test("a 32 MiB record is written as more than one <=256 KiB slice", async () => {
  const fake = createFakeSendStream();
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 64 * 1024 * 1024);
  const frame = new Uint8Array(32 * 1024 * 1024).fill(7);
  const outcome = await writer.send(frame);
  expect(outcome).toBe("sent");
  expect(fake.writeAllCalls.length).toBeGreaterThan(1);
  for (const call of fake.writeAllCalls) {
    expect(call.length).toBeLessThanOrEqual(STREAM_RECORD_SLICE_BYTES);
  }
  const rebuilt = Buffer.concat(fake.writeAllCalls.map((c) => Buffer.from(c)));
  expect(rebuilt.readUInt32BE(0)).toBe(frame.length);
  expect(rebuilt.length).toBe(frame.length + 4);
});

test("unauthorized drops the record and retires the connection, never the stream", async () => {
  const fake = createFakeSendStream();
  const failures: StreamWriteFailure[] = [];
  const writer = new StreamRecordWriter(fake.stream, () => false, (r) => failures.push(r), 1_000_000);
  const outcome = await writer.send(new Uint8Array([1, 2, 3]));
  expect(outcome).toBe("dropped");
  expect(failures).toEqual(["unauthorized"]);
  expect(fake.writeAllCalls).toEqual([]);
  expect(fake.resetCalls).toEqual([]);
});

// A4 carry-over 4 (docs/iroh-reduction/stage-A-A4-contract.md §6): a project
// stream's writer is built with the admission's own `authorized()`, which
// includes the remote-access switch, so these two orderings matter beyond the
// general case above — a peer refused mid-connection must never be told
// "overflow" (D3: only the write-time queue check retires the stream itself).

test("send-time authorized() refuses before the overflow check", async () => {
  const fake = createFakeSendStream();
  const failures: StreamWriteFailure[] = [];
  // maxQueuedBytes is smaller than the record, so an overflow check that ran
  // first would report "overflow" and reset the stream instead of dropping.
  const writer = new StreamRecordWriter(fake.stream, () => false, (r) => failures.push(r), 4, 0, 99n);
  const outcome = await writer.send(new Uint8Array(8));
  expect(outcome).toBe("dropped");
  expect(failures).toEqual(["unauthorized"]);
  expect(fake.resetCalls).toEqual([]);
  expect(fake.writeAllCalls).toEqual([]);
});

test("drain-time authorized() refuses before priority or any write", async () => {
  const fake = createFakeSendStream();
  const failures: StreamWriteFailure[] = [];
  let calls = 0;
  // True only at submit time (send()'s own check) and false once drain picks
  // the record up — without the drain-time recheck, setPriority would already
  // have run before this test's per-slice guard ever caught it.
  const writer = new StreamRecordWriter(fake.stream, () => (++calls === 1), (r) => failures.push(r), 1_000_000);
  const outcome = await writer.send(new Uint8Array([1]));
  expect(outcome).toBe("dropped");
  expect(failures).toEqual(["unauthorized"]);
  expect(fake.setPriorityCalls).toEqual([]);
  expect(fake.writeAllCalls).toEqual([]);
});

test("authorization is rechecked when a queued record reaches the front, not just at send()", async () => {
  const fake = createFakeSendStream();
  const gate = fake.gateNextWrite(); // gates A's slice so B stays queued behind it
  const failures: StreamWriteFailure[] = [];
  let allowed = true;
  const writer = new StreamRecordWriter(fake.stream, () => allowed, (r) => failures.push(r), 1_000_000);
  const first = writer.send(new Uint8Array([1])); // starts draining, gets stuck on the gate
  const second = writer.send(new Uint8Array([2])); // authorized() was true at submit time; sits queued
  await flush();
  expect(fake.writeAllCalls.length).toBe(1); // only A's slice has reached the native call
  allowed = false;
  gate.release();
  expect(await first).toBe("sent"); // already past the native call before revocation
  expect(await second).toBe("dropped"); // never reached the wire once authorized() flipped
  expect(failures).toEqual(["unauthorized"]);
  expect(fake.writeAllCalls.length).toBe(1); // B's write was never attempted
});

test("overflow resets the stream only, never the connection", async () => {
  const fake = createFakeSendStream();
  const failures: StreamWriteFailure[] = [];
  // Room in the queue for exactly one 8-byte record ([4-byte len][4-byte frame]).
  const writer = new StreamRecordWriter(fake.stream, () => true, (r) => failures.push(r), 10, 0, 99n);
  // All three calls happen synchronously, before setPriority's promise can
  // resolve, so A is already shifted off the queue (drain is mid-flight,
  // suspended before its first write) while B still occupies it.
  const sentA = writer.send(new Uint8Array(4));
  const sentB = writer.send(new Uint8Array(4));
  const sentC = writer.send(new Uint8Array(4)); // 8 (B) + 8 (C) > 10 -> overflow
  expect(await sentC).toBe("dropped");
  expect(await sentB).toBe("dropped");
  expect(await sentA).toBe("dropped"); // aborted before its write ever reached the wire
  await flush();
  expect(fake.writeAllCalls).toEqual([]);
  expect(fake.resetCalls).toEqual([99n]);
  expect(failures).toEqual(["overflow"]);
});

test("an overflow reset waits for at most the in-flight slice, not the rest of a multi-slice record", async () => {
  const fake = createFakeSendStream();
  const gate = fake.gateNextWrite();
  const failures: StreamWriteFailure[] = [];
  const bigFrame = new Uint8Array(Math.floor(STREAM_RECORD_SLICE_BYTES * 1.5)); // needs 2 slices
  const writer = new StreamRecordWriter(
    fake.stream,
    () => true,
    (r) => failures.push(r),
    bigFrame.length + 4 + 10, // room for bigFrame once, nothing more
    0,
    5n,
  );

  const sentBig = writer.send(bigFrame);
  await flush();
  // Slice 1 has reached the native call and is now stuck on the gate; slice 2
  // has not been attempted.
  expect(fake.writeAllCalls.length).toBe(1);

  const sentOverflow = writer.send(new Uint8Array(STREAM_RECORD_SLICE_BYTES * 2));
  expect(await sentOverflow).toBe("dropped");
  await flush();
  // The trap this test guards: a fake without the shared lock would let this
  // resolve immediately even though a slice write is still "in flight".
  expect(fake.resetCalls).toEqual([]);
  expect(fake.writeAllCalls.length).toBe(1);

  gate.release();
  expect(await sentBig).toBe("dropped"); // aborted after its one outstanding slice
  await flush();
  expect(fake.writeAllCalls.length).toBe(1); // slice 2 of bigFrame was never sent
  expect(fake.resetCalls).toEqual([5n]);
  expect(failures).toEqual(["overflow"]); // stream-only; never "unauthorized"
});

test("a native write rejection resets only this stream and never retires the connection", async () => {
  const fake = createFakeSendStream();
  const gate = fake.gateNextWrite();
  fake.failNextWrite(new Error("Stopped(VarInt(0))"));
  const failures: StreamWriteFailure[] = [];
  const writer = new StreamRecordWriter(fake.stream, () => true, (r) => failures.push(r), 1_000_000, 0, 3n);
  const first = writer.send(new Uint8Array([1]));
  const queued = writer.send(new Uint8Array([2]));
  await flush();
  gate.release();
  expect(await first).toBe("dropped");
  expect(await queued).toBe("dropped");
  await flush();
  expect(failures).toEqual(["stream-lost"]);
  expect(fake.resetCalls).toEqual([3n]);
  expect(fake.writeAllCalls.length).toBe(1);
  expect(await writer.send(new Uint8Array([3]))).toBe("dropped");
  expect(failures).toEqual(["stream-lost"]);
});

test("revoking authorization mid-record stops a multi-slice record after the in-flight slice", async () => {
  const fake = createFakeSendStream();
  const gate = fake.gateNextWrite();
  const failures: StreamWriteFailure[] = [];
  let allowed = true;
  const writer = new StreamRecordWriter(fake.stream, () => allowed, (r) => failures.push(r), 64 * 1024 * 1024);
  const sent = writer.send(new Uint8Array(STREAM_RECORD_SLICE_BYTES * 4));
  await flush();
  expect(fake.writeAllCalls.length).toBe(1);
  allowed = false;
  gate.release();
  expect(await sent).toBe("dropped");
  expect(fake.writeAllCalls.length).toBe(1);
  expect(failures).toEqual(["unauthorized"]);
  expect(fake.resetCalls).toEqual([]);
});

test("finish() writes every queued record, then finishes the send half once", async () => {
  const fake = createFakeSendStream();
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 1_000_000);
  const sentA = writer.send(new Uint8Array([1]));
  const sentB = writer.send(new Uint8Array([2]));
  await writer.finish();
  expect(await sentA).toBe("sent");
  expect(await sentB).toBe("sent");
  expect(fake.writeAllCalls.length).toBe(2);
  expect(fake.finishCalls()).toBe(1);
  // finish() lands only after both queued records are on the wire.
  expect(fake.order.indexOf("finish")).toBeGreaterThan(fake.order.lastIndexOf("writeAll"));
  // Idempotent: a second call does not re-issue the native finish.
  await writer.finish();
  expect(fake.finishCalls()).toBe(1);
});

test("finish() after an overflow reset is a no-op", async () => {
  const fake = createFakeSendStream();
  const failures: StreamWriteFailure[] = [];
  // Room for exactly one 8-byte record; the third overflows before any of
  // the three writes reaches the wire (see the analogous test above).
  const writer = new StreamRecordWriter(fake.stream, () => true, (r) => failures.push(r), 10, 0, 99n);
  const sentA = writer.send(new Uint8Array(4));
  const sentB = writer.send(new Uint8Array(4));
  const sentC = writer.send(new Uint8Array(4));
  expect(await sentC).toBe("dropped");
  expect(await sentB).toBe("dropped");
  expect(await sentA).toBe("dropped");
  expect(failures).toEqual(["overflow"]);
  await writer.finish();
  expect(fake.finishCalls()).toBe(0);
  expect(fake.resetCalls).toEqual([99n]);
});

test("send() after finish() is dropped", async () => {
  const fake = createFakeSendStream();
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 1_000_000);
  await writer.send(new Uint8Array([1]));
  await writer.finish();
  expect(fake.finishCalls()).toBe(1);
  expect(await writer.send(new Uint8Array([2]))).toBe("dropped");
  expect(fake.writeAllCalls.length).toBe(1); // the post-finish send never reached the wire
});

// --- StreamRecordWriter: send()'s signal and abort() (A2 §3.1) --------

test("send() with an already-aborted signal is dropped without queueing", async () => {
  const fake = createFakeSendStream();
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 1_000_000);
  const controller = new AbortController();
  controller.abort();
  const outcome = await writer.send(new Uint8Array([1]), controller.signal);
  expect(outcome).toBe("dropped");
  expect(fake.writeAllCalls).toEqual([]);
});

test("a signal aborted while queued removes the record and frees its queued bytes", async () => {
  const fake = createFakeSendStream();
  const gate = fake.gateNextWrite(); // A is already dequeued and gated mid-write
  // Room for exactly one queued 8-byte record ([4-byte len][4-byte frame]) on
  // top of A, which is in flight and no longer counts against the queue.
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 8);
  const controller = new AbortController();
  const first = writer.send(new Uint8Array(4)); // dequeued immediately, stuck on the gate
  const second = writer.send(new Uint8Array(4), controller.signal); // fills the one queue slot
  await flush();
  controller.abort();
  expect(await second).toBe("dropped");
  // If the abort had not freed second's queued bytes, this would overflow.
  const third = writer.send(new Uint8Array(4));
  await flush();
  expect(fake.writeAllCalls.length).toBe(1); // still only A's slice, stuck on the gate
  gate.release();
  expect(await first).toBe("sent");
  expect(await third).toBe("sent");
});

test("a signal aborted after the first slice lets the record complete", async () => {
  const fake = createFakeSendStream();
  const gate = fake.gateNextWrite();
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 1_000_000);
  const controller = new AbortController();
  const sent = writer.send(new Uint8Array([1, 2, 3]), controller.signal);
  await flush(); // the record's one slice has reached writeAll and is now gated
  controller.abort(); // too late: a partial record would corrupt the framing
  gate.release();
  expect(await sent).toBe("sent");
});

test("abort() drops the queue, resets without awaiting, and never calls onFailure", async () => {
  const fake = createFakeSendStream();
  const gate = fake.gateNextWrite();
  const failures: StreamWriteFailure[] = [];
  const writer = new StreamRecordWriter(fake.stream, () => true, (r) => failures.push(r), 1_000_000, 0, 7n);
  const first = writer.send(new Uint8Array([1])); // stuck on the gate
  const second = writer.send(new Uint8Array([2])); // queued behind it
  await flush();
  writer.abort(); // calls reset() right away, without waiting on the gated write
  expect(await second).toBe("dropped");
  expect(failures).toEqual([]);
  // The reset call was issued synchronously above; it only settles once the
  // shared mutex frees up, which the gated write is holding (FakeMutex models
  // the binding's single per-stream lock — see the module comment above).
  expect(fake.resetCalls).toEqual([]);
  gate.release();
  await flush();
  expect(fake.resetCalls).toEqual([7n]);
  expect(await writer.send(new Uint8Array([3]))).toBe("dropped"); // stopped for good
});

test("abort() after finish() is a no-op", async () => {
  const fake = createFakeSendStream();
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 1_000_000, 0, 7n);
  await writer.send(new Uint8Array([1]));
  await writer.finish();
  writer.abort();
  expect(fake.resetCalls).toEqual([]); // finish() already ran; abort() must not reset
  expect(fake.finishCalls()).toBe(1);
});

// --- StreamRecordReader -------------------------------------------------

test("reads a length-prefixed record delivered in one piece", async () => {
  const frame = new Uint8Array([1, 2, 3, 4, 5]);
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(frame.length);
  const fake = createFakeRecvStream([Array.from(prefix), Array.from(frame)]);
  const failures: StreamReadFailure[] = [];
  const reader = new StreamRecordReader(fake.stream, 1_000_000, (r) => failures.push(r));
  const result = await reader.read();
  expect(Array.from(result)).toEqual(Array.from(frame));
  expect(fake.requested).toEqual([4, frame.length]);
  expect(failures).toEqual([]);
});

test("reads a body across multiple <=256 KiB pieces", async () => {
  const bodyLength = STREAM_RECORD_SLICE_BYTES + 10;
  const body = new Uint8Array(bodyLength).fill(3);
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(bodyLength);
  const fake = createFakeRecvStream([
    Array.from(prefix),
    Array.from(body.subarray(0, STREAM_RECORD_SLICE_BYTES)),
    Array.from(body.subarray(STREAM_RECORD_SLICE_BYTES)),
  ]);
  const reader = new StreamRecordReader(fake.stream, bodyLength, () => {});
  const result = await reader.read();
  expect(result.length).toBe(bodyLength);
  expect(Array.from(result)).toEqual(Array.from(body));
  expect(fake.requested).toEqual([4, STREAM_RECORD_SLICE_BYTES, 10]);
});

test("an oversized length prefix is a protocol violation that retires the connection", async () => {
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(2_000_000);
  const fake = createFakeRecvStream([Array.from(prefix)]);
  const failures: StreamReadFailure[] = [];
  const reader = new StreamRecordReader(fake.stream, 1_000_000, (r) => failures.push(r));
  await expect(reader.read()).rejects.toThrow(StreamProtocolViolation);
  expect(failures).toEqual(["protocol-violation"]);
  expect(fake.requested).toEqual([4]); // never trusted the body length enough to read it
});

test("a zero-length record is a protocol violation", async () => {
  const prefix = Buffer.alloc(4);
  prefix.writeUInt32BE(0);
  const fake = createFakeRecvStream([Array.from(prefix)]);
  const failures: StreamReadFailure[] = [];
  const reader = new StreamRecordReader(fake.stream, 1_000_000, (r) => failures.push(r));
  await expect(reader.read()).rejects.toThrow(StreamProtocolViolation);
  expect(failures).toEqual(["protocol-violation"]);
});

test("a native read rejection propagates as-is and is not a protocol violation", async () => {
  const boom = new Error("peer reset this stream");
  const reader = new StreamRecordReader(
    { recv: { readExact: async () => { throw boom; } } },
    1_000_000,
    () => { throw new Error("must not be called for a plain stream end"); },
  );
  await expect(reader.read()).rejects.toBe(boom);
});

// --- StreamRecordWriter: sendRaw -------------------------------------------
// sendRaw shares send()'s queue, overflow bound and per-slice authorized()
// check; the only difference is the wire shape — no [u32 len] prefix.

test("sendRaw writes the bytes verbatim, with no length prefix", async () => {
  const fake = createFakeSendStream();
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 1_000_000, 3);
  const bytes = new Uint8Array([9, 8, 7, 6, 5]);
  const outcome = await writer.sendRaw(bytes);
  expect(outcome).toBe("sent");
  expect(fake.setPriorityCalls).toEqual([3]); // still runs once, before the first write
  expect(fake.writeAllCalls).toEqual([[9, 8, 7, 6, 5]]);
});

test("sendRaw slices a large payload to <=256 KiB pieces, byte-exact and unprefixed", async () => {
  const fake = createFakeSendStream();
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 64 * 1024 * 1024);
  const bytes = new Uint8Array(Math.floor(STREAM_RECORD_SLICE_BYTES * 2.5)).map((_, i) => i % 251);
  const outcome = await writer.sendRaw(bytes);
  expect(outcome).toBe("sent");
  expect(fake.writeAllCalls.length).toBeGreaterThan(1);
  for (const call of fake.writeAllCalls) expect(call.length).toBeLessThanOrEqual(STREAM_RECORD_SLICE_BYTES);
  const rebuilt = Buffer.concat(fake.writeAllCalls.map((c) => Buffer.from(c)));
  expect(rebuilt.length).toBe(bytes.length); // no +4 prefix anywhere in the stream
  expect(Array.from(rebuilt)).toEqual(Array.from(bytes));
});

test("sendRaw resolves 'sent' without writing for a zero-length call", async () => {
  const fake = createFakeSendStream();
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 1_000_000);
  const outcome = await writer.sendRaw(new Uint8Array(0));
  expect(outcome).toBe("sent");
  expect(fake.writeAllCalls).toEqual([]);
  // The record still passes through drain() (so it observes authorization the
  // same as any other), which is what sets priority on the FIRST dequeued
  // record regardless of its length — only `writeInSlices`'s loop is skipped
  // for zero bytes.
  expect(fake.setPriorityCalls).toEqual([0]);
});

test("sendRaw is authorized before send and rechecked per slice, exactly like send()", async () => {
  const fake = createFakeSendStream();
  const failures: StreamWriteFailure[] = [];
  const writer = new StreamRecordWriter(fake.stream, () => false, (r) => failures.push(r), 1_000_000);
  const outcome = await writer.sendRaw(new Uint8Array([1, 2, 3]));
  expect(outcome).toBe("dropped");
  expect(failures).toEqual(["unauthorized"]);
  expect(fake.writeAllCalls).toEqual([]);
});

test("revoking authorization mid-sendRaw stops after the in-flight slice, resetting only the stream", async () => {
  const fake = createFakeSendStream();
  const gate = fake.gateNextWrite();
  const failures: StreamWriteFailure[] = [];
  let allowed = true;
  const writer = new StreamRecordWriter(fake.stream, () => allowed, (r) => failures.push(r), 64 * 1024 * 1024);
  const sent = writer.sendRaw(new Uint8Array(STREAM_RECORD_SLICE_BYTES * 3));
  await flush();
  expect(fake.writeAllCalls.length).toBe(1);
  allowed = false;
  gate.release();
  expect(await sent).toBe("dropped");
  expect(fake.writeAllCalls.length).toBe(1);
  expect(failures).toEqual(["unauthorized"]);
});

test("an overflowing sendRaw resets the stream only, sharing send()'s overflow bound", async () => {
  const fake = createFakeSendStream();
  const failures: StreamWriteFailure[] = [];
  // Room for exactly one 8-byte raw write. As in the analogous send() test:
  // all three calls land synchronously, so A is already dequeued (drain is
  // mid-flight, suspended before its first write) while B still occupies the
  // 10-byte queue and C's arrival overflows it.
  const writer = new StreamRecordWriter(fake.stream, () => true, (r) => failures.push(r), 10, 0, 42n);
  const sentA = writer.sendRaw(new Uint8Array(8));
  const sentB = writer.sendRaw(new Uint8Array(8));
  const sentC = writer.sendRaw(new Uint8Array(8)); // 8 (B) + 8 (C) > 10 -> overflow
  expect(await sentC).toBe("dropped");
  expect(await sentB).toBe("dropped");
  expect(await sentA).toBe("dropped"); // aborted before its write ever reached the wire
  await flush();
  expect(fake.writeAllCalls).toEqual([]);
  expect(fake.resetCalls).toEqual([42n]);
  expect(failures).toEqual(["overflow"]);
});

// --- StreamRawReader -------------------------------------------------------

test("StreamRawReader.read returns the bytes read, clamping maxBytes to [1, STREAM_RAW_READ_BYTES]", async () => {
  const fake = createFakeRawRecvStream([[1, 2, 3]]);
  const reader = new StreamRawReader(fake.stream);
  const result = await reader.read(1_000_000_000);
  expect(Array.from(result!)).toEqual([1, 2, 3]);
  expect(fake.requested).toEqual([STREAM_RAW_READ_BYTES]);
});

test("StreamRawReader.read clamps a request below 1 up to 1", async () => {
  const fake = createFakeRawRecvStream([[7]]);
  const reader = new StreamRawReader(fake.stream);
  await reader.read(0);
  expect(fake.requested).toEqual([1]);
});

test("StreamRawReader.read resolves null at FIN (an empty array), never a zero-length Uint8Array", async () => {
  const fake = createFakeRawRecvStream([], { atEnd: true });
  const reader = new StreamRawReader(fake.stream);
  const result = await reader.read(100);
  expect(result).toBeNull();
});

test("StreamRawReader.read rejects on reset or connection loss, rethrown as-is", async () => {
  const boom = new Error("peer reset this stream");
  const fake = createFakeRawRecvStream([boom]);
  const reader = new StreamRawReader(fake.stream);
  await expect(reader.read(100)).rejects.toBe(boom);
});

test("StreamRawReader.read passes maxBytes through unclamped inside the valid range", async () => {
  const fake = createFakeRawRecvStream([[1, 2, 3, 4, 5]]);
  const reader = new StreamRawReader(fake.stream);
  await reader.read(5);
  expect(fake.requested).toEqual([5]);
});
