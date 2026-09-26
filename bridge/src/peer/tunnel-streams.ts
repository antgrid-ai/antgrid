/**
 * Tunnel HTTP and WebSocket streams (Stage A wave A3,
 * docs/iroh-reduction/stage-A-A3-contract.md §3.3). A tunneled preview request
 * or browser-side WebSocket gets its own QUIC bidi stream: after the A0b open
 * frame, every record is `[u32 len][body]` with the body discriminated by its
 * first byte — `0x7B` JSON control record, or a tagged binary data record
 * (§1.1). There is no `{s, m}` envelope and no preview-channel frame, so no
 * tunnel traffic ever rides the project stream (§1.2).
 *
 * This registry is plugged into `PeerStreamAcceptor` as the `tunnel-http` and
 * `tunnel-ws` handlers. It never opens or promotes a core: `tunnelBinding` is
 * a lookup over whatever `ProjectStreamRegistry` already has attached, and the
 * real per-checkout authorization runs through `TunnelStreamServer.admit` once
 * the head record names a checkout (D-7: `checkoutId` rides the head, not the
 * open frame, because the A0b open schemas are frozen).
 */

import {
  decodeTunnelRecord,
  encodeTunnelDataRecord,
  STREAM_MAX_TUNNEL_STREAMS_PER_PEER,
  STREAM_TUNNEL_RECORD_MAX_BYTES,
  STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES,
  TUNNEL_RECORD_TAG_WS_BINARY,
  TUNNEL_RECORD_TAG_WS_TEXT,
  type StreamRefusedCode,
  type TunnelHttpStreamOpen,
  type TunnelWsStreamOpen,
} from "antgrid-wire";
import { isSafeProjectId } from "../project-id";
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
  refuseStream,
  STREAM_OPEN_DEADLINE_MS,
  type AcceptedBiStream,
  type StreamAdmission,
  type StreamHandler,
  type StreamRefusal as DispatchStreamRefusal,
} from "./stream-dispatch";
import {
  StreamRawReader,
  StreamRecordReader,
  StreamRecordWriter,
  STREAM_RAW_READ_BYTES,
  type StreamSendOutcome,
  type StreamWriteFailure,
} from "./stream-records";
import type { TunnelProjectBinding } from "../project-streams";
import type { NetwatchStreamKind } from "../netwatch";

export const TUNNEL_STREAM_MAX_QUEUED_BYTES = 4 * 1024 * 1024;
/** Below the session stream's binding default of 0, and below terminal's `1`
 *  (§9 D-8 of A2: A4 must place project streams below both). Tunnel traffic
 *  is a page load, not a live viewer — it never needs to preempt either. */
export const STREAM_PRIORITY_TUNNEL = -1;
// Reset/stop codes are bridge diagnostics only — Dart cannot read them back.
export const STREAM_RESET_TUNNEL = 0x15n;
export const STREAM_STOP_TUNNEL = 0x16n;

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

const defaultSchedule = (callback: () => void, ms: number): (() => void) => {
  const timer = setTimeout(callback, ms);
  timer.unref?.();
  return () => clearTimeout(timer);
};

interface BaseBinding {
  readonly peerId: string;
  /** `requestId` (HTTP) or `wsId` (WS) — the open frame's own id. */
  readonly id: string;
  readonly projectId: string;
  /** Normalized once the head record parses (D-7); "main" until then, though
   *  nothing is sent before that point. */
  checkoutId: string;
  readonly stream: AcceptedBiStream;
  readonly writer: StreamRecordWriter;
  readonly reader: StreamRecordReader;
  readonly authorized: () => boolean;
  readonly tunnelBinding: TunnelProjectBinding;
  /** Removed from every index and its cap slot freed. The staleness guard
   *  every async step checks: once unbound, nothing may act on this binding
   *  again — which is what keeps a lagging callback from a torn-down stream
   *  reaching into whatever now reuses the same peerId or id. */
  unbound: boolean;
}

interface HttpBinding extends BaseBinding {
  readonly kind: "http";
  bodyLength: number;
  /** `writer.finish()` has been issued for this exchange's response.
   *  Marks the app's own FIN afterward as orderly rather than a cancel. */
  ended: boolean;
  readonly exchangeAbort: AbortController;
  /** Set only when `bodyLength > 0`; the cancel watcher does not start until
   *  it reports a full, successful drain. */
  bodySource?: TunnelRequestBodySource;
}

/** Hooks a `TunnelRequestBodySource` calls back into the registry with —
 *  kept separate from the registry's own methods because the source has no
 *  business calling `unbind`/`retirePeer` itself; it only reports what its
 *  own raw reads observed. */
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
}

/**
 * Backs one HTTP tunnel run's upstream request body: a pull-based
 * `ReadableStream` (`highWaterMark: 0`, so `fetch` never buffers ahead of what
 * it has actually written upstream) over the tunnel stream's raw receive
 * half. `pull()` never asks for more than the declared length remaining
 * (§3), so an app that sends extra bytes is caught by the cancel watcher that
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
    private readonly schedule: (callback: () => void, ms: number) => () => void,
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
    const clear = () => { if (this.pendingRead === readPromise) this.pendingRead = null; };
    readPromise.then(clear, clear);
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

interface WsBinding extends BaseBinding {
  readonly kind: "ws";
  sink: TunnelWsUpstreamSink | undefined;
  /** `tunnel:ws-close` has already been written (or is not needed because the
   *  peer never got that far) — guards `close()`'s idempotence. */
  wsClosed: boolean;
}

type Binding = HttpBinding | WsBinding;

export interface TunnelStreamRegistryOptions {
  /** host-server `seenProjects.has`. Absent => every open is refused NOT_ALLOWED (fail closed). */
  projectCataloged?: (projectId: string) => boolean;
  /** `ProjectStreamRegistry.tunnelBinding`. Lookup only: never opens or promotes a core. */
  tunnelBinding: (projectId: string) => TunnelProjectBinding | null;
  /** Only ever "unauthorized" (a writer, or a per-record authorized() check on read) or
   *  "protocol-violation" (a malformed length prefix from StreamRecordReader). */
  retirePeer: (peerId: string, reason: "unauthorized" | "protocol-violation") => void;
  /** `stream` names the record's native stream for `NetwatchEvent.streamKind`/
   *  `streamId` — `"tunnel-http"` or `"tunnel-ws"` per the binding's own
   *  `kind`, paired with its `id` (the open frame's `requestId`/`wsId`, stable
   *  for the exchange's whole life, the same way a project stream's
   *  `streamId` is its `projectId`). Absent only for an event with no single
   *  binding to attribute (there are none today). */
  diagnostic?: (type: string, detail: Record<string, unknown>, stream?: { kind: NetwatchStreamKind; id: string }) => void;
  /** Timer seam for the head deadline; defaults to setTimeout/clearTimeout. */
  schedule?: (callback: () => void, ms: number) => () => void;
  /** Test seam for the request-body idle clock; defaults to `FETCH_READ_IDLE_MS`. */
  requestBodyIdleMs?: number;
}

/** `(peerId, kind, id) -> binding`, registered into `PeerStreamAcceptor`'s
 *  handler table as `{ "tunnel-http": registry.httpHandler, "tunnel-ws":
 *  registry.wsHandler }`. */
export class TunnelStreamRegistry {
  private readonly bindings = new Map<string, Binding>();
  private readonly peerBindings = new Map<string, Set<Binding>>();
  private readonly schedule: (callback: () => void, ms: number) => () => void;

  constructor(private readonly opts: TunnelStreamRegistryOptions) {
    this.schedule = opts.schedule ?? defaultSchedule;
  }

  readonly httpHandler: StreamHandler<TunnelHttpStreamOpen> = (admission) => this.admitHttp(admission);
  readonly wsHandler: StreamHandler<TunnelWsStreamOpen> = (admission) => this.admitWs(admission);

  /** Live HTTP + WS bindings holding a cap slot for the peer. */
  streamCount(peerId: string): number {
    return this.peerBindings.get(peerId)?.size ?? 0;
  }

  // ---- Admission (synchronous, before any read) --------------------------

  /** Every check is synchronous and runs before any read is issued on `recv`:
   *  a handler that has started its read loop never returns a refusal again. */
  private gate(
    peerId: string,
    projectId: string,
    kind: "http" | "ws",
    id: string,
  ): { ok: true; projBinding: TunnelProjectBinding } | { ok: false; refusal: DispatchStreamRefusal } {
    if (this.streamCount(peerId) >= STREAM_MAX_TUNNEL_STREAMS_PER_PEER) {
      return { ok: false, refusal: { code: "CAP_EXCEEDED", message: "too many tunnel streams" } };
    }
    if (!isSafeProjectId(projectId)) {
      return { ok: false, refusal: { code: "NOT_ALLOWED", message: "unsafe project id" } };
    }
    if (!this.opts.projectCataloged || !this.opts.projectCataloged(projectId)) {
      return { ok: false, refusal: { code: "NOT_ALLOWED", message: "project not recognized" } };
    }
    const projBinding = this.opts.tunnelBinding(projectId);
    if (projBinding === null) {
      return { ok: false, refusal: { code: "NOT_READY", message: "project is not attached" } };
    }
    // A4: the project stream is the single per-peer admission point for a
    // projectId. Closing the project stream does not unbind an already-open
    // tunnel stream.
    if (!projBinding.hasOpenStream(peerId)) {
      return { ok: false, refusal: { code: "NOT_ALLOWED", message: "open the project stream first" } };
    }
    const refusal = projBinding.refusalFor(peerId);
    if (refusal) {
      return {
        ok: false,
        refusal: refusal.code === "UPDATE_REQUIRED"
          ? { code: "UPDATE_REQUIRED", message: refusal.message }
          : { code: "NOT_ALLOWED", message: refusal.message },
      };
    }
    if (this.bindings.has(this.key(peerId, kind, id))) {
      return { ok: false, refusal: { code: "INVALID", message: "duplicate id" } };
    }
    if (projBinding.tunnels() === null) {
      return { ok: false, refusal: { code: "NOT_ALLOWED", message: "tunnels not available" } };
    }
    return { ok: true, projBinding };
  }

  private admitHttp(admission: StreamAdmission<TunnelHttpStreamOpen>): DispatchStreamRefusal | undefined {
    const { peerId, open, stream, authorized } = admission;
    const gate = this.gate(peerId, open.projectId, "http", open.requestId);
    if (!gate.ok) return gate.refusal;

    // Referenced by the writer/reader failure closures below before it is
    // assigned; both only ever run after this function has returned.
    let binding!: HttpBinding;
    const writer = new StreamRecordWriter(
      stream,
      authorized,
      (reason) => this.onWriterFailure(binding, reason),
      TUNNEL_STREAM_MAX_QUEUED_BYTES,
      STREAM_PRIORITY_TUNNEL,
      STREAM_RESET_TUNNEL,
    );
    const reader = new StreamRecordReader(
      stream,
      STREAM_TUNNEL_RECORD_MAX_BYTES,
      () => { if (!binding.unbound) this.opts.retirePeer(peerId, "protocol-violation"); },
    );
    binding = {
      kind: "http",
      peerId,
      id: open.requestId,
      projectId: open.projectId,
      checkoutId: "main",
      stream,
      writer,
      reader,
      authorized,
      tunnelBinding: gate.projBinding,
      unbound: false,
      bodyLength: 0,
      ended: false,
      exchangeAbort: new AbortController(),
    };
    this.bind(binding);
    void this.runHttpHead(binding);
    return undefined;
  }

  private admitWs(admission: StreamAdmission<TunnelWsStreamOpen>): DispatchStreamRefusal | undefined {
    const { peerId, open, stream, authorized } = admission;
    const gate = this.gate(peerId, open.projectId, "ws", open.wsId);
    if (!gate.ok) return gate.refusal;

    let binding!: WsBinding;
    const writer = new StreamRecordWriter(
      stream,
      authorized,
      (reason) => this.onWriterFailure(binding, reason),
      TUNNEL_STREAM_MAX_QUEUED_BYTES,
      STREAM_PRIORITY_TUNNEL,
      STREAM_RESET_TUNNEL,
    );
    const reader = new StreamRecordReader(
      stream,
      STREAM_TUNNEL_RECORD_MAX_BYTES,
      () => { if (!binding.unbound) this.opts.retirePeer(peerId, "protocol-violation"); },
    );
    binding = {
      kind: "ws",
      peerId,
      id: open.wsId,
      projectId: open.projectId,
      checkoutId: "main",
      stream,
      writer,
      reader,
      authorized,
      tunnelBinding: gate.projBinding,
      unbound: false,
      sink: undefined,
      wsClosed: false,
    };
    this.bind(binding);
    void this.runWsHead(binding);
    return undefined;
  }

  // ---- Async phase: head ---------------------------------------------------

  /** Reads exactly one record under `STREAM_OPEN_DEADLINE_MS`. On a timeout,
   *  aborts the writer and unbinds without writing a refusal, and stops the
   *  receive half only once that read settles (the binding mutex: `stop`
   *  would otherwise queue behind a still-pending `readExact`). */
  private async readHeadRecord(binding: Binding): Promise<Uint8Array | undefined> {
    let settled = false;
    let cancelTimer: (() => void) | undefined;
    const readPromise = binding.reader.read();
    const outcome = await new Promise<Uint8Array | "timeout" | "ended">((resolve) => {
      cancelTimer = this.schedule(() => {
        if (settled) return;
        settled = true;
        resolve("timeout");
      }, STREAM_OPEN_DEADLINE_MS);
      readPromise.then((bytes) => {
        if (settled) return;
        settled = true;
        resolve(bytes);
      }, () => {
        if (settled) return;
        settled = true;
        resolve("ended");
      });
    });
    cancelTimer?.();
    if (outcome === "timeout") {
      binding.writer.abort();
      this.unbind(binding);
      readPromise.then(() => { void binding.stream.recv.stop(STREAM_STOP_TUNNEL).catch(() => {}); }, () => {});
      return undefined;
    }
    if (outcome === "ended") {
      // The app reset or FIN'd before its head (a cancel while opening): the
      // slot must go now, or every such cancel leaks one of the peer's
      // STREAM_MAX_TUNNEL_STREAMS_PER_PEER until the connection retires.
      binding.writer.abort();
      this.unbind(binding);
      return undefined;
    }
    if (binding.unbound) {
      void binding.stream.recv.stop(STREAM_STOP_TUNNEL).catch(() => {});
      return undefined;
    }
    return outcome;
  }

  /** Unbinds first, so `refuseStream`'s own writer is the only one that
   *  touches the send half and the registry's own writer is never reused. No
   *  read is outstanding at either call site (§3.3). */
  private refuseInline(binding: Binding, code: StreamRefusedCode, message: string): void {
    this.unbind(binding);
    refuseStream(
      binding.stream,
      { code, message },
      binding.authorized,
      () => this.opts.retirePeer(binding.peerId, "unauthorized"),
    );
  }

  private async runHttpHead(binding: HttpBinding): Promise<void> {
    const record = await this.readHeadRecord(binding);
    if (record === undefined) return; // timeout, or the app's FIN/reset before a head ever arrived
    if (!binding.authorized()) { this.opts.retirePeer(binding.peerId, "unauthorized"); return; }

    const decoded = decodeTunnelRecord(record);
    if (!decoded || decoded.kind !== "json") {
      this.refuseInline(binding, "INVALID", "expected a JSON control record");
      return;
    }
    const parsedJson = parseJsonRecord(decoded.text);
    if (!parsedJson.ok) {
      this.refuseInline(binding, "INVALID", "malformed JSON");
      return;
    }
    const parsed = TunnelHttpRequest.safeParse(parsedJson.value);
    if (!parsed.success || parsed.data.requestId !== binding.id) {
      this.refuseInline(binding, "INVALID", "malformed tunnel:http-request");
      return;
    }
    const req = parsed.data;
    if (req.bodyLength > STREAM_TUNNEL_REQUEST_BODY_MAX_BYTES) {
      this.refuseInline(binding, "INVALID", "body too large");
      return;
    }
    const declared = headerContentLength(req.headers);
    if (declared !== undefined && declared !== req.bodyLength) {
      this.refuseInline(binding, "INVALID", "content-length does not match bodyLength");
      return;
    }

    const admission = binding.tunnelBinding.tunnels()?.admit(binding.peerId, req.checkoutId) ?? null;
    if (admission === null) {
      this.refuseInline(binding, "NOT_ALLOWED", "tunnels not available");
      return;
    }
    if (!admission.ok) {
      this.refuseInline(binding, admission.refusal.code, admission.refusal.message);
      return;
    }

    binding.checkoutId = req.checkoutId;
    binding.bodyLength = req.bodyLength;
    await this.runHttpBody(binding, req, admission.manager);
  }

  private async runWsHead(binding: WsBinding): Promise<void> {
    const record = await this.readHeadRecord(binding);
    if (record === undefined) return;
    if (!binding.authorized()) { this.opts.retirePeer(binding.peerId, "unauthorized"); return; }

    const decoded = decodeTunnelRecord(record);
    if (!decoded || decoded.kind !== "json") {
      this.refuseInline(binding, "INVALID", "expected a JSON control record");
      return;
    }
    const parsedJson = parseJsonRecord(decoded.text);
    if (!parsedJson.ok) {
      this.refuseInline(binding, "INVALID", "malformed JSON");
      return;
    }
    const parsed = TunnelWsOpen.safeParse(parsedJson.value);
    if (!parsed.success || parsed.data.tunnelId !== binding.id) {
      this.refuseInline(binding, "INVALID", "malformed tunnel:ws-open");
      return;
    }
    const open = parsed.data;

    const admission = binding.tunnelBinding.tunnels()?.admit(binding.peerId, open.checkoutId) ?? null;
    if (admission === null) {
      this.refuseInline(binding, "NOT_ALLOWED", "tunnels not available");
      return;
    }
    if (!admission.ok) {
      this.refuseInline(binding, admission.refusal.code, admission.refusal.message);
      return;
    }

    binding.checkoutId = open.checkoutId;
    const peer: TunnelWsPeer = {
      send: (frame) => this.sendWsFrame(binding, frame),
      close: (code, reason) => this.closeWs(binding, code, reason),
    };
    binding.sink = admission.manager.serveWs(open, peer);
    void this.runWsLoop(binding);
  }

  // ---- Async phase: HTTP body, then run ------------------------------------

  private async runHttpBody(binding: HttpBinding, req: TunnelHttpRequest, manager: TunnelManager): Promise<void> {
    let bodySource: TunnelRequestBodySource | undefined;
    if (req.bodyLength > 0) {
      bodySource = new TunnelRequestBodySource(
        new StreamRawReader(binding.stream),
        req.bodyLength,
        this.opts.requestBodyIdleMs ?? FETCH_READ_IDLE_MS,
        this.schedule,
        {
          unbound: () => binding.unbound,
          authorized: binding.authorized,
          onUnauthorized: () => this.opts.retirePeer(binding.peerId, "unauthorized"),
          onIncomplete: () => {
            binding.exchangeAbort.abort();
            binding.writer.abort();
            this.unbind(binding);
          },
          onDrained: () => { void this.watchHttpCancel(binding); },
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
    // owns `recv` from the start (§3); with one, `onDrained` above starts it
    // once every declared byte has been pulled.
    if (!bodySource) void this.watchHttpCancel(binding);
  }

  private async sendHttpHead(
    binding: HttpBinding,
    head: { status: number; headers: Record<string, string>; setCookies?: string[] },
  ): Promise<StreamSendOutcome> {
    if (!binding.tunnelBinding.mayDeliverTo(binding.peerId)) {
      binding.exchangeAbort.abort();
      binding.writer.abort();
      this.unbind(binding);
      return "dropped";
    }
    return binding.writer.send(encodeJsonRecord({
      type: "tunnel:http-head",
      requestId: binding.id,
      status: head.status,
      headers: head.headers,
      ...(head.setCookies ? { setCookies: head.setCookies } : {}),
      checkoutId: binding.checkoutId,
    }));
  }

  private async sendHttpBody(binding: HttpBinding, bytes: Uint8Array): Promise<StreamSendOutcome> {
    if (!binding.tunnelBinding.mayDeliverTo(binding.peerId)) {
      binding.exchangeAbort.abort();
      binding.writer.abort();
      this.unbind(binding);
      return "dropped";
    }
    return binding.writer.sendRaw(bytes);
  }

  /** A clean FIN and a reset are natively distinguishable on the wire, so
   *  `writer.finish()` alone is the "done" signal for a response body. */
  private async endHttp(binding: HttpBinding): Promise<StreamSendOutcome> {
    if (!binding.tunnelBinding.mayDeliverTo(binding.peerId)) {
      binding.exchangeAbort.abort();
      binding.writer.abort();
      this.unbind(binding);
      return "dropped";
    }
    binding.ended = true;
    await binding.writer.finish();
    // A request-body read can still be outstanding if the origin answered
    // before the app finished sending it — `recv.stop` is chained on that
    // read settling rather than issued now, since it would otherwise queue
    // behind the binding's shared per-stream mutex.
    const pendingBody = binding.bodySource && !binding.bodySource.drained
      ? binding.bodySource.awaitIdle() : undefined;
    this.unbind(binding);
    if (pendingBody) void pendingBody.then(() => { void binding.stream.recv.stop(STREAM_STOP_TUNNEL).catch(() => {}); });
    return "sent";
  }

  private failHttp(binding: HttpBinding, reason: string): void {
    if (binding.unbound) return;
    this.opts.diagnostic?.("tunnel-stream:http-failed", { peerId: binding.peerId, requestId: binding.id, reason },
      { kind: "tunnel-http", id: binding.id });
    binding.writer.abort();
    const pendingBody = binding.bodySource && !binding.bodySource.drained
      ? binding.bodySource.awaitIdle() : undefined;
    this.unbind(binding);
    if (pendingBody) void pendingBody.then(() => { void binding.stream.recv.stop(STREAM_STOP_TUNNEL).catch(() => {}); });
  }

  /** Starts once the request body (if any) has fully drained — before that,
   *  the body source is the stream's one active reader (§3). One pending
   *  `raw.read(1)` stays outstanding for the rest of the run, purely to
   *  detect the app sending anything else: a byte is a breach, and FIN/reset
   *  is the app's own end unless it beat our own orderly one. */
  private async watchHttpCancel(binding: HttpBinding): Promise<void> {
    const raw = new StreamRawReader(binding.stream);
    let bytes: Uint8Array | null;
    try {
      bytes = await raw.read(1);
    } catch {
      bytes = null; // reset: folded into the same "ended early" handling as FIN
    }
    if (binding.unbound) {
      void binding.stream.recv.stop(STREAM_STOP_TUNNEL).catch(() => {});
      return;
    }
    if (bytes === null) {
      // A rejection or FIN before `end()` was written is the app's cancel.
      // One after `end()` is the app's own orderly FIN and is ignored.
      if (binding.ended) return;
      binding.exchangeAbort.abort();
      binding.writer.abort();
      this.unbind(binding);
      return;
    }
    // A record here is a stream breach: the app must send nothing more once
    // its run is complete.
    binding.exchangeAbort.abort();
    binding.writer.abort();
    this.unbind(binding);
    void binding.stream.recv.stop(STREAM_STOP_TUNNEL).catch(() => {});
  }

  // ---- Async phase: WS ------------------------------------------------------

  private async sendWsFrame(binding: WsBinding, frame: TunnelWsFrame): Promise<StreamSendOutcome> {
    if (!binding.tunnelBinding.mayDeliverTo(binding.peerId)) {
      binding.writer.abort();
      this.unbind(binding);
      binding.sink?.closed();
      return "dropped";
    }
    const tag = frame.binary ? TUNNEL_RECORD_TAG_WS_BINARY : TUNNEL_RECORD_TAG_WS_TEXT;
    return binding.writer.send(encodeTunnelDataRecord(tag, frame.bytes));
  }

  private closeWs(binding: WsBinding, code?: number, reason?: string): void {
    if (binding.unbound || binding.wsClosed) return;
    binding.wsClosed = true;
    if (!binding.tunnelBinding.mayDeliverTo(binding.peerId)) {
      binding.writer.abort();
      this.unbind(binding);
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
      this.unbind(binding);
    })();
  }

  private async runWsLoop(binding: WsBinding): Promise<void> {
    let sawClose = false;
    for (;;) {
      let bytes: Uint8Array;
      try {
        bytes = await binding.reader.read();
      } catch {
        // The app's own end (FIN or reset): mirror it to the manager, FIN our
        // own send half if it has not closed yet, then unbind.
        if (binding.unbound) return;
        binding.sink?.closed();
        if (!binding.wsClosed) void binding.writer.finish();
        this.unbind(binding);
        return;
      }
      if (binding.unbound) {
        void binding.stream.recv.stop(STREAM_STOP_TUNNEL).catch(() => {});
        return;
      }
      if (!binding.authorized()) { this.opts.retirePeer(binding.peerId, "unauthorized"); return; }
      if (sawClose) {
        // Only FIN may follow a close record; the loop was reading solely to
        // observe it, so any further record is a breach.
        binding.sink?.closed(1002);
        binding.writer.abort();
        this.unbind(binding);
        void binding.stream.recv.stop(STREAM_STOP_TUNNEL).catch(() => {});
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
      binding.writer.abort();
      this.unbind(binding);
      void binding.stream.recv.stop(STREAM_STOP_TUNNEL).catch(() => {});
      return;
    }
  }

  // ---- Writer failures, teardown -------------------------------------------

  private onWriterFailure(binding: Binding, reason: StreamWriteFailure): void {
    if (binding.unbound) return;
    if (reason === "unauthorized") {
      // The only connection-closing path; the writer has not reset itself
      // (that is `retirePeer`'s job once it tears down the whole connection).
      this.opts.retirePeer(binding.peerId, "unauthorized");
      return;
    }
    // "overflow" or "stream-lost": the writer has already reset its own half.
    if (binding.kind === "ws") binding.sink?.closed();
    else binding.exchangeAbort.abort();
    this.unbind(binding);
  }

  /** The project's last live `ProjectStreamRegistry` entry detached: its bus is
   *  gone, so every bound stream is aborted with no synthesized message —
   *  there is nothing left to dispatch one to. */
  projectDetached(projectId: string): void {
    for (const set of this.peerBindings.values()) {
      for (const binding of [...set]) {
        if (binding.projectId !== projectId) continue;
        if (binding.kind === "ws") binding.sink?.closed();
        else binding.exchangeAbort.abort();
        binding.writer.abort();
        this.unbind(binding);
      }
    }
  }

  /** Connection retired: abort and unbind everything for the peer. Never
   *  calls `retirePeer` — the peer is already gone. */
  dropPeer(peerId: string): void {
    const set = this.peerBindings.get(peerId);
    if (!set) return;
    for (const binding of [...set]) {
      if (binding.kind === "ws") binding.sink?.closed();
      else binding.exchangeAbort.abort();
      binding.writer.abort();
      this.unbind(binding);
    }
  }

  // ---- Indexing --------------------------------------------------------------

  private bind(binding: Binding): void {
    this.bindings.set(this.key(binding.peerId, binding.kind, binding.id), binding);
    let set = this.peerBindings.get(binding.peerId);
    if (!set) {
      set = new Set();
      this.peerBindings.set(binding.peerId, set);
    }
    set.add(binding);
  }

  /** Removes the index entry and frees the cap slot exactly once. An `unbound`
   *  flag, not a generation counter, is what makes every late callback below a
   *  no-op once it fires. */
  private unbind(binding: Binding): void {
    if (binding.unbound) return;
    binding.unbound = true;
    this.bindings.delete(this.key(binding.peerId, binding.kind, binding.id));
    const set = this.peerBindings.get(binding.peerId);
    if (set) {
      set.delete(binding);
      if (set.size === 0) this.peerBindings.delete(binding.peerId);
    }
  }

  private key(peerId: string, kind: "http" | "ws", id: string): string {
    return `${peerId}\u0000${kind}\u0000${id}`;
  }
}
