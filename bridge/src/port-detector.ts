import type { PortInfo } from "./protocol";
import { extractUrls, canonicalize, toUrlString } from "./url-parser";

export interface PortDetectorInit {
  ports?: { port: number; name?: string }[];
}

export interface PortDetectionEvent {
  port: number;
  url: string;
  scheme: "http" | "https";
  source: "process" | "output";
  sourceSessionId?: string;
}

const PORT_PATTERNS = [
  // http://localhost:3000, http://127.0.0.1:8080, http://0.0.0.0:5173
  /https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d{4,5})/,
  // "listening on port 3000" or "listening on 3000"
  /listening\s+on\s+(?:port\s+)?(\d{4,5})/i,
  // "started on :5173" or "running on :3000"
  /(?:started|running)\s+on\s+:(\d{4,5})/i,
  // General ":NNNN" (4+ digit port after colon)
  /:(\d{4,5})\b/,
];

const MAX_LINE_BUFFER = 64 * 1024; // 64KB — truncate if no newline arrives

function extractPort(line: string): number | null {
  if (!line.includes(":")) {
    const lower = line.toLowerCase();
    if (!lower.includes("port") && !lower.includes("listening") && !lower.includes("running")) return null;
  }
  for (const pattern of PORT_PATTERNS) {
    const match = line.match(pattern);
    if (match) {
      const port = parseInt(match[1], 10);
      if (port >= 1024 && port <= 65535) return port;
    }
  }
  return null;
}

export class PortDetector {
  private terminalPorts = new Map<string, Set<number>>();
  private configuredPorts: Set<number>;
  private portLabels: Map<number, string>;
  private lineBuffers = new Map<string, string>();
  private observers = new Set<(e: PortDetectionEvent) => void>();
  private lastDetections = new Map<number, { url: string; scheme: "http" | "https"; source: "process" | "output" }>();
  onPortsChange: ((ports: PortInfo[]) => void) | null = null;

  onDetection(fn: (e: PortDetectionEvent) => void): () => void {
    this.observers.add(fn);
    return () => {
      this.observers.delete(fn);
    };
  }

  observeOutput(sessionId: string, chunk: string): void {
    if (!chunk.includes("://")) return;
    for (const raw of extractUrls(chunk)) {
      const hit = canonicalize(raw);
      const url = toUrlString(hit);
      if (this.lastDetections.get(hit.port)?.url === url) continue;
      this.lastDetections.set(hit.port, { url, scheme: hit.scheme, source: "output" });
      this.emit({
        port: hit.port,
        url,
        scheme: hit.scheme,
        source: "output",
        sourceSessionId: sessionId,
      });
    }
  }

  private emit(event: PortDetectionEvent): void {
    for (const fn of this.observers) {
      try {
        fn(event);
      } catch {
        /* ignore */
      }
    }
  }

  constructor(init?: PortDetectorInit) {
    this.configuredPorts = new Set<number>();
    this.portLabels = new Map();
    if (init?.ports) {
      for (const p of init.ports) {
        this.configuredPorts.add(p.port);
        if (p.name) this.portLabels.set(p.port, p.name);
      }
    }
  }

  feed(terminalId: string, data: string): void {
    let buffer = (this.lineBuffers.get(terminalId) ?? "") + data;
    if (!buffer.includes("\n") && buffer.length > MAX_LINE_BUFFER) {
      buffer = buffer.slice(-MAX_LINE_BUFFER);
    }
    const lines = buffer.split("\n");
    this.lineBuffers.set(terminalId, lines.pop()!);

    let changed = false;
    for (const line of lines) {
      const port = extractPort(line);
      if (port === null) continue;

      let termPorts = this.terminalPorts.get(terminalId);
      if (!termPorts) {
        termPorts = new Set();
        this.terminalPorts.set(terminalId, termPorts);
      }
      if (!termPorts.has(port)) {
        termPorts.add(port);
        changed = true;
      }
    }

    if (changed) this.emitPorts();
  }

  removeTerminal(terminalId: string): void {
    this.lineBuffers.delete(terminalId);
    const termPorts = this.terminalPorts.get(terminalId);
    if (!termPorts) return;
    this.terminalPorts.delete(terminalId);

    let changed = false;
    for (const port of termPorts) {
      if (this.configuredPorts.has(port)) continue;
      let stillOwned = false;
      for (const s of this.terminalPorts.values()) {
        if (s.has(port)) { stillOwned = true; break; }
      }
      if (!stillOwned) changed = true;
    }

    if (changed) this.emitPorts();
  }

  getConfiguredPorts(): Set<number> {
    return this.configuredPorts;
  }

  getPortLabels(): Map<number, string> {
    return this.portLabels;
  }

  /** Snapshot of the most recent URL/scheme observed for each port. */
  getLastDetections(): Map<number, { url: string; scheme: "http" | "https"; source: "process" | "output" }> {
    return this.lastDetections;
  }

  stop(): void {
    this.terminalPorts.clear();
    this.lineBuffers.clear();
    this.lastDetections.clear();
  }

  private emitPorts(): void {
    const allPorts = new Set<number>();
    for (const ports of this.terminalPorts.values()) {
      for (const port of ports) allPorts.add(port);
    }
    for (const port of this.configuredPorts) {
      allPorts.add(port);
    }

    const portInfos: PortInfo[] = Array.from(allPorts)
      .sort((a, b) => a - b)
      .map((port) => ({
        port,
        ...(this.portLabels.has(port) ? { label: this.portLabels.get(port) } : {}),
      }));

    this.onPortsChange?.(portInfos);
  }
}
