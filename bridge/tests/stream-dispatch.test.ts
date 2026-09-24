import { expect, test } from "bun:test";
import {
  decodeStreamRefused,
  encodeStreamOpen,
  STREAM_OPEN_MAX_BYTES,
  type StreamOpen,
  type StreamRefusedCode,
} from "antgrid-wire";
import {
  PeerStreamAcceptor,
  readStreamOpen,
  refuseStream,
  STREAM_OPEN_DEADLINE_MS,
  STREAM_RESET_OPEN_TIMEOUT,
  STREAM_STOP_REFUSED,
  type AcceptedBiStream,
  type PeerStreamAcceptorOptions,
  type StreamDiagnosticType,
  type StreamHandlers,
} from "../src/peer/stream-dispatch";

// --- fakes ----------------------------------------------------------------

/** Models the binding's per-stream `Arc<Mutex<..>>` (stream-records.ts's own
 *  module comment): `reset`, `finish` and `setPriority` queue behind any
 *  `writeAll` in flight, exactly like the real binding serializes every
 *  send-half call on one lock. The fake defines no `stopped`/`receivedReset`,
 *  so a call to either throws — nothing under test may ever reach for them. */
function createFakeMutex() {
  let tail: Promise<unknown> = Promise.resolve();
  return function run<T>(fn: () => Promise<T>): Promise<T> {
    const result = tail.then(fn);
    tail = result.then(() => undefined, () => undefined);
    return result;
  };
}

function lengthPrefix(length: number): number[] {
  const buf = Buffer.alloc(4);
  buf.writeUInt32BE(length, 0);
  return Array.from(buf);
}

function openFrameBytes(open: StreamOpen): { prefix: number[]; body: number[] } {
  const body = Array.from(encodeStreamOpen(open));
  return { prefix: lengthPrefix(body.length), body };
}

/** A `recv.readExact` that serves explicit steps in order, then hangs on any
 *  call past the script — like a real stream whose peer never writes more. */
function scriptedRecv(steps: number[][]) {
  let index = 0;
  const calls: number[] = [];
  return {
    readExact: async (size: number): Promise<number[]> => {
      calls.push(size);
      if (index >= steps.length) return new Promise<number[]>(() => {});
      return steps[index++]!;
    },
    calls,
  };
}

function createFakeStream(recv: { readExact: (size: number) => Promise<number[]> }) {
  const mutex = createFakeMutex();
  const writeAllCalls: number[][] = [];
  const setPriorityCalls: number[] = [];
  const resetCalls: bigint[] = [];
  const stopCalls: bigint[] = [];
  let finishCalls = 0;
  const stream: AcceptedBiStream = {
    send: {
      writeAll: (bytes: number[]) => mutex(async () => { writeAllCalls.push(bytes); }),
      setPriority: (p: number) => mutex(async () => { setPriorityCalls.push(p); }),
      reset: (code: bigint) => mutex(async () => { resetCalls.push(code); }),
      finish: () => mutex(async () => { finishCalls++; }),
    },
    recv: {
      readExact: recv.readExact,
      stop: async (code: bigint) => { stopCalls.push(code); },
    },
  };
  return {
    stream, writeAllCalls, setPriorityCalls, resetCalls, stopCalls,
    finishCalls: () => finishCalls,
    /** Concatenates every queued `writeAll` slice and decodes it as one
     *  length-prefixed `stream:refused` record. */
    writtenRefusal(): { code: StreamRefusedCode; message: string } | null {
      if (!writeAllCalls.length) return null;
      const all = Buffer.concat(writeAllCalls.map((bytes) => Buffer.from(bytes)));
      const length = all.readUInt32BE(0);
      const decoded = decodeStreamRefused(all.subarray(4, 4 + length));
      return decoded ? { code: decoded.code, message: decoded.message } : null;
    },
  };
}

function fakeSchedule() {
  const timers: Array<{ ms: number; fire: () => void; cancelled: boolean }> = [];
  return {
    schedule: (callback: () => void, ms: number) => {
      const timer = { ms, fire: () => { if (!timer.cancelled) callback(); }, cancelled: false };
      timers.push(timer);
      return () => { timer.cancelled = true; };
    },
    timers,
  };
}

/** A connection whose `acceptBi()` serves streams pushed onto it, in order,
 *  and otherwise hangs — like a real connection with nothing more to offer. */
function connectionQueue() {
  const waiters: Array<(stream: AcceptedBiStream) => void> = [];
  const queued: AcceptedBiStream[] = [];
  return {
    connection: {
      acceptBi: (): Promise<AcceptedBiStream> => {
        const next = queued.shift();
        if (next) return Promise.resolve(next);
        return new Promise((resolve) => waiters.push(resolve));
      },
    },
    push(stream: AcceptedBiStream): void {
      const waiter = waiters.shift();
      if (waiter) waiter(stream);
      else queued.push(stream);
    },
  };
}

function createAcceptor(overrides: Partial<PeerStreamAcceptorOptions> & { connection: PeerStreamAcceptorOptions["connection"] }) {
  const diagnostics: Array<{ type: StreamDiagnosticType; detail: unknown }> = [];
  const unauthorizedCalls: number[] = [];
  const acceptor = new PeerStreamAcceptor({
    peerId: "peer-1",
    isCurrent: () => true,
    authorized: () => true,
    established: () => true,
    onUnauthorized: () => { unauthorizedCalls.push(1); },
    handlers: {},
    diagnostic: (type, detail) => diagnostics.push({ type, detail }),
    ...overrides,
  });
  return { acceptor, diagnostics, unauthorizedCalls };
}

async function until(condition: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition not met in time");
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

// --- readStreamOpen ---------------------------------------------------------

test("readStreamOpen parses a well-formed frame", async () => {
  const open: StreamOpen = { kind: "project", projectId: "proj-1" };
  const { prefix, body } = openFrameBytes(open);
  const result = await readStreamOpen(scriptedRecv([prefix, body]));
  expect(result).toEqual({ ok: true, open });
});

test("readStreamOpen: an oversized length prefix is 'oversize' without reading the body", async () => {
  const recv = scriptedRecv([lengthPrefix(STREAM_OPEN_MAX_BYTES + 1)]);
  const result = await readStreamOpen(recv);
  expect(result).toEqual({ ok: false, reason: "oversize" });
  expect(recv.calls).toEqual([4]);
});

test("readStreamOpen: a zero-length frame is 'invalid'", async () => {
  const result = await readStreamOpen(scriptedRecv([lengthPrefix(0)]));
  expect(result).toEqual({ ok: false, reason: "invalid" });
});

test("readStreamOpen: an unparseable body is 'invalid'", async () => {
  const garbage = [0xff, 0xfe, 0xfd];
  const result = await readStreamOpen(scriptedRecv([lengthPrefix(garbage.length), garbage]));
  expect(result).toEqual({ ok: false, reason: "invalid" });
});

// --- PeerStreamAcceptor: admission order ------------------------------------

test("an unparseable open frame is refused INVALID in-band, then FIN, and the connection lives", async () => {
  const queue = connectionQueue();
  const { acceptor } = createAcceptor({ connection: queue.connection });
  const garbage = [0xff, 0xfe, 0xfd];
  const fake = createFakeStream(scriptedRecv([lengthPrefix(garbage.length), garbage]));
  acceptor.start();
  queue.push(fake.stream);
  await until(() => fake.writeAllCalls.length > 0);
  expect(fake.writtenRefusal()?.code).toBe("INVALID");
  await until(() => fake.finishCalls() > 0); // FIN
  acceptor.stop();
});

test("an oversized open-frame length prefix is refused INVALID without reading the body", async () => {
  const queue = connectionQueue();
  const { acceptor } = createAcceptor({ connection: queue.connection });
  const recv = scriptedRecv([lengthPrefix(STREAM_OPEN_MAX_BYTES + 1)]);
  const fake = createFakeStream(recv);
  acceptor.start();
  queue.push(fake.stream);
  await until(() => fake.writeAllCalls.length > 0);
  expect(fake.writtenRefusal()?.code).toBe("INVALID");
  expect(recv.calls).toEqual([4]); // the body was never read
  acceptor.stop();
});

test("a zero-length open frame is refused INVALID", async () => {
  const queue = connectionQueue();
  const { acceptor } = createAcceptor({ connection: queue.connection });
  const fake = createFakeStream(scriptedRecv([lengthPrefix(0)]));
  acceptor.start();
  queue.push(fake.stream);
  await until(() => fake.writeAllCalls.length > 0);
  expect(fake.writtenRefusal()?.code).toBe("INVALID");
  acceptor.stop();
});

test("a later session-kind open is refused INVALID", async () => {
  const queue = connectionQueue();
  const { acceptor } = createAcceptor({ connection: queue.connection, established: () => true });
  const { prefix, body } = openFrameBytes({ kind: "session" });
  const fake = createFakeStream(scriptedRecv([prefix, body]));
  acceptor.start();
  queue.push(fake.stream);
  await until(() => fake.writeAllCalls.length > 0);
  expect(fake.writtenRefusal()?.code).toBe("INVALID");
  acceptor.stop();
});

test("every non-session kind is refused NOT_ALLOWED once established (A1 has no handlers)", async () => {
  const kinds: StreamOpen[] = [
    { kind: "project", projectId: "p1" },
    { kind: "terminal", projectId: "p1", requestId: "r1" },
    { kind: "tunnel-http", projectId: "p1", requestId: "r1" },
    { kind: "tunnel-ws", projectId: "p1", wsId: "w1" },
  ];
  for (const open of kinds) {
    const queue = connectionQueue();
    const { acceptor } = createAcceptor({ connection: queue.connection, established: () => true, handlers: {} });
    const { prefix, body } = openFrameBytes(open);
    const fake = createFakeStream(scriptedRecv([prefix, body]));
    acceptor.start();
    queue.push(fake.stream);
    await until(() => fake.writeAllCalls.length > 0);
    expect(fake.writtenRefusal()?.code).toBe("NOT_ALLOWED");
    acceptor.stop();
  }
});

test("a non-session open before the session is established is refused NOT_READY", async () => {
  const queue = connectionQueue();
  const { acceptor } = createAcceptor({ connection: queue.connection, established: () => false });
  const { prefix, body } = openFrameBytes({ kind: "project", projectId: "p1" });
  const fake = createFakeStream(scriptedRecv([prefix, body]));
  acceptor.start();
  queue.push(fake.stream);
  await until(() => fake.writeAllCalls.length > 0);
  expect(fake.writtenRefusal()?.code).toBe("NOT_READY");
  acceptor.stop();
});

test("an open over the pending-open cap is refused CAP_EXCEEDED without being read, and the connection lives", async () => {
  const queue = connectionQueue();
  const { acceptor } = createAcceptor({ connection: queue.connection, maxPendingOpens: 1 });
  const hanging = createFakeStream(scriptedRecv([])); // never sends its open frame
  const overCapRecv = scriptedRecv([lengthPrefix(0)]);
  const overCap = createFakeStream(overCapRecv);
  acceptor.start();
  queue.push(hanging.stream);
  await until(() => acceptor.pendingOpens === 1);
  queue.push(overCap.stream);
  await until(() => overCap.writeAllCalls.length > 0);
  expect(overCap.writtenRefusal()?.code).toBe("CAP_EXCEEDED");
  expect(overCapRecv.calls).toEqual([]); // never read
  await until(() => overCap.stopCalls.length > 0); // the refusal still FINs the recv half
  expect(overCap.stopCalls).toEqual([STREAM_STOP_REFUSED]);
  acceptor.stop();
});

test("a pending slot is released when its open frame arrives and when its deadline fires", async () => {
  const sched = fakeSchedule();
  const queue = connectionQueue();
  const { acceptor } = createAcceptor({ connection: queue.connection, maxPendingOpens: 1, schedule: sched.schedule });

  const first = createFakeStream(scriptedRecv([lengthPrefix(0)])); // settles (invalid, but settles)
  acceptor.start();
  queue.push(first.stream);
  await until(() => first.writeAllCalls.length > 0);
  await until(() => acceptor.pendingOpens === 0);

  const second = createFakeStream(scriptedRecv([])); // hangs; released only by its deadline
  queue.push(second.stream);
  await until(() => acceptor.pendingOpens === 1);
  const deadlineTimer = sched.timers.find((t) => t.ms === STREAM_OPEN_DEADLINE_MS && !t.cancelled)!;
  deadlineTimer.fire();
  await until(() => acceptor.pendingOpens === 0);

  const third = createFakeStream(scriptedRecv([lengthPrefix(0)]));
  queue.push(third.stream);
  await until(() => third.writeAllCalls.length > 0);
  expect(third.writtenRefusal()?.code).toBe("INVALID"); // admitted, not CAP_EXCEEDED
  acceptor.stop();
});

test("an open frame missing its 5s deadline resets the send half and never calls recv.stop", async () => {
  const sched = fakeSchedule();
  const queue = connectionQueue();
  const { acceptor, diagnostics } = createAcceptor({ connection: queue.connection, schedule: sched.schedule });
  const fake = createFakeStream(scriptedRecv([])); // never sends its open frame
  acceptor.start();
  queue.push(fake.stream);
  await until(() => sched.timers.some((t) => t.ms === STREAM_OPEN_DEADLINE_MS));
  sched.timers.find((t) => t.ms === STREAM_OPEN_DEADLINE_MS)!.fire();
  await until(() => fake.resetCalls.length > 0);
  expect(fake.resetCalls).toEqual([STREAM_RESET_OPEN_TIMEOUT]);
  expect(fake.stopCalls).toEqual([]); // the read still holds the recv mutex
  expect(fake.writeAllCalls).toEqual([]);
  expect(diagnostics.some((d) => d.type === "peer:stream-open-timeout")).toBe(true);
  acceptor.stop();
});

test("stream N+1 is admitted while stream N has not sent its open frame; N+1 is refused CAP_EXCEEDED before N's deadline", async () => {
  const sched = fakeSchedule();
  const queue = connectionQueue();
  const { acceptor } = createAcceptor({ connection: queue.connection, maxPendingOpens: 1, schedule: sched.schedule });
  const streamTwo = createFakeStream(scriptedRecv([])); // hangs; never sends its open frame
  acceptor.start();
  queue.push(streamTwo.stream);
  await until(() => acceptor.pendingOpens === 1);

  const streamThree = createFakeStream(scriptedRecv([lengthPrefix(0)]));
  queue.push(streamThree.stream);
  await until(() => streamThree.writeAllCalls.length > 0);
  expect(streamThree.writtenRefusal()?.code).toBe("CAP_EXCEEDED");
  // Refused without ever racing its own deadline, and stream 2's is untouched.
  expect(sched.timers.filter((t) => t.ms === STREAM_OPEN_DEADLINE_MS)).toHaveLength(1);
  expect(streamTwo.resetCalls).toEqual([]);
  acceptor.stop();
});

test("a stream whose peer is no longer authorized writes nothing and retires the connection as unauthorized", async () => {
  const queue = connectionQueue();
  const { acceptor, unauthorizedCalls } = createAcceptor({ connection: queue.connection, authorized: () => false });
  const { prefix, body } = openFrameBytes({ kind: "session" });
  const fake = createFakeStream(scriptedRecv([prefix, body]));
  acceptor.start();
  queue.push(fake.stream);
  await until(() => unauthorizedCalls.length > 0);
  expect(fake.writeAllCalls).toEqual([]);
  acceptor.stop();
});

test("a refusal stops the receive half without awaiting it", async () => {
  const fake = createFakeStream(scriptedRecv([]));
  fake.stream.recv.stop = () => new Promise<void>(() => {}); // never resolves
  let unauthorizedCalled = false;
  refuseStream(fake.stream, { code: "NOT_ALLOWED", message: "x" }, () => true, () => { unauthorizedCalled = true; });
  await until(() => fake.writeAllCalls.length > 0);
  await until(() => fake.finishCalls() > 0);
  // Reaching this line at all — rather than the test timing out — is the
  // assertion: refuseStream never awaits the hung recv.stop() promise.
  expect(unauthorizedCalled).toBe(false);
});

test("a registered handler receives the parsed open and owns the stream; a returned refusal is written in-band; a throwing handler is refused NOT_ALLOWED", async () => {
  // Owns the stream: no write.
  {
    const queue = connectionQueue();
    let received: StreamOpen | undefined;
    const handlers: StreamHandlers = { project: (admission) => { received = admission.open; return undefined; } };
    const { acceptor } = createAcceptor({ connection: queue.connection, established: () => true, handlers });
    const open: StreamOpen = { kind: "project", projectId: "p1" };
    const { prefix, body } = openFrameBytes(open);
    const fake = createFakeStream(scriptedRecv([prefix, body]));
    acceptor.start();
    queue.push(fake.stream);
    await until(() => received !== undefined);
    expect(received).toEqual(open);
    expect(fake.writeAllCalls).toEqual([]);
    acceptor.stop();
  }
  // Returns a refusal: written in-band by the acceptor, not the handler.
  {
    const queue = connectionQueue();
    const handlers: StreamHandlers = { terminal: () => ({ code: "NOT_ALLOWED", message: "no handler yet" }) };
    const { acceptor } = createAcceptor({ connection: queue.connection, established: () => true, handlers });
    const { prefix, body } = openFrameBytes({ kind: "terminal", projectId: "p1", requestId: "r1" });
    const fake = createFakeStream(scriptedRecv([prefix, body]));
    acceptor.start();
    queue.push(fake.stream);
    await until(() => fake.writeAllCalls.length > 0);
    expect(fake.writtenRefusal()?.code).toBe("NOT_ALLOWED");
    acceptor.stop();
  }
  // Throws: refused NOT_ALLOWED, same as no handler at all.
  {
    const queue = connectionQueue();
    const handlers: StreamHandlers = { "tunnel-http": () => { throw new Error("boom"); } };
    const { acceptor } = createAcceptor({ connection: queue.connection, established: () => true, handlers });
    const { prefix, body } = openFrameBytes({ kind: "tunnel-http", projectId: "p1", requestId: "r1" });
    const fake = createFakeStream(scriptedRecv([prefix, body]));
    acceptor.start();
    queue.push(fake.stream);
    await until(() => fake.writeAllCalls.length > 0);
    expect(fake.writtenRefusal()?.code).toBe("NOT_ALLOWED");
    acceptor.stop();
  }
});

test("after stop(), an accepted stream is dropped without a write", async () => {
  const queue = connectionQueue();
  const { acceptor } = createAcceptor({ connection: queue.connection });
  const { prefix, body } = openFrameBytes({ kind: "project", projectId: "p1" });
  const recv = scriptedRecv([prefix, body]);
  const fake = createFakeStream(recv);
  queue.push(fake.stream); // already queued, so `acceptBi()` resolves synchronously
  acceptor.start();
  acceptor.stop(); // same tick: `admit()`'s own stopped check must still win
  await new Promise((resolve) => setTimeout(resolve, 20));
  expect(fake.writeAllCalls).toEqual([]);
  expect(recv.calls).toEqual([]);
});

/** A `recv.readExact` whose first call waits until `release()` hands it the
 *  whole scripted open frame — a peer that sends its open frame late. */
function gatedRecv(steps: number[][]) {
  let open!: () => void;
  const gate = new Promise<void>((resolve) => { open = resolve; });
  let index = 0;
  return {
    readExact: async (_size: number): Promise<number[]> => {
      await gate;
      if (index >= steps.length) return new Promise<number[]>(() => {});
      return steps[index++]!;
    },
    release: () => open(),
  };
}

test("an open frame that arrives after its deadline is never admitted, and its receive half is stopped once the read settles", async () => {
  const sched = fakeSchedule();
  const queue = connectionQueue();
  let handled = false;
  const handlers: StreamHandlers = { project: () => { handled = true; return undefined; } };
  const { acceptor } = createAcceptor({ connection: queue.connection, schedule: sched.schedule, handlers });
  const { prefix, body } = openFrameBytes({ kind: "project", projectId: "p1" });
  const recv = gatedRecv([prefix, body]);
  const fake = createFakeStream(recv);
  acceptor.start();
  queue.push(fake.stream);
  await until(() => sched.timers.some((t) => t.ms === STREAM_OPEN_DEADLINE_MS));
  sched.timers.find((t) => t.ms === STREAM_OPEN_DEADLINE_MS)!.fire();
  await until(() => fake.resetCalls.length > 0);
  expect(fake.stopCalls).toEqual([]); // the read still holds the recv mutex
  recv.release();
  await until(() => fake.stopCalls.length > 0);
  expect(fake.stopCalls).toEqual([STREAM_STOP_REFUSED]);
  expect(fake.writeAllCalls).toEqual([]);
  expect(handled).toBe(false);
  acceptor.stop();
});

test("with the default cap, stream N+1 is read and dispatched while stream N has not sent its open frame", async () => {
  const sched = fakeSchedule();
  const queue = connectionQueue();
  const { acceptor } = createAcceptor({ connection: queue.connection, schedule: sched.schedule });
  const hanging = createFakeStream(scriptedRecv([]));
  acceptor.start();
  queue.push(hanging.stream);
  await until(() => acceptor.pendingOpens === 1);
  const { prefix, body } = openFrameBytes({ kind: "project", projectId: "p1" });
  const next = createFakeStream(scriptedRecv([prefix, body]));
  queue.push(next.stream);
  await until(() => next.writeAllCalls.length > 0);
  expect(next.writtenRefusal()?.code).toBe("NOT_ALLOWED");
  expect(acceptor.pendingOpens).toBe(1);
  expect(hanging.resetCalls).toEqual([]);
  acceptor.stop();
});

test("a well-formed open from a peer that is no longer authorized never reaches its registered handler", async () => {
  const queue = connectionQueue();
  let handled = false;
  const handlers: StreamHandlers = { project: () => { handled = true; return undefined; } };
  const { acceptor, unauthorizedCalls } = createAcceptor({
    connection: queue.connection, authorized: () => false, established: () => true, handlers,
  });
  const { prefix, body } = openFrameBytes({ kind: "project", projectId: "p1" });
  const fake = createFakeStream(scriptedRecv([prefix, body]));
  acceptor.start();
  queue.push(fake.stream);
  await until(() => unauthorizedCalls.length > 0);
  await new Promise((resolve) => setTimeout(resolve, 10));
  expect(handled).toBe(false);
  expect(fake.writeAllCalls).toEqual([]);
  acceptor.stop();
});

test("an open frame that settles after stop() or after the connection is superseded is dropped without a write", async () => {
  for (const retire of ["stop", "superseded"] as const) {
    const queue = connectionQueue();
    let current = true;
    let handled = false;
    const handlers: StreamHandlers = { project: () => { handled = true; return undefined; } };
    const { acceptor } = createAcceptor({ connection: queue.connection, isCurrent: () => current, handlers });
    const { prefix, body } = openFrameBytes({ kind: "project", projectId: "p1" });
    const recv = gatedRecv([prefix, body]);
    const fake = createFakeStream(recv);
    acceptor.start();
    queue.push(fake.stream);
    await until(() => acceptor.pendingOpens === 1);
    if (retire === "stop") acceptor.stop();
    else current = false;
    recv.release();
    await until(() => acceptor.pendingOpens === 0);
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(handled).toBe(false);
    expect(fake.writeAllCalls).toEqual([]);
    acceptor.stop();
  }
});
