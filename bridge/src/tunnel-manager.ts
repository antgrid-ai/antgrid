import { logger } from "./logger";
const log = logger.child({ component: "tunnel-manager" });
import { createMessage, type AbMessage, type PortInfo, type PreviewUrlEntry } from "./protocol";
import type { TunnelTcpOpen } from "./tunnel-protocol";
import { probeTls, TunnelTcpRun, type TlsProbeResult, type TunnelTcpPeer, type TunnelTcpUpstreamSink } from "./tunnel-tcp";
import type { ConnState } from "./conn-state";

export type TunnelAdmission =
  | { ok: false; refusal: { code: "NOT_ALLOWED"; message: string } }
  | { ok: true; manager: TunnelManager };

/** What a project's core exposes to the tunnel registry: `AgentCore`
 *  implements it (`agent-core.ts`). */
export interface TunnelStreamServer {
  admit(peerId: string, checkoutId: string): TunnelAdmission;
}

export class TunnelManager {
  private projectId: string;
  private portLabels: Map<number, string>;
  private previewPorts: Set<number>;
  private sendEncrypted: (msg: AbMessage) => void;
  private relayHost: string;
  private connState: ConnState;
  private sentUrlDetails = new Map<number, PreviewUrlEntry>();
  /** Ports whose current entry was recorded while the stream was suppressed and
   *  so never reached the phone. Cleared on the send that delivers them. */
  private undelivered = new Set<number>();
  /** Live raw TCP forwards, each owning one upstream socket. */
  private tcpRuns = new Set<TunnelTcpRun>();
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
  }) {
    this.projectId = opts.projectId;
    this.portLabels = opts.portLabels;
    this.previewPorts = opts.previewPorts;
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

  /** Dials `localhost:<port>` and pipes raw bytes between it and `peer`. The
   *  bytes are the browser's own, so no header, cookie or scheme is ever
   *  translated here. Never throws: an unreachable port reports through
   *  `peer.unreachable`. */
  serveTcp(open: TunnelTcpOpen, peer: TunnelTcpPeer): TunnelTcpUpstreamSink {
    const run = new TunnelTcpRun(open.port, peer, (settled) => { this.tcpRuns.delete(settled); });
    if (this.stopped) {
      run.fail("tunnel manager stopped");
      return run;
    }
    this.tcpRuns.add(run);
    run.start();
    return run;
  }

  probeTcp(port: number): Promise<TlsProbeResult> {
    return probeTls(port);
  }

  /** Ends every forward: each upstream socket gets a graceful end and its
   *  stream a FIN. */
  stop(): void {
    this.stopped = true;
    this.sentUrlDetails.clear();
    for (const run of [...this.tcpRuns]) run.end();
    this.tcpRuns.clear();
  }
}
