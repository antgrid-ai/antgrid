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
      }
    }

    // Send preview:url for new ports. Skipped entirely in local mode
    // (empty relayHost) — there's no relay-hosted preview origin to point at,
    // and the message has no consumer in that path.
    if (!this.relayHost) return;
    for (const p of ports) {
      // A port can gain a scheme after its entry was first sent (URL sighting
      // lands later than the line-based detection) — keep the snapshot fresh.
      const existing = this.sentUrlDetails.get(p.port);
      if (existing && p.scheme && existing.scheme !== p.scheme) {
        this.sentUrlDetails.set(p.port, { ...existing, scheme: p.scheme });
      }
      if (!this.sentUrlDetails.has(p.port) && this.previewPorts.has(p.port)) {
        const url = `http://${this.relayHost}/preview/${p.port}/`;
        const label = this.portLabels.get(p.port) ?? p.label;
        const entry: PreviewUrlEntry = {
          port: p.port,
          url,
          ...(label ? { label } : {}),
          ...(p.scheme ? { scheme: p.scheme } : {}),
        };
        this.sentUrlDetails.set(p.port, entry);
        if (this.connState.suppressed) continue;
        this.sendEncrypted(
          createMessage("preview:url", {
            projectId: this.projectId,
            port: p.port,
            url,
            ...(label ? { label } : {}),
          }),
        );
        log.info("Sent preview:url for port %d → %s", p.port, url);
      }
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
      });
    } catch (err) {
      this.sendTunnel({
        type: "tunnel:http-response" as const,
        requestId: msg.requestId,
        status: 502,
        headers: {},
        body: `Proxy error: ${err instanceof Error ? err.message : String(err)}`,
        bodyEncoding: "utf8" as const,
      });
    }
  }

  stop(): void {
    this.sentUrlDetails.clear();
  }
}
