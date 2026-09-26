/**
 * Admission for every native bidi stream after the session stream (Stage A
 * wave A1, docs/iroh-reduction/stage-A-A1-contract.md §3.2). The session
 * stream itself never reaches this file — `native-host-connection.ts` reads
 * its open frame and hands the stream straight to a `StreamRecordWriter` /
 * `StreamRecordReader` pair before this acceptor's loop starts.
 *
 * A1 ships an empty `handlers` table, so every well-formed later stream is
 * refused `NOT_ALLOWED`; A2–A4 plug in project/terminal/tunnel handlers
 * through the same table without touching admission order.
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
import { StreamRecordWriter, type RawStreamRecv, type StreamRecv, type StreamSend } from "./stream-records";

export const STREAM_OPEN_DEADLINE_MS = 5_000;
// Reset/stop codes are bridge diagnostics only — the Dart binding exposes no
// way to read them back (spec §1.2), so their values are never asserted on
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

/** The slice of a project's stream binding the shared admission gate reads. */
export interface GatedProjectBinding {
  hasOpenStream(peerId: string): boolean;
  refusalFor(peerId: string): { readonly code: string; readonly message: string } | null;
}

/**
 * The admission every project-scoped stream (terminal, tunnel, upload) runs
 * before its own registry-specific checks, in this order: the per-peer cap,
 * the safe-id and catalog checks (`seenProjects` + `isSafeProjectId` are the
 * only bound on which projectId a peer may name), the project's binding
 * (`NOT_READY` while it has no live entry), an open project stream for this
 * peer (A4's single admission point), then the entry's own per-sender gate.
 * Lookup only: nothing here opens or promotes a core.
 */
export function gateProjectStream<B extends GatedProjectBinding>(
  peerId: string,
  projectId: string,
  cap: { open: number; max: number; message: string },
  projectCataloged: ((projectId: string) => boolean) | undefined,
  lookup: (projectId: string) => B | null,
): { ok: true; binding: B } | { ok: false; refusal: StreamRefusal } {
  const refuse = (code: StreamRefusedCode, message: string) => ({ ok: false as const, refusal: { code, message } });
  if (cap.open >= cap.max) return refuse("CAP_EXCEEDED", cap.message);
  if (!isSafeProjectId(projectId)) return refuse("NOT_ALLOWED", "unsafe project id");
  if (!projectCataloged?.(projectId)) return refuse("NOT_ALLOWED", "project not recognized");
  const binding = lookup(projectId);
  if (binding === null) return refuse("NOT_READY", "project is not attached");
  if (!binding.hasOpenStream(peerId)) return refuse("NOT_ALLOWED", "open the project stream first");
  const refusal = binding.refusalFor(peerId);
  if (refusal) return refuse("NOT_ALLOWED", refusal.message);
  return { ok: true, binding };
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
  /** A1 passes `{}` (or omits it) — there are no handlers yet. */
  handlers?: StreamHandlers;
  schedule?: (callback: () => void, ms: number) => () => void;
  /** `stream` is set only for a refusal whose open frame parsed; a timeout or
   *  an unparseable open names no stream. */
  diagnostic?: (type: StreamDiagnosticType,
    detail: { code?: StreamRefusedCode; kind?: string; pending: number },
    stream?: StreamDiagnosticLabel) => void;
  /** Default `STREAM_MAX_PENDING_OPENS_PER_PEER`; tests may lower it. */
  maxPendingOpens?: number;
}

const defaultSchedule = (callback: () => void, ms: number): (() => void) => {
  const timer = setTimeout(callback, ms);
  timer.unref?.();
  return () => clearTimeout(timer);
};

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

    let settled = false;
    let cancelTimer: (() => void) | undefined;
    const readPromise = readStreamOpen(stream.recv);
    const outcome = await new Promise<StreamOpenRead | "timeout" | "read-failed">((resolve) => {
      cancelTimer = schedule(() => {
        if (settled) return;
        settled = true;
        resolve("timeout");
      }, STREAM_OPEN_DEADLINE_MS);
      readPromise.then((result) => {
        if (settled) return;
        settled = true;
        resolve(result);
      }, () => {
        if (settled) return;
        settled = true;
        resolve("read-failed");
      });
    });
    cancelTimer?.();

    if (outcome === "timeout") {
      this.pending--;
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
    if (outcome === "read-failed") {
      this.pending--;
      return;
    }
    this.pending--;
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
