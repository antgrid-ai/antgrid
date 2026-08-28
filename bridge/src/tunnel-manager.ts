import { logger } from "./logger";
const log = logger.child({ component: "tunnel-manager" });
import { fetchLocalhost } from "./localhost-fetch";
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
}

/** How long a sent response stays replayable. Must outlive the app's 30s tunnel
 *  timeout so a retry issued just before it gives up still finds the entry. */
const OUTBOX_TTL_MS = 35_000;
/** Bodies past this are not retained. A retry for one re-fetches, which is safe
 *  in the case that produces them — a large GET is a static asset. The requests
 *  where re-execution actually bites (a dev API route behind a GET) are small,
 *  and those are exactly the ones this keeps. */
const OUTBOX_MAX_ENTRY_BYTES = 2 * 1024 * 1024;
const OUTBOX_MAX_TOTAL_BYTES = 16 * 1024 * 1024;

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

  constructor(opts: {
    projectId: string;
    portLabels: Map<number, string>;
    previewPorts: Set<number>;
    sendTunnel: (data: object) => void;
    sendEncrypted: (msg: AbMessage) => void;
    relayHost: string;
    connState: ConnState;
  }) {
    this.projectId = opts.projectId;
    this.portLabels = opts.portLabels;
    this.previewPorts = opts.previewPorts;
    this.sendTunnel = opts.sendTunnel;
    this.sendEncrypted = opts.sendEncrypted;
    this.relayHost = opts.relayHost;
    this.connState = opts.connState;
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
    if (this.wsTunnels.has(msg.tunnelId)) return; // duplicate open, ignore
    const scheme = msg.scheme === "https" ? "wss" : "ws";
    const safePath = msg.path.startsWith("/") ? msg.path : `/${msg.path}`;
    const url = `${scheme}://localhost:${msg.port}${safePath}`;
    const entry: WsUpstream = { socket: new WebSocket(url), open: false, pending: [] };
    this.wsTunnels.set(msg.tunnelId, entry);

    entry.socket.addEventListener("open", () => {
      entry.open = true;
      for (const frame of entry.pending) this.sendUpstream(entry, frame.data, frame.binary);
      entry.pending = [];
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
    const teardown = (code?: number, reason?: string) => {
      if (!this.wsTunnels.delete(msg.tunnelId)) return; // already closed the other way
      this.sendTunnel({
        type: "tunnel:ws-close",
        tunnelId: msg.tunnelId,
        ...(code !== undefined ? { code } : {}),
        ...(reason ? { reason } : {}),
        checkoutId: msg.checkoutId,
      });
    };
    entry.socket.addEventListener("close", (event) => teardown(event.code, event.reason));
    entry.socket.addEventListener("error", () => teardown());
  }

  /** A browser-sent frame to relay upstream. Queued on [WsUpstream.pending]
   *  if the real connection hasn't finished its handshake yet. */
  onWsData(msg: TunnelWsData): void {
    const entry = this.wsTunnels.get(msg.tunnelId);
    if (!entry) return; // closed/never opened — nothing to relay into
    if (!entry.open) {
      entry.pending.push({ data: msg.data, binary: msg.binary === true });
      return;
    }
    this.sendUpstream(entry, msg.data, msg.binary === true);
  }

  private sendUpstream(entry: WsUpstream, data: string, binary: boolean): void {
    entry.socket.send(binary ? Buffer.from(data, "base64") : data);
  }

  /** The app's side of the tunnel closed (the browser tab's WS closed) —
   *  mirror it upstream. Idempotent: a close already relayed the other way
   *  (via [onWsOpen]'s teardown) has already removed the map entry. */
  onWsClose(msg: TunnelWsClose): void {
    const entry = this.wsTunnels.get(msg.tunnelId);
    if (!entry) return;
    this.wsTunnels.delete(msg.tunnelId);
    entry.socket.close();
  }

  stop(): void {
    this.sentUrlDetails.clear();
    this.outbox.clear();
    this.outboxBytes = 0;
    this.inflight.clear();
    for (const entry of this.wsTunnels.values()) entry.socket.close();
    this.wsTunnels.clear();
  }
}
