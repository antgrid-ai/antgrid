// The upload stream's wire and body protocol: docs/protocol/peer-session.md
// §1e. Drives UploadStreamRegistry directly with fakes — no PeerStreamAcceptor,
// no real FileUploadManager. Admission (authorization, the open-frame read,
// refusal codes, caps, unauthorized mid-stream, projectDetached, dropPeer) is
// covered once for every kind by stream-admission.test.ts; this file starts at
// the handler boundary and covers upload's own body: the raw read loop,
// begin/write/end sequencing against the fake manager, and the two orderings
// unique to upload (server.admit before authorized(), begin() before any
// byte is read). FileUploadManager's real begin/write/end/cancel units
// (including real disk behaviour) are file-upload.test.ts's job.
import { test, expect } from "bun:test";
import {
  UploadStreamRegistry,
  STREAM_RESET_UPLOAD,
  STREAM_STOP_UPLOAD,
  type UploadStreamRegistryOptions,
} from "../src/peer/upload-streams";
import type { UploadStreamOpen } from "antgrid-wire";
import { STREAM_RAW_READ_BYTES, STREAM_RECORD_SLICE_BYTES } from "../src/peer/stream-records";
import type { UploadProjectBinding } from "../src/project-streams";
import type {
  FileUploadManager,
  StreamUpload,
  StreamUploadWrite,
  UploadAdmission,
  UploadResultFields,
  UploadStreamServer,
} from "../src/file-upload";
import { setLogLevel } from "../src/logger";
import { createFakeBiStream, createFakeProjectBinding, until, type FakeBiStream } from "./support/fake-bi-stream";

setLogLevel("error");

/** Decodes the one length-prefixed JSON record this stream has written, if
 *  any — every test result/refusal here fits one framed record. */
function writtenRecord(fake: FakeBiStream): { type: string; [k: string]: unknown } | undefined {
  const text = fake.firstRecord();
  return text === undefined ? undefined : JSON.parse(text);
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
  let refusal: { code: "NOT_ALLOWED"; message: string } | null = null;
  const admit = async (peerId: string, checkoutId: string): Promise<UploadAdmission> => {
    admitCalls.push({ peerId, checkoutId });
    if (refusal) return { ok: false, refusal };
    return { ok: true, manager };
  };
  return { admit, admitCalls, setRefusal: (r: typeof refusal) => { refusal = r; } };
}

function makeRegistry(overrides: Partial<UploadStreamRegistryOptions> = {}) {
  const cataloged = new Set<string>();
  const bindings = new Map<string, UploadProjectBinding>();
  const retiredPeers: Array<{ peerId: string; reason: "unauthorized" | "protocol-violation" }> = [];
  const diagnostics: Array<{ type: string; detail: Record<string, unknown>; stream?: { kind: string; id: string } }> = [];
  const opts: UploadStreamRegistryOptions = {
    projectCataloged: (id) => cataloged.has(id),
    projectBinding: (id) => bindings.get(id) ?? null,
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
  const fake = createFakeBiStream();
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
  const result = registry.handlerFor("upload")(admission);
  return { fake, requestId, open, admission, result };
}

/** Sets up one project fully wired for a successful admission through the
 *  server-admit and begin() steps. */
function wireProject(rig: ReturnType<typeof makeRegistry>, projectId = PROJECT) {
  rig.cataloged.add(projectId);
  const mgr = fakeManager();
  const server = fakeUploadServer(mgr.manager);
  const proj = createFakeProjectBinding();
  proj.setUploads({ admit: server.admit } as UploadStreamServer);
  rig.bindings.set(projectId, proj as UploadProjectBinding);
  return { mgr, server, proj };
}

test("server admit refusal is written in-band (async, after synchronous admission passed)", async () => {
  const rig = makeRegistry();
  const { server } = wireProject(rig);
  server.setRefusal({ code: "NOT_ALLOWED", message: "checkout is being deleted" });
  const { fake, result } = admitUpload(rig.registry);
  expect(result).toBeUndefined(); // synchronous steps all passed; the refusal is in-band
  await until(() => writtenRecord(fake) !== undefined);
  expect(writtenRecord(fake)).toEqual({ type: "stream:refused", code: "NOT_ALLOWED", message: "checkout is being deleted" });
  await until(() => fake.isFinished());
});

test("a well-formed open from a peer no longer authorized still reaches server.admit, but never manager.begin", async () => {
  // The admission order checks `authorized()` AFTER server.admit — admit is a
  // pure checkout/switch lookup with no opinion on this peer's live
  // authorization, so it still runs.
  const rig = makeRegistry();
  const { server, mgr } = wireProject(rig);
  const { fake } = admitUpload(rig.registry, { authorized: () => false });
  await until(() => rig.retiredPeers.length > 0);
  expect(server.admitCalls).toEqual([{ peerId: PEER, checkoutId: "main" }]);
  expect(mgr.beginCalls).toEqual([]);
  expect(rig.retiredPeers).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
  expect(fake.order).not.toContain("writeAll");
});

test("happy path: raw bytes (> one slice, not slice-aligned) reach the upload byte-exact; exactly one result record then FIN", async () => {
  const rig = makeRegistry();
  const { mgr } = wireProject(rig);
  const size = STREAM_RECORD_SLICE_BYTES + 777; // over one slice and not aligned to it
  const payload = new Uint8Array(size).map((_, i) => i % 256);
  const { fake, requestId } = admitUpload(rig.registry, { size });
  // Fed in two pushes to prove the reassembly isn't an artifact of one big read.
  fake.pushRaw(payload.subarray(0, STREAM_RECORD_SLICE_BYTES));
  fake.pushRaw(payload.subarray(STREAM_RECORD_SLICE_BYTES));
  fake.endWith();
  await until(() => writtenRecord(fake) !== undefined);
  const handle = mgr.handles.get(requestId)!;
  expect(handle.written).toEqual(Array.from(payload));
  expect(handle.ended).toBe(true);
  expect(writtenRecord(fake)).toMatchObject({ type: "file:upload-result", ok: true });
  await until(() => fake.isFinished());
  // Every raw read stayed within the bound the registry sets for it.
  for (const req of fake.readSizes) expect(req).toBeLessThanOrEqual(STREAM_RAW_READ_BYTES);
});

test("a FIN short of the declared size ends the upload as INCOMPLETE", async () => {
  const rig = makeRegistry();
  const { mgr } = wireProject(rig);
  const { fake, requestId } = admitUpload(rig.registry, { size: 10 });
  fake.pushRaw(new Uint8Array([1, 2, 3]));
  fake.endWith();
  await until(() => writtenRecord(fake) !== undefined);
  expect(writtenRecord(fake)).toMatchObject({ type: "file:upload-result", ok: false, error: "INCOMPLETE" });
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
  fake.pushRaw(new Uint8Array([1, 2, 3, 4, 5])); // one byte over
  await until(() => fake.resets.length > 0);
  expect(fake.resets).toEqual([STREAM_RESET_UPLOAD]);
  expect(writtenRecord(fake)).toBeUndefined();
  expect(mgr.handles.get(requestId)!.cancelled).toBe(true);
  expect(rig.diagnostics.some((d) => d.type === "upload-stream:oversize")).toBe(true);
  await until(() => fake.stops.length > 0);
  expect(fake.stops).toEqual([STREAM_STOP_UPLOAD]);
});

test("the app ending mid-body removes the partial, resets the stream and frees the cap slot: an explicit reset, or a bare connection loss, alike", async () => {
  for (const end of [
    (fake: FakeBiStream) => fake.endWith(new Error("peer reset this stream")),
    (fake: FakeBiStream) => fake.endWith(new Error("connection lost")),
  ]) {
    const rig = makeRegistry();
    const { mgr } = wireProject(rig);
    const { fake, requestId } = admitUpload(rig.registry, { size: 100 });
    fake.pushRaw(new Uint8Array([1, 2, 3]));
    await until(() => fake.readSizes.length > 0);
    end(fake);
    await until(() => mgr.handles.get(requestId)!.cancelled);
    expect(writtenRecord(fake)).toBeUndefined();
    await until(() => rig.registry.streamCount(PEER) === 0);
  }
});

test("an early per-file refusal (begin() itself refuses) writes its result before any byte is read", async () => {
  const rig = makeRegistry();
  const { mgr } = wireProject(rig);
  mgr.setNextBeginRefusal({ ok: false, error: "BUSY", message: "Too many concurrent uploads" });
  const { fake } = admitUpload(rig.registry, { size: 10 });
  await until(() => writtenRecord(fake) !== undefined);
  expect(writtenRecord(fake)).toMatchObject({ ok: false, error: "BUSY" });
  expect(fake.readSizes).toEqual([]); // never read before the early result
  await until(() => fake.isFinished());
});

test("mayDeliverTo turning false before the result is sent resets the stream and writes nothing", async () => {
  const rig = makeRegistry();
  const { proj } = wireProject(rig);
  const { fake } = admitUpload(rig.registry, { size: 3 });
  fake.pushRaw(new Uint8Array([1, 2, 3]));
  // Wait for the declared bytes to be fully consumed and the FIN-probe read
  // (the `remaining == 0` read(1)) to be outstanding before flipping the
  // outbound gate — the deterministic point at which the result is about to
  // be sent but has not been yet.
  await until(() => fake.readSizes.length >= 2);
  proj.setMayDeliver(false);
  fake.endWith();
  await until(() => fake.resets.length > 0 || writtenRecord(fake) !== undefined);
  expect(writtenRecord(fake)).toBeUndefined();
  expect(fake.resets).toContain(STREAM_RESET_UPLOAD);
});

test("an inactivity TIMEOUT fired by the manager writes its result and FINs, and stops recv only once the pending read settles", async () => {
  const rig = makeRegistry();
  const { mgr, proj } = wireProject(rig);
  const { fake, requestId } = admitUpload(rig.registry, { size: 10 });
  await until(() => mgr.handles.get(requestId) !== undefined);
  const handle = mgr.handles.get(requestId)!;
  handle.forceResult({ ok: false, error: "TIMEOUT", message: "Upload timed out" });
  await until(() => writtenRecord(fake) !== undefined);
  expect(writtenRecord(fake)).toMatchObject({ ok: false, error: "TIMEOUT" });
  await until(() => fake.isFinished());
  // The read the raw loop issued at admission is still outstanding: recv.stop()
  // cannot run yet (the binding's per-stream recv mutex).
  expect(fake.stops).toEqual([]);
  fake.endWith();
  await until(() => fake.stops.length > 0);
  expect(fake.stops).toEqual([STREAM_STOP_UPLOAD]);
  void proj; // binding kept alive for the duration of the case; nothing else exercised on it here
});
