/**
 * Tunnel HTTP and WebSocket streams. A tunneled preview request or
 * browser-side WebSocket gets its own QUIC bidi stream: after the open frame,
 * every record is `[u32 len][body]` with the body discriminated by its first
 * byte — `0x7B` JSON control record, or a tagged binary data record. No
 * tunnel traffic ever rides the project stream.
 *
 * Registered into `PeerStreamAcceptor` as the `tunnel-http` and `tunnel-ws`
 * handlers via `handlerFor`, sharing one cap and one bindings index across
 * both kinds. Admission (the per-peer cap, the safe-id/catalog checks, the
 * project's own binding lookup) lives once in `ScopedStreamRegistry`
 * (`stream-dispatch.ts`); this file owns the head-record shape, the HTTP
 * request-body source, and the WS record loop — the real per-checkout
 * authorization runs through `TunnelStreamServer.admit` once the head record
 * names a checkout, since the stream-open wire schemas are frozen and carry
 * no `checkoutId`.
 */

import {
  decodeTunnelRecord,
  encodeTunnelDataRecord,
  STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
  STREAM_TUNNEL_RECORD_MAX_BYTES,
  STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES,
  TUNNEL_RECORD_TAG_WS_BINARY,
  TUNNEL_RECORD_TAG_WS_TEXT,
  type TunnelHttpStreamOpen,
  type TunnelWsStreamOpen,
} from "antgrid-wire";
import { TUNNEL_BODY_REPLAY_MAX_BYTES, TunnelHttpRequest, TunnelWsClose, TunnelWsOpen } from "../tunnel-protocol";
import { FETCH_READ_IDLE_MS, UpstreamBodyError, type TunnelRequestBody } from "../localhost-fetch";
import type {
  TunnelHttpExchange,
  TunnelManager,
  TunnelWsFrame,
  TunnelWsPeer,
  TunnelWsUpstreamSink,
} from "../tunnel-manager";
import {
  defaultSchedule,
  raceDeadline,
  READ_ENDED,
  READ_UNBOUND,
  ScopedStreamRegistry,
  STREAM_DEADLINE,
  STREAM_OPEN_DEADLINE_MS,
  STREAM_RESET_SCOPED,
  STREAM_STOP_SCOPED,
  type ScopedBinding,
  type ScopedEndCause,
  type ScopedStreamOptions,
  type Schedule,
} from "./stream-dispatch";
import {
  StreamRawReader,
  StreamRecordReader,
  STREAM_RAW_READ_BYTES,
  type StreamSendOutcome,
} from "./stream-records";
import type { TunnelProjectBinding } from "../project-streams";

export const TUNNEL_STREAM_MAX_QUEUED_BYTES = 4 * 1024 * 1024;
/** Below session (2), terminal (1) and project (0). Tunnel traffic is a page
 *  load, not a live viewer — it never needs to preempt any of them. */
export const STREAM_PRIORITY_TUNNEL = -1;

const textEncoder = new TextEncoder();

function encodeJsonRecord(record: unknown): Uint8Array {
  return textEncoder.encode(JSON.stringify(record));
}

/** `content-length`, case-insensitively, parsed as a number — `NaN` when
 *  present but unparseable, which always fails a `=== bodyLength` check
 *  rather than silently passing one. `undefined` when the header is absent. */
function headerContentLength(headers: Record<string, string> | undefined): number | undefined {
  if (!headers) return undefined;
  for (const [k, v] of Object.entries(headers)) {
    if (k.toLowerCase() !== "content-length") continue;
    return Number(v);
  }
  return undefined;
}

function parseJsonRecord(text: string): { ok: true; value: unknown } | { ok: false } {
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch {
    return { ok: false };
  }
}

/** Hooks a `TunnelRequestBodySource` calls back into the registry with —
 *  kept separate from the registry's own methods because the source has no
 *  business calling `end`/`retirePeer` itself; it only reports what its own
 *  raw reads observed. */
interface RequestBodySourceHooks {
  unbound: () => boolean;
  authorized: () => boolean;
  onUnauthorized: () => void;
  /** FIN, reset, or a stalled read short of the declared length: never
   *  `close()`s the `ReadableStream` (a closed short stream reads to `fetch`
   *  as a complete, truncated body) — `error()`s it instead. */
  onIncomplete: () => void;
  /** Every declared byte has been pulled off the wire and handed to `fetch`.
   *  This is when the cancel watcher may safely start reading `recv` — before
   *  this, the body source is still the stream's one active reader. */
  onDrained: () => void;
  /** Mirrors the source's own outstanding native read onto the binding, so
   *  `end()` can wait for it before stopping the receive half — the same
   *  mutex constraint `awaitIdle()` exists for, from the other side. */
  trackRead: (pending: Promise<unknown> | null) => void;
}

/**
 * Backs one HTTP tunnel run's upstream request body: a pull-based
 * `ReadableStream` (`highWaterMark: 0`, so `fetch` never buffers ahead of what
 * it has actually written upstream) over the tunnel stream's raw receive
 * half. `pull()` never asks for more than the declared length remaining, so
 * an app that sends extra bytes is caught by the cancel watcher that
 * starts once this source drains, not by this class.
 *
 * Keeps everything it has read, up to `TUNNEL_BODY_REPLAY_MAX_BYTES`, so a
 * second `stream()` call (the http/https scheme retry) can replay the
 * first attempt's bytes before continuing from the wire; past the cap,
 * `stream()` returns `null` and the retry is skipped.
 */
class TunnelRequestBodySource implements TunnelRequestBody {
  readonly length: number;
  readonly complete: Promise<void>;
  private resolveComplete!: () => void;
  private received = 0;
  private replay: Buffer[] = [];
  private replayBytes = 0;
  private replayCapped = false;
  private failure: unknown;
  private pendingRead: Promise<unknown> | null = null;
  drained = false;

  constructor(
    private readonly raw: StreamRawReader,
    length: number,
    private readonly idleMs: number,
    private readonly schedule: Schedule,
    private readonly hooks: RequestBodySourceHooks,
  ) {
    this.length = length;
    this.complete = new Promise((resolve) => { this.resolveComplete = resolve; });
  }

  stream(): ReadableStream<Uint8Array> | null {
    if (this.replayCapped) return null;
    if (this.failure !== undefined) {
      const failure = this.failure;
      return new ReadableStream<Uint8Array>({ start: (controller) => controller.error(failure) });
    }
    // How far into the pulled bytes THIS attempt has delivered. Read live on
    // every pull rather than snapshotted here: an earlier attempt's read can
    // still be outstanding, and the bytes it lands belong to this one too.
    let delivered = 0;
    return new ReadableStream<Uint8Array>(
      {
        pull: async (controller) => {
          // One reader per receive half: an abandoned attempt's read is
          // waited out, and its bytes reach this attempt through the replay
          // buffer instead of being lost between the two.
          await this.awaitIdle();
          if (this.failure !== undefined) { controller.error(this.failure); return; }
          if (delivered < this.received) {
            if (this.replayCapped) {
              controller.error(new UpstreamBodyError("request body exceeds the replay cap"));
              return;
            }
            const replayed = Buffer.concat(this.replay, this.replayBytes).subarray(delivered);
            delivered = this.received;
            controller.enqueue(new Uint8Array(replayed));
            if (delivered === this.length) controller.close();
            return;
          }
          if (this.received === this.length) { controller.close(); return; }
          const bytes = await this.pullFresh();
          if (bytes === null) { controller.error(this.failure); return; }
          delivered = this.received;
          controller.enqueue(bytes);
          if (delivered === this.length) controller.close();
        },
      },
      { highWaterMark: 0 },
    );
  }

  /** Resolves once whatever raw read is currently outstanding has settled (or
   *  immediately, if none is) — lets a caller that must stop the receive half
   *  wait for the shared per-stream mutex to free rather than queuing behind
   *  a still-pending native read (stream-records.ts's binding constraints). */
  awaitIdle(): Promise<void> {
    return this.pendingRead ? this.pendingRead.then(() => {}, () => {}) : Promise.resolve();
  }

  /** One raw read off the wire. Returns the bytes, already counted and
   *  remembered, or `null` once `failure` is set. The bookkeeping never
   *  depends on which attempt's controller asked, so bytes landing after that
   *  attempt was abandoned are still counted toward the drain. */
  private async pullFresh(): Promise<Uint8Array | null> {
    if (this.failure !== undefined) return null;
    const want = Math.min(STREAM_RAW_READ_BYTES, this.length - this.received);
    let settled = false;
    let cancelTimer: (() => void) | undefined;
    const readPromise = this.raw.read(want);
    // Cleared only when the NATIVE read settles, not when the idle clock
    // fires: after a stall the read still holds the receive half's mutex.
    this.pendingRead = readPromise;
    this.hooks.trackRead(readPromise);
    const clear = () => {
      if (this.pendingRead !== readPromise) return;
      this.pendingRead = null;
      this.hooks.trackRead(null);
    };
    readPromise.then(clear, clear);
    // Resolved directly, not through a shared deadline helper: the extra
    // microtask hop would let a retry's `awaitIdle()`, chained on this same
    // `readPromise`, run before `this.received` is updated.
    const outcome = await new Promise<Uint8Array | null | "timeout">((resolve) => {
      cancelTimer = this.schedule(() => { if (settled) return; settled = true; resolve("timeout"); }, this.idleMs);
      readPromise.then(
        (bytes) => { if (settled) return; settled = true; resolve(bytes); },
        () => { if (settled) return; settled = true; resolve(null); }, // reset: folded into the same short-body handling as FIN
      );
    });
    cancelTimer?.();

    if (this.hooks.unbound()) {
      this.failure = new UpstreamBodyError("tunnel stream unbound");
      return null;
    }
    if (!this.hooks.authorized()) {
      this.failure = new UpstreamBodyError("unauthorized");
      this.hooks.onUnauthorized();
      return null;
    }
    if (outcome === "timeout") {
      this.failure = new UpstreamBodyError("request body stalled");
      this.hooks.onIncomplete();
      return null;
    }
    if (outcome === null) {
      this.failure = new UpstreamBodyError("request body ended before its declared length");
      this.hooks.onIncomplete();
      return null;
    }
    this.received += outcome.byteLength;
    this.remember(outcome);
    if (this.received === this.length) {
      this.drained = true;
      this.resolveComplete();
      this.hooks.onDrained();
    }
    return outcome;
  }

  private remember(bytes: Uint8Array): void {
    if (this.replayCapped) return;
    if (this.replayBytes + bytes.byteLength > TUNNEL_BODY_REPLAY_MAX_BYTES) {
      this.replayCapped = true;
      this.replay = [];
      this.replayBytes = 0;
      return;
    }
    this.replay.push(Buffer.from(bytes));
    this.replayBytes += bytes.byteLength;
  }
}

interface TunnelHttpBinding extends ScopedBinding<TunnelProjectBinding> {
  readonly kind: "tunnel-http";
  checkoutId: string;
  readonly reader: StreamRecordReader;
  bodyLength: number;
  /** `writer.finish()` has been issued for this exchange's response. Marks
   *  the app's own FIN afterward as orderly rather than a cancel. */
  ended: boolean;
  readonly exchangeAbort: AbortController;
  /** Set only when `bodyLength > 0`; the cancel watcher does not start until
   *  it reports a full, successful drain. */
  bodySource?: TunnelRequestBodySource;
}

interface TunnelWsBinding extends ScopedBinding<TunnelProjectBinding> {
  readonly kind: "tunnel-ws";
  checkoutId: string;
  readonly reader: StreamRecordReader;
  sink: TunnelWsUpstreamSink | undefined;
  /** `tunnel:ws-close` has already been written (or is not needed because the
   *  peer never got that far) — guards `closeWs`'s idempotence. */
  wsClosed: boolean;
}

type TunnelBinding = TunnelHttpBinding | TunnelWsBinding;

export type TunnelStreamRegistryOptions = ScopedStreamOptions<TunnelProjectBinding> & {
  /** Test seam for the request-body idle clock; defaults to `FETCH_READ_IDLE_MS`. */
  requestBodyIdleMs?: number;
};

/** `(peerId, kind, id) -> binding`, registered via `handlerFor("tunnel-http")`
 *  and `handlerFor("tunnel-ws")` — one instance, one cap, shared by both. */
export class TunnelStreamRegistry extends ScopedStreamRegistry<
  TunnelHttpStreamOpen | TunnelWsStreamOpen,
  TunnelBinding,
  TunnelProjectBinding
> {
  private readonly scheduleFn: Schedule;
  private readonly requestBodyIdleMs: number;

  constructor(opts: TunnelStreamRegistryOptions) {
    super({
      kinds: ["tunnel-http", "tunnel-ws"],
      cap: STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
      capMessage: "too many tunnel streams",
      priority: STREAM_PRIORITY_TUNNEL,
      resetCode: STREAM_RESET_SCOPED,
      stopCode: STREAM_STOP_SCOPED,
      maxQueuedBytes: TUNNEL_STREAM_MAX_QUEUED_BYTES,
    }, opts);
    this.scheduleFn = opts.schedule ?? defaultSchedule;
    this.requestBodyIdleMs = opts.requestBodyIdleMs ?? FETCH_READ_IDLE_MS;
  }

  protected idOf(open: TunnelHttpStreamOpen | TunnelWsStreamOpen): string {
    return open.kind === "tunnel-http" ? open.requestId : open.wsId;
  }

  protected available(project: TunnelProjectBinding) {
    return project.tunnels() === null
      ? { code: "NOT_ALLOWED" as const, message: "tunnels not available" }
      : undefined;
  }

  protected createBinding(base: ScopedBinding<TunnelProjectBinding>, open: TunnelHttpStreamOpen | TunnelWsStreamOpen): TunnelBinding {
    let binding!: TunnelBinding;
    const reader = new StreamRecordReader(
      base.stream,
      STREAM_TUNNEL_RECORD_MAX_BYTES,
      () => { if (!binding.unbound) this.opts.retirePeer(base.peerId, "protocol-violation"); },
    );
    if (open.kind === "tunnel-http") {
      binding = { ...base, kind: "tunnel-http", checkoutId: "main", reader, bodyLength: 0, ended: false, exchangeAbort: new AbortController() };
    } else {
      binding = { ...base, kind: "tunnel-ws", checkoutId: "main", reader, sink: undefined, wsClosed: false };
    }
    return binding;
  }

  protected serve(binding: TunnelBinding): void {
    if (binding.kind === "tunnel-http") void this.runHttpHead(binding);
    else void this.runWsHead(binding);
  }

  /** No cause-specific cleanup for a tunnel exchange, unlike terminal's
   *  synthesized unsubscribe: nothing downstream reads WHY a preview request
   *  or WebSocket ended, only that it did, so every abnormal cause aborts the
   *  in-flight upstream work the same way. */
  protected onEnded(binding: TunnelBinding, _cause: ScopedEndCause): void {
    if (binding.kind === "tunnel-ws") binding.sink?.closed();
    else binding.exchangeAbort.abort();
  }

  // ---- Async phase: head ---------------------------------------------------

  /** Reads exactly one record under `STREAM_OPEN_DEADLINE_MS`. On a timeout
   *  the read is still outstanding and holds the recv mutex, so only the slot
   *  and the send half go now; the receive half is stopped once that read
   *  later resolves, but not if it rejects — a reset means the peer's own
   *  send half is already gone, so there is nothing left to stop. */
  private async readHeadRecord(binding: TunnelBinding): Promise<Uint8Array | undefined> {
    const readPromise = binding.reader.read();
    binding.pendingRead = readPromise;
    const outcome = await raceDeadline(readPromise, STREAM_OPEN_DEADLINE_MS, this.scheduleFn)
      .catch(() => "ended" as const);
    if (outcome === STREAM_DEADLINE) {
      binding.writer.abort();
      this.release(binding);
      readPromise.then(() => this.stopRecv(binding), () => {});
      return undefined;
    }
    binding.pendingRead = null;
    if (outcome === "ended") {
      // The app reset or FIN'd before its head (a cancel while opening): the
      // slot must go now, or every such cancel leaks one of the peer's
      // STREAM_MAX_TUNNEL_STREAMS_PER_PEER until the connection retires. The
      // read has already settled, so recv needs no stop.
      binding.writer.abort();
      this.release(binding);
      return undefined;
    }
    if (binding.unbound) {
      this.stopRecv(binding);
      return undefined;
    }
    return outcome;
  }

  /** The head-record steps neither kind skips: read under the open deadline,
   *  recheck authorization, decode the one JSON control record, and parse it
   *  against the caller's schema — refusing inline (and returning `undefined`)
   *  on any failure. `matches` re-checks the id field HTTP and WS each key
   *  their schema on (`requestId` vs `tunnelId`) against the open frame's own
   *  id, since two different Zod shapes can't share one field name to read
   *  generically. */
  private async parseHead<T>(
    binding: TunnelBinding,
    schema: { safeParse(v: unknown): { success: true; data: T } | { success: false } },
    matches: (data: T) => boolean,
    malformedMessage: string,
  ): Promise<T | undefined> {
    const record = await this.readHeadRecord(binding);
    if (record === undefined) return undefined; // timeout, or the app's FIN/reset before a head ever arrived
    if (!this.stillAuthorized(binding)) return undefined;

    const decoded = decodeTunnelRecord(record);
    if (!decoded || decoded.kind !== "json") {
      this.refuseInline(binding, { code: "INVALID", message: "expected a JSON control record" });
      return undefined;
    }
    const parsedJson = parseJsonRecord(decoded.text);
    if (!parsedJson.ok) {
      this.refuseInline(binding, { code: "INVALID", message: "malformed JSON" });
      return undefined;
    }
    const parsed = schema.safeParse(parsedJson.value);
    if (!parsed.success || !matches(parsed.data)) {
      this.refuseInline(binding, { code: "INVALID", message: malformedMessage });
      return undefined;
    }
    return parsed.data;
  }

  /** The `tunnels()?.admit` call and its refusal handling, shared by both
   *  kinds' head run — only what happens with a granted `TunnelManager`
   *  differs (`runHttpBody` vs. `serveWs`). */
  private admitTunnel(binding: TunnelBinding, checkoutId: string): TunnelManager | undefined {
    const admission = binding.project.tunnels()?.admit(binding.peerId, checkoutId) ?? null;
    if (admission === null) {
      this.refuseInline(binding, { code: "NOT_ALLOWED", message: "tunnels not available" });
      return undefined;
    }
    if (!admission.ok) {
      this.refuseInline(binding, admission.refusal);
      return undefined;
    }
    return admission.manager;
  }

  private async runHttpHead(binding: TunnelHttpBinding): Promise<void> {
    const req = await this.parseHead(
      binding,
      TunnelHttpRequest,
      (data) => data.requestId === binding.id,
      "malformed tunnel:http-request",
    );
    if (req === undefined) return;
    if (req.bodyLength > STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES) {
      this.refuseInline(binding, { code: "INVALID", message: "body too large" });
      return;
    }
    const declared = headerContentLength(req.headers);
    if (declared !== undefined && declared !== req.bodyLength) {
      this.refuseInline(binding, { code: "INVALID", message: "content-length does not match bodyLength" });
      return;
    }

    const manager = this.admitTunnel(binding, req.checkoutId);
    if (!manager) return;

    binding.checkoutId = req.checkoutId;
    binding.bodyLength = req.bodyLength;
    await this.runHttpBody(binding, req, manager);
  }

  private async runWsHead(binding: TunnelWsBinding): Promise<void> {
    const open = await this.parseHead(
      binding,
      TunnelWsOpen,
      (data) => data.tunnelId === binding.id,
      "malformed tunnel:ws-open",
    );
    if (open === undefined) return;

    const manager = this.admitTunnel(binding, open.checkoutId);
    if (!manager) return;

    binding.checkoutId = open.checkoutId;
    const peer: TunnelWsPeer = {
      send: (frame) => this.sendWsFrame(binding, frame),
      close: (code, reason) => this.closeWs(binding, code, reason),
    };
    binding.sink = manager.serveWs(open, peer);
    void this.runWsLoop(binding);
  }

  // ---- Async phase: HTTP body, then run ------------------------------------

  private async runHttpBody(binding: TunnelHttpBinding, req: TunnelHttpRequest, manager: TunnelManager): Promise<void> {
    let bodySource: TunnelRequestBodySource | undefined;
    if (req.bodyLength > 0) {
      bodySource = new TunnelRequestBodySource(
        new StreamRawReader(binding.stream),
        req.bodyLength,
        this.requestBodyIdleMs,
        this.scheduleFn,
        {
          unbound: () => binding.unbound,
          authorized: binding.authorized,
          onUnauthorized: () => this.opts.retirePeer(binding.peerId, "unauthorized"),
          onIncomplete: () => this.end(binding, "app-ended"),
          onDrained: () => { void this.watchHttpCancel(binding); },
          trackRead: (pending) => { binding.pendingRead = pending; },
        },
      );
      binding.bodySource = bodySource;
    }

    const exchange: TunnelHttpExchange = {
      peerId: binding.peerId,
      get signal() { return binding.exchangeAbort.signal; },
      head: (head) => this.sendHttpHead(binding, head),
      body: (bytes) => this.sendHttpBody(binding, bytes),
      end: () => this.endHttp(binding),
      fail: (reason) => this.failHttp(binding, reason),
    };
    void manager.serveHttp(req, bodySource ?? null, exchange);
    // With no declared body there is nothing to drain first — the watcher
    // owns `recv` from the start; with one, `onDrained` above starts it
    // once every declared byte has been pulled.
    if (!bodySource) void this.watchHttpCancel(binding);
  }

  /** The per-receiver gate every outbound tunnel record passes: a peer that
   *  may no longer receive from this project ends the exchange instead. */
  private undeliverable(binding: TunnelBinding): boolean {
    if (binding.project.mayDeliverTo(binding.peerId)) return false;
    this.end(binding, "app-ended");
    return true;
  }

  private async sendHttpHead(
    binding: TunnelHttpBinding,
    head: { status: number; headers: Record<string, string>; setCookies?: string[] },
  ): Promise<StreamSendOutcome> {
    if (this.undeliverable(binding)) return "dropped";
    return binding.writer.send(encodeJsonRecord({
      type: "tunnel:http-head",
      requestId: binding.id,
      status: head.status,
      headers: head.headers,
      ...(head.setCookies ? { setCookies: head.setCookies } : {}),
      checkoutId: binding.checkoutId,
    }));
  }

  private async sendHttpBody(binding: TunnelHttpBinding, bytes: Uint8Array): Promise<StreamSendOutcome> {
    if (this.undeliverable(binding)) return "dropped";
    return binding.writer.sendRaw(bytes);
  }

  /** A clean FIN and a reset are natively distinguishable on the wire, so
   *  `writer.finish()` alone is the "done" signal for a response body. A
   *  voluntary, graceful end on the exchange's own terms: `release`, not
   *  `end` — nothing failed, so nothing should be re-aborted. */
  private async endHttp(binding: TunnelHttpBinding): Promise<StreamSendOutcome> {
    if (this.undeliverable(binding)) return "dropped";
    binding.ended = true;
    await binding.writer.finish();
    this.releaseHttp(binding);
    return "sent";
  }

  /** A request-body read can still be outstanding if the origin answered
   *  before the app finished sending it; the receive half is stopped once it
   *  settles. With no body pending the cancel watcher (`watchHttpCancel`)
   *  owns `recv` and stops it itself — stopping here too would race its
   *  outstanding read. */
  private releaseHttp(binding: TunnelHttpBinding): void {
    const pendingBody = binding.bodySource && !binding.bodySource.drained
      ? binding.bodySource.awaitIdle() : undefined;
    this.release(binding);
    if (pendingBody) this.stopRecv(binding, pendingBody);
  }

  /** The upstream fetch/serve itself failed (origin unreachable, timeout, …):
   *  no response was ever sent, so the writer resets rather than finishes.
   *  Still a voluntary end on the exchange's own terms — it is reporting its
   *  own conclusion, not being cut off from outside. */
  private failHttp(binding: TunnelHttpBinding, reason: string): void {
    if (binding.unbound) return;
    this.diag(binding, "tunnel-stream:http-failed", { peerId: binding.peerId, requestId: binding.id, reason });
    binding.writer.abort();
    this.releaseHttp(binding);
  }

  /** Starts once the request body (if any) has fully drained — before that,
   *  the body source is the stream's one active reader. One pending
   *  `raw.read(1)` stays outstanding for the rest of the run, purely to
   *  detect the app sending anything else: a byte is a breach, and FIN/reset
   *  is the app's own end unless it beat our own orderly one. */
  private async watchHttpCancel(binding: TunnelHttpBinding): Promise<void> {
    const outcome = await this.trackRead(binding, new StreamRawReader(binding.stream).read(1));
    if (outcome === READ_UNBOUND) return;
    // A reset is folded into the same "ended early" handling as FIN.
    const bytes = outcome === READ_ENDED ? null : outcome;
    if (binding.unbound) {
      // Ended elsewhere while a rejected read was outstanding: nothing else
      // reads `recv` once the body has drained.
      this.stopRecv(binding);
      return;
    }
    if (bytes === null) {
      // A rejection or FIN before `end()` was written is the app's cancel.
      // One after `end()` is the app's own orderly FIN and is ignored. The
      // receive half already ended itself here, so `end()`'s own stop is a
      // harmless no-op rather than one this branch must arrange.
      if (binding.ended) return;
      this.end(binding, "app-ended");
      return;
    }
    // A record here is a stream breach: the app must send nothing more once
    // its run is complete.
    this.end(binding, "breach");
  }

  // ---- Async phase: WS ------------------------------------------------------

  private async sendWsFrame(binding: TunnelWsBinding, frame: TunnelWsFrame): Promise<StreamSendOutcome> {
    if (this.undeliverable(binding)) return "dropped";
    const tag = frame.binary ? TUNNEL_RECORD_TAG_WS_BINARY : TUNNEL_RECORD_TAG_WS_TEXT;
    return binding.writer.send(encodeTunnelDataRecord(tag, frame.bytes));
  }

  /** The sink itself asked to close: it already knows, so — unlike every
   *  other ending here — this never re-notifies it through `onEnded`. */
  private closeWs(binding: TunnelWsBinding, code?: number, reason?: string): void {
    if (binding.unbound || binding.wsClosed) return;
    binding.wsClosed = true;
    if (!binding.project.mayDeliverTo(binding.peerId)) {
      binding.writer.abort();
      this.release(binding);
      return;
    }
    const record: TunnelWsClose = {
      type: "tunnel:ws-close",
      tunnelId: binding.id,
      ...(code !== undefined ? { code } : {}),
      ...(reason ? { reason } : {}),
      checkoutId: binding.checkoutId,
    };
    void (async () => {
      await binding.writer.send(encodeJsonRecord(record));
      await binding.writer.finish();
      this.release(binding);
    })();
  }

  private async runWsLoop(binding: TunnelWsBinding): Promise<void> {
    let sawClose = false;
    for (;;) {
      if (binding.unbound) return;
      const bytes = await this.trackRead(binding, binding.reader.read());
      if (bytes === READ_UNBOUND) return;
      if (bytes === READ_ENDED) {
        this.end(binding, "app-ended");
        return;
      }
      if (!this.stillAuthorized(binding)) return;
      if (sawClose) {
        // Only FIN may follow a close record; the loop was reading solely to
        // observe it, so any further record is a breach.
        binding.sink?.closed(1002);
        this.end(binding, "breach");
        return;
      }
      const decoded = decodeTunnelRecord(bytes);
      if (decoded?.kind === "data" && (decoded.tag === TUNNEL_RECORD_TAG_WS_TEXT || decoded.tag === TUNNEL_RECORD_TAG_WS_BINARY)) {
        binding.sink?.data({ binary: decoded.tag === TUNNEL_RECORD_TAG_WS_BINARY, bytes: decoded.payload });
        continue;
      }
      if (decoded?.kind === "json") {
        const parsedJson = parseJsonRecord(decoded.text);
        const parsed = parsedJson.ok ? TunnelWsClose.safeParse(parsedJson.value) : undefined;
        if (parsed?.success && parsed.data.tunnelId === binding.id) {
          sawClose = true;
          binding.sink?.closed(parsed.data.code, parsed.data.reason);
          continue;
        }
      }
      // Anything else — a wrong-kind tag, a malformed record, a close naming
      // another tunnel — is a breach.
      binding.sink?.closed(1002);
      this.end(binding, "breach");
      return;
    }
  }
}
