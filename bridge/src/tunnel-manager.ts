import { logger } from "./logger";
const log = logger.child({ component: "tunnel-manager" });
import { fetchLocalhost, isTlsOnlyPort } from "./localhost-fetch";
import { createMessage, type AbMessage, type PortInfo, type PreviewUrlEntry } from "./protocol";
import type { TunnelHttpRequest, TunnelWsClose, TunnelWsData, TunnelWsOpen } from "./tunnel-protocol";
import type { ConnState } from "./conn-state";

/** One upstream `ws://localhost:<port><path>` connection, keyed by tunnelId.
 *  [pending] holds app→bridge frames that arrived before `open` fired (the
 *  browser can send immediately once ITS local WS accepts, which races this
 *  socket's real handshake) — flushed in order on open, then unused. */
interface WsUpstream {
  socket: WebSocket;
  open: boolean;
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
 *  Outlives the app's 30s tunnel timeout so the refusal beats the give-up. */
const WS_POISON_TTL_MS = 35_000;
const WS_PREOPEN_MAX_TUNNELS = 64;
const WS_BUFFER_MAX_FRAMES = 64;
const WS_BUFFER_MAX_BYTES = 1024 * 1024;
const WS_PREOPEN_MAX_TOTAL_BYTES = 16 * 1024 * 1024;
/** Both buffers are fed from the data path, so their drop paths must never log
 *  per frame — a streaming socket would emit thousands of lines. */
const WS_PREOPEN_WARN_INTERVAL_MS = 5_000;

/** How long a sent response stays replayable. Must outlive the app's 30s tunnel
 *  timeout so a retry issued just before it gives up still finds the entry. */
const OUTBOX_TTL_MS = 35_000;
/** Bodies past this are not retained. A retry for one re-fetches, which is safe
 *  in the case that produces them — a large GET is a static asset. The requests
 *  where re-execution actually bites (a dev API route behind a GET) are small,
 *  and those are exactly the ones this keeps. */
const OUTBOX_MAX_ENTRY_BYTES = 2 * 1024 * 1024;
const OUTBOX_MAX_TOTAL_BYTES = 16 * 1024 * 1024;

// Handshake headers the upstream connection owns: Bun mints its own key,
// version and framing, and `host` follows from the URL we build. The
// subprotocol is dropped rather than forwarded because nothing carries the
// server's choice back to the browser — letting the server agree one the
// browser never hears about is worse than negotiating none.
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
  "sec-websocket-protocol",
]);

function upstreamWsHeaders(headers: Record<string, string> | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(headers ?? {})) {
    if (WS_HOP_BY_HOP_HEADERS.has(k.toLowerCase())) continue;
    out[k] = v;
  }
  return out;
}

export class TunnelManager {
  private projectId: string;
  private portLabels: Map<number, string>;
  private previewPorts: Set<number>;
  private sendTunnel: (data: object) => void;
  private sendEncrypted: (msg: AbMessage) => void;
  private relayHost: string;
  private connState: ConnState;
  private sentUrlDetails = new Map<number, PreviewUrlEntry>();
  /** Ports whose current entry was recorded while the stream was suppressed and
   *  so never reached the phone. Cleared on the send that delivers them. */
  private undelivered = new Set<number>();
  /** Responses already emitted, keyed by requestId, so a retry replays rather
   *  than re-runs. The relay drops a routed frame when the pair/channel budget
   *  is exhausted and tells only the SENDER, so neither end can tell whether the
   *  request or the response died — the app therefore retries with the original
   *  requestId and this is what makes that safe. Insertion-ordered: the oldest
   *  entry is the first eviction candidate. */
  private outbox = new Map<string, { response: object; bytes: number; expiresAt: number }>();
  private outboxBytes = 0;
  /** Requests currently being fetched. A retry can arrive while the original is
   *  still upstream (the app cannot see that), and awaiting it here is what
   *  stops the duplicate from becoming a second upstream request. */
  private inflight = new Map<string, Promise<void>>();
  /** Live WS relays, keyed by tunnelId — see [WsUpstream]. */
  private wsTunnels = new Map<string, WsUpstream>();
  /** Async sealing can put the first data frame ahead of its open frame. Keep
   *  that bounded orphan briefly so a Blazor/SignalR handshake is not lost.
   *  Insertion-ordered: the oldest tombstone is the first eviction candidate. */
  private wsPreopen = new Map<string, WsPreopen>();
  private wsPreopenBytes = 0;
  private wsPreopenWarnedAt = 0;
  private wsPreopenTtlMs: number;
  /** [stop] is terminal. Without this a frame still in flight when a checkout
   *  is torn down re-arms a timer on a manager nothing owns any more — the
   *  callers null nothing, so the flag is what has to hold the line. */
  private stopped = false;

  constructor(opts: {
    projectId: string;
    portLabels: Map<number, string>;
    previewPorts: Set<number>;
    sendTunnel: (data: object) => void;
    sendEncrypted: (msg: AbMessage) => void;
    relayHost: string;
    connState: ConnState;
    wsPreopenTtlMs?: number;
  }) {
    this.projectId = opts.projectId;
    this.portLabels = opts.portLabels;
    this.previewPorts = opts.previewPorts;
    this.sendTunnel = opts.sendTunnel;
    this.sendEncrypted = opts.sendEncrypted;
    this.relayHost = opts.relayHost;
    this.connState = opts.connState;
    this.wsPreopenTtlMs = opts.wsPreopenTtlMs ?? WS_PREOPEN_TTL_MS;
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
    // request the app is waiting on costs it a 30s timeout if dropped, and
    // serving one holds nothing open afterwards.
    // Outbox first, before anything can reach the dev server: this is the whole
    // safety property of the app's retry.
    const inflight = this.inflight.get(msg.requestId);
    if (inflight) await inflight.catch(() => {});
    const stored = this.readOutbox(msg.requestId);
    if (stored) {
      this.sendTunnel(stored);
      return;
    }

    const run = this.fetchAndRespond(msg);
    this.inflight.set(msg.requestId, run);
    try {
      await run;
    } finally {
      this.inflight.delete(msg.requestId);
    }
  }

  private async fetchAndRespond(msg: TunnelHttpRequest): Promise<void> {
    const safePath = msg.path.startsWith("/") ? msg.path : `/${msg.path}`;
    const url = `${msg.scheme ?? "http"}://localhost:${msg.port}${safePath}`;
    try {
      const result = await fetchLocalhost({
        url,
        method: msg.method,
        headers: msg.headers,
        body: msg.body,
        acceptEncodings: msg.acceptEncodings,
      });

      this.emitResponse(msg.requestId, result.body, {
        type: "tunnel:http-response" as const,
        requestId: msg.requestId,
        status: result.status,
        headers: result.headers,
        setCookies: result.setCookies,
        body: result.body,
        bodyEncoding: result.bodyEncoding,
        checkoutId: msg.checkoutId,
      });
    } catch (err) {
      const body = `Proxy error: ${err instanceof Error ? err.message : String(err)}`;
      // The 502 reaches only the previewing device, so without this a tunnel
      // failure is diagnosable exclusively from the phone's screen.
      log.warn("Tunnel fetch failed for %s: %s", url, body);
      this.emitResponse(msg.requestId, body, {
        type: "tunnel:http-response" as const,
        requestId: msg.requestId,
        status: 502,
        headers: {},
        body,
        bodyEncoding: "utf8" as const,
        checkoutId: msg.checkoutId,
      });
    }
  }

  /** Send a response and retain it for replay. */
  private emitResponse(requestId: string, body: string, response: object): void {
    const bytes = Buffer.byteLength(body);
    if (bytes <= OUTBOX_MAX_ENTRY_BYTES) {
      this.evictOutbox(bytes);
      this.outbox.set(requestId, { response, bytes, expiresAt: Date.now() + OUTBOX_TTL_MS });
      this.outboxBytes += bytes;
    }
    this.sendTunnel(response);
  }

  private readOutbox(requestId: string): object | undefined {
    const entry = this.outbox.get(requestId);
    if (!entry) return undefined;
    if (entry.expiresAt <= Date.now()) {
      this.outbox.delete(requestId);
      this.outboxBytes -= entry.bytes;
      return undefined;
    }
    return entry.response;
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
      this.sendTunnel({
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
      this.sendTunnel({
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
    // lib.dom's WebSocket shadows Bun's (tsconfig takes the default libs for an
    // ESNext target), and its constructor's second parameter is `protocols` —
    // so the options Bun does accept at runtime have to be cast past the type.
    const wsOptions: Bun.WebSocketOptions = {
      headers: upstreamWsHeaders(msg.headers),
      ...(secure ? { tls: { rejectUnauthorized: false } } : {}),
    };
    const socket = new WebSocket(url, wsOptions as unknown as string[]);
    const entry: WsUpstream = {
      socket,
      open: false,
      pending: preopen?.frames ?? [],
      pendingBytes: preopen?.bytes ?? 0,
      checkoutId: msg.checkoutId,
    };
    this.wsTunnels.set(msg.tunnelId, entry);

    entry.socket.addEventListener("open", () => {
      entry.open = true;
      for (const frame of entry.pending) this.sendUpstream(entry, frame.data, frame.binary);
      entry.pending = [];
      entry.pendingBytes = 0;
    });
    entry.socket.addEventListener("message", (event) => {
      const binary = typeof event.data !== "string";
      const data = typeof event.data === "string"
        ? event.data
        : event.data instanceof ArrayBuffer
          ? Buffer.from(event.data).toString("base64")
          : Buffer.from(event.data as Uint8Array).toString("base64");
      this.sendTunnel({
        type: "tunnel:ws-data",
        tunnelId: msg.tunnelId,
        data,
        ...(binary ? { binary: true } : {}),
        checkoutId: msg.checkoutId,
      });
    });
    entry.socket.addEventListener("close", (event) =>
      this.teardownWs(msg.tunnelId, event.code, event.reason),
    );
    entry.socket.addEventListener("error", () => this.teardownWs(msg.tunnelId));
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
    this.sendTunnel({
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
        // Report before closing: the socket's own close event runs the same
        // teardown, and whichever wins owns the reason the app is told.
        this.teardownWs(msg.tunnelId, undefined, "upstream handshake buffer overflow");
        entry.socket.close();
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
    entry.socket.close();
  }

  stop(): void {
    this.stopped = true;
    this.sentUrlDetails.clear();
    this.outbox.clear();
    this.outboxBytes = 0;
    this.inflight.clear();
    for (const [tunnelId, entry] of this.wsTunnels) {
      // Delete BEFORE closing so the socket's own close event finds nothing
      // and cannot send a second frame — and send here rather than leave it to
      // that event, which a socket still CONNECTING never fires at all. A
      // session deleted mid-handshake would otherwise leave the app's tunnel
      // entry and the browser's socket waiting on a close that never comes.
      this.wsTunnels.delete(tunnelId);
      this.sendTunnel({
        type: "tunnel:ws-close",
        tunnelId,
        reason: "tunnel manager stopped",
        checkoutId: entry.checkoutId,
      });
      entry.socket.close();
    }
    this.wsTunnels.clear();
    for (const pending of this.wsPreopen.values()) clearTimeout(pending.timer);
    this.wsPreopen.clear();
    this.wsPreopenBytes = 0;
  }
}
