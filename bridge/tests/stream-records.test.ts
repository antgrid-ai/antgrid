import { expect, test } from "bun:test";
import {
  STREAM_RECORD_SLICE_BYTES,
  StreamProtocolViolation,
  StreamRecordReader,
  StreamRecordWriter,
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

// --- StreamRecordWriter -----------------------------------------------

test("writes a single-slice record once, after setting priority", async () => {
  const fake = createFakeSendStream();
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 1_000_000, 7);
  const frame = new Uint8Array([9, 9, 9, 9]);
  const outcome = await writer.send(frame);
  expect(outcome).toBe("sent");
  expect(fake.setPriorityCalls).toEqual([7]);
  expect(fake.order).toEqual(["setPriority", "writeAll"]);
  const written = Buffer.from(fake.writeAllCalls[0]!);
  expect(written.readUInt32BE(0)).toBe(frame.length);
  expect(Array.from(written.subarray(4))).toEqual(Array.from(frame));
});

test("setPriority runs once even across several sends", async () => {
  const fake = createFakeSendStream();
  const writer = new StreamRecordWriter(fake.stream, () => true, () => {}, 1_000_000);
  await writer.send(new Uint8Array([1]));
  await writer.send(new Uint8Array([2]));
  expect(fake.setPriorityCalls.length).toBe(1);
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
