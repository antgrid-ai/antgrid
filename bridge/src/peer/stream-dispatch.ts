/**
 * Admission for every native bidi stream after the session stream. The session
 * stream itself never reaches this file — `native-host-connection.ts` reads
 * its open frame and hands the stream straight to a `StreamRecordWriter` /
 * `StreamRecordReader` pair before this acceptor's loop starts.
 *
 * An unknown or not-yet-registered `kind` is refused `NOT_ALLOWED`; project,
 * terminal and tunnel handlers plug into the same `handlers` table without
 * touching admission order.
 *
 * `ScopedStreamRegistry` below is the shared admission path for every
 * project-scoped kind (terminal, tunnel-http, tunnel-ws, upload): the per-peer
 * cap, the safe-id/catalog checks, the project's own binding lookup and its
 * per-sender gate, duplicate-id detection, teardown and the writer-failure
 * mapping all live once here. A kind supplies only its cap/priority/reset
 * constants, its own id field, and the body that runs once admitted.
 */

import {
  decodeStreamOpen,
  encodeStreamRefused,
  STREAM_MAX_PENDING_OPENS_PER_PEER,
  STREAM_OPEN_MAX_BYTES,
  type StreamOpen,
  type StreamOpenKind,
  type StreamRefused,
  type StreamRefusedCode,
} from "antgrid-wire";
import { isSafeProjectId } from "../project-id";
import { StreamRecordWriter, stopRecvWhenSettled, type RawStreamRecv, type StreamRecv, type StreamSend, type StreamWriteFailure } from "./stream-records";
import type { NetwatchStreamKind } from "../netwatch";

export const STREAM_OPEN_DEADLINE_MS = 5_000;
// Reset/stop codes are bridge diagnostics only — the Dart binding exposes no
// way to read them back, so their values are never asserted on
// the wire, only in bridge-side tests and logs.
export const STREAM_STOP_REFUSED = 0x10n;
export const STREAM_RESET_OPEN_TIMEOUT = 0x11n;
export const STREAM_RESET_REFUSED = 0x12n;
export const STREAM_REFUSAL_MAX_QUEUED_BYTES = 8_192;

/** Structural subset of `@number0/iroh` `BiStream`; the real one satisfies it. */
export interface AcceptedBiStream {
  send: StreamSend;
  recv: RawStreamRecv & { stop(errorCode: bigint): Promise<void> };
}

export type StreamOpenRead =
  | { ok: true; open: StreamOpen }
  | { ok: false; reason: "oversize" | "invalid" };

/**
 * Exactly one `readExact(4)` for the length prefix, then (unless the prefix
 * is short, zero, or oversize) exactly one `readExact(length)` for the body.
 * Never throws on a malformed frame — that must be refusable, not connection
 * fatal — but a native `readExact` rejection (peer FIN/reset, connection
 * gone) propagates as-is; callers wrap this in their own deadline.
 */
export async function readStreamOpen(recv: StreamRecv): Promise<StreamOpenRead> {
  const prefix = await recv.readExact(4);
  if (prefix.length !== 4) return { ok: false, reason: "invalid" };
  const length = Buffer.from(prefix).readUInt32BE();
  if (length === 0) return { ok: false, reason: "invalid" };
  if (length > STREAM_OPEN_MAX_BYTES) return { ok: false, reason: "oversize" };
  const body = await recv.readExact(length);
  if (body.length !== length) return { ok: false, reason: "invalid" };
  const open = decodeStreamOpen(Uint8Array.from(body));
  if (open === null) return { ok: false, reason: "invalid" };
  return { ok: true, open };
}

export interface StreamRefusal {
  code: StreamRefusedCode;
  message: string;
}

/**
 * Fire-and-forget: the caller never awaits this. It is only ever called
 * before any read is outstanding on `stream.recv`, so `stop()` cannot queue
 * behind the binding's per-stream recv mutex.
 */
export function refuseStream(stream: AcceptedBiStream, refusal: StreamRefusal,
  authorized: () => boolean, onUnauthorized: () => void): void {
  const writer = new StreamRecordWriter(stream, authorized, (reason) => {
    if (reason === "unauthorized") onUnauthorized();
  }, STREAM_REFUSAL_MAX_QUEUED_BYTES, 0, STREAM_RESET_REFUSED);
  const record: StreamRefused = { type: "stream:refused", code: refusal.code, message: refusal.message };
  void writer.send(encodeStreamRefused(record));
  void writer.finish().then(() => {
    stream.recv.stop(STREAM_STOP_REFUSED).catch(() => {});
  });
}

export interface StreamAdmission<O extends StreamOpen = StreamOpen> {
  peerId: string;
  open: O;
  stream: AcceptedBiStream;
  authorized: () => boolean;
}

/** A handler owns the stream when it returns `undefined`. A returned refusal
 *  is written in-band by the acceptor; a throwing handler is refused
 *  `NOT_ALLOWED`. */
export type StreamHandler<O extends StreamOpen> =
  (admission: StreamAdmission<O>) => StreamRefusal | undefined | Promise<StreamRefusal | undefined>;

export type StreamHandlers = {
  [K in Exclude<StreamOpenKind, "session">]?: StreamHandler<Extract<StreamOpen, { kind: K }>>;
};

export type StreamDiagnosticType = "peer:stream-refused" | "peer:stream-open-timeout";

/** The stream a refused open named, for `NetwatchEvent.streamKind`/`streamId`:
 *  the same label the registry that would have owned it tags its own records
 *  with, so a refusal files under the stream it refused. */
export interface StreamDiagnosticLabel {
  kind: StreamOpenKind;
  /** Unset for a `session` open here: a second session stream is a protocol
   *  error, and labelling it `"0"` would file it under the live one. */
  id?: string;
}

export function streamLabelOf(open: StreamOpen): StreamDiagnosticLabel {
  switch (open.kind) {
    case "session": return { kind: open.kind };
    case "project": return { kind: open.kind, id: open.projectId };
    case "terminal": return { kind: open.kind, id: open.requestId };
    case "tunnel-http": return { kind: open.kind, id: open.requestId };
    case "tunnel-ws": return { kind: open.kind, id: open.wsId };
    case "upload": return { kind: open.kind, id: open.requestId };
  }
}

// ---------------------------------------------------------------------------
// Shared timer/deadline plumbing. One copy for the acceptor's own open-frame
// deadline and for every project-scoped kind's own head/record deadlines.
// ---------------------------------------------------------------------------

export type Schedule = (callback: () => void, ms: number) => () => void;

export const defaultSchedule: Schedule = (callback, ms) => {
  const timer = setTimeout(callback, ms);
  timer.unref?.();
  return () => clearTimeout(timer);
};

/** Resolved by `raceDeadline` when `ms` elapses before `read` settles. */
export const STREAM_DEADLINE: unique symbol = Symbol("stream-deadline");

/**
 * Races `read` against `ms`; resolves `STREAM_DEADLINE` on timeout, or
 * settles (resolve/reject) exactly as `read` does otherwise. Never cancels
 * `read` itself — a caller that must stop the receive half on timeout awaits
 * `read`'s own eventual settlement first (the binding mutex:
 * stream-records.ts's per-stream lock), never calls `stop()` while it is
 * still outstanding.
 */
export function raceDeadline<T>(read: Promise<T>, ms: number, schedule: Schedule): Promise<T | typeof STREAM_DEADLINE> {
  let settled = false;
  return new Promise<T | typeof STREAM_DEADLINE>((resolve, reject) => {
    const cancelTimer = schedule(() => {
      if (settled) return;
      settled = true;
      resolve(STREAM_DEADLINE);
    }, ms);
    read.then(
      (value) => { if (settled) return; settled = true; cancelTimer(); resolve(value); },
      (error) => { if (settled) return; settled = true; cancelTimer(); reject(error); },
    );
  });
}

export type StreamDiagnostic =
  (type: string, detail: Record<string, unknown>, stream?: { kind: NetwatchStreamKind; id: string }) => void;

/** Retires the whole connection. Only ever called with "unauthorized" (a
 *  writer, or a per-record `authorized()` recheck) or "protocol-violation"
 *  (a malformed length prefix from `StreamRecordReader`). */
export type RetirePeer = (peerId: string, reason: "unauthorized" | "protocol-violation") => void;

export interface PeerStreamAcceptorOptions {
  connection: { acceptBi(): Promise<AcceptedBiStream> };
  peerId: string;
  /** This connection still owns `peerId` and is not retired. */
  isCurrent: () => boolean;
  /** `NativePeerSessions.authorized(peerId, endpointId)`. */
  authorized: () => boolean;
  /** `this.sessions.has(peerId)`. */
  established: () => boolean;
  /** `retirePeer(peerId, "unauthorized")` if still current. */
  onUnauthorized: () => void;
  /** Omit or pass `{}` when no non-session stream kind is registered yet —
   *  every such open is then refused `NOT_ALLOWED`. */
  handlers?: StreamHandlers;
  schedule?: Schedule;
  /** `stream` is set only for a refusal whose open frame parsed; a timeout or
   *  an unparseable open names no stream. */
  diagnostic?: (type: StreamDiagnosticType,
    detail: { code?: StreamRefusedCode; kind?: string; pending: number },
    stream?: StreamDiagnosticLabel) => void;
  /** Default `STREAM_MAX_PENDING_OPENS_PER_PEER`; tests may lower it. */
  maxPendingOpens?: number;
}

const DEFAULT_REFUSAL_MESSAGE: Record<StreamRefusedCode, string> = {
  NOT_READY: "session not established yet",
  NOT_ALLOWED: "stream kind not allowed",
  CAP_EXCEEDED: "too many pending stream opens",
  INVALID: "invalid stream open frame",
};

/**
 * Admits every non-session bidi stream on one native connection. One `admit`
 * task per accepted stream — the accept loop never awaits it, so stream N+1
 * is never blocked behind stream N's open-frame read.
 */
export class PeerStreamAcceptor {
  private stopped = false;
  private pending = 0;

  constructor(private readonly options: PeerStreamAcceptorOptions) {}

  get pendingOpens(): number {
    return this.pending;
  }

  start(): void {
    void this.loop();
  }

  /** Idempotent. In-flight admissions drop without writing once this fires. */
  stop(): void {
    this.stopped = true;
  }

  private async loop(): Promise<void> {
    while (!this.stopped && this.options.isCurrent()) {
      let stream: AcceptedBiStream;
      try {
        stream = await this.options.connection.acceptBi();
      } catch {
        return;
      }
      void this.admit(stream);
    }
  }

  private async admit(stream: AcceptedBiStream): Promise<void> {
    const { authorized, onUnauthorized, isCurrent, established, peerId } = this.options;
    const handlers = this.options.handlers ?? {};
    const diagnostic = this.options.diagnostic;
    const schedule = this.options.schedule ?? defaultSchedule;
    const maxPendingOpens = this.options.maxPendingOpens ?? STREAM_MAX_PENDING_OPENS_PER_PEER;

    if (this.stopped || !isCurrent()) return;
    if (this.pending >= maxPendingOpens) {
      this.refuse(stream, "CAP_EXCEEDED", undefined, diagnostic);
      return;
    }
    this.pending++;

    const readPromise = readStreamOpen(stream.recv);
    const outcome = await raceDeadline(readPromise, STREAM_OPEN_DEADLINE_MS, schedule).catch(() => "read-failed" as const);
    this.pending--;

    if (outcome === STREAM_DEADLINE) {
      // The read is still pending and holds the recv mutex — `recv.stop`
      // would queue behind it, so only the send half is reset now. Once a late
      // read settles the mutex is free, and stopping then is what keeps a
      // peer that answers after the deadline from parking data on a stream
      // nothing will ever read again.
      stream.send.reset(STREAM_RESET_OPEN_TIMEOUT).catch(() => {});
      readPromise.then(() => { stream.recv.stop(STREAM_STOP_REFUSED).catch(() => {}); }, () => {});
      diagnostic?.("peer:stream-open-timeout", { pending: this.pending });
      return;
    }
    if (outcome === "read-failed") return;
    const opened = outcome;

    if (this.stopped || !isCurrent()) return;
    if (!authorized()) { onUnauthorized(); return; }
    if (!opened.ok) { this.refuse(stream, "INVALID", undefined, diagnostic); return; }
    if (opened.open.kind === "session") { this.refuse(stream, "INVALID", opened.open, diagnostic); return; }
    const open = opened.open;
    if (!established()) { this.refuse(stream, "NOT_READY", open, diagnostic); return; }
    const handler = handlers[open.kind as Exclude<StreamOpenKind, "session">] as
      StreamHandler<typeof open> | undefined;
    if (!handler) { this.refuse(stream, "NOT_ALLOWED", open, diagnostic); return; }
    let result: StreamRefusal | undefined;
    try {
      result = await handler({ peerId, open, stream, authorized });
    } catch {
      this.refuse(stream, "NOT_ALLOWED", open, diagnostic);
      return;
    }
    if (this.stopped) return;
    if (result) this.refuse(stream, result.code, open, diagnostic, result.message);
  }

  private refuse(stream: AcceptedBiStream, code: StreamRefusedCode, open: StreamOpen | undefined,
    diagnostic: PeerStreamAcceptorOptions["diagnostic"], message: string = DEFAULT_REFUSAL_MESSAGE[code]): void {
    diagnostic?.("peer:stream-refused", { code, kind: open?.kind, pending: this.pending },
      open ? streamLabelOf(open) : undefined);
    refuseStream(stream, { code, message }, this.options.authorized, this.options.onUnauthorized);
  }
}

// ---------------------------------------------------------------------------
// Generic admission for every project-scoped kind (terminal, tunnel-http,
// tunnel-ws, upload). See `bridge/CLAUDE.md`'s project-streams.ts entry for
// what a "project's binding" means; this is the consumer side of it.
// ---------------------------------------------------------------------------

/** The slice of a project's stream binding every project-scoped kind's
 *  admission reads. Pure lookup — never opens or promotes a core. */
export interface ScopedProjectBinding {
  hasOpenStream(peerId: string): boolean;
  /** Any code this returns is masked to `NOT_ALLOWED` by the admission gate:
   *  the reason a sender is refused is not the app's business past that. */
  refusalFor(peerId: string): StreamRefusal | undefined;
}

/** A project-scoped kind's fixed constants — cap, priority and the reset/stop
 *  codes its writer uses. Every value must be a named constant from
 *  antgrid-wire (the cap) or the kind's own file (the rest), never a literal
 *  inlined here. */
export interface ScopedStreamSpec {
  readonly kinds: readonly ("terminal" | "tunnel-http" | "tunnel-ws" | "upload")[];
  readonly cap: number;
  readonly capMessage: string;
  readonly priority: number;
  readonly resetCode: bigint;
  readonly stopCode: bigint;
  readonly maxQueuedBytes: number;
}

export interface ScopedStreamOptions<P extends ScopedProjectBinding> {
  /** host-server `seenProjects.has`. Absent => every open refused NOT_ALLOWED (fail closed). */
  projectCataloged?: (projectId: string) => boolean;
  /** `ProjectStreamRegistry.projectBinding`. Lookup only: never opens or promotes a core. */
  projectBinding: (projectId: string) => P | null;
  retirePeer: RetirePeer;
  diagnostic?: StreamDiagnostic;
  schedule?: Schedule;
}

/** The fields every project-scoped binding carries; a kind's own binding type
 *  extends this with whatever is genuinely its own (a reader, sub-kind
 *  fields, in-flight state). */
export interface ScopedBinding<P extends ScopedProjectBinding = ScopedProjectBinding> {
  readonly peerId: string;
  readonly kind: ScopedStreamSpec["kinds"][number];
  /** requestId / wsId: duplicate key within (peerId, kind). */
  readonly id: string;
  readonly projectId: string;
  readonly stream: AcceptedBiStream;
  readonly writer: StreamRecordWriter;
  readonly project: P;
  /** The admission's own authorization check, re-read on every inbound
   *  record — the mirror of the outbound check the writer already runs on
   *  every send. */
  readonly authorized: () => boolean;
  /** Removed from every index and its cap slot freed. The staleness guard
   *  every async step checks: once unbound, nothing may act on this binding
   *  again — which is what keeps a lagging callback from a torn-down stream
   *  reaching into whatever now reuses the same peerId or id. */
  unbound: boolean;
  /** The read currently outstanding on `recv`, if the kind's body tracks one
   *  (it must, to keep `end()` from stopping the receive half while a read
   *  still holds the shared per-stream mutex — stream-records.ts's binding
   *  constraints). `null` when nothing is outstanding. */
  pendingRead: Promise<unknown> | null;
}

export const READ_ENDED: unique symbol = Symbol("read-ended");
export const READ_UNBOUND: unique symbol = Symbol("read-unbound");

export type ScopedEndCause = "app-ended" | "overflow" | "stream-lost" | "detached" | "peer-dropped" | "breach";

/** `stream.priority`/`resetCode`/`maxQueuedBytes` in one call, shared by every
 *  scoped kind and by `project-streams.ts` (which does not extend
 *  {@link ScopedStreamRegistry} — the project kind's own admission is not
 *  gated on an open project stream — but reuses this to build its writer). */
export function openScopedWriter(
  stream: AcceptedBiStream,
  authorized: () => boolean,
  spec: Pick<ScopedStreamSpec, "priority" | "resetCode" | "maxQueuedBytes">,
  onFailure: (failure: StreamWriteFailure) => void,
): StreamRecordWriter {
  return new StreamRecordWriter(stream, authorized, onFailure, spec.maxQueuedBytes, spec.priority, spec.resetCode);
}

/**
 * The shared admission path for a project-scoped stream kind. Registers one
 * `StreamHandler` per kind (`handlerFor`) into `PeerStreamAcceptor`'s handler
 * table; `native-host-connection.ts` wires terminal, tunnel-http, tunnel-ws
 * and upload through one instance each (tunnel-http and tunnel-ws share ONE
 * `TunnelStreamRegistry` instance and its cap).
 *
 * `handlerFor`'s admission order (every step before any read from the
 * stream): the per-peer cap; the kind's own open-frame validation; the safe-id
 * and catalog checks (root CLAUDE.md's "seenProjects + isSafeProjectId are the
 * only bound" invariant); the project's binding (`NOT_READY` while it has no
 * live entry — a lookup only, never opening or promoting a core); an open
 * project stream for this peer (the single per-peer admission point for a
 * projectId); the project's own per-sender gate; a duplicate (peerId, kind,
 * id); the kind's own availability check (its server disabled/absent).
 */
export abstract class ScopedStreamRegistry<
  O extends Extract<StreamOpen, { kind: ScopedStreamSpec["kinds"][number] }>,
  B extends ScopedBinding<P>,
  P extends ScopedProjectBinding,
> {
  private readonly bindings = new Map<string, B>();
  private readonly peerBindings = new Map<string, Set<B>>();
  private readonly recvStopped = new WeakSet<B>();

  protected constructor(private readonly spec: ScopedStreamSpec, protected readonly opts: ScopedStreamOptions<P>) {}

  /** One `StreamHandler` per stream kind; native-host-connection registers these. */
  handlerFor(kind: O["kind"]): StreamHandler<O> {
    return (admission) => this.admit(kind, admission);
  }

  /** Live bindings holding a cap slot for the peer, across every kind this
   *  registry instance serves. */
  streamCount(peerId: string): number {
    return this.peerBindings.get(peerId)?.size ?? 0;
  }

  private admit(kind: O["kind"], admission: StreamAdmission<O>): StreamRefusal | undefined {
    const { peerId, open, stream, authorized } = admission;
    const refuse = (code: StreamRefusedCode, message: string): StreamRefusal => ({ code, message });

    if (this.streamCount(peerId) >= this.spec.cap) return refuse("CAP_EXCEEDED", this.spec.capMessage);
    const invalidOpen = this.validateOpen(open);
    if (invalidOpen) return invalidOpen;

    const { projectId } = open;
    if (!isSafeProjectId(projectId)) return refuse("NOT_ALLOWED", "unsafe project id");
    if (!this.opts.projectCataloged?.(projectId)) return refuse("NOT_ALLOWED", "project not recognized");
    const project = this.opts.projectBinding(projectId);
    if (project === null) return refuse("NOT_READY", "project is not attached");
    if (!project.hasOpenStream(peerId)) return refuse("NOT_ALLOWED", "open the project stream first");
    const refusal = project.refusalFor(peerId);
    if (refusal) return refuse("NOT_ALLOWED", refusal.message);

    const id = this.idOf(open);
    if (this.bindings.has(this.key(peerId, kind, id))) return refuse("INVALID", "duplicate id");
    const unavailable = this.available(project, open);
    if (unavailable) return unavailable;

    // `binding` is referenced by the writer-failure closure before it is
    // assigned; it only ever runs after this function has returned.
    let binding!: B;
    const writer = openScopedWriter(stream, authorized, this.spec, (reason) => this.onWriterFailure(binding, reason));
    const base: ScopedBinding<P> = {
      peerId, kind, id, projectId, stream, writer, project, authorized, unbound: false, pendingRead: null,
    };
    binding = this.createBinding(base, open);
    this.bind(binding);
    const result = this.serve(binding);
    if (result) {
      void Promise.resolve(result).then((maybeRefusal) => {
        if (maybeRefusal) this.refuseInline(binding, maybeRefusal);
      });
    }
    return undefined;
  }

  /** Field-level open checks beyond the Zod schema (terminal: uuid requestId). */
  protected validateOpen(_open: O): StreamRefusal | undefined {
    return undefined;
  }

  /** After the shared gate passes: server availability (tunnels()/uploads()
   *  null → NOT_ALLOWED). */
  protected available(_project: P, _open: O): StreamRefusal | undefined {
    return undefined;
  }

  protected abstract idOf(open: O): string;
  protected abstract createBinding(base: ScopedBinding<P>, open: O): B;
  /** The body. May return a refusal only before anything has been read from
   *  the stream — a kind may also call {@link refuseInline} itself from
   *  deeper inside its own async admission (a bad head record, a server's own
   *  async admit refusing) and simply return afterward. */
  protected abstract serve(binding: B): void | Promise<StreamRefusal | undefined>;
  /** Kind cleanup when a binding ends for any cause (terminal: synthesize
   *  unsubscribe; tunnel: abort exchange / close sink; upload: cancel the
   *  upload). Runs once, before unbind. */
  protected abstract onEnded(binding: B, cause: ScopedEndCause): void;

  /** Unbinds first, so `refuseStream`'s own writer is the only one that
   *  touches the send half and the registry's own writer is never reused. A
   *  no-op once the binding is already unbound (idempotent against a `serve`
   *  that both calls this itself and returns a refusal). */
  protected refuseInline(binding: B, refusal: StreamRefusal): void {
    if (binding.unbound) return;
    this.unbind(binding);
    refuseStream(binding.stream, refusal, binding.authorized, () => this.opts.retirePeer(binding.peerId, "unauthorized"));
  }

  /** Ends a binding for any of the causes above: kind cleanup, then abort the
   *  writer (a no-op if it already finished), unbind, and stop the receive
   *  half once whatever read the kind was tracking on `binding.pendingRead`
   *  settles — never before, since `recv.stop()` would otherwise queue behind
   *  it on the binding's shared per-stream mutex. */
  protected end(binding: B, cause: ScopedEndCause): void {
    if (binding.unbound) return;
    this.onEnded(binding, cause);
    binding.writer.abort();
    const pending = binding.pendingRead;
    this.unbind(binding);
    this.stopRecv(binding, pending);
  }

  /** Stops the receive half with this kind's code once `pending` settles, or
   *  at once when nothing is outstanding. Once per binding: several teardown
   *  paths can each be the one that knows the recv mutex is free. */
  protected stopRecv(binding: B, pending: Promise<unknown> | null = null): void {
    if (this.recvStopped.has(binding)) return;
    this.recvStopped.add(binding);
    stopRecvWhenSettled(pending, () => { void binding.stream.recv.stop(this.spec.stopCode).catch(() => {}); });
  }

  /** Awaits `read` as the binding's one outstanding read. `READ_ENDED` when it
   *  rejected (the app's FIN/reset, or a protocol violation the reader already
   *  reported). `READ_UNBOUND` when the binding was released or ended while it
   *  was outstanding: the read has settled and freed the recv mutex, so the
   *  receive half is stopped here, since no other reader is left to do it. */
  protected async trackRead<T>(binding: B, read: Promise<T>): Promise<T | typeof READ_ENDED | typeof READ_UNBOUND> {
    binding.pendingRead = read;
    let value: T;
    try {
      value = await read;
    } catch {
      return READ_ENDED;
    } finally {
      binding.pendingRead = null;
    }
    if (!binding.unbound) return value;
    this.stopRecv(binding);
    return READ_UNBOUND;
  }

  /** Per-record recheck, the same rule the outbound writer already applies on
   *  every send: a lease revoked mid-stream must not keep dispatching what
   *  the peer already had in flight. False also ends this binding. */
  protected stillAuthorized(binding: B): boolean {
    if (binding.authorized()) return true;
    this.opts.retirePeer(binding.peerId, "unauthorized");
    this.end(binding, "breach");
    return false;
  }

  protected diag(binding: B, type: string, detail: Record<string, unknown>): void {
    this.opts.diagnostic?.(type, detail, { kind: binding.kind, id: binding.id });
  }

  /** A voluntary, graceful retirement on the kind's own terms (the writer
   *  already finished or is about to): just the index/cap-slot removal, with
   *  no `onEnded` and no abort — unlike {@link end}, which is for the six
   *  enumerated abnormal causes. */
  protected release(binding: B): void {
    this.unbind(binding);
  }

  private onWriterFailure(binding: B, reason: StreamWriteFailure): void {
    if (binding.unbound) return;
    if (reason === "unauthorized") {
      this.opts.retirePeer(binding.peerId, "unauthorized");
      this.end(binding, "breach");
      return;
    }
    // "overflow" or "stream-lost": the writer has already reset its own half.
    this.end(binding, reason);
  }

  /** The project's last live `ProjectStreamRegistry` entry detached: its bus
   *  is gone, so every bound stream ends with no synthesized message — there
   *  is nothing left to dispatch one to. */
  projectDetached(projectId: string): void {
    for (const set of this.peerBindings.values()) {
      for (const binding of [...set]) {
        if (binding.projectId !== projectId) continue;
        this.end(binding, "detached");
      }
    }
  }

  /** Connection retired: end every binding for the peer. Never calls
   *  `retirePeer` — the peer is already gone. */
  dropPeer(peerId: string): void {
    const set = this.peerBindings.get(peerId);
    if (!set) return;
    for (const binding of [...set]) this.end(binding, "peer-dropped");
  }

  private key(peerId: string, kind: string, id: string): string {
    return `${peerId}\u0000${kind}\u0000${id}`;
  }

  private bind(binding: B): void {
    this.bindings.set(this.key(binding.peerId, binding.kind, binding.id), binding);
    let set = this.peerBindings.get(binding.peerId);
    if (!set) {
      set = new Set();
      this.peerBindings.set(binding.peerId, set);
    }
    set.add(binding);
  }

  /** Removes the index entry and frees the cap slot exactly once. An
   *  `unbound` flag, not a generation counter, is what makes every late
   *  callback a no-op once it fires. */
  private unbind(binding: B): void {
    if (binding.unbound) return;
    binding.unbound = true;
    this.bindings.delete(this.key(binding.peerId, binding.kind, binding.id));
    const set = this.peerBindings.get(binding.peerId);
    if (set) {
      set.delete(binding);
      if (set.size === 0) this.peerBindings.delete(binding.peerId);
    }
  }
}
