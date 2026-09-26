// The upload stream's wire and admission order: docs/protocol/peer-session.md §1e.
// Drives UploadStreamRegistry directly with fakes — no PeerStreamAcceptor, no
// real FileUploadManager — mirroring tunnel-streams.test.ts's pattern for the
// tunnel registry: this file proves the registry's own admission order and raw
// read loop; FileUploadManager's begin/write/end/cancel units (including real
// disk behaviour) are file-upload.test.ts's job.
import { describe, test, expect } from "bun:test";
import {
  UploadStreamRegistry,
  STREAM_RESET_UPLOAD,
  STREAM_STOP_UPLOAD,
  type UploadStreamRegistryOptions,
} from "../src/peer/upload-streams";
import { STREAM_MAX_UPLOAD_STREAMS_PER_PEER, type UploadStreamOpen } from "antgrid-wire";
import { STREAM_RAW_READ_BYTES, STREAM_RECORD_SLICE_BYTES } from "../src/peer/stream-records";
import type { UploadProjectBinding } from "../src/project-streams";
import type { StreamRefusal } from "../src/peer/stream-dispatch";
import type {
  FileUploadManager,
  StreamUpload,
  StreamUploadWrite,
  UploadAdmission,
  UploadResultFields,
  UploadStreamServer,
} from "../src/file-upload";
import { setLogLevel } from "../src/logger";

setLogLevel("error");

/** Serializes calls exactly like the real binding's `Arc<Mutex<..>>`, mirroring
 *  stream-records.test.ts's FakeMutex: a call queued behind another does not
 *  start running its body until the prior one's promise settles. */
class FakeMutex {
  private tail: Promise<unknown> = Promise.resolve();
  run<T>(fn: () => Promise<T>): Promise<T> {
    const result = this.tail.then(fn);
    this.tail = result.then(() => undefined, () => undefined);
    return result;
  }
}

function flush(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

async function until(condition: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition not met in time");
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

/** One fake upload stream: a length-prefixed JSON send half (result/refusal
 *  records) and a RAW recv half fed by a FIFO byte queue — `pushBytes` queues
 *  app-sent body bytes, `endFin`/`endReset` end the queue the way a native
 *  `read(sizeLimit)` resolves `[]` at FIN or rejects on reset. */
function createFakeUploadStream() {
  const sendMutex = new FakeMutex();
  const recvMutex = new FakeMutex();
  const writeAllCalls: number[][] = [];
  const setPriorityCalls: number[] = [];
  const resetCalls: bigint[] = [];
  const stopCalls: bigint[] = [];
  const readCalls: number[] = [];
  let finishCalls = 0;
  let pendingGate: Promise<void> | null = null;

  const send = {
    writeAll: (bytes: number[]) =>
      sendMutex.run(async () => {
        writeAllCalls.push(bytes);
        const gate = pendingGate;
        pendingGate = null;
        if (gate) await gate;
      }),
    setPriority: (p: number) => sendMutex.run(async () => { setPriorityCalls.push(p); }),
    reset: (code: bigint) => sendMutex.run(async () => { resetCalls.push(code); }),
    finish: () => sendMutex.run(async () => { finishCalls++; }),
  };

  let buffer: number[] = [];
  let ended: "fin" | Error | null = null;
  const waiters: Array<{ sizeLimit: number; resolve: (v: number[]) => void; reject: (e: unknown) => void }> = [];
  function pump(): void {
    while (waiters.length) {
      const w = waiters[0]!;
      if (buffer.length > 0) {
        const n = Math.min(w.sizeLimit, buffer.length);
        const chunk = buffer.splice(0, n);
        waiters.shift();
        w.resolve(chunk);
      } else if (ended === "fin") {
        waiters.shift();
        w.resolve([]);
      } else if (ended instanceof Error) {
        waiters.shift();
        w.reject(ended);
      } else break;
    }
  }
  const recv = {
    readExact: async (): Promise<number[]> => {
      throw new Error("upload stream body is read raw; readExact must never be called on it");
    },
    read: (sizeLimit: number) => {
      readCalls.push(sizeLimit);
      return recvMutex.run(() => new Promise<number[]>((resolve, reject) => {
        waiters.push({ sizeLimit, resolve, reject });
        pump();
      }));
    },
    stop: (code: bigint) => recvMutex.run(async () => { stopCalls.push(code); }),
  };

  return {
    stream: { send, recv },
    writeAllCalls, setPriorityCalls, resetCalls, stopCalls, readCalls,
    finishCalls: () => finishCalls,
    pushBytes(bytes: number[] | Uint8Array): void { buffer.push(...Array.from(bytes)); pump(); },
    endFin(): void { ended = "fin"; pump(); },
    endReset(err: Error = new Error("peer reset this stream")): void { ended = err; pump(); },
    /** Blocks the NEXT `writeAll` (through the shared send lock). One-shot. */
    gateNextWrite(): { release: () => void } {
      const { promise, resolve } = Promise.withResolvers<void>();
      pendingGate = promise;
      return { release: () => resolve() };
    },
    /** Decodes the one length-prefixed JSON record this stream has written, if
     *  any — every test result/refusal here fits one `writeAll` slice. */
    writtenRecord(): { type: string; [k: string]: unknown } | undefined {
      if (!writeAllCalls.length) return undefined;
      const all = Buffer.concat(writeAllCalls.map((b) => Buffer.from(b)));
      const len = all.readUInt32BE(0);
      return JSON.parse(all.subarray(4, 4 + len).toString("utf8"));
    },
  };
}

// --- fake FileUploadManager / StreamUpload ---------------------------------

interface FakeUploadHandle {
  readonly upload: StreamUpload;
  written: number[];
  ended: boolean;
  cancelled: boolean;
  resultReported: UploadResultFields | undefined;
  /** Queues the outcome the NEXT `write()` call returns; default "ok". */
  queueWrite(outcome: StreamUploadWrite): void;
  /** Fires `onResult` out of band (e.g. an inactivity TIMEOUT), as the real
   *  manager's own timer does with no `write()`/`end()` call from the caller. */
  forceResult(result: UploadResultFields): void;
}

function createUploadHandle(
  requestId: string,
  declaredSize: number,
  onResult: (result: UploadResultFields) => void,
): FakeUploadHandle {
  const written: number[] = [];
  const writeQueue: StreamUploadWrite[] = [];
  let ended = false;
  let cancelled = false;
  let resultReported: UploadResultFields | undefined;
  const report = (result: UploadResultFields) => {
    if (resultReported) return; // onResult is called at most once per upload
    resultReported = result;
    onResult(result);
  };
  const upload: StreamUpload = {
    uploadId: `fake-${requestId}`,
    write: (bytes) => {
      const outcome = writeQueue.shift() ?? "ok";
      if (outcome === "ok") written.push(...Array.from(bytes));
      else if (outcome === "failed") {
        report({ ok: false, error: "WRITE_FAILED", message: "Could not write to staging file" });
      }
      return outcome;
    },
    end: () => {
      ended = true;
      if (written.length === declaredSize) {
        report({ ok: true, path: `/fake/${requestId}`, relPath: requestId, mimeType: undefined });
      } else {
        report({ ok: false, error: "INCOMPLETE", message: `Declared ${declaredSize} bytes, received ${written.length}` });
      }
    },
    cancel: () => { cancelled = true; },
  };
  return {
    upload,
    get written() { return written; },
    get ended() { return ended; },
    get cancelled() { return cancelled; },
    get resultReported() { return resultReported; },
    queueWrite: (o) => writeQueue.push(o),
    forceResult: (r) => report(r),
  };
}

function fakeManager() {
  const beginCalls: Array<{ requestId: string; fileName: string; size: number }> = [];
  const handles = new Map<string, FakeUploadHandle>();
  let nextBeginRefusal: UploadResultFields | null = null;
  const manager: Pick<FileUploadManager, "begin"> = {
    begin: (start, onResult) => {
      beginCalls.push({ ...start });
      if (nextBeginRefusal) {
        const result = nextBeginRefusal;
        nextBeginRefusal = null;
        return { ok: false, result };
      }
      const handle = createUploadHandle(start.requestId, start.size, onResult);
      handles.set(start.requestId, handle);
      return { ok: true, upload: handle.upload };
    },
  };
  return {
    manager: manager as FileUploadManager,
    beginCalls,
    handles,
    setNextBeginRefusal: (result: UploadResultFields) => { nextBeginRefusal = result; },
  };
}

function fakeUploadServer(manager: FileUploadManager) {
  const admitCalls: Array<{ peerId: string; checkoutId: string }> = [];
  let refusal: { code: "UPDATE_REQUIRED" | "NOT_ALLOWED"; message: string } | null = null;
  const admit = async (peerId: string, checkoutId: string): Promise<UploadAdmission> => {
    admitCalls.push({ peerId, checkoutId });
    if (refusal) return { ok: false, refusal };
    return { ok: true, manager };
  };
  return { admit, admitCalls, setRefusal: (r: typeof refusal) => { refusal = r; } };
}

function fakeUploadBinding(server: ReturnType<typeof fakeUploadServer>) {
  let refuse: ((peerId: string) => StreamRefusal | null) | null = null;
  let mayDeliver = true;
  let available = true;
  let hasOpen: ((peerId: string) => boolean) | null = null;
  const binding: UploadProjectBinding = {
    hasOpenStream: (peerId) => (hasOpen ? hasOpen(peerId) : true),
    refusalFor: (peerId) => (refuse ? refuse(peerId) : null),
    mayDeliverTo: () => mayDeliver,
    uploads: (): UploadStreamServer | null => (available ? { admit: server.admit } : null),
  };
  return {
    binding,
    setRefusal: (fn: typeof refuse) => { refuse = fn; },
    setMayDeliver: (v: boolean) => { mayDeliver = v; },
    setAvailable: (v: boolean) => { available = v; },
    setHasOpenStream: (fn: typeof hasOpen) => { hasOpen = fn; },
  };
}

function makeRegistry(overrides: Partial<UploadStreamRegistryOptions> = {}) {
  const cataloged = new Set<string>();
  const bindings = new Map<string, UploadProjectBinding>();
  const retiredPeers: Array<{ peerId: string; reason: "unauthorized" }> = [];
  const diagnostics: Array<{ type: string; detail: Record<string, unknown>; stream?: { kind: string; id: string } }> = [];
  const opts: UploadStreamRegistryOptions = {
    projectCataloged: (id) => cataloged.has(id),
    uploadBinding: (id) => bindings.get(id) ?? null,
    retirePeer: (peerId, reason) => retiredPeers.push({ peerId, reason }),
    diagnostic: (type, detail, stream) => diagnostics.push({ type, detail, stream }),
    ...overrides,
  };
  const registry = new UploadStreamRegistry(opts);
  return { registry, cataloged, bindings, retiredPeers, diagnostics };
}

const PROJECT = "proj1";
const PEER = "peer1";

function admitUpload(
  registry: UploadStreamRegistry,
  opts: {
    peerId?: string; projectId?: string; requestId?: string; fileName?: string;
    size?: number; checkoutId?: string; mimeType?: string; authorized?: () => boolean;
  } = {},
) {
  const fake = createFakeUploadStream();
  const requestId = opts.requestId ?? crypto.randomUUID();
  const open: UploadStreamOpen = {
    kind: "upload",
    projectId: opts.projectId ?? PROJECT,
    requestId,
    fileName: opts.fileName ?? "a.txt",
    size: opts.size ?? 5,
    ...(opts.checkoutId ? { checkoutId: opts.checkoutId } : {}),
    ...(opts.mimeType ? { mimeType: opts.mimeType } : {}),
  };
  const admission = { peerId: opts.peerId ?? PEER, open, stream: fake.stream, authorized: opts.authorized ?? (() => true) };
  // Steps 1-8 are synchronous, exactly like the tunnel gate() (§2.3): the
  // handler never returns a Promise.
  const result = registry.handler(admission) as StreamRefusal | undefined;
  return { fake, requestId, open, admission, result };
}

/** Sets up one project fully wired for a successful admission through step 9. */
function wireProject(rig: ReturnType<typeof makeRegistry>, projectId = PROJECT) {
  rig.cataloged.add(projectId);
  const mgr = fakeManager();
  const server = fakeUploadServer(mgr.manager);
  const proj = fakeUploadBinding(server);
  rig.bindings.set(projectId, proj.binding);
  return { mgr, server, proj };
}

// --- admission order (§2.3) -------------------------------------------------

describe("admission order", () => {
  test("no binding at all -> NOT_READY", () => {
    const rig = makeRegistry();
    rig.cataloged.add(PROJECT);
    const { result } = admitUpload(rig.registry);
    expect(result).toEqual({ code: "NOT_READY", message: "project is not attached" });
  });

  test("unsafe project id -> NOT_ALLOWED, before catalog or binding are even consulted", () => {
    const rig = makeRegistry();
    const { result } = admitUpload(rig.registry, { projectId: "../etc/passwd" });
    expect(result).toEqual({ code: "NOT_ALLOWED", message: "unsafe project id" });
  });

  test("uncatalogued project id -> NOT_ALLOWED (fail closed)", () => {
    const rig = makeRegistry();
    const { result } = admitUpload(rig.registry, { projectId: "unknown-proj" });
    expect(result).toEqual({ code: "NOT_ALLOWED", message: "project not recognized" });
  });

  test("no projectCataloged option at all -> every open refused NOT_ALLOWED (fail closed)", () => {
    const rig = makeRegistry({ projectCataloged: undefined });
    const { result } = admitUpload(rig.registry, { projectId: PROJECT });
    expect(result).toEqual({ code: "NOT_ALLOWED", message: "project not recognized" });
  });

  test("no open project stream for the peer -> NOT_ALLOWED", () => {
    const rig = makeRegistry();
    const { proj } = wireProject(rig);
    proj.setHasOpenStream(() => false);
    const { result } = admitUpload(rig.registry);
    expect(result).toEqual({ code: "NOT_ALLOWED", message: "open the project stream first" });
  });

  test("refusalFor UPDATE_REQUIRED passes through as-is", () => {
    const rig = makeRegistry();
    const { proj } = wireProject(rig);
    proj.setRefusal(() => ({ code: "UPDATE_REQUIRED", message: "please update" }));
    const { result } = admitUpload(rig.registry);
    expect(result).toEqual({ code: "UPDATE_REQUIRED", message: "please update" });
  });

  test("a duplicate (peerId, requestId) -> INVALID", async () => {
    const rig = makeRegistry();
    wireProject(rig);
    const requestId = "dup-1";
    const first = admitUpload(rig.registry, { requestId });
    expect(first.result).toBeUndefined(); // owns the stream
    const second = admitUpload(rig.registry, { requestId });
    expect(second.result).toEqual({ code: "INVALID", message: "duplicate id" });
  });

  test("uploads() null -> NOT_ALLOWED", () => {
    const rig = makeRegistry();
    const { proj } = wireProject(rig);
    proj.setAvailable(false);
    const { result } = admitUpload(rig.registry);
    expect(result).toEqual({ code: "NOT_ALLOWED", message: "uploads not available" });
  });

  test("server admit refusal is written in-band (async, after synchronous admission passed)", async () => {
    const rig = makeRegistry();
    const { server } = wireProject(rig);
    server.setRefusal({ code: "NOT_ALLOWED", message: "checkout is being deleted" });
    const { fake, result } = admitUpload(rig.registry);
    expect(result).toBeUndefined(); // synchronous steps all passed; the refusal is in-band
    await until(() => fake.writtenRecord() !== undefined);
    expect(fake.writtenRecord()).toEqual({ type: "stream:refused", code: "NOT_ALLOWED", message: "checkout is being deleted" });
    await until(() => fake.finishCalls() > 0);
  });

  test("cap: a 5th concurrent open for the same peer -> CAP_EXCEEDED, and completing one frees a slot", async () => {
    const rig = makeRegistry();
    wireProject(rig);
    const opens = [];
    for (let i = 0; i < STREAM_MAX_UPLOAD_STREAMS_PER_PEER; i++) {
      const a = admitUpload(rig.registry, { requestId: `r${i}` });
      expect(a.result).toBeUndefined();
      opens.push(a);
    }
    await until(() => rig.registry.streamCount(PEER) === STREAM_MAX_UPLOAD_STREAMS_PER_PEER);
    const overCap = admitUpload(rig.registry, { requestId: "over-cap" });
    expect(overCap.result).toEqual({ code: "CAP_EXCEEDED", message: "too many uploads" });

    // Complete one of the four already-open uploads to free its slot (an
    // INCOMPLETE end still unbinds and releases the cap, exactly like an ok one).
    opens[0]!.fake.endFin();
    await until(() => rig.registry.streamCount(PEER) === STREAM_MAX_UPLOAD_STREAMS_PER_PEER - 1);

    const afterFree = admitUpload(rig.registry, { requestId: "after-free" });
    expect(afterFree.result).toBeUndefined();
  });

  test("a stream open never opens or promotes a core: uploadBinding is a pure lookup, called with the open's projectId only", () => {
    const lookups: string[] = [];
    const rig = makeRegistry({ uploadBinding: (id) => { lookups.push(id); return null; } });
    rig.cataloged.add("proj-x");
    const { result } = admitUpload(rig.registry, { projectId: "proj-x" });
    expect(result).toEqual({ code: "NOT_READY", message: "project is not attached" });
    expect(lookups).toEqual(["proj-x"]);
  });
});

// --- unauthorized at open, and mid-stream -----------------------------------

test("a well-formed open from a peer no longer authorized still reaches server.admit (step 9), but never manager.begin (step 11)", async () => {
  // The admission order (contract §2.3) checks `authorized()` at step 10,
  // AFTER `server.admit` at step 9 — admit is a pure checkout/switch lookup
  // with no opinion on this peer's live authorization, so it still runs.
  const rig = makeRegistry();
  const { server, mgr } = wireProject(rig);
  const { fake } = admitUpload(rig.registry, { authorized: () => false });
  await flush();
  expect(server.admitCalls).toEqual([{ peerId: PEER, checkoutId: "main" }]);
  expect(mgr.beginCalls).toEqual([]);
  expect(rig.retiredPeers).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
  expect(fake.writeAllCalls).toEqual([]);
});

test("authorized() flips false after the first raw read: retirePeer, and no further bytes reach the manager", async () => {
  const rig = makeRegistry();
  const { mgr } = wireProject(rig);
  let allowed = true;
  const { fake, requestId } = admitUpload(rig.registry, { size: 10, authorized: () => allowed });
  fake.pushBytes([1, 2, 3, 4, 5]);
  // Wait for the first chunk to be fully processed (written, authorized() OK)
  // and the loop to have issued its NEXT read — the deterministic point at
  // which flipping `allowed` lands strictly after the first chunk's own check.
  await until(() => fake.readCalls.length >= 2);
  allowed = false;
  fake.pushBytes([6, 7, 8, 9, 10]);
  await until(() => rig.retiredPeers.length > 0);
  expect(rig.retiredPeers).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
  const handle = mgr.handles.get(requestId)!;
  expect(handle.written.length).toBe(5); // only the first (still-authorized) chunk was written
});

// --- happy path, truncation, oversize, cancel, timeout (§2.2) --------------

test("happy path: raw bytes (> one slice, not slice-aligned) reach the upload byte-exact; exactly one result record then FIN", async () => {
  const rig = makeRegistry();
  const { mgr } = wireProject(rig);
  const size = STREAM_RECORD_SLICE_BYTES + 777; // over one slice and not aligned to it
  const payload = new Uint8Array(size).map((_, i) => i % 256);
  const { fake, requestId } = admitUpload(rig.registry, { size });
  // Fed in two pushes to prove the reassembly isn't an artifact of one big read.
  fake.pushBytes(payload.subarray(0, STREAM_RECORD_SLICE_BYTES));
  fake.pushBytes(payload.subarray(STREAM_RECORD_SLICE_BYTES));
  fake.endFin();
  await until(() => fake.writtenRecord() !== undefined);
  const handle = mgr.handles.get(requestId)!;
  expect(handle.written).toEqual(Array.from(payload));
  expect(handle.ended).toBe(true);
  expect(fake.writtenRecord()).toMatchObject({ type: "file:upload-result", ok: true });
  await until(() => fake.finishCalls() > 0);
  // Every raw read stayed within the bound the spec sets for it.
  for (const req of fake.readCalls) expect(req).toBeLessThanOrEqual(STREAM_RAW_READ_BYTES);
});

test("a FIN short of the declared size ends the upload as INCOMPLETE", async () => {
  const rig = makeRegistry();
  const { mgr } = wireProject(rig);
  const { fake, requestId } = admitUpload(rig.registry, { size: 10 });
  fake.pushBytes([1, 2, 3]);
  fake.endFin();
  await until(() => fake.writtenRecord() !== undefined);
  expect(fake.writtenRecord()).toMatchObject({ type: "file:upload-result", ok: false, error: "INCOMPLETE" });
  expect(mgr.handles.get(requestId)!.written.length).toBe(3);
});

// PROOF this test guards the overrun mechanism, not just the framing: with the
// `remaining + 1` probe removed (i.e. reading exactly `remaining` bytes and no
// more), a peer sending one byte too many would be accepted as a complete,
// correctly-sized upload instead of being caught here.
test("more than the declared size resets the stream (STREAM_RESET_UPLOAD), writes no result, and cancels the upload", async () => {
  const rig = makeRegistry();
  const { mgr } = wireProject(rig);
  const { fake, requestId } = admitUpload(rig.registry, { size: 4 });
  fake.pushBytes([1, 2, 3, 4, 5]); // one byte over
  await until(() => fake.resetCalls.length > 0);
  expect(fake.resetCalls).toEqual([STREAM_RESET_UPLOAD]);
  expect(fake.writtenRecord()).toBeUndefined();
  expect(mgr.handles.get(requestId)!.cancelled).toBe(true);
  expect(rig.diagnostics.some((d) => d.type === "upload-stream:oversize")).toBe(true);
  await until(() => fake.stopCalls.length > 0);
  expect(fake.stopCalls).toEqual([STREAM_STOP_UPLOAD]);
});

test("the app resetting mid-body (cancel) removes the partial, resets the stream, and frees the cap slot", async () => {
  const rig = makeRegistry();
  const { mgr } = wireProject(rig);
  const { fake, requestId } = admitUpload(rig.registry, { size: 100 });
  fake.pushBytes([1, 2, 3]);
  await until(() => fake.readCalls.length > 0);
  fake.endReset();
  await until(() => fake.resetCalls.length > 0);
  expect(mgr.handles.get(requestId)!.cancelled).toBe(true);
  expect(fake.writtenRecord()).toBeUndefined();
  await until(() => rig.registry.streamCount(PEER) === 0);
});

test("connection loss (a native read rejection with no explicit endReset) is treated exactly like a cancel", async () => {
  const rig = makeRegistry();
  const { mgr } = wireProject(rig);
  const { fake, requestId } = admitUpload(rig.registry, { size: 100 });
  fake.pushBytes([1]);
  await until(() => fake.readCalls.length > 0);
  fake.endReset(new Error("connection lost"));
  await until(() => mgr.handles.get(requestId)!.cancelled);
  expect(fake.writtenRecord()).toBeUndefined();
});

test("an early per-file refusal (begin() itself refuses) writes its result before any byte is read", async () => {
  const rig = makeRegistry();
  const { mgr } = wireProject(rig);
  mgr.setNextBeginRefusal({ ok: false, error: "BUSY", message: "Too many concurrent uploads" });
  const { fake } = admitUpload(rig.registry, { size: 10 });
  await until(() => fake.writtenRecord() !== undefined);
  expect(fake.writtenRecord()).toMatchObject({ ok: false, error: "BUSY" });
  expect(fake.readCalls).toEqual([]); // never read before the early result
  await until(() => fake.finishCalls() > 0);
});

test("mayDeliverTo turning false before the result is sent resets the stream and writes nothing", async () => {
  const rig = makeRegistry();
  const { proj } = wireProject(rig);
  const { fake } = admitUpload(rig.registry, { size: 3 });
  fake.pushBytes([1, 2, 3]);
  // Wait for the declared bytes to be fully consumed and the FIN-probe read
  // (§2.2's `remaining == 0` read(1)) to be outstanding before flipping the
  // outbound gate — the deterministic point at which the result is about to
  // be sent but has not been yet.
  await until(() => fake.readCalls.length >= 2);
  proj.setMayDeliver(false);
  fake.endFin();
  await until(() => fake.resetCalls.length > 0 || fake.writtenRecord() !== undefined);
  expect(fake.writtenRecord()).toBeUndefined();
  expect(fake.resetCalls).toContain(STREAM_RESET_UPLOAD);
});

test("an inactivity TIMEOUT fired by the manager writes its result and FINs, and stops recv only once the pending read settles", async () => {
  const rig = makeRegistry();
  const { mgr, proj } = wireProject(rig);
  const { fake, requestId } = admitUpload(rig.registry, { size: 10 });
  await until(() => mgr.handles.get(requestId) !== undefined);
  const handle = mgr.handles.get(requestId)!;
  handle.forceResult({ ok: false, error: "TIMEOUT", message: "Upload timed out" });
  await until(() => fake.writtenRecord() !== undefined);
  expect(fake.writtenRecord()).toMatchObject({ ok: false, error: "TIMEOUT" });
  await until(() => fake.finishCalls() > 0);
  // The read the raw loop issued at admission is still outstanding: recv.stop()
  // cannot run yet (the binding's per-stream recv mutex, spec §1.1/1.2).
  expect(fake.stopCalls).toEqual([]);
  fake.endFin();
  await until(() => fake.stopCalls.length > 0);
  expect(fake.stopCalls).toEqual([STREAM_STOP_UPLOAD]);
  void proj; // binding kept alive for the duration of the case; nothing else exercised on it here
});

// --- teardown: projectDetached / dropPeer -----------------------------------

test("projectDetached cancels every upload for that project and unbinds it, without touching other projects", async () => {
  const rig = makeRegistry();
  const { mgr: mgrA } = wireProject(rig, "proj-a");
  const { mgr: mgrB } = wireProject(rig, "proj-b");
  const a = admitUpload(rig.registry, { projectId: "proj-a", requestId: "ra", size: 10 });
  const b = admitUpload(rig.registry, { projectId: "proj-b", requestId: "rb", size: 10 });
  await until(() => mgrA.handles.get("ra") !== undefined && mgrB.handles.get("rb") !== undefined);
  rig.registry.projectDetached("proj-a");
  await until(() => mgrA.handles.get("ra")!.cancelled);
  expect(mgrB.handles.get("rb")!.cancelled).toBe(false);
  expect(a.fake.resetCalls).toContain(STREAM_RESET_UPLOAD);
  expect(b.fake.resetCalls).toEqual([]);
});

test("dropPeer cancels every upload for that peer without calling retirePeer (the peer is already gone)", async () => {
  const rig = makeRegistry();
  const { mgr } = wireProject(rig);
  const { fake, requestId } = admitUpload(rig.registry, { size: 10 });
  await until(() => mgr.handles.get(requestId) !== undefined);
  rig.registry.dropPeer(PEER);
  await until(() => mgr.handles.get(requestId)!.cancelled);
  expect(fake.resetCalls).toContain(STREAM_RESET_UPLOAD);
  expect(rig.retiredPeers).toEqual([]);
});

