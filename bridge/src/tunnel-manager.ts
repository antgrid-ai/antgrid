import { logger } from "./logger";
const log = logger.child({ component: "tunnel-manager" });
import {
  fetchLocalhost,
  isTlsOnlyPort,
  UpstreamBodyError,
  type FetchLocalhostOpts,
  type LocalhostFetchStream,
  type TunnelRequestBody,
} from "./localhost-fetch";
import { createMessage, type AbMessage, type PortInfo, type PreviewUrlEntry } from "./protocol";
import type { TunnelHttpRequest, TunnelWsOpen } from "./tunnel-protocol";
import type { StreamSendOutcome } from "./peer/stream-records";
import { STREAM_TUNNEL_DATA_MAX_BYTES } from "antgrid-wire";
import type { ConnState } from "./conn-state";

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
const WS_BUFFER_MAX_FRAMES = 64;
const WS_BUFFER_MAX_BYTES = 1024 * 1024;

/** The slice-sizing and upstream-clock seams a test overrides; production
 *  leaves every one of them at the module defaults. */
export type TunnelFetchOpts = Pick<
  FetchLocalhostOpts,
  "headTimeoutMs" | "readIdleMs" | "chunkBytes" | "flushMs" | "maxBodyBytes"
>;

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

/** One HTTP tunnel run's view of its own stream: the registry (A3
 *  `peer/tunnel-streams.ts`) implements this over a `StreamRecordWriter`. */
export interface TunnelHttpExchange {
  /** Whose stream this run is on — `abortHttpStreams(peerId)` aborts by this,
   *  never by project or checkout, so a second phone establishing does not
   *  abort a first phone's in-flight preview load (A3 trap, §3.8). */
  readonly peerId: string;
  /** Aborted by the app's cancel, a failed/gated send, projectDetached, dropPeer, or abortHttpStreams. */
  readonly signal: AbortSignal;
  head(head: { status: number; headers: Record<string, string>; setCookies?: string[] }): Promise<StreamSendOutcome>;
  /** Raw bytes, at most `TUNNEL_BODY_SLICE_BYTES` per call. */
  body(bytes: Uint8Array): Promise<StreamSendOutcome>;
  /** FIN's the send half. Only after the upstream body completed without error. */
  end(): Promise<StreamSendOutcome>;
  /** writer.abort(): reset, no end record. Idempotent; a no-op after end(). */
  fail(reason: string): void;
}

export interface TunnelWsFrame {
  binary: boolean;
  bytes: Uint8Array;
}

/** One WS tunnel run's view of its own stream. */
export interface TunnelWsPeer {
  /** One upstream message toward the app. "dropped" means the stream is gone: release the upstream (1001). */
  send(frame: TunnelWsFrame): Promise<StreamSendOutcome>;
  /** Upstream closed: queue a tunnel:ws-close after every frame already sent, then FIN. Idempotent. */
  close(code?: number, reason?: string): void;
}

export interface TunnelWsUpstreamSink {
  /** One app message toward the upstream (buffered while CONNECTING, as today). */
  data(frame: TunnelWsFrame): void;
  /** The app closed (close record, FIN or reset) or the stream was torn down. Idempotent. */
  closed(code?: number, reason?: string): void;
}

export type TunnelAdmission =
  | { ok: false; refusal: { code: "NOT_ALLOWED"; message: string } }
  | { ok: true; manager: TunnelManager };

/** What a project's core exposes to the tunnel registry: `AgentCore`
 *  implements it (`agent-core.ts`). */
export interface TunnelStreamServer {
  admit(peerId: string, checkoutId: string): TunnelAdmission;
}

/** One upstream `ws://localhost:<port><path>` connection for a browser-side
 *  tab's own WebSocket, open for the life of the tunnel stream. IS the
 *  `TunnelWsUpstreamSink` handed back to the caller, and `wsRuns` is keyed by
 *  its identity rather than by `tunnelId`: this manager is scoped to one
 *  PROJECT, not one peer, so two peers legitimately choose the same
 *  `tunnelId` and only the registry (per peer) guarantees it is unique. */
class TunnelWsRun implements TunnelWsUpstreamSink {
  socket: WebSocket | undefined;
  open = false;
  /** The tunnel is over: nothing this socket says may reach `peer` any more,
   *  and nothing may be relayed into it. Set on both the closed-by-app and
   *  closed-by-upstream paths so either one short-circuits the other. */
  abandoned = false;
  /** Frames sent by the app before this socket finished its own handshake. */
  pending: TunnelWsFrame[] = [];
  pendingBytes = 0;

  constructor(private readonly mgr: TunnelManager, readonly peer: TunnelWsPeer) {}

  data(frame: TunnelWsFrame): void {
    this.mgr.relayToUpstream(this, frame);
  }

  closed(): void {
    this.mgr.wsClosedByApp(this);
  }
}

export class TunnelManager {
  private projectId: string;
  private portLabels: Map<number, string>;
  private previewPorts: Set<number>;
  private sendEncrypted: (msg: AbMessage) => void;
  private relayHost: string;
  private connState: ConnState;
  private fetchOpts: TunnelFetchOpts;
  private sentUrlDetails = new Map<number, PreviewUrlEntry>();
  /** Ports whose current entry was recorded while the stream was suppressed and
   *  so never reached the phone. Cleared on the send that delivers them. */
  private undelivered = new Set<number>();
  /** Per-run controllers for every `serveHttp` in flight, keyed to the peer
   *  whose stream it runs on, so `abortHttpStreams(peerId)` can cancel one
   *  peer's runs without the manager tracking requestIds — the registry (one
   *  per peer) is what dedupes those. */
  private inflight = new Map<AbortController, string>();
  /** Live WS relays — see [TunnelWsRun]. */
  private wsRuns = new Set<TunnelWsRun>();
  /** Sockets released mid-handshake — see [WS_ABANDONED_MAX]. Insertion-ordered
   *  so the oldest is the eviction candidate. Outlives [stop] on purpose: the
   *  manager is gone, the dev server is not. */
  private wsAbandoned = new Set<TunnelWsRun>();
  private wsAbandonedMax: number;
  /** [stop] is terminal. Without this a frame still in flight when a checkout
   *  is torn down re-arms a timer on a manager nothing owns any more — the
   *  callers null nothing, so the flag is what has to hold the line. */
  private stopped = false;

  constructor(opts: {
    projectId: string;
    portLabels: Map<number, string>;
    previewPorts: Set<number>;
    sendEncrypted: (msg: AbMessage) => void;
    relayHost: string;
    connState: ConnState;
    wsAbandonedMax?: number;
    /** Test seam: slice sizing and the upstream clocks. */
    fetchOpts?: TunnelFetchOpts;
  }) {
    this.projectId = opts.projectId;
    this.portLabels = opts.portLabels;
    this.previewPorts = opts.previewPorts;
    this.sendEncrypted = opts.sendEncrypted;
    this.relayHost = opts.relayHost;
    this.connState = opts.connState;
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

  /** Runs one HTTP request end to end: fetch localhost, stream the response
   *  through `exchange`, then `end()` or `fail()`. Never rejects — every
   *  failure path is answered on `exchange` (a synthesized 502, or `fail`),
   *  never thrown back at the caller. */
  async serveHttp(req: TunnelHttpRequest, body: TunnelRequestBody | null, exchange: TunnelHttpExchange): Promise<void> {
    const runAbort = new AbortController();
    this.inflight.set(runAbort, exchange.peerId);
    try {
      await this.runHttp(req, body, exchange, AbortSignal.any([exchange.signal, runAbort.signal]), runAbort);
    } finally {
      this.inflight.delete(runAbort);
    }
    // An abort that did not come through the exchange (abortHttpStreams, stop)
    // still owes the stream its reset: the app is alive and would otherwise
    // wait out its idle timer on a body that will never finish, holding a
    // tunnel slot on both ends. A no-op once end() has been written.
    if (runAbort.signal.aborted && !exchange.signal.aborted) exchange.fail("aborted");
  }

  private async runHttp(
    req: TunnelHttpRequest,
    body: TunnelRequestBody | null,
    exchange: TunnelHttpExchange,
    signal: AbortSignal,
    runAbort: AbortController,
  ): Promise<void> {
    const safePath = req.path.startsWith("/") ? req.path : `/${req.path}`;
    const url = `${req.scheme ?? "http"}://localhost:${req.port}${safePath}`;

    let head: LocalhostFetchStream;
    try {
      head = await fetchLocalhost({
        url,
        method: req.method,
        headers: req.headers,
        body: body ?? undefined,
        signal,
        ...this.fetchOpts,
      });
    } catch (err) {
      if (signal.aborted) return;
      const text = `Proxy error: ${err instanceof Error ? err.message : String(err)}`;
      // The 502 reaches only the previewing device, so without this a tunnel
      // failure is diagnosable exclusively from the phone's screen.
      log.warn("Tunnel fetch failed for %s: %s", url, text);
      // A head failure is a real, replayable answer — not an error end: the
      // real headers never went out, so there is nothing incomplete to abort.
      await this.sendSynthesizedError(exchange, runAbort, 502, text);
      return;
    }

    const it = head.body;
    let started = false;
    try {
      // Peeked BEFORE the real head goes out: a first-piece failure (a stalled
      // read, a body over the cap) is answered the same as a head-fetch
      // failure, both being a position with nothing sent yet.
      const first = await it.next();
      if (!(await this.sendOrAbort(
        exchange.head({ status: head.status, headers: head.headers, setCookies: head.setCookies }),
        runAbort,
      ))) return;
      started = true;
      if (!first.done) {
        if (!(await this.sendOrAbort(exchange.body(first.value), runAbort))) return;
        // Read-side pacing: the next piece is pulled only once the previous
        // one has left the send queue, so a stream holds at most one queued
        // piece and QUIC flow control is the only thing setting the rate.
        // The loop keeps reading until the generator itself reports done —
        // a clean FIN and a reset are natively distinguishable on the wire,
        // so no piece needs to carry a `last` flag of its own.
        for (;;) {
          const next = await it.next();
          if (next.done) break;
          if (!(await this.sendOrAbort(exchange.body(next.value), runAbort))) return;
        }
      }
      await this.sendOrAbort(exchange.end(), runAbort);
    } catch (err) {
      // Our own cancel: the app has already forgotten the id.
      if (signal.aborted) return;
      const reason = err instanceof UpstreamBodyError
        ? err.message
        : `upstream read failed: ${err instanceof Error ? err.message : String(err)}`;
      if (!started) {
        log.warn("Tunnel stream %s failed before its head went out: %s", req.requestId, reason);
        await this.sendSynthesizedError(exchange, runAbort, 502, `Proxy error: ${reason}`);
        return;
      }
      log.warn("Tunnel stream %s ended with error after the head: %s", req.requestId, reason);
      exchange.fail(reason);
    } finally {
      // Cancels the upstream read on every exit path.
      await it.return(undefined).catch(() => {});
    }
  }

  /** Awaits one send; a non-"sent" outcome aborts the run (the writer has
   *  already reset, or the registry aborted it) and reports "stop here". */
  private async sendOrAbort(promise: Promise<StreamSendOutcome>, runAbort: AbortController): Promise<boolean> {
    if (await promise === "sent") return true;
    runAbort.abort();
    return false;
  }

  private async sendSynthesizedError(
    exchange: TunnelHttpExchange,
    runAbort: AbortController,
    status: number,
    text: string,
  ): Promise<void> {
    if (!(await this.sendOrAbort(exchange.head({ status, headers: {} }), runAbort))) return;
    if (!(await this.sendOrAbort(exchange.body(new TextEncoder().encode(text)), runAbort))) return;
    await this.sendOrAbort(exchange.end(), runAbort);
  }

  /** `peerId`'s session or project stream is gone: every in-flight HTTP run of
   *  THIS peer exits through its own cancelled path — the fetch aborted, the
   *  upstream connection closed, nothing retained — instead of streaming the
   *  rest of a body toward a stream that is already gone. A sibling peer's
   *  runs are untouched, so a second phone establishing does not abort the
   *  first phone's preview load. WS tunnels are left alone: the app re-opens
   *  them on loss. */
  abortHttpStreams(peerId: string): void {
    for (const [controller, p] of this.inflight) {
      if (p === peerId) controller.abort();
    }
  }

  /** Opens the real upstream WebSocket for a browser-side tab's WS and returns
   *  the sink the caller feeds app-side traffic into. Never throws back at the
   *  caller — an upstream that refuses/errors reports through `peer.close`,
   *  mirroring what a rejected browser-side connect would look like, rather
   *  than dropping silently. */
  serveWs(open: TunnelWsOpen, peer: TunnelWsPeer): TunnelWsUpstreamSink {
    const run = new TunnelWsRun(this, peer);
    // The phone can only guess the scheme for a dev server it never saw
    // announce itself; `fetchLocalhost` has already corrected the guess for
    // this port by the time a page on it opens a socket.
    const secure = open.scheme === "https" || isTlsOnlyPort(open.port);
    const safePath = open.path.startsWith("/") ? open.path : `/${open.path}`;
    const url = `${secure ? "wss" : "ws"}://localhost:${open.port}${safePath}`;
    // Same self-signed-cert exemption `fetchLocalhost` makes, and for the same
    // reason: without it every wss upstream dies in the TLS handshake, and a
    // dev server whose page needs a socket — Blazor, Vite HMR, a live-reload
    // shim — renders as a blank tab with nothing to point at.
    const tlsOptions: Bun.WebSocketOptions = secure ? { tls: { rejectUnauthorized: false } } : {};
    const { headers, protocols } = splitUpstreamWsHeaders(open.headers);
    // Every option is either a plain property or annotated on its own const,
    // because TypeScript skips its excess-property check on a spread: a typo'd
    // `protocolls`, or `tsl` above, inside `...(cond ? { ... } : {})` compiles
    // clean and costs the whole option silently. An empty `protocols` sends no
    // header, same as omitting it.
    const wsOptions: Bun.WebSocketOptions = { headers, protocols, ...tlsOptions };
    const socket = this.openUpstream(url, wsOptions, open, peer);
    if (!socket) {
      // openUpstream already reported the close; mark the run dead so a
      // `data()` the caller sends before it notices never buffers forever.
      run.abandoned = true;
      return run;
    }
    run.socket = socket;
    this.wsRuns.add(run);

    socket.addEventListener("open", () => {
      if (run.abandoned) {
        // Now a completed handshake, so this close is a FIN the server's own
        // WebSocket layer answers — not the reset a close mid-handshake sends.
        this.wsAbandoned.delete(run);
        socket.close();
        return;
      }
      run.open = true;
      // The app answered the browser's 101 with `protocols[0]` before this
      // socket existed, so a server that picks a LATER entry leaves the two
      // ends framing to different subprotocols with no error on either — Bun
      // opens on any answer — and this log is the only place that shows.
      // It catches only that half: measured, Bun reports `protocol` as the
      // FIRST OFFERED entry when the server echoes none at all, so a server
      // that negotiated nothing is indistinguishable here from one that
      // accepted the browser's choice.
      if (protocols.length > 0 && socket.protocol && socket.protocol !== protocols[0]) {
        log.warn(
          "WS tunnel %s: upstream chose subprotocol %s, the page was told %s",
          open.tunnelId,
          socket.protocol,
          protocols[0],
        );
      }
      for (const frame of run.pending) this.sendUpstream(run, frame);
      run.pending = [];
      run.pendingBytes = 0;
    });
    // A released socket answers to nobody: its run is already gone from
    // `wsRuns` and, over a long park, may even belong to a tunnelId a fresh
    // `serveWs` call has since reused — so nothing it does may reach `peer`.
    socket.addEventListener("message", (event) => {
      if (run.abandoned) return;
      const binary = typeof event.data !== "string";
      const bytes = binary
        ? event.data instanceof ArrayBuffer
          ? new Uint8Array(event.data)
          : (event.data as Uint8Array)
        : new TextEncoder().encode(event.data as string);
      if (bytes.byteLength > STREAM_TUNNEL_DATA_MAX_BYTES) {
        log.warn("Closing WS tunnel %s: upstream message too large to tunnel", open.tunnelId);
        this.wsRuns.delete(run);
        run.peer.close(1009);
        this.releaseUpstream(run);
        return;
      }
      void run.peer.send({ binary, bytes }).then((outcome) => {
        if (outcome === "sent" || run.abandoned) return;
        if (!this.wsRuns.has(run)) return; // already torn down by another path
        // A WS stream with a hole in it is worse than a closed one, and the
        // page's reconnect gives it a fresh tunnel.
        log.warn("Closing WS tunnel %s: upstream frame could not be delivered", open.tunnelId);
        this.wsRuns.delete(run);
        run.peer.close(1001);
        this.releaseUpstream(run);
      });
    });
    // Both endings free the park slot first: a socket that ERRORS while parked
    // holds one just as a closed one does, and the budget has no TTL to
    // reclaim it later.
    const settle = (code?: number, reason?: string) => {
      this.wsAbandoned.delete(run);
      if (run.abandoned) return;
      this.wsRuns.delete(run);
      run.peer.close(code, reason);
      run.abandoned = true;
    };
    socket.addEventListener("close", (event) => settle(event.code, event.reason));
    socket.addEventListener("error", () => settle());
    return run;
  }

  /** A browser-sent frame to relay upstream, buffered on [TunnelWsRun.pending]
   *  while the real connection is still handshaking. Bounded, and an overflow
   *  ends the tunnel rather than relays a stream with a hole in it. */
  relayToUpstream(run: TunnelWsRun, frame: TunnelWsFrame): void {
    if (this.stopped || run.abandoned) return;
    if (!run.open) {
      // A port that accepts TCP but stalls the upgrade — a dev server
      // mid-startup, or an https-only port reached as `ws://` — holds this
      // open for the OS connect timeout, so the buffer needs its own cap
      // rather than trusting the handshake to resolve quickly.
      if (
        run.pending.length >= WS_BUFFER_MAX_FRAMES
        || run.pendingBytes + frame.bytes.byteLength > WS_BUFFER_MAX_BYTES
      ) {
        log.warn("Closing WS tunnel: upstream handshake did not finish before its buffer filled");
        this.wsRuns.delete(run);
        run.peer.close(undefined, "upstream handshake buffer overflow");
        this.releaseUpstream(run);
        return;
      }
      run.pending.push(frame);
      run.pendingBytes += frame.bytes.byteLength;
      return;
    }
    this.sendUpstream(run, frame);
  }

  /** The app's side of the tunnel closed (the browser tab's WS closed) —
   *  mirror it upstream. Idempotent: a close already relayed the other way
   *  (via `settle` in `serveWs`) has already marked the run abandoned. */
  wsClosedByApp(run: TunnelWsRun): void {
    if (this.stopped || run.abandoned || !this.wsRuns.has(run)) return;
    this.wsRuns.delete(run);
    this.releaseUpstream(run);
  }

  /** The upstream socket for [serveWs], or undefined once the tunnel has been
   *  refused. The constructor VALIDATES both of the strings the browser chose:
   *  Bun throws `SyntaxError` for a subprotocol that is not an RFC 6455 token
   *  and for a URL carrying a fragment. Nothing between the registry's read
   *  loop and here catches, and `index.ts` answers an uncaught exception by
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
    open: TunnelWsOpen,
    peer: TunnelWsPeer,
  ): WebSocket | undefined {
    try {
      return new WebSocket(url, wsOptions as unknown as string[]);
    } catch (err) {
      log.warn("Refusing WS tunnel %s: upstream connection was rejected: %s", open.tunnelId, err);
      peer.close(undefined, "upstream connection could not be opened");
      return undefined;
    }
  }

  /** Close an upstream whose tunnel is over. An OPEN socket closes now. One
   *  still CONNECTING is parked and closed once it opens — or once it fails on
   *  its own — because closing it now is a reset, and a reset can take the dev
   *  server down with it (see [WS_ABANDONED_MAX]). The park is bounded.
   *
   *  The caller MUST have dropped [run] from [wsRuns] first. Releasing marks
   *  the run abandoned, which permanently suppresses anything it would still
   *  say to [peer] — so a run left in the set becomes immortal, with the app
   *  never told the tunnel died. */
  private releaseUpstream(run: TunnelWsRun): void {
    run.abandoned = true;
    run.pending = [];
    run.pendingBytes = 0;
    if (run.open) {
      run.socket?.close();
      return;
    }
    // Same shape as an LRU eviction: drain until under budget, so the bound
    // holds whatever [wsAbandonedMax] is rather than only for a set that grows
    // by one.
    for (const oldest of this.wsAbandoned) {
      if (this.wsAbandoned.size < this.wsAbandonedMax) break;
      // The one path that closes a socket mid-handshake, which is the reset the
      // park exists to avoid — so it says so, like every other drop path here.
      // Logged before the delete, so the count is read and not reconstructed.
      log.warn("Cutting a parked WS handshake: %d parked, cap %d", this.wsAbandoned.size, this.wsAbandonedMax);
      this.wsAbandoned.delete(oldest);
      oldest.socket?.close();
    }
    this.wsAbandoned.add(run);
  }

  private sendUpstream(run: TunnelWsRun, frame: TunnelWsFrame): void {
    run.socket?.send(frame.binary ? frame.bytes : new TextDecoder().decode(frame.bytes));
  }

  /** Aborts every HTTP run, and closes every upstream WS with `peer.close(1001)`. */
  stop(): void {
    this.stopped = true;
    this.sentUrlDetails.clear();
    // Aborted before the run set is cleared, or a run in flight would keep
    // reading its upstream and shipping frames a stopped manager can no
    // longer own. Every peer's runs, unlike `abortHttpStreams(peerId)`.
    for (const controller of this.inflight.keys()) controller.abort();
    this.inflight.clear();
    for (const run of this.wsRuns) {
      // Deleted BEFORE closing so the socket's own close event finds nothing
      // and cannot call back into a manager that has already reported this
      // tunnel over.
      this.wsRuns.delete(run);
      run.peer.close(1001, "tunnel manager stopped");
      this.releaseUpstream(run);
    }
  }
}
