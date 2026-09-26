// The ONE admission suite for every native bidi stream kind after the session
// stream. `PeerStreamAcceptor`'s connection-level order (stream-dispatch.ts)
// and `ScopedStreamRegistry`'s project-scoped order (the same file) are each
// exercised exactly once here, generically over every kind they serve —
// terminal, tunnel-http, tunnel-ws and upload share one base class and one
// admission order, so this file proves that shared order once instead of
// four times. `project` is its own registry (it does not extend
// `ScopedStreamRegistry` — it IS the binding the other four look up) and gets
// its own block below, proving the same invariants against its own gate.
//
// What stays OUT of this file, by design: each kind's own head/body protocol
// (subscribe/subscribed, the HTTP/WS exchange, the upload byte loop) — that
// is terminal-streams.test.ts / tunnel-streams.test.ts / upload-streams.test.ts's
// job, and native-host-connection.test.ts's job for how the real bridge wires
// these registries together.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  decodeStreamRefused,
  encodeStreamOpen,
  encodeTunnelDataRecord,
  TUNNEL_RECORD_TAG_WS_TEXT,
  StreamOpen as StreamOpenSchema,
  STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER,
  STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
  STREAM_MAX_UPLOAD_STREAMS_PER_PEER,
  STREAM_OPEN_MAX_BYTES,
  STREAM_PROJECT_APP_RECORD_MAX_BYTES,
  STREAM_TERMINAL_APP_RECORD_MAX_BYTES,
  type StreamOpen,
} from "antgrid-wire";
import {
  PeerStreamAcceptor,
  streamLabelOf,
  STREAM_OPEN_DEADLINE_MS,
  STREAM_RESET_OPEN_TIMEOUT,
  STREAM_STOP_REFUSED,
  type AcceptedBiStream,
  type PeerStreamAcceptorOptions,
  type StreamHandlers,
  type StreamHandler,
  type StreamRefusal,
} from "../src/peer/stream-dispatch";
import { NETWATCH_SESSION_STREAM_LABEL } from "../src/netwatch";
import { createMessage } from "../src/protocol";
import { MessageBus } from "../src/message-bus";
import {
  ProjectStreamRegistry,
  STREAM_RESET_PROJECT,
  type ProjectStreamRegistryOptions,
} from "../src/project-streams";
import {
  TerminalStreamRegistry,
  STREAM_PRIORITY_TERMINAL,
  STREAM_RESET_TERMINAL,
  STREAM_STOP_TERMINAL,
  type TerminalStreamRegistryOptions,
} from "../src/peer/terminal-streams";
import {
  TunnelStreamRegistry,
  STREAM_PRIORITY_TUNNEL,
  STREAM_RESET_TUNNEL,
  STREAM_STOP_TUNNEL,
  type TunnelStreamRegistryOptions,
} from "../src/peer/tunnel-streams";
import {
  UploadStreamRegistry,
  STREAM_PRIORITY_UPLOAD,
  STREAM_RESET_UPLOAD,
  STREAM_STOP_UPLOAD,
  type UploadStreamRegistryOptions,
} from "../src/peer/upload-streams";
import { TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";
import type { TunnelManager } from "../src/tunnel-manager";
import type { FileUploadManager, StreamUpload, UploadResultFields, UploadStreamServer } from "../src/file-upload";
import {
  createFakeBiStream, createFakeProjectBinding, flush, lengthPrefix, manualSchedule, refusalOf, until,
  type FakeBiStream, type FakeProjectBinding,
} from "./support/fake-bi-stream";

const PROJECT = "proj1";
const PEER = "peer1";

// ============================================================================
// 1. Acceptor-level: PeerStreamAcceptor's connection-level admission order.
//    Runs over a real handler table wired for every kind, so these rules hold
//    no matter which kind's registry actually backs the table.
// ============================================================================

function openFrame(open: StreamOpen): Uint8Array {
  const body = encodeStreamOpen(open);
  const framed = new Uint8Array(4 + body.length);
  new DataView(framed.buffer).setUint32(0, body.length, false);
  framed.set(body, 4);
  return framed;
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

/** One real registry per kind, wired permissively (catalogued, remote access
 *  on, one project already attached) so a well-formed open of any kind would
 *  actually be admitted — proving the acceptor's shared order holds for the
 *  real wiring, not a synthetic stub table. */
function realHandlerTable(): StreamHandlers {
  const project = new ProjectStreamRegistry({
    remoteAccessEnabled: () => true,
    projectCataloged: () => true,
    peerSession: () => null,
    sendSessionMessage: () => {},
    retirePeer: () => {},
  });
  project.attach(new MessageBus(), { projectId: PROJECT });
  const terminal = new TerminalStreamRegistry({
    projectCataloged: () => true,
    projectBinding: () => createFakeProjectBinding(),
    retirePeer: () => {},
  });
  const tunnel = new TunnelStreamRegistry({
    projectCataloged: () => true,
    projectBinding: () => createFakeProjectBinding(),
    retirePeer: () => {},
  });
  const upload = new UploadStreamRegistry({
    projectCataloged: () => true,
    projectBinding: () => createFakeProjectBinding(),
    retirePeer: () => {},
  });
  return {
    project: project.handler,
    terminal: terminal.handlerFor("terminal"),
    "tunnel-http": tunnel.handlerFor("tunnel-http"),
    "tunnel-ws": tunnel.handlerFor("tunnel-ws"),
    upload: upload.handlerFor("upload"),
  };
}

function createAcceptor(overrides: Partial<PeerStreamAcceptorOptions> & { connection: PeerStreamAcceptorOptions["connection"] }) {
  const unauthorizedCalls: string[] = [];
  const acceptor = new PeerStreamAcceptor({
    peerId: PEER,
    isCurrent: () => true,
    authorized: () => true,
    established: () => true,
    onUnauthorized: () => { unauthorizedCalls.push(PEER); },
    handlers: realHandlerTable(),
    ...overrides,
  });
  return { acceptor, unauthorizedCalls };
}

const EVERY_KIND_OPEN: StreamOpen[] = [
  { kind: "project", projectId: PROJECT },
  { kind: "terminal", projectId: PROJECT, requestId: crypto.randomUUID() },
  { kind: "tunnel-http", projectId: PROJECT, requestId: crypto.randomUUID() },
  { kind: "tunnel-ws", projectId: PROJECT, wsId: crypto.randomUUID() },
  { kind: "upload", projectId: PROJECT, requestId: crypto.randomUUID(), fileName: "a.bin", size: 0 },
];

describe("PeerStreamAcceptor: shared admission order (every kind through the real handler table)", () => {
  test("an unknown kind, a malformed frame and an oversize length prefix are all refused INVALID in-band, then FIN — the connection lives", async () => {
    const cases: Array<{ name: string; frame: Uint8Array }> = [
      { name: "malformed JSON body", frame: (() => {
        const garbage = new Uint8Array([0xff, 0xfe, 0xfd]);
        const framed = new Uint8Array(4 + garbage.length);
        new DataView(framed.buffer).setUint32(0, garbage.length, false);
        framed.set(garbage, 4);
        return framed;
      })() },
      { name: "zero-length frame", frame: new Uint8Array(lengthPrefix(0)) },
      { name: "oversize length prefix", frame: new Uint8Array(lengthPrefix(STREAM_OPEN_MAX_BYTES + 1)) },
    ];
    for (const { frame } of cases) {
      const queue = connectionQueue();
      const { acceptor } = createAcceptor({ connection: queue.connection });
      const fake = createFakeBiStream();
      fake.pushRaw(frame);
      acceptor.start();
      queue.push(fake.stream);
      await until(() => fake.records().length > 0);
      expect(refusalOf(fake)?.code).toBe("INVALID");
      await until(() => fake.isFinished());
      acceptor.stop();
    }
  });

  test("an oversize length prefix is refused without ever reading the body", async () => {
    const queue = connectionQueue();
    const { acceptor } = createAcceptor({ connection: queue.connection });
    const fake = createFakeBiStream();
    fake.pushOverlongPrefix(STREAM_OPEN_MAX_BYTES + 1);
    acceptor.start();
    queue.push(fake.stream);
    await until(() => fake.records().length > 0);
    expect(refusalOf(fake)?.code).toBe("INVALID");
    expect(fake.readExactSizes).toEqual([4]); // the body was never read
    acceptor.stop();
  });

  test("a second session-kind open is refused INVALID", async () => {
    const queue = connectionQueue();
    const { acceptor } = createAcceptor({ connection: queue.connection });
    const fake = createFakeBiStream();
    fake.pushRaw(openFrame({ kind: "session" }));
    acceptor.start();
    queue.push(fake.stream);
    await until(() => fake.records().length > 0);
    expect(refusalOf(fake)?.code).toBe("INVALID");
    acceptor.stop();
  });

  test("a non-session open before the session is established is refused NOT_READY, for every kind", async () => {
    for (const open of EVERY_KIND_OPEN) {
      const queue = connectionQueue();
      const { acceptor } = createAcceptor({ connection: queue.connection, established: () => false });
      const fake = createFakeBiStream();
      fake.pushRaw(openFrame(open));
      acceptor.start();
      queue.push(fake.stream);
      await until(() => fake.records().length > 0);
      expect(refusalOf(fake)?.code).toBe("NOT_READY");
      acceptor.stop();
    }
  });

  test("an unauthorized peer writes nothing and never reaches any handler", async () => {
    const queue = connectionQueue();
    let handled = false;
    const { acceptor, unauthorizedCalls } = createAcceptor({
      connection: queue.connection,
      authorized: () => false,
      handlers: { project: () => { handled = true; return undefined; } },
    });
    const fake = createFakeBiStream();
    fake.pushRaw(openFrame({ kind: "project", projectId: PROJECT }));
    acceptor.start();
    queue.push(fake.stream);
    await until(() => unauthorizedCalls.length > 0);
    await flush();
    expect(handled).toBe(false);
    expect(fake.records()).toEqual([]);
    acceptor.stop();
  });

  test("a throwing handler is refused NOT_ALLOWED, same as no handler at all", async () => {
    const queue = connectionQueue();
    const handlers: StreamHandlers = { project: () => { throw new Error("boom"); } };
    const { acceptor } = createAcceptor({ connection: queue.connection, handlers });
    const fake = createFakeBiStream();
    fake.pushRaw(openFrame({ kind: "project", projectId: PROJECT }));
    acceptor.start();
    queue.push(fake.stream);
    await until(() => fake.records().length > 0);
    expect(refusalOf(fake)?.code).toBe("NOT_ALLOWED");
    acceptor.stop();
  });

  test("an open over the pending-open cap is refused CAP_EXCEEDED without being read, and the connection lives", async () => {
    const queue = connectionQueue();
    const { acceptor } = createAcceptor({ connection: queue.connection, maxPendingOpens: 1 });
    const hanging = createFakeBiStream(); // never sends its open frame
    const overCap = createFakeBiStream();
    overCap.pushOverlongPrefix(0); // would-be INVALID, never reached
    acceptor.start();
    queue.push(hanging.stream);
    await until(() => acceptor.pendingOpens === 1);
    queue.push(overCap.stream);
    await until(() => overCap.records().length > 0);
    expect(refusalOf(overCap)?.code).toBe("CAP_EXCEEDED");
    expect(overCap.readExactSizes).toEqual([]); // never read
    await until(() => overCap.stops.length > 0); // the refusal still stops recv
    expect(overCap.stops).toEqual([STREAM_STOP_REFUSED]);
    acceptor.stop();
  });

  test("a pending slot is released when its open frame arrives, and when its deadline fires", async () => {
    const sched = manualSchedule();
    const queue = connectionQueue();
    const { acceptor } = createAcceptor({ connection: queue.connection, maxPendingOpens: 1, schedule: sched.schedule });

    const first = createFakeBiStream();
    first.pushOverlongPrefix(0);
    acceptor.start();
    queue.push(first.stream);
    await until(() => first.records().length > 0);
    await until(() => acceptor.pendingOpens === 0);

    const second = createFakeBiStream(); // hangs; released only by its deadline
    queue.push(second.stream);
    await until(() => acceptor.pendingOpens === 1);
    sched.timers.find((t) => t.ms === STREAM_OPEN_DEADLINE_MS && !t.cancelled)!.fire();
    await until(() => acceptor.pendingOpens === 0);

    const third = createFakeBiStream();
    third.pushOverlongPrefix(0);
    queue.push(third.stream);
    await until(() => third.records().length > 0);
    expect(refusalOf(third)?.code).toBe("INVALID"); // admitted, not CAP_EXCEEDED
    acceptor.stop();
  });

  test("an open frame missing its deadline resets the send half and never calls recv.stop while the read is still outstanding", async () => {
    const sched = manualSchedule();
    const queue = connectionQueue();
    const { acceptor } = createAcceptor({ connection: queue.connection, schedule: sched.schedule });
    const fake = createFakeBiStream(); // never sends its open frame
    acceptor.start();
    queue.push(fake.stream);
    await until(() => sched.timers.some((t) => t.ms === STREAM_OPEN_DEADLINE_MS));
    sched.timers.find((t) => t.ms === STREAM_OPEN_DEADLINE_MS)!.fire();
    await until(() => fake.resets.length > 0);
    expect(fake.resets).toEqual([STREAM_RESET_OPEN_TIMEOUT]);
    expect(fake.stops).toEqual([]); // the read still holds the recv mutex
    expect(fake.records()).toEqual([]);
    acceptor.stop();
  });

  test("an open frame that arrives after its own deadline is never admitted, and its receive half is stopped once the late read settles", async () => {
    const sched = manualSchedule();
    const queue = connectionQueue();
    let handled = false;
    const { acceptor } = createAcceptor({
      connection: queue.connection, schedule: sched.schedule,
      handlers: { project: () => { handled = true; return undefined; } },
    });
    const fake = createFakeBiStream();
    acceptor.start();
    queue.push(fake.stream);
    await until(() => sched.timers.some((t) => t.ms === STREAM_OPEN_DEADLINE_MS));
    sched.timers.find((t) => t.ms === STREAM_OPEN_DEADLINE_MS)!.fire();
    await until(() => fake.resets.length > 0);
    expect(fake.stops).toEqual([]);
    fake.pushRaw(openFrame({ kind: "project", projectId: PROJECT })); // arrives late
    await until(() => fake.stops.length > 0);
    expect(fake.stops).toEqual([STREAM_STOP_REFUSED]);
    expect(fake.records()).toEqual([]);
    expect(handled).toBe(false);
    acceptor.stop();
  });

  test("an open frame that settles after stop() or after the connection is superseded is dropped without a write", async () => {
    for (const retire of ["stop", "superseded"] as const) {
      const queue = connectionQueue();
      let current = true;
      let handled = false;
      const { acceptor } = createAcceptor({
        connection: queue.connection, isCurrent: () => current,
        handlers: { project: () => { handled = true; return undefined; } },
      });
      const fake = createFakeBiStream(); // no open frame yet: stays pending
      acceptor.start();
      queue.push(fake.stream);
      await until(() => acceptor.pendingOpens === 1);
      if (retire === "stop") acceptor.stop();
      else current = false;
      fake.pushRaw(openFrame({ kind: "project", projectId: PROJECT }));
      await until(() => acceptor.pendingOpens === 0);
      await flush();
      expect(handled).toBe(false);
      expect(fake.records()).toEqual([]);
      acceptor.stop();
    }
  });

  test("streamLabelOf labels every kind, matching the shared label vectors the Dart client asserts too", () => {
    expect(streamLabelOf({ kind: "session" })).toEqual({ kind: "session" });
    expect(streamLabelOf({ kind: "project", projectId: "p1" })).toEqual({ kind: "project", id: "p1" });
    expect(streamLabelOf({ kind: "terminal", projectId: "p1", requestId: "r1" })).toEqual({ kind: "terminal", id: "r1" });
    expect(streamLabelOf({ kind: "tunnel-http", projectId: "p1", requestId: "r1" })).toEqual({ kind: "tunnel-http", id: "r1" });
    expect(streamLabelOf({ kind: "tunnel-ws", projectId: "p1", wsId: "ws-1" })).toEqual({ kind: "tunnel-ws", id: "ws-1" });
    expect(streamLabelOf({ kind: "upload", projectId: "p1", requestId: "r1", fileName: "a.bin", size: 1 }))
      .toEqual({ kind: "upload", id: "r1" });

    const fixture = JSON.parse(
      readFileSync(join(import.meta.dir, "../../evals/fixtures/peer-transport-vectors.json"), "utf8"),
    ) as { streamOpen: { labels: Array<{ name: string; open: unknown; streamKind: string; streamId: string }> } };
    const labels = fixture.streamOpen.labels;
    expect(labels.map((l) => l.streamKind).sort()).toEqual(
      ["project", "session", "terminal", "tunnel-http", "tunnel-ws", "upload"],
    );
    for (const row of labels) {
      const label = streamLabelOf(StreamOpenSchema.parse(row.open));
      expect({ name: row.name, kind: label.kind as string, id: label.id ?? NETWATCH_SESSION_STREAM_LABEL })
        .toEqual({ name: row.name, kind: row.streamKind, id: row.streamId });
    }
  });
});

// ============================================================================
// 2. Registry-level: ScopedStreamRegistry's shared order, generic over the
//    four project-scoped kinds (terminal, tunnel-http, tunnel-ws, upload).
// ============================================================================

// `ScopedStreamRegistry.admit` never actually returns a Promise (only a
// handler's own `serve()` may refuse asynchronously, via `refuseInline`, not
// through this return value) — narrowed here so every generic-loop test below
// can read `.code` off an admission result without an `await`.
type SyncAdmit = (admission: any) => StreamRefusal | undefined;

interface MadeKind {
  handler: SyncAdmit;
  cataloged: Set<string>;
  lookups: string[];
  retired: Array<{ peerId: string; reason: string }>;
  count(peerId: string): number;
  /** How many inbound records or opens reached the kind's own consumer
   *  (bus dispatch, tunnel manager, upload manager). */
  reached(): number;
  drop(peerId: string): void;
  detach(projectId: string): void;
  /** A fresh, catalogued, fully-available `FakeProjectBinding` for `projectId`
   *  (server wired where the kind has one), registered as this registry's
   *  `projectBinding(projectId)` answer. */
  registerProject(projectId: string): FakeProjectBinding;
  /** Pushes this kind's own cheapest legitimate first application traffic —
   *  enough to exercise the per-record recheck path, not to fully complete
   *  the kind's own protocol (that is the kind file's job). */
  pushFirstTraffic(fake: FakeBiStream, id: string): void;
  /** Drives exactly one outbound record through this binding's writer —
   *  assumes `pushFirstTraffic` already ran for terminal/tunnel/upload alike. */
  driveOneWrite(peerId: string, id: string, fake: FakeBiStream): Promise<void>;
  /** Runs immediately before the kind's first outbound write, after every
   *  inbound read that write depends on has already passed its own check. */
  setBeforeWrite(fn: () => void): void;
  /** A record the kind accepts after its first traffic has been consumed;
   *  absent for tunnel-http, which reads nothing after its head but the
   *  cancel signal. */
  pushLaterTraffic?(fake: FakeBiStream, id: string): void;
}

interface KindCase {
  kind: "terminal" | "tunnel-http" | "tunnel-ws" | "upload";
  cap: number;
  priority: number;
  resetCode: bigint;
  stopCode: bigint;
  /** `hasAvailability`: this kind's `available()` override can refuse
   *  NOT_ALLOWED when its server is absent (tunnel, upload); terminal has
   *  none. */
  hasAvailability: boolean;
  open(projectId: string, id: string): StreamOpen;
  make(): MadeKind;
}

function terminalCase(): KindCase {
  return {
    kind: "terminal",
    cap: STREAM_MAX_TERMINAL_ATTACHMENTS_PER_PEER,
    priority: STREAM_PRIORITY_TERMINAL,
    resetCode: STREAM_RESET_TERMINAL,
    stopCode: STREAM_STOP_TERMINAL,
    hasAvailability: false,
    open: (projectId, id) => ({ kind: "terminal", projectId, requestId: id }),
    make() {
      const cataloged = new Set<string>();
      const bindings = new Map<string, FakeProjectBinding>();
      const lookups: string[] = [];
      const retired: Array<{ peerId: string; reason: string }> = [];
      const registry = new TerminalStreamRegistry({
        projectCataloged: (id) => cataloged.has(id),
        projectBinding: (id) => { lookups.push(id); return bindings.get(id) ?? null; },
        retirePeer: (peerId, reason) => retired.push({ peerId, reason }),
      } satisfies TerminalStreamRegistryOptions);
      let beforeWrite = () => {};
      return {
        handler: registry.handlerFor("terminal") as unknown as SyncAdmit,
        cataloged, lookups, retired,
        count: (peerId) => registry.streamCount(peerId),
        reached: () => [...bindings.values()].reduce((n, b) => n + b.dispatched.length, 0),
        drop: (peerId) => registry.dropPeer(peerId),
        detach: (projectId) => registry.projectDetached(projectId),
        registerProject(projectId) {
          const b = createFakeProjectBinding();
          bindings.set(projectId, b);
          cataloged.add(projectId);
          return b;
        },
        pushFirstTraffic(fake, id) {
          fake.pushRecord(createMessage("terminal:subscribe", {
            terminalId: "t1", version: TERMINAL_PROTOCOL_VERSION, requestId: id, checkoutId: "main",
          }));
        },
        async driveOneWrite(peerId, id) {
          await flush(5); // the subscribe must be read and dispatched first
          beforeWrite();
          await registry.route(peerId, createMessage("terminal:subscribed", {
            terminalId: "t1", runId: crypto.randomUUID(), attachmentId: crypto.randomUUID(),
            version: TERMINAL_PROTOCOL_VERSION, requestId: id, checkoutId: "main",
          }));
        },
        setBeforeWrite(fn) { beforeWrite = fn; },
        pushLaterTraffic(fake) {
          fake.pushRecord(createMessage("terminal:ack", {
            terminalId: "t1", runId: crypto.randomUUID(), attachmentId: crypto.randomUUID(), sequence: 1, checkoutId: "main",
          }));
        },
      };
    },
  };
}

function tunnelCase(subKind: "tunnel-http" | "tunnel-ws"): KindCase {
  return {
    kind: subKind,
    cap: STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
    priority: STREAM_PRIORITY_TUNNEL,
    resetCode: STREAM_RESET_TUNNEL,
    stopCode: STREAM_STOP_TUNNEL,
    hasAvailability: true,
    open: (projectId, id) => subKind === "tunnel-http"
      ? { kind: "tunnel-http", projectId, requestId: id }
      : { kind: "tunnel-ws", projectId, wsId: id },
    make() {
      const cataloged = new Set<string>();
      const bindings = new Map<string, FakeProjectBinding>();
      const lookups: string[] = [];
      const retired: Array<{ peerId: string; reason: string }> = [];
      const registry = new TunnelStreamRegistry({
        projectCataloged: (id) => cataloged.has(id),
        projectBinding: (id) => { lookups.push(id); return bindings.get(id) ?? null; },
        retirePeer: (peerId, reason) => retired.push({ peerId, reason }),
      } satisfies TunnelStreamRegistryOptions);
      // A manager whose serveHttp/serveWs each immediately produce exactly
      // one outbound record, so `driveOneWrite` needs only to let it settle.
      let reached = 0;
      let beforeWrite = () => {};
      const manager: Pick<TunnelManager, "serveHttp" | "serveWs"> = {
        serveHttp: async (_req, _body, exchange) => {
          reached++;
          beforeWrite();
          await exchange.head({ status: 200, headers: {} });
        },
        serveWs: (_open, peer) => {
          reached++;
          beforeWrite();
          peer.send({ binary: false, bytes: new TextEncoder().encode("hi") });
          return { data() { reached++; }, closed() {} };
        },
      };
      const server = { admit: (_peerId: string, _checkoutId: string) => ({ ok: true as const, manager: manager as TunnelManager }) };
      return {
        handler: registry.handlerFor(subKind) as unknown as SyncAdmit,
        cataloged, lookups, retired,
        count: (peerId) => registry.streamCount(peerId),
        reached: () => reached,
        drop: (peerId) => registry.dropPeer(peerId),
        detach: (projectId) => registry.projectDetached(projectId),
        registerProject(projectId) {
          const b = createFakeProjectBinding();
          b.setTunnels(server);
          bindings.set(projectId, b);
          cataloged.add(projectId);
          return b;
        },
        pushFirstTraffic(fake, id) {
          if (subKind === "tunnel-http") {
            fake.pushRecord({ type: "tunnel:http-request", requestId: id, port: 3000, method: "GET", path: "/", bodyLength: 0, checkoutId: "main" });
          } else {
            fake.pushRecord({ type: "tunnel:ws-open", tunnelId: id, port: 3000, path: "/", checkoutId: "main" });
          }
        },
        async driveOneWrite() {
          await flush(5); // the head record's async read + parse + admit chain
        },
        setBeforeWrite(fn) { beforeWrite = fn; },
        pushLaterTraffic: subKind === "tunnel-ws"
          ? (fake) => fake.pushRecord(encodeTunnelDataRecord(TUNNEL_RECORD_TAG_WS_TEXT, new TextEncoder().encode("later")))
          : undefined,
      };
    },
  };
}

function uploadCase(): KindCase {
  return {
    kind: "upload",
    cap: STREAM_MAX_UPLOAD_STREAMS_PER_PEER,
    priority: STREAM_PRIORITY_UPLOAD,
    resetCode: STREAM_RESET_UPLOAD,
    stopCode: STREAM_STOP_UPLOAD,
    hasAvailability: true,
    open: (projectId, id) => ({ kind: "upload", projectId, requestId: id, fileName: "a.bin", size: 0 }),
    make() {
      const cataloged = new Set<string>();
      const bindings = new Map<string, FakeProjectBinding>();
      const lookups: string[] = [];
      const retired: Array<{ peerId: string; reason: string }> = [];
      const registry = new UploadStreamRegistry({
        projectCataloged: (id) => cataloged.has(id),
        projectBinding: (id) => { lookups.push(id); return bindings.get(id) ?? null; },
        retirePeer: (peerId, reason) => retired.push({ peerId, reason }),
      } satisfies UploadStreamRegistryOptions);
      // A manager that always admits a 0-byte upload and reports success the
      // instant `end()` is called — reached the moment the app FINs.
      let reached = 0;
      let beforeWrite = () => {};
      const manager: Pick<FileUploadManager, "begin"> = {
        begin: (start, onResult) => {
          reached++;
          const upload: StreamUpload = {
            uploadId: `fake-${start.requestId}`,
            write: () => { reached++; return "ok"; },
            end: () => { beforeWrite(); onResult({ ok: true } as UploadResultFields); },
            cancel: () => {},
          };
          return { ok: true as const, upload };
        },
      };
      const server: Pick<UploadStreamServer, "admit"> = {
        admit: async (_peerId, _checkoutId) => ({ ok: true as const, manager: manager as FileUploadManager }),
      };
      return {
        handler: registry.handlerFor("upload") as unknown as SyncAdmit,
        cataloged, lookups, retired,
        count: (peerId) => registry.streamCount(peerId),
        reached: () => reached,
        drop: (peerId) => registry.dropPeer(peerId),
        detach: (projectId) => registry.projectDetached(projectId),
        registerProject(projectId) {
          const b = createFakeProjectBinding();
          b.setUploads(server as UploadStreamServer);
          bindings.set(projectId, b);
          cataloged.add(projectId);
          return b;
        },
        // A 0-byte upload's own "first record" is simply its FIN — there is
        // no framed record at all on this kind's wire.
        pushFirstTraffic(fake) { fake.endWith(); },
        async driveOneWrite() { await flush(5); }, // admit() await + begin() + end() + deliverResult
        setBeforeWrite(fn) { beforeWrite = fn; },
        // Any byte past admission is a body read, whatever the declared size.
        pushLaterTraffic(fake) { fake.pushRaw(new Uint8Array([1])); },
      };
    },
  };
}

const SCOPED_KINDS: KindCase[] = [terminalCase(), tunnelCase("tunnel-http"), tunnelCase("tunnel-ws"), uploadCase()];

function open(kc: KindCase, peerId: string, projectId: string, id: string, stream: AcceptedBiStream, authorized: () => boolean = () => true) {
  return { peerId, open: kc.open(projectId, id), stream, authorized };
}

describe("ScopedStreamRegistry: shared admission order (generic over terminal, tunnel-http, tunnel-ws, upload)", () => {
  for (const kc of SCOPED_KINDS) {
    test(`${kc.kind}: an unsafe project id is refused NOT_ALLOWED even when catalogued and bound`, () => {
      const made = kc.make();
      made.registerProject("../evil");
      const fake = createFakeBiStream();
      const result = made.handler(open(kc, PEER, "../evil", crypto.randomUUID(), fake.stream));
      expect(result).toEqual({ code: "NOT_ALLOWED", message: "unsafe project id" });
    });

    test(`${kc.kind}: an uncatalogued project is refused NOT_ALLOWED (fail closed)`, () => {
      const made = kc.make();
      const fake = createFakeBiStream();
      const result = made.handler(open(kc, PEER, PROJECT, crypto.randomUUID(), fake.stream));
      expect(result).toEqual({ code: "NOT_ALLOWED", message: "project not recognized" });
    });

    test(`${kc.kind}: an unbound project is NOT_READY, and the project lookup is consulted exactly once`, () => {
      const made = kc.make();
      made.cataloged.add(PROJECT); // catalogued, but no projectBinding entry exists
      const fake = createFakeBiStream();
      const result = made.handler(open(kc, PEER, PROJECT, crypto.randomUUID(), fake.stream));
      expect(result).toEqual({ code: "NOT_READY", message: "project is not attached" });
      expect(made.lookups).toEqual([PROJECT]);
    });

    test(`${kc.kind}: no open project stream for this peer is refused NOT_ALLOWED; another peer's open stream does not count`, () => {
      const made = kc.make();
      const binding = made.registerProject(PROJECT);
      binding.setHasOpenStream(PEER, false);
      binding.setHasOpenStream("other-peer", true);
      const fake = createFakeBiStream();
      const result = made.handler(open(kc, PEER, PROJECT, crypto.randomUUID(), fake.stream));
      expect(result).toEqual({ code: "NOT_ALLOWED", message: "open the project stream first" });
    });

    test(`${kc.kind}: the project's own per-sender refusal is masked to NOT_ALLOWED`, () => {
      const made = kc.make();
      const binding = made.registerProject(PROJECT);
      binding.setRefusal({ code: "CAP_EXCEEDED", message: "checkout is being deleted" });
      const fake = createFakeBiStream();
      const result = made.handler(open(kc, PEER, PROJECT, crypto.randomUUID(), fake.stream));
      expect(result).toEqual({ code: "NOT_ALLOWED", message: "checkout is being deleted" });
    });

    test(`${kc.kind}: a duplicate (peer, kind, id) is refused INVALID`, () => {
      const made = kc.make();
      made.registerProject(PROJECT);
      const id = crypto.randomUUID();
      const first = createFakeBiStream();
      expect(made.handler(open(kc, PEER, PROJECT, id, first.stream))).toBeUndefined();
      const second = createFakeBiStream();
      expect(made.handler(open(kc, PEER, PROJECT, id, second.stream))).toEqual({ code: "INVALID", message: "duplicate id" });
    });

    if (kc.hasAvailability) {
      test(`${kc.kind}: the kind's own server being unavailable is refused NOT_ALLOWED`, () => {
        const made = kc.make();
        const binding = made.registerProject(PROJECT);
        binding.setTunnels(null);
        binding.setUploads(null);
        const fake = createFakeBiStream();
        const result = made.handler(open(kc, PEER, PROJECT, crypto.randomUUID(), fake.stream));
        expect(result).toEqual({ code: "NOT_ALLOWED", message: kc.kind === "upload" ? "uploads not available" : "tunnels not available" });
      });

      test(`${kc.kind}: a refusal after admission is one stream:refused record, then FIN, and nothing else`, async () => {
        const made = kc.make();
        const binding = made.registerProject(PROJECT);
        const refusal = { code: "NOT_ALLOWED" as const, message: "checkout is gone" };
        const refusing = { admit: () => ({ ok: false as const, refusal }) };
        binding.setTunnels(refusing as never);
        binding.setUploads(refusing as never);
        const id = crypto.randomUUID();
        const fake = createFakeBiStream();
        expect(made.handler(open(kc, PEER, PROJECT, id, fake.stream))).toBeUndefined();
        made.pushFirstTraffic(fake, id);
        await flush(5);
        expect(refusalOf(fake)).toMatchObject(refusal);
        expect(fake.records()).toHaveLength(1);
        expect(fake.isFinished()).toBe(true);
        expect(made.retired).toEqual([]);
      });
    }

    test(`${kc.kind}: the (cap+1)th stream is CAP_EXCEEDED before any read, and ending one frees a slot for one more`, () => {
      const made = kc.make();
      made.registerProject(PROJECT);
      const fakes: FakeBiStream[] = [];
      for (let i = 0; i < kc.cap; i++) {
        const fake = createFakeBiStream();
        fakes.push(fake);
        expect(made.handler(open(kc, PEER, PROJECT, crypto.randomUUID(), fake.stream))).toBeUndefined();
      }
      expect(made.count(PEER)).toBe(kc.cap);
      const overCap = createFakeBiStream();
      const result = made.handler(open(kc, PEER, PROJECT, crypto.randomUUID(), overCap.stream));
      expect(result?.code).toBe("CAP_EXCEEDED");
      expect(overCap.readExactSizes).toEqual([]); // never read

      fakes[0]!.endWith();
      return flush().then(() => {
        expect(made.count(PEER)).toBe(kc.cap - 1);
        const oneMore = createFakeBiStream();
        expect(made.handler(open(kc, PEER, PROJECT, crypto.randomUUID(), oneMore.stream))).toBeUndefined();
      });
    });

    test(`${kc.kind}: setPriority is called exactly once, with this kind's own priority, before the first write`, async () => {
      const made = kc.make();
      made.registerProject(PROJECT);
      const id = crypto.randomUUID();
      const fake = createFakeBiStream();
      expect(made.handler(open(kc, PEER, PROJECT, id, fake.stream))).toBeUndefined();
      made.pushFirstTraffic(fake, id);
      await made.driveOneWrite(PEER, id, fake);
      await flush();
      expect(fake.order[0]).toBe("setPriority");
      expect(fake.priorities).toEqual([kc.priority]);
    });

    test(`${kc.kind}: a record read while the peer is no longer authorized retires the connection and never reaches the binding`, async () => {
      const made = kc.make();
      made.registerProject(PROJECT);
      const id = crypto.randomUUID();
      const fake = createFakeBiStream();
      let authorized = true;
      expect(made.handler(open(kc, PEER, PROJECT, id, fake.stream, () => authorized))).toBeUndefined();
      authorized = false;
      made.pushFirstTraffic(fake, id);
      await flush(5);
      expect(made.retired).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
      expect(made.reached()).toBe(0);
      expect(fake.records()).toEqual([]); // nothing was ever written back
    });

    test(`${kc.kind}: a write while the peer is no longer authorized writes nothing and retires the connection`, async () => {
      const made = kc.make();
      made.registerProject(PROJECT);
      const id = crypto.randomUUID();
      const fake = createFakeBiStream();
      let authorized = true;
      let writtenAtRevoke = -1;
      made.setBeforeWrite(() => {
        authorized = false;
        writtenAtRevoke = fake.records().length + fake.rawWritten().length;
      });
      expect(made.handler(open(kc, PEER, PROJECT, id, fake.stream, () => authorized))).toBeUndefined();
      made.pushFirstTraffic(fake, id);
      await made.driveOneWrite(PEER, id, fake).catch(() => {});
      await flush(5);
      expect(writtenAtRevoke).toBeGreaterThanOrEqual(0);
      expect(fake.records().length + fake.rawWritten().length).toBe(writtenAtRevoke);
      expect(made.retired).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
    });

    if (kc.make().pushLaterTraffic) {
      test(`${kc.kind}: a later record read after authorization is revoked retires the connection and reaches nothing`, async () => {
        const made = kc.make();
        made.registerProject(PROJECT);
        const id = crypto.randomUUID();
        const fake = createFakeBiStream();
        let authorized = true;
        expect(made.handler(open(kc, PEER, PROJECT, id, fake.stream, () => authorized))).toBeUndefined();
        // A 0-byte upload's first traffic is its FIN, which would end the
        // body loop; admission alone is what puts it into the loop.
        if (kc.kind !== "upload") made.pushFirstTraffic(fake, id);
        await flush(5);
        expect(made.retired).toEqual([]);
        const reachedBefore = made.reached();
        authorized = false;
        made.pushLaterTraffic!(fake, id);
        await flush(5);
        expect(made.retired).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
        expect(made.reached()).toBe(reachedBefore);
      });
    }

    test(`${kc.kind}: a non-fatal write failure resets only that stream, not the connection; a sibling stream on the same peer still writes`, async () => {
      const made = kc.make();
      made.registerProject(PROJECT);
      const idA = crypto.randomUUID();
      const idB = crypto.randomUUID();
      const fakeA = createFakeBiStream();
      const fakeB = createFakeBiStream();
      expect(made.handler(open(kc, PEER, PROJECT, idA, fakeA.stream))).toBeUndefined();
      expect(made.handler(open(kc, PEER, PROJECT, idB, fakeB.stream))).toBeUndefined();

      fakeA.failNextWrite();
      made.pushFirstTraffic(fakeA, idA);
      await made.driveOneWrite(PEER, idA, fakeA).catch(() => {});
      await flush(5);
      expect(fakeA.resets).toEqual([kc.resetCode]);
      expect(made.retired).toEqual([]); // stream-scoped, not connection-fatal

      made.pushFirstTraffic(fakeB, idB);
      await made.driveOneWrite(PEER, idB, fakeB);
      await flush();
      expect(fakeB.records().length + fakeB.rawWritten().length).toBeGreaterThan(0); // B still got through
    });

    if (kc.kind !== "terminal") {
      test(`${kc.kind}: mayDeliverTo false on send drops it — nothing is written, and the binding ends`, async () => {
        const made = kc.make();
        const binding = made.registerProject(PROJECT);
        const id = crypto.randomUUID();
        const fake = createFakeBiStream();
        expect(made.handler(open(kc, PEER, PROJECT, id, fake.stream))).toBeUndefined();
        binding.setMayDeliver(false);
        made.pushFirstTraffic(fake, id);
        await made.driveOneWrite(PEER, id, fake);
        await flush();
        expect(fake.records()).toEqual([]);
        expect(made.count(PEER)).toBe(0);
      });
    }

    test(`${kc.kind}: the app ending before any traffic frees the slot with no crash and no dangling read`, async () => {
      const made = kc.make();
      made.registerProject(PROJECT);
      const id = crypto.randomUUID();
      const fake = createFakeBiStream();
      expect(made.handler(open(kc, PEER, PROJECT, id, fake.stream))).toBeUndefined();
      fake.endWith();
      await flush(5);
      expect(made.count(PEER)).toBe(0);
      expect(fake.pendingReads()).toBe(0);
    });

    test(`${kc.kind}: projectDetached ends every binding for that project, and leaves another project's binding untouched`, async () => {
      const made = kc.make();
      made.registerProject(PROJECT);
      made.registerProject("other-project");
      const fakeA = createFakeBiStream();
      const fakeB = createFakeBiStream();
      expect(made.handler(open(kc, PEER, PROJECT, crypto.randomUUID(), fakeA.stream))).toBeUndefined();
      expect(made.handler(open(kc, "peer2", "other-project", crypto.randomUUID(), fakeB.stream))).toBeUndefined();
      made.detach(PROJECT);
      await flush();
      expect(made.count(PEER)).toBe(0);
      expect(made.count("peer2")).toBe(1);
    });

    test(`${kc.kind}: dropPeer unbinds that peer's bindings without calling retirePeer`, async () => {
      const made = kc.make();
      made.registerProject(PROJECT);
      const fake = createFakeBiStream();
      expect(made.handler(open(kc, PEER, PROJECT, crypto.randomUUID(), fake.stream))).toBeUndefined();
      made.drop(PEER);
      await flush();
      expect(made.count(PEER)).toBe(0);
      expect(made.retired).toEqual([]);
    });

    test(`${kc.kind}: the project's own hasOpenStream gate is read only at admission — closing it afterward does not unbind an already-open stream`, () => {
      const made = kc.make();
      const binding = made.registerProject(PROJECT);
      const fake = createFakeBiStream();
      expect(made.handler(open(kc, PEER, PROJECT, crypto.randomUUID(), fake.stream))).toBeUndefined();
      binding.setHasOpenStream(PEER, false); // simulates the peer's project stream closing
      expect(made.count(PEER)).toBe(1); // this stream is untouched
    });
  }

  test("oversize inbound record: the terminal kind's own overlong length prefix retires the connection as a protocol violation", async () => {
    const kc = SCOPED_KINDS.find((k) => k.kind === "terminal")!;
    const made = kc.make();
    made.registerProject(PROJECT);
    const id = crypto.randomUUID();
    const fake = createFakeBiStream();
    expect(made.handler(open(kc, PEER, PROJECT, id, fake.stream))).toBeUndefined();
    fake.pushOverlongPrefix(STREAM_TERMINAL_APP_RECORD_MAX_BYTES + 1);
    await flush(5);
    expect(made.retired).toEqual([{ peerId: PEER, reason: "protocol-violation" }]);
  });

  test("tunnel-http and tunnel-ws share one cap and one bindings index on the same registry instance", async () => {
    const cataloged = new Set([PROJECT]);
    const binding = createFakeProjectBinding();
    binding.setTunnels({ admit: () => ({ ok: true as const, manager: {} as TunnelManager }) });
    const registry = new TunnelStreamRegistry({
      projectCataloged: (id) => cataloged.has(id),
      projectBinding: () => binding,
      retirePeer: () => {},
    });
    const httpFake = createFakeBiStream();
    const wsFake = createFakeBiStream();
    expect(registry.handlerFor("tunnel-http")({
      peerId: PEER, stream: httpFake.stream, authorized: () => true,
      open: { kind: "tunnel-http", projectId: PROJECT, requestId: crypto.randomUUID() },
    })).toBeUndefined();
    expect(registry.streamCount(PEER)).toBe(1);
    expect(registry.handlerFor("tunnel-ws")({
      peerId: PEER, stream: wsFake.stream, authorized: () => true,
      open: { kind: "tunnel-ws", projectId: PROJECT, wsId: crypto.randomUUID() },
    })).toBeUndefined();
    expect(registry.streamCount(PEER)).toBe(2); // shared count across both kinds
  });
});

// ============================================================================
// 3. `ProjectStreamRegistry`'s own admission — a structurally different
//    registry (it IS the binding the four kinds above look up), proving the
//    same invariants through its own gate and its own knobs.
// ============================================================================

function makeProjectRegistry(overrides: Partial<ProjectStreamRegistryOptions> = {}) {
  const cataloged = new Set<string>();
  const retired: Array<{ peerId: string; reason: string }> = [];
  let remoteAccessEnabled = true;
  const opts: ProjectStreamRegistryOptions = {
    remoteAccessEnabled: () => remoteAccessEnabled,
    projectCataloged: (id) => cataloged.has(id),
    peerSession: (peerId) => ({ peerId, peerPubkey: `pub-${peerId}` }),
    sendSessionMessage: () => {},
    retirePeer: (peerId, reason) => retired.push({ peerId, reason }),
    ...overrides,
  };
  const registry = new ProjectStreamRegistry(opts);
  return {
    registry, cataloged, retired,
    setRemoteAccessEnabled: (v: boolean) => { remoteAccessEnabled = v; },
  };
}

function openProject(peerId: string, projectId: string, stream: AcceptedBiStream, authorized: () => boolean = () => true) {
  return { peerId, open: { kind: "project" as const, projectId }, stream, authorized };
}

describe("ProjectStreamRegistry: own admission gate, same invariants as the scoped kinds", () => {
  test("an unsafe project id is refused NOT_ALLOWED even when remote access is on and the project is attached", () => {
    const { registry } = makeProjectRegistry();
    registry.attach(new MessageBus(), { projectId: "../evil" });
    const fake = createFakeBiStream();
    expect(registry.handler(openProject(PEER, "../evil", fake.stream))).toEqual({ code: "NOT_ALLOWED", message: "unsafe project id" });
  });

  test("remote access disabled refuses NOT_ALLOWED even for a catalogued, attached project", () => {
    const { registry, cataloged, setRemoteAccessEnabled } = makeProjectRegistry();
    cataloged.add(PROJECT);
    setRemoteAccessEnabled(false);
    registry.attach(new MessageBus(), { projectId: PROJECT });
    const fake = createFakeBiStream();
    expect(registry.handler(openProject(PEER, PROJECT, fake.stream)))
      .toEqual({ code: "NOT_ALLOWED", message: "mobile access is disabled on this machine" });
  });

  test("an uncatalogued project is refused NOT_ALLOWED (fail closed)", () => {
    const { registry } = makeProjectRegistry();
    registry.attach(new MessageBus(), { projectId: PROJECT });
    const fake = createFakeBiStream();
    expect(registry.handler(openProject(PEER, PROJECT, fake.stream)))
      .toEqual({ code: "NOT_ALLOWED", message: "project not recognized" });
  });

  test("no attach() yet for this project is NOT_READY", () => {
    const { registry, cataloged } = makeProjectRegistry();
    cataloged.add(PROJECT);
    const fake = createFakeBiStream();
    expect(registry.handler(openProject(PEER, PROJECT, fake.stream)))
      .toEqual({ code: "NOT_READY", message: "project is not ready; wait for stream-ready" });
  });

  test("the attached entry's own mayDeliver false refuses NOT_ALLOWED", () => {
    const { registry, cataloged } = makeProjectRegistry();
    cataloged.add(PROJECT);
    registry.attach(new MessageBus(), { projectId: PROJECT, mayDeliver: () => false });
    const fake = createFakeBiStream();
    expect(registry.handler(openProject(PEER, PROJECT, fake.stream)))
      .toEqual({ code: "NOT_ALLOWED", message: "mobile access is disabled on this machine" });
  });

  test("the entry's own mayAcceptFrom refusal is masked to NOT_ALLOWED", () => {
    const { registry, cataloged } = makeProjectRegistry();
    cataloged.add(PROJECT);
    registry.attach(new MessageBus(), {
      projectId: PROJECT,
      mayAcceptFrom: () => ({ code: "CAP_EXCEEDED", message: "checkout is being deleted" }),
    });
    const fake = createFakeBiStream();
    expect(registry.handler(openProject(PEER, PROJECT, fake.stream)))
      .toEqual({ code: "NOT_ALLOWED", message: "checkout is being deleted" });
  });

  test("a duplicate (peer, project) open is refused INVALID", () => {
    const { registry, cataloged } = makeProjectRegistry();
    cataloged.add(PROJECT);
    registry.attach(new MessageBus(), { projectId: PROJECT });
    const first = createFakeBiStream();
    expect(registry.handler(openProject(PEER, PROJECT, first.stream))).toBeUndefined();
    const second = createFakeBiStream();
    expect(registry.handler(openProject(PEER, PROJECT, second.stream))).toEqual({ code: "INVALID", message: "project stream already open" });
  });

  test("the (cap+1)th project stream is CAP_EXCEEDED; ending one frees a slot for one more", async () => {
    const { registry, cataloged } = makeProjectRegistry();
    const projectIds: string[] = [];
    for (let i = 0; i < 33; i++) {
      const id = `p${i}`;
      projectIds.push(id);
      cataloged.add(id);
      registry.attach(new MessageBus(), { projectId: id });
    }
    const fakes: FakeBiStream[] = [];
    for (let i = 0; i < 32; i++) {
      const fake = createFakeBiStream();
      fakes.push(fake);
      expect(registry.handler(openProject(PEER, projectIds[i]!, fake.stream))).toBeUndefined();
    }
    const overCap = createFakeBiStream();
    const overCapResult = registry.handler(openProject(PEER, projectIds[32]!, overCap.stream)) as StreamRefusal | undefined;
    expect(overCapResult?.code).toBe("CAP_EXCEEDED");

    fakes[0]!.endWith();
    await flush();
    const oneMore = createFakeBiStream();
    expect(registry.handler(openProject(PEER, projectIds[32]!, oneMore.stream))).toBeUndefined();
  });

  test("admission's own first write (stream-ready) sets priority exactly once", async () => {
    const { registry, cataloged } = makeProjectRegistry();
    cataloged.add(PROJECT);
    registry.attach(new MessageBus(), { projectId: PROJECT });
    const fake = createFakeBiStream();
    expect(registry.handler(openProject(PEER, PROJECT, fake.stream))).toBeUndefined();
    await flush();
    expect(fake.order[0]).toBe("setPriority");
    expect(fake.priorities.length).toBe(1);
    expect(JSON.parse(fake.firstRecord()!)).toMatchObject({ type: "stream-ready", projectId: PROJECT });
  });

  test("a record read while the peer is no longer authorized retires the connection", async () => {
    const { registry, cataloged, retired } = makeProjectRegistry();
    cataloged.add(PROJECT);
    registry.attach(new MessageBus(), { projectId: PROJECT });
    const fake = createFakeBiStream();
    let authorized = true;
    expect(registry.handler(openProject(PEER, PROJECT, fake.stream, () => authorized))).toBeUndefined();
    await flush(); // let admission's own stream-ready write settle first
    authorized = false;
    fake.pushRecord(createMessage("pong", {}));
    await flush(5);
    expect(retired).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
  });

  test("a send while the peer is no longer authorized writes nothing and retires the connection", async () => {
    const { registry, cataloged, retired } = makeProjectRegistry();
    cataloged.add(PROJECT);
    const handle = registry.attach(new MessageBus(), { projectId: PROJECT });
    const fake = createFakeBiStream();
    let authorized = true;
    expect(registry.handler(openProject(PEER, PROJECT, fake.stream, () => authorized))).toBeUndefined();
    await flush();
    expect(fake.records()).toHaveLength(1); // stream-ready
    authorized = false;
    await handle.sendTo(createMessage("pong", {}), "control", { kind: "peer", peerId: PEER }).catch(() => {});
    await flush(5);
    expect(fake.records()).toHaveLength(1);
    expect(retired).toEqual([{ peerId: PEER, reason: "unauthorized" }]);
  });

  test("an open from a peer with no session view is refused by the project's own acceptance hook, masked to NOT_ALLOWED", () => {
    const { registry, cataloged } = makeProjectRegistry({ peerSession: () => null });
    cataloged.add(PROJECT);
    registry.attach(new MessageBus(), {
      projectId: PROJECT,
      mayAcceptFrom: (peer) => (peer ? null : { code: "INVALID", message: "unknown peer" }),
    });
    const fake = createFakeBiStream();
    expect(registry.handler(openProject(PEER, PROJECT, fake.stream)))
      .toEqual({ code: "NOT_ALLOWED", message: "unknown peer" });
  });

  test("an overlong inbound length prefix retires the connection as a protocol violation", async () => {
    const { registry, cataloged, retired } = makeProjectRegistry();
    cataloged.add(PROJECT);
    registry.attach(new MessageBus(), { projectId: PROJECT });
    const fake = createFakeBiStream();
    expect(registry.handler(openProject(PEER, PROJECT, fake.stream))).toBeUndefined();
    fake.pushOverlongPrefix(STREAM_PROJECT_APP_RECORD_MAX_BYTES + 1);
    await flush(5);
    expect(retired).toEqual([{ peerId: PEER, reason: "protocol-violation" }]);
  });

  test("a write failure resets only that stream, not the connection; a sibling peer's stream on the same project still lives", async () => {
    const { registry, cataloged, retired } = makeProjectRegistry();
    cataloged.add(PROJECT);
    registry.attach(new MessageBus(), { projectId: PROJECT });
    const fakeA = createFakeBiStream();
    fakeA.failNextWrite(); // fails the admission's own stream-ready write
    expect(registry.handler(openProject(PEER, PROJECT, fakeA.stream))).toBeUndefined();
    await flush();
    expect(fakeA.resets).toEqual([STREAM_RESET_PROJECT]);
    expect(retired).toEqual([]);

    const fakeB = createFakeBiStream();
    expect(registry.handler(openProject("peer2", PROJECT, fakeB.stream))).toBeUndefined();
    await flush();
    expect(fakeB.records().length).toBe(1); // peer2's own stream-ready landed fine
  });

  test("dropPeer unbinds that peer's bindings without calling retirePeer", async () => {
    const { registry, cataloged, retired } = makeProjectRegistry();
    cataloged.add(PROJECT);
    registry.attach(new MessageBus(), { projectId: PROJECT });
    const fake = createFakeBiStream();
    expect(registry.handler(openProject(PEER, PROJECT, fake.stream))).toBeUndefined();
    registry.dropPeer(PEER);
    await flush();
    expect(registry.openStreamCount(PEER)).toBe(0);
    expect(retired).toEqual([]);
  });
});
