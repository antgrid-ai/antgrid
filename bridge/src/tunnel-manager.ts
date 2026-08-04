import { logger } from "./logger";
const log = logger.child({ component: "tunnel-manager" });
import { fetchLocalhost } from "./localhost-fetch";
import { createMessage, type AbMessage, type PortInfo, type PreviewUrlEntry } from "./protocol";
import type { TunnelHttpRequest } from "./tunnel-protocol";
import type { ConnState } from "./conn-state";

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

      this.sendTunnel({
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
      this.sendTunnel({
        type: "tunnel:http-response" as const,
        requestId: msg.requestId,
        status: 502,
        headers: {},
        body: `Proxy error: ${err instanceof Error ? err.message : String(err)}`,
        bodyEncoding: "utf8" as const,
        checkoutId: msg.checkoutId,
      });
    }
  }

  stop(): void {
    this.sentUrlDetails.clear();
  }
}
