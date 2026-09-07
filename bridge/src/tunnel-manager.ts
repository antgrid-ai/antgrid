import { logger } from "./logger";
const log = logger.child({ component: "tunnel-manager" });
import {
  fetchLocalhost,
  isTlsOnlyPort,
  UpstreamBodyError,
  type FetchLocalhostOpts,
  type LocalhostFetchStream,
} from "./localhost-fetch";
import { createMessage, type AbMessage, type PortInfo, type PreviewUrlEntry } from "./protocol";
import type {
  TunnelHttpCancel,
  TunnelHttpRequest,
  TunnelWsClose,
  TunnelWsData,
  TunnelWsOpen,
} from "./tunnel-protocol";
import type { SendOutcome } from "./send-scheduler";
import type { ConnState } from "./conn-state";

/** One upstream `ws://localhost:<port><path>` connection, keyed by tunnelId.
 *  [pending] holds app→bridge frames that arrived before `open` fired (the
 *  browser can send immediately once ITS local WS accepts, which races this
 *  socket's real handshake) — flushed in order on open, then unused. */
interface WsUpstream {
  socket: WebSocket;
  open: boolean;
  /** The tunnel is over: nothing this socket says may be routed by its id any
   *  more, and nothing may be relayed into it. NOT derivable from [wsAbandoned]
   *  membership — that Set is only the bounded eviction queue, and the two
   *  legitimately disagree for a socket released while already open (never
   *  added) and for an evicted one (removed, still abandoned). */
  abandoned: boolean;
  pending: Array<{ data: string; binary: boolean }>;
  pendingBytes: number;
  checkoutId: string;
}

/** A tunnelId the app has sent data for while no upstream socket exists.
 *  Either still buffering, or [poisoned] — the prefix is gone (overflowed,
 *  expired, or the tunnel already closed), so what follows can no longer be
 *  replayed as a faithful stream and the tunnel must be refused instead. */
interface WsPreopen {
  frames: Array<{ data: string; binary: boolean }>;
  bytes: number;
  poisoned: boolean;
  timer: ReturnType<typeof setTimeout>;
}

const WS_PREOPEN_TTL_MS = 5_000;
/** How long a poisoned tunnelId is remembered. A WebSocket carries a byte
 *  stream, so an open that arrives after its buffered prefix died must be
 *  refused rather than started mid-stream: a dev server handed a spliced
 *  message stream believes it holds a valid session and hangs, where a refused
 *  one gives the browser the close event its reconnect logic waits for.
 *  Outlives the app's 30s head timeout (`kTunnelHeadTimeout`) so the refusal
 *  beats the give-up. */
const WS_POISON_TTL_MS = 35_000;
const WS_PREOPEN_MAX_TUNNELS = 64;
const WS_BUFFER_MAX_FRAMES = 64;
const WS_BUFFER_MAX_BYTES = 1024 * 1024;
const WS_PREOPEN_MAX_TOTAL_BYTES = 16 * 1024 * 1024;
/** Both buffers are fed from the data path, so their drop paths must never log
 *  per frame — a streaming socket would emit thousands of lines. */
const WS_PREOPEN_WARN_INTERVAL_MS = 5_000;
/** Upstream sockets whose tunnel ended mid-handshake are PARKED, not closed:
 *  Bun aborts a socket that never finished its handshake with a RESET, and Node
 *  hands an `upgrade` request to its listeners with its own error handler
 *  already removed — so a dev server that ignored the upgrade (Vite does, for
 *  any path or subprotocol it does not own) holds that socket with no error
 *  listener at all, and the reset lands as an unhandled `read ECONNRESET` that
 *  exits the dev server. Measured on Node 26 against Astro. Past this many
 *  parked sockets the oldest is closed anyway: an upgrade nothing will ever
 *  answer is a leaked fd per tunnel, and one bounded crash risk beats
 *  unbounded growth. */
const WS_ABANDONED_MAX = 32;

/** How long a sent response stays replayable. Must outlive the window a retry
 *  can be issued in (the app's `kTunnelHeadTimeout` plus its `_retryGrace`) so
 *  a retry issued just before it gives up still finds the entry. */
const OUTBOX_TTL_MS = 35_000;
/** Streams past this are not retained, measured on the summed base64 `data` of
 *  their frames (≈1.5 MiB raw). A retry for one re-fetches, which is safe in
 *  the case that produces them — a large GET is a static asset. The requests
 *  where re-execution actually bites (a dev API route behind a GET) are small,
 *  and those are exactly the ones this keeps. */
const OUTBOX_MAX_ENTRY_BYTES = 2 * 1024 * 1024;
const OUTBOX_MAX_TOTAL_BYTES = 16 * 1024 * 1024;

/** The slice-sizing and upstream-clock seams a test overrides; production
 *  leaves every one of them at the module defaults. */
export type TunnelFetchOpts = Pick<
  FetchLocalhostOpts,
  "headTimeoutMs" | "readIdleMs" | "chunkBytes" | "flushMs" | "maxBodyBytes"
>;

/** Resolves when [signal] aborts (already resolved if it fired first). Built
 *  ONCE per streaming run and raced against every frame, so a 100 MB body
 *  registers one abort listener rather than one per chunk. */
function abortedPromise(signal: AbortSignal): Promise<void> {
  if (signal.aborted) return Promise.resolve();
  return new Promise((resolve) => signal.addEventListener("abort", () => resolve(), { once: true }));
}

/** What one streaming run has emitted so far and whether it is still worth
 *  retaining: any failure, cancel or undelivered frame clears both. */
interface StreamState {
  frames: object[];
  bytes: number;
  retain: boolean;
}

const WS_SUBPROTOCOL_HEADER = "sec-websocket-protocol";

// Handshake headers the upstream connection owns: Bun mints its own key,
// version and framing, and `host` follows from the URL we build. The
// subprotocol header is minted by Bun too — from `protocols`, which is where
// the browser's list goes instead (see [splitUpstreamWsHeaders]).
const WS_HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "upgrade",
  "host",
  "content-length",
  "transfer-encoding",
  "sec-websocket-key",
  "sec-websocket-version",
  "sec-websocket-extensions",
  "sec-websocket-accept",
  WS_SUBPROTOCOL_HEADER,
]);

/** Split the browser's handshake headers into the ones the upstream request may
 *  carry and the subprotocol list Bun mints `Sec-WebSocket-Protocol` from. One
 *  pass: the hop-by-hop filter already lowercases every key and already drops
 *  the subprotocol header, so harvesting its value rides along for free.
 *
 *  A Vite-family dev server (Astro, Nuxt, SvelteKit, plain Vite and the rest)
 *  only answers an HMR upgrade that names `vite-hmr`; one without it is never
 *  upgraded. The app has already echoed the browser's first choice by the time
 *  this socket opens, so the negotiation is optimistic — a server that picks a
 *  later entry than the browser's first is not corrected. The app echoes off
 *  ITS read of the same header (`_requestedSubprotocols` in
 *  `app/lib/services/preview_proxy_server.dart`), so ORDER and the trim/drop-
 *  empty rules must agree with it: a disagreement tells the browser a
 *  subprotocol the dev server was never offered, which neither end can detect.
 *  Deduping is deliberately one-sided, not drift — Bun's WebSocket constructor
 *  REFUSES a list containing a duplicate (see [openUpstream]), while shelf
 *  takes the app's list as a set already. */
function splitUpstreamWsHeaders(
  headers: Record<string, string> | undefined,
): { headers: Record<string, string>; protocols: string[] } {
  const out: Record<string, string> = {};
  const protocols = new Set<string>();
  for (const [k, v] of Object.entries(headers ?? {})) {
    const lower = k.toLowerCase();
    if (lower === WS_SUBPROTOCOL_HEADER) {
      for (const p of v.split(",")) {
        const trimmed = p.trim();
        if (trimmed) protocols.add(trimmed);
      }
      // No `continue`: the hop-by-hop set below is still what drops this
      // header, so its entry stays load-bearing rather than dead.
    }
    if (WS_HOP_BY_HOP_HEADERS.has(lower)) continue;
    out[k] = v;
  }
  return { headers: out, protocols: [...protocols] };
}

export class TunnelManager {
  private projectId: string;
  private portLabels: Map<number, string>;
  private previewPorts: Set<number>;
  private sendTunnel: (data: object) => Promise<SendOutcome>;
  private sendEncrypted: (msg: AbMessage) => void;
  private relayHost: string;
  private connState: ConnState;
  private fetchOpts: TunnelFetchOpts;
  private sentUrlDetails = new Map<number, PreviewUrlEntry>();
  /** Ports whose current entry was recorded while the stream was suppressed and
   *  so never reached the phone. Cleared on the send that delivers them. */
  private undelivered = new Set<number>();
  /** Streams already emitted IN FULL, keyed by requestId, so a retry replays
   *  rather than re-runs. The relay drops a routed frame when the pair/channel
   *  budget is exhausted and tells only the SENDER, so neither end can tell
   *  whether the request or the response died — the app therefore retries with
   *  the original requestId and this is what makes that safe. `frames` is the
   *  frame list in emit order (`[start]` for a single-slice body, else
   *  `[start, chunk 1..N, end]`); a stream that failed or was cancelled is
   *  never here. Insertion-ordered: the oldest entry is the first eviction
   *  candidate. */
  private outbox = new Map<string, { frames: object[]; bytes: number; expiresAt: number }>();
  private outboxBytes = 0;
  /** Requests currently being streamed. A retry can arrive while the original
   *  is still upstream (the app cannot see that), and awaiting it here is what
   *  stops the duplicate from becoming a second upstream request; the abort is
   *  what stops the run itself (app cancel, peer loss, checkout stop). */
  private inflight = new Map<string, { run: Promise<void>; abort: AbortController }>();
  /** Live WS relays, keyed by tunnelId — see [WsUpstream]. */
  private wsTunnels = new Map<string, WsUpstream>();
  /** Async sealing can put the first data frame ahead of its open frame. Keep
   *  that bounded orphan briefly so a Blazor/SignalR handshake is not lost.
   *  Insertion-ordered: the oldest tombstone is the first eviction candidate. */
  private wsPreopen = new Map<string, WsPreopen>();
  private wsPreopenBytes = 0;
  private wsPreopenWarnedAt = 0;
  private wsPreopenTtlMs: number;
  /** Sockets released mid-handshake — see [WS_ABANDONED_MAX]. Insertion-ordered
   *  so the oldest is the eviction candidate. Outlives [stop] on purpose: the
   *  manager is gone, the dev server is not. */
  private wsAbandoned = new Set<WsUpstream>();
  private wsAbandonedMax: number;
  /** [stop] is terminal. Without this a frame still in flight when a checkout
   *  is torn down re-arms a timer on a manager nothing owns any more — the
   *  callers null nothing, so the flag is what has to hold the line. */
  private stopped = false;

  constructor(opts: {
    projectId: string;
    portLabels: Map<number, string>;
    previewPorts: Set<number>;
    sendTunnel: (data: object) => Promise<SendOutcome>;
    sendEncrypted: (msg: AbMessage) => void;
    relayHost: string;
    connState: ConnState;
    wsPreopenTtlMs?: number;
    wsAbandonedMax?: number;
    /** Test seam: slice sizing and the upstream clocks. */
    fetchOpts?: TunnelFetchOpts;
  }) {
    this.projectId = opts.projectId;
    this.portLabels = opts.portLabels;
    this.previewPorts = opts.previewPorts;
    this.sendTunnel = opts.sendTunnel;
    this.sendEncrypted = opts.sendEncrypted;
    this.relayHost = opts.relayHost;
    this.connState = opts.connState;
    this.wsPreopenTtlMs = opts.wsPreopenTtlMs ?? WS_PREOPEN_TTL_MS;
    this.wsAbandonedMax = opts.wsAbandonedMax ?? WS_ABANDONED_MAX;
    this.fetchOpts = opts.fetchOpts ?? {};
  }

  onPortsUpdate(ports: PortInfo[]): void {
    const currentPorts = new Set(ports.map((p) => p.port));

    // Remove URLs for ports that are no longer active
    for (const port of [...this.sentUrlDetails.keys()]) {
      if (!currentPorts.has(port)) {
        this.sentUrlDetails.delete(port);
        this.undelivered.delete(port);
      }
    }

    // Send preview:url for new ports. Skipped entirely in local mode
    // (empty relayHost) — there's no relay-hosted preview origin to point at,
    // and the message has no consumer in that path.
    if (!this.relayHost) return;
    for (const p of ports) {
      const existing = this.sentUrlDetails.get(p.port);
      if (!existing && !this.previewPorts.has(p.port)) continue;

      const label = this.portLabels.get(p.port) ?? p.label ?? existing?.label;
      // Absent scheme means "no URL sighting yet", not http — never downgrade
      // a scheme already known for this port.
      const scheme = p.scheme ?? existing?.scheme;
      const entry: PreviewUrlEntry = {
        port: p.port,
        url: `http://${this.relayHost}/preview/${p.port}/`,
        ...(label ? { label } : {}),
        ...(scheme ? { scheme } : {}),
      };
      // A port's scheme (or label) can change after its entry was first sent —
      // the URL sighting lands later than the line-based detection — so re-push
      // rather than only re-caching, keeping the live push and the
      // welcome-replayed snapshot describing the same entry.
      const unchanged = existing
        && existing.label === entry.label
        && existing.scheme === entry.scheme;
      if (unchanged && !this.undelivered.has(p.port)) continue;

      // Recorded even while suppressed, so getPreviewSnapshot() stays complete —
      // but the entry is ALSO remembered as undelivered, because nothing else
      // will re-push it: reconnect re-enters here via resyncState's
      // emitCurrent(), where the unchanged-entry check above would otherwise
      // short-circuit and the phone would never learn the port exists.
      this.sentUrlDetails.set(p.port, entry);
      if (this.connState.suppressed) {
        this.undelivered.add(p.port);
        continue;
      }
      this.undelivered.delete(p.port);
      this.sendEncrypted(
        createMessage("preview:url", {
          projectId: this.projectId,
          port: entry.port,
          url: entry.url,
          ...(entry.label ? { label: entry.label } : {}),
          ...(entry.scheme ? { scheme: entry.scheme } : {}),
        }),
      );
      log.info("Sent preview:url for port %d → %s", entry.port, entry.url);
    }
  }

  getPreviewSnapshot(): PreviewUrlEntry[] {
    return [...this.sentUrlDetails.values()];
  }

  async onHttpRequest(msg: TunnelHttpRequest): Promise<void> {
    // Deliberately NOT gated on [stopped], unlike the WS handlers: an HTTP
    // request the app is waiting on costs it a head timeout if dropped, and
    // serving one holds nothing open afterwards.
    // A LOOP, not one await: two duplicates waiting on the same prior run both
    // resume when it ends, and without the re-check both would stream this id
    // at once with independent seq spaces — harmless when a response was one
    // whole body, a spliced or truncated body once it is chunks. [runInflight]
    // registers its entry before invoking the run, so the second waiter's
    // re-check sees it.
    for (;;) {
      const prior = this.inflight.get(msg.requestId);
      if (!prior) break;
      await prior.run.catch(() => {});
    }
    // Outbox first, before anything can reach the dev server: this is the whole
    // safety property of the app's retry.
    const stored = this.readOutbox(msg.requestId);
    await this.runInflight(msg.requestId, (abort) =>
      stored
        ? this.replayStream(stored.frames, abort)
        : this.streamResponse(msg, abort));
  }

  private async runInflight(
    requestId: string,
    fn: (abort: AbortController) => Promise<void>,
  ): Promise<void> {
    const abort = new AbortController();
    // `run` is assigned synchronously below, before any waiter can resume, so
    // a third request joining mid-registration awaits the real run.
    const entry = { abort, run: Promise.resolve() };
    this.inflight.set(requestId, entry);
    entry.run = fn(abort);
    try {
      await entry.run;
    } finally {
      if (this.inflight.get(requestId) === entry) this.inflight.delete(requestId);
    }
  }

  /** App-side cancel: the browser went away, the app detected a gap, or it is
   *  no longer waiting on this id. Stops the fetch and the frames; sends
   *  nothing. Idempotent, and a no-op for an id with no live run. */
  onHttpCancel(msg: TunnelHttpCancel): void {
    this.inflight.get(msg.requestId)?.abort.abort();
  }

  /** The peer is gone or was just re-established: every in-flight HTTP run
   *  exits through its own cancelled path — the fetch aborted, the upstream
   *  connection closed, nothing retained — instead of streaming the rest of a
   *  body into a relay that will drop it or an app that will ignore it. The
   *  relay client's queue clear only reaches a run that happens to be parked on
   *  a settle at that instant; this reaches the rest. WS tunnels are left
   *  alone: they survive a rekey today and the app re-opens them on loss. */
  abortHttpStreams(): void {
    for (const entry of this.inflight.values()) entry.abort.abort();
  }

  private async streamResponse(msg: TunnelHttpRequest, abort: AbortController): Promise<void> {
    const { requestId, checkoutId } = msg;
    const safePath = msg.path.startsWith("/") ? msg.path : `/${msg.path}`;
    const url = `${msg.scheme ?? "http"}://localhost:${msg.port}${safePath}`;
    const st: StreamState = { frames: [], bytes: 0, retain: true };
    const cancelled = abortedPromise(abort.signal).then(() => "cancelled" as const);

    let head: LocalhostFetchStream;
    try {
      head = await fetchLocalhost({
        url,
        method: msg.method,
        headers: msg.headers,
        body: msg.body,
        acceptEncodings: msg.acceptEncodings,
        signal: abort.signal,
        ...this.fetchOpts,
      });
    } catch (err) {
      if (abort.signal.aborted) return;
      const text = `Proxy error: ${err instanceof Error ? err.message : String(err)}`;
      // The 502 reaches only the previewing device, so without this a tunnel
      // failure is diagnosable exclusively from the phone's screen.
      log.warn("Tunnel fetch failed for %s: %s", url, text);
      // A head failure is a real, replayable answer — not an error end: the
      // headers never went out, so there is nothing incomplete to abort.
      await this.emit(st, {
        type: "tunnel:http-start",
        requestId,
        status: 502,
        headers: {},
        data: Buffer.from(text, "utf8").toString("base64"),
        bodyEncoding: "base64",
        last: true,
        checkoutId,
      }, abort, cancelled);
      this.retain(requestId, st);
      return;
    }

    const it = head.slices;
    let seq = 0;
    // The head has left; only then is an `end` a terminator the app can read.
    let started = false;
    try {
      const first = await it.next();
      const start = {
        type: "tunnel:http-start",
        requestId,
        status: head.status,
        headers: head.headers,
        setCookies: head.setCookies,
        data: first.done ? "" : first.value.data,
        bodyEncoding: first.done ? "base64" : first.value.bodyEncoding,
        ...(first.done || first.value.last ? { last: true as const } : {}),
        checkoutId,
      };
      if (await this.emit(st, start, abort, cancelled) !== "sent") return;
      started = true;
      if (start.last) { this.retain(requestId, st); return; }
      for (;;) {
        // Read-side pacing: the next slice is pulled only once the previous
        // frame left the send queue, so a stream holds at most one queued frame
        // and the credit window is the only thing setting the rate.
        const next = await it.next();
        if (next.done) break;
        seq++;
        const chunk = {
          type: "tunnel:http-chunk",
          requestId,
          seq,
          data: next.value.data,
          bodyEncoding: next.value.bodyEncoding,
          checkoutId,
        };
        if (await this.emit(st, chunk, abort, cancelled) !== "sent") return;
      }
      if (await this.emit(st, { type: "tunnel:http-end", requestId, chunks: seq, checkoutId }, abort, cancelled) !== "sent") return;
      this.retain(requestId, st);
    } catch (err) {
      // Our own cancel: the app has already forgotten the id.
      if (abort.signal.aborted) return;
      const reason = err instanceof UpstreamBodyError
        ? err.message
        : `upstream read failed: ${err instanceof Error ? err.message : String(err)}`;
      if (!started) {
        // The FIRST slice can fail (a stalled read, a body over the cap), and
        // the headers have not gone out yet — same position as a head failure,
        // so the same answer. A bare `end` here is indistinguishable from a
        // `start` the relay dropped, which the app recovers from by re-issuing
        // the request that has just failed.
        const text = `Proxy error: ${reason}`;
        log.warn("Tunnel stream %s failed before its head went out: %s", requestId, reason);
        await this.emit(st, {
          type: "tunnel:http-start",
          requestId,
          status: 502,
          headers: {},
          data: Buffer.from(text, "utf8").toString("base64"),
          bodyEncoding: "base64",
          last: true,
          checkoutId,
        }, abort, cancelled);
        this.retain(requestId, st);
        return;
      }
      log.warn("Tunnel stream %s ended with error after %d chunk(s): %s", requestId, seq, reason);
      st.retain = false;
      await this.emit(st, { type: "tunnel:http-end", requestId, chunks: seq, error: reason, checkoutId }, abort, cancelled);
    } finally {
      // Cancels the upstream read on every exit path.
      await it.return(undefined).catch(() => {});
    }
  }

  /** Hand one frame to the send path and wait for it to leave the queue. */
  private async emit(
    st: StreamState,
    frame: object,
    abort: AbortController,
    cancelled: Promise<"cancelled">,
  ): Promise<SendOutcome | "cancelled"> {
    // Checked BEFORE sendTunnel: a cancelled run must not enqueue one more
    // frame. The app has re-keyed a lost-start recovery under a fresh id by
    // now, so a frame that goes out anyway is a window of link wasted — and
    // under a shared id would have been spliced into the fresh run's body.
    if (abort.signal.aborted) { st.retain = false; return "cancelled"; }
    const outcome = await Promise.race([this.sendTunnel(frame), cancelled]);
    // The frame handed over just now may still go out; the app discards it as
    // unknown and answers it with one cancel.
    if (outcome === "cancelled") { st.retain = false; return outcome; }
    if (outcome !== "sent") {
      // "dropped", "too-large" and "gated" all end the stream: the app sees a
      // hole it cannot fill and nothing partial is worth replaying.
      const type = (frame as { type?: string }).type;
      log.warn("Tunnel stream %s aborted: frame %s %s", (frame as { requestId?: string }).requestId, type, outcome);
      st.retain = false;
      st.frames = [];
      return outcome;
    }
    const data = (frame as { data?: unknown }).data;
    const len = typeof data === "string" ? data.length : 0;
    if (st.retain && st.bytes + len <= OUTBOX_MAX_ENTRY_BYTES) {
      st.frames.push(frame);
      st.bytes += len;
    } else {
      st.retain = false;
      st.frames = [];
    }
    return "sent";
  }

  /** Re-send a completed stream, paced and cancellable exactly like a live one.
   *  Never re-retained — the entry it came from is still the retention. */
  private async replayStream(frames: object[], abort: AbortController): Promise<void> {
    const cancelled = abortedPromise(abort.signal).then(() => "cancelled" as const);
    for (const frame of frames) {
      if (abort.signal.aborted) return;
      if (await Promise.race([this.sendTunnel(frame), cancelled]) !== "sent") return;
    }
  }

  private retain(requestId: string, st: StreamState): void {
    if (!st.retain) return;
    this.evictOutbox(st.bytes);
    this.outbox.set(requestId, { frames: st.frames, bytes: st.bytes, expiresAt: Date.now() + OUTBOX_TTL_MS });
    this.outboxBytes += st.bytes;
  }

  private readOutbox(requestId: string): { frames: object[] } | undefined {
    const entry = this.outbox.get(requestId);
    if (!entry) return undefined;
    if (entry.expiresAt <= Date.now()) {
      this.outbox.delete(requestId);
      this.outboxBytes -= entry.bytes;
      return undefined;
    }
    return entry;
  }

  /** Drop expired entries, then the oldest, until [incoming] fits. */
  private evictOutbox(incoming: number): void {
    const now = Date.now();
    for (const [id, entry] of this.outbox) {
      if (entry.expiresAt > now) break; // insertion order == expiry order
      this.outbox.delete(id);
      this.outboxBytes -= entry.bytes;
    }
    for (const [id, entry] of this.outbox) {
      if (this.outboxBytes + incoming <= OUTBOX_MAX_TOTAL_BYTES) break;
      this.outbox.delete(id);
      this.outboxBytes -= entry.bytes;
    }
  }

  /** Opens the real upstream WebSocket for a browser-side tab's WS. Never
   *  throws back at the caller — an upstream that refuses/errors reports
   *  through the normal `tunnel:ws-close` path, mirroring what a rejected
   *  browser-side connect would look like, rather than dropping silently. */
  onWsOpen(msg: TunnelWsOpen): void {
    if (this.stopped) {
      // Refuse rather than drop: this manager will never relay again, and the
      // browser's socket only reconnects once it sees a close.
      void this.sendTunnel({
        type: "tunnel:ws-close",
        tunnelId: msg.tunnelId,
        reason: "tunnel manager stopped",
        checkoutId: msg.checkoutId,
      });
      return;
    }
    if (this.wsTunnels.has(msg.tunnelId)) return; // duplicate open, ignore
    if (this.wsPreopen.get(msg.tunnelId)?.poisoned) {
      // Opening here would relay a stream whose prefix is missing. Refusing
      // is what gets the browser a close event it can reconnect from. The
      // tombstone is deliberately LEFT in place: frames still in flight behind
      // this open must not start a second, tail-only buffer for the same id.
      void this.sendTunnel({
        type: "tunnel:ws-close",
        tunnelId: msg.tunnelId,
        reason: "buffered frames were dropped before the tunnel opened",
        checkoutId: msg.checkoutId,
      });
      return;
    }
    const preopen = this.takePreopen(msg.tunnelId);
    // The phone can only guess the scheme for a dev server it never saw
    // announce itself; `fetchLocalhost` has already corrected the guess for
    // this port by the time a page on it opens a socket.
    const secure = msg.scheme === "https" || isTlsOnlyPort(msg.port);
    const safePath = msg.path.startsWith("/") ? msg.path : `/${msg.path}`;
    const url = `${secure ? "wss" : "ws"}://localhost:${msg.port}${safePath}`;
    // Same self-signed-cert exemption `fetchLocalhost` makes, and for the same
    // reason: without it every wss upstream dies in the TLS handshake, and a
    // dev server whose page needs a socket — Blazor, Vite HMR, a live-reload
    // shim — renders as a blank tab with nothing to point at.
    const tlsOptions: Bun.WebSocketOptions = secure ? { tls: { rejectUnauthorized: false } } : {};
    const { headers, protocols } = splitUpstreamWsHeaders(msg.headers);
    // Every option is either a plain property or annotated on its own const,
    // because TypeScript skips its excess-property check on a spread: a typo'd
    // `protocolls`, or `tsl` above, inside `...(cond ? { ... } : {})` compiles
    // clean and costs the whole option silently. An empty `protocols` sends no
    // header, same as omitting it.
    const wsOptions: Bun.WebSocketOptions = { headers, protocols, ...tlsOptions };
    const socket = this.openUpstream(url, wsOptions, msg);
    if (!socket) return;
    const entry: WsUpstream = {
      socket,
      open: false,
      abandoned: false,
      pending: preopen?.frames ?? [],
      pendingBytes: preopen?.bytes ?? 0,
      checkoutId: msg.checkoutId,
    };
    this.wsTunnels.set(msg.tunnelId, entry);

    // Captured instead of `msg`: these listeners outlive the frame — for a
    // parked socket, potentially for the process — and `msg.headers` carries
    // the browser's whole handshake, `Cookie` included. Forwarding those is
    // load-bearing: a cookie-authenticated dev server reads its session off
    // the WebSocket request, not the page load before it, so dropping them
    // opens an ANONYMOUS socket behind an authenticated page — which renders
    // as "not authorized" rather than as a failure, and only on the phone,
    // since the desktop WebView dials the port itself.
    const tunnelId = msg.tunnelId;
    const checkoutId = entry.checkoutId;

    entry.socket.addEventListener("open", () => {
      if (entry.abandoned) {
        // Now a completed handshake, so this close is a FIN the server's own
        // WebSocket layer answers — not the reset a close mid-handshake sends.
        this.wsAbandoned.delete(entry);
        entry.socket.close();
        return;
      }
      entry.open = true;
      // The app answered the browser's 101 with `protocols[0]` before this
      // socket existed, so a server that picks a LATER entry leaves the two
      // ends framing to different subprotocols with no error on either — Bun
      // opens on any answer — and this log is the only place that shows.
      // It catches only that half: measured, Bun reports `protocol` as the
      // FIRST OFFERED entry when the server echoes none at all, so a server
      // that negotiated nothing is indistinguishable here from one that
      // accepted the browser's choice.
      if (protocols.length > 0 && entry.socket.protocol && entry.socket.protocol !== protocols[0]) {
        log.warn(
          "WS tunnel %s: upstream chose subprotocol %s, the page was told %s",
          tunnelId,
          entry.socket.protocol,
          protocols[0],
        );
      }
      for (const frame of entry.pending) this.sendUpstream(entry, frame.data, frame.binary);
      entry.pending = [];
      entry.pendingBytes = 0;
    });
    // A released socket answers to nobody: its tunnel id is already gone from
    // the map and, over a long park, may even name a newer tunnel — so nothing
    // it does may be routed by that id.
    entry.socket.addEventListener("message", (event) => {
      if (entry.abandoned) return;
      const binary = typeof event.data !== "string";
      const data = typeof event.data === "string"
        ? event.data
        : event.data instanceof ArrayBuffer
          ? Buffer.from(event.data).toString("base64")
          : Buffer.from(event.data as Uint8Array).toString("base64");
      void this.sendTunnel({
        type: "tunnel:ws-data",
        tunnelId,
        data,
        ...(binary ? { binary: true } : {}),
        checkoutId,
      }).then((outcome) => {
        if (outcome === "sent" || entry.abandoned) return;
        // "gated" = mobile access is switched off on this machine. Today's
        // semantics for that are "the frame is dropped, the tunnel stays": the
        // close a teardown would send is gated too, so the app could never
        // learn of it and would hold a mute browser socket for the life of the
        // page.
        if (outcome === "gated") return;
        // A newer tunnel may own this id after a park.
        if (this.wsTunnels.get(tunnelId) !== entry) return;
        // A WS stream with a hole in it is worse than a closed one (the same
        // rule the inbound overflow path applies), and the page's reconnect
        // gives it a fresh tunnel.
        log.warn("Closing WS tunnel %s: upstream frame %s", tunnelId, outcome);
        // Report FIRST — the same ordering, and for the same reason, as the
        // inbound overflow path below.
        this.teardownWs(
          tunnelId,
          outcome === "too-large" ? 1009 : 1001,
          outcome === "too-large"
            ? "upstream message too large to tunnel"
            : "tunnel frame could not be delivered",
        );
        this.releaseUpstream(entry);
      });
    });
    // Both endings free the park slot first: a socket that ERRORS while parked
    // holds one just as a closed one does, and the budget has no TTL to
    // reclaim it later.
    const settle = (code?: number, reason?: string) => {
      this.wsAbandoned.delete(entry);
      if (entry.abandoned) return;
      this.teardownWs(tunnelId, code, reason);
    };
    entry.socket.addEventListener("close", (event) => settle(event.code, event.reason));
    entry.socket.addEventListener("error", () => settle());
  }

  /** The upstream socket for [onWsOpen], or undefined once the tunnel has been
   *  refused. The constructor VALIDATES both of the strings the browser chose:
   *  Bun throws `SyntaxError` for a subprotocol that is not an RFC 6455 token
   *  and for a URL carrying a fragment. Nothing between the relay's message
   *  listener and here catches, and `index.ts` answers an uncaught exception by
   *  shutting the whole host down — so an escape here would cost every agent on
   *  the machine. Refuse the one tunnel instead, which is what every other
   *  upstream failure already does.
   *
   *  lib.dom's WebSocket shadows Bun's (tsconfig takes the default libs for an
   *  ESNext target) and its constructor's second parameter is `protocols`, so
   *  the options Bun does accept at runtime have to be cast past the type. */
  private openUpstream(
    url: string,
    wsOptions: Bun.WebSocketOptions,
    msg: TunnelWsOpen,
  ): WebSocket | undefined {
    try {
      return new WebSocket(url, wsOptions as unknown as string[]);
    } catch (err) {
      log.warn("Refusing WS tunnel %s: upstream connection was rejected: %s", msg.tunnelId, err);
      void this.sendTunnel({
        type: "tunnel:ws-close",
        tunnelId: msg.tunnelId,
        reason: "upstream connection could not be opened",
        checkoutId: msg.checkoutId,
      });
      return undefined;
    }
  }

  /** Close an upstream whose tunnel is over. An OPEN socket closes now. One
   *  still CONNECTING is parked and closed once it opens — or once it fails on
   *  its own — because closing it now is a reset, and a reset can take the dev
   *  server down with it (see [WS_ABANDONED_MAX]). The park is bounded.
   *
   *  The caller MUST have dropped the entry from [wsTunnels] first. Releasing
   *  marks the socket abandoned, which permanently suppresses the
   *  `tunnel:ws-close` its own ending would have sent — so an entry left mapped
   *  becomes immortal (nothing else deletes it, and [onWsOpen] refuses every
   *  reuse of that id) with the app never told the tunnel died. */
  private releaseUpstream(entry: WsUpstream): void {
    // Marked on BOTH branches, not just the park: a close is a handshake the
    // peer may keep sending frames through, so anything the socket still says
    // would be routed by an id that names nothing, or someone else's tunnel.
    entry.abandoned = true;
    entry.pending = [];
    entry.pendingBytes = 0;
    if (entry.open) {
      entry.socket.close();
      return;
    }
    // Same shape as [evictOutbox]: drain until under budget, so the bound holds
    // whatever [wsAbandonedMax] is rather than only for a set that grows by one.
    for (const oldest of this.wsAbandoned) {
      if (this.wsAbandoned.size < this.wsAbandonedMax) break;
      // The one path that closes a socket mid-handshake, which is the reset the
      // park exists to avoid — so it says so, like every other drop path here.
      // Logged before the delete, so the count is read and not reconstructed.
      log.warn("Cutting a parked WS handshake: %d parked, cap %d", this.wsAbandoned.size, this.wsAbandonedMax);
      this.wsAbandoned.delete(oldest);
      oldest.socket.close();
    }
    this.wsAbandoned.add(entry);
  }

  /** Tell the app a tunnel is over and stop relaying it. Idempotent: a close
   *  already relayed the other way has removed the map entry, and this is what
   *  keeps the socket's own close event from sending a second frame. */
  private teardownWs(tunnelId: string, code?: number, reason?: string): void {
    const entry = this.wsTunnels.get(tunnelId);
    if (!entry) return;
    this.wsTunnels.delete(tunnelId);
    // The app answers a bridge-initiated close by dropping its own tunnel
    // entry, so it never sends `tunnel:ws-close` back and [onWsClose] never
    // runs for this id. Anything still in flight would otherwise land in
    // [bufferPreopenFrame] and hold one of the 64 slots for a full TTL.
    this.poisonPreopen(tunnelId);
    void this.sendTunnel({
      type: "tunnel:ws-close",
      tunnelId,
      ...(code !== undefined ? { code } : {}),
      ...(reason ? { reason } : {}),
      checkoutId: entry.checkoutId,
    });
  }

  /** A browser-sent frame to relay upstream. Buffered on [WsUpstream.pending]
   *  while the real connection is still handshaking, or on [wsPreopen] when its
   *  `tunnel:ws-open` has not landed yet. Both buffers are bounded, and both
   *  answer an overflow by ending the tunnel rather than by relaying a stream
   *  with a hole in it. */
  onWsData(msg: TunnelWsData): void {
    if (this.stopped) return;
    const entry = this.wsTunnels.get(msg.tunnelId);
    if (!entry) {
      this.bufferPreopenFrame(msg);
      return;
    }
    if (!entry.open) {
      // Same ceiling as the pre-open buffer, and for a stronger reason: this
      // window is the LONGER of the two. A port that accepts TCP but stalls
      // the upgrade — a dev server mid-startup, or an https-only port reached
      // as `ws://` — holds it open for the OS connect timeout.
      const bytes = Buffer.byteLength(msg.data);
      if (
        entry.pending.length >= WS_BUFFER_MAX_FRAMES
        || entry.pendingBytes + bytes > WS_BUFFER_MAX_BYTES
      ) {
        log.warn(
          "Closing WS tunnel %s: upstream handshake did not finish before its buffer filled",
          msg.tunnelId,
        );
        // Report FIRST: [teardownWs] is what removes the entry from
        // [wsTunnels], and [releaseUpstream] neither removes it nor sends
        // anything — so releasing first would leave a released entry in the map
        // for [onWsData] to buffer into again.
        this.teardownWs(msg.tunnelId, undefined, "upstream handshake buffer overflow");
        this.releaseUpstream(entry);
        return;
      }
      entry.pending.push({ data: msg.data, binary: msg.binary === true });
      entry.pendingBytes += bytes;
      return;
    }
    this.sendUpstream(entry, msg.data, msg.binary === true);
  }

  private bufferPreopenFrame(msg: TunnelWsData): void {
    const existing = this.wsPreopen.get(msg.tunnelId);
    if (existing?.poisoned) return; // already unreplayable; the open will be refused
    const bytes = Buffer.byteLength(msg.data);

    let pending = existing;
    if (!pending) {
      if (!this.makeRoomForPreopen()) {
        // Throttled: this fires from the data path, once per frame of every
        // unknown tunnel, and the tunnelId is what makes it diagnosable.
        const now = Date.now();
        if (now - this.wsPreopenWarnedAt >= WS_PREOPEN_WARN_INTERVAL_MS) {
          this.wsPreopenWarnedAt = now;
          log.warn(
            "Dropping pre-open WS data for %s: %d tunnels already buffering",
            msg.tunnelId,
            this.wsPreopen.size,
          );
        }
        return;
      }
      pending = {
        frames: [],
        bytes: 0,
        poisoned: false,
        // Captures the id, not the frame — a timer that closed over `msg`
        // would pin its whole payload for the TTL even after a rejection.
        timer: this.armPreopenTimer(msg.tunnelId, this.wsPreopenTtlMs),
      };
      this.wsPreopen.set(msg.tunnelId, pending);
    }

    if (
      pending.frames.length >= WS_BUFFER_MAX_FRAMES
      || pending.bytes + bytes > WS_BUFFER_MAX_BYTES
      || this.wsPreopenBytes + bytes > WS_PREOPEN_MAX_TOTAL_BYTES
    ) {
      log.warn("Poisoning WS tunnel %s: pre-open buffer limit reached", msg.tunnelId);
      this.poisonPreopen(msg.tunnelId);
      return;
    }
    pending.frames.push({ data: msg.data, binary: msg.binary === true });
    pending.bytes += bytes;
    this.wsPreopenBytes += bytes;
  }

  /** Make a slot available under [WS_PREOPEN_MAX_TUNNELS], evicting the oldest
   *  tombstone first — a dev server in a reconnect loop churns a fresh tunnelId
   *  per attempt, and without this its dead ids starve the live one. */
  private makeRoomForPreopen(): boolean {
    if (this.wsPreopen.size < WS_PREOPEN_MAX_TUNNELS) return true;
    for (const [id, pending] of this.wsPreopen) {
      if (!pending.poisoned) continue;
      clearTimeout(pending.timer);
      this.wsPreopen.delete(id);
      return true;
    }
    return false;
  }

  private armPreopenTimer(tunnelId: string, ms: number): ReturnType<typeof setTimeout> {
    const timer = setTimeout(() => {
      const pending = this.wsPreopen.get(tunnelId);
      if (!pending) return;
      // First expiry drops the buffered prefix but REMEMBERS that it existed;
      // the second retires the tombstone.
      if (pending.poisoned) {
        this.wsPreopen.delete(tunnelId);
        return;
      }
      this.poisonPreopen(tunnelId);
    }, ms);
    if (typeof timer.unref === "function") timer.unref();
    return timer;
  }

  /** Mark [tunnelId] unreplayable and release what it held. The entry stays as
   *  a tombstone so a later open is refused rather than started mid-stream. */
  private poisonPreopen(tunnelId: string): void {
    const pending = this.wsPreopen.get(tunnelId);
    if (pending) {
      if (pending.poisoned) return;
      clearTimeout(pending.timer);
      this.wsPreopenBytes -= pending.bytes;
      pending.frames = [];
      pending.bytes = 0;
      pending.poisoned = true;
      pending.timer = this.armPreopenTimer(tunnelId, WS_POISON_TTL_MS);
      return;
    }
    if (!this.makeRoomForPreopen()) return;
    this.wsPreopen.set(tunnelId, {
      frames: [],
      bytes: 0,
      poisoned: true,
      timer: this.armPreopenTimer(tunnelId, WS_POISON_TTL_MS),
    });
  }

  private takePreopen(tunnelId: string): WsPreopen | undefined {
    const pending = this.wsPreopen.get(tunnelId);
    if (!pending) return undefined;
    clearTimeout(pending.timer);
    this.wsPreopenBytes -= pending.bytes;
    this.wsPreopen.delete(tunnelId);
    return pending;
  }

  private sendUpstream(entry: WsUpstream, data: string, binary: boolean): void {
    entry.socket.send(binary ? Buffer.from(data, "base64") : data);
  }

  /** The app's side of the tunnel closed (the browser tab's WS closed) —
   *  mirror it upstream, or discard the pre-open buffer when the tunnel never
   *  got that far. Idempotent: a close already relayed the other way (via
   *  [teardownWs]) has already removed the map entry. */
  onWsClose(msg: TunnelWsClose): void {
    if (this.stopped) return;
    const entry = this.wsTunnels.get(msg.tunnelId);
    if (!entry) {
      this.takePreopen(msg.tunnelId);
      return;
    }
    this.wsTunnels.delete(msg.tunnelId);
    this.releaseUpstream(entry);
  }

  stop(): void {
    this.stopped = true;
    this.sentUrlDetails.clear();
    this.outbox.clear();
    this.outboxBytes = 0;
    // Aborted before the map is cleared, or a run in flight would keep reading
    // its upstream and shipping frames a stopped manager can no longer own.
    this.abortHttpStreams();
    this.inflight.clear();
    for (const [tunnelId, entry] of this.wsTunnels) {
      // Delete BEFORE closing so the socket's own close event finds nothing
      // and cannot send a second frame — and send here rather than leave it to
      // that event, which a socket still CONNECTING never fires at all. A
      // session deleted mid-handshake would otherwise leave the app's tunnel
      // entry and the browser's socket waiting on a close that never comes.
      this.wsTunnels.delete(tunnelId);
      void this.sendTunnel({
        type: "tunnel:ws-close",
        tunnelId,
        reason: "tunnel manager stopped",
        checkoutId: entry.checkoutId,
      });
      this.releaseUpstream(entry);
    }
    this.wsTunnels.clear();
    for (const pending of this.wsPreopen.values()) clearTimeout(pending.timer);
    this.wsPreopen.clear();
    this.wsPreopenBytes = 0;
  }
}
