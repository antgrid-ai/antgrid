import { TerminalSession, buildSpawnEnv } from "./terminal-session";
import { ScrollbackBuffer } from "./scrollback";
import { logger } from "./logger";
import { createMessage, type AbMessage } from "./protocol";
import type { ConnState } from "./conn-state";

export interface TerminalSpawnConfig {
  terminalId?: string;
  name?: string;
  command?: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  cols?: number;
  rows?: number;
  type?: "agent" | "service";
  suppressOscNotifications?: boolean;
  suppressOscTitle?: boolean;
  expectsHookAliveProbe?: boolean;
}

interface StoppedTerminalInfo {
  name: string;
  shell: string;
  cols: number;
  rows: number;
}

export interface TerminalManagerCallbacks {
  onTerminalOutput?: (terminalId: string, data: string) => void;
  onTerminalExited?: (terminalId: string) => void;
  onTerminalNotification?: (terminalId: string) => void;
  onTerminalTitle?: (terminalId: string, title: string) => void;
}

export class TerminalManager {
  private sessions = new Map<string, TerminalSession>();
  private scrollbacks = new Map<string, ScrollbackBuffer>();
  private terminalTypes = new Map<string, "agent" | "service">();
  /** Metadata for exited terminals so they remain visible in status. */
  private stoppedTerminals = new Map<string, StoppedTerminalInfo>();
  private sendMessage: (msg: AbMessage) => void;
  private callbacks: TerminalManagerCallbacks;
  private connState: ConnState;
  private getApiPort: (() => number | null) | undefined;
  private sessionObservers = new Set<(s: TerminalSession) => void>();

  constructor(
    sendMessage: (msg: AbMessage) => void,
    callbacks: TerminalManagerCallbacks | undefined,
    connState: ConnState,
    getApiPort?: () => number | null,
  ) {
    this.sendMessage = sendMessage;
    this.callbacks = callbacks ?? {};
    this.connState = connState;
    this.getApiPort = getApiPort;
  }

  onSessionCreated(fn: (s: TerminalSession) => void): () => void {
    this.sessionObservers.add(fn);
    // Replay for already-running sessions so late subscribers still see current state
    for (const s of this.sessions.values()) {
      try { fn(s); } catch { /* ignore */ }
    }
    return () => {
      this.sessionObservers.delete(fn);
    };
  }

  spawn(config: TerminalSpawnConfig): string {
    const terminalId = config.terminalId ?? crypto.randomUUID();

    if (this.sessions.has(terminalId)) {
      logger.warn(`Terminal "${terminalId}" already exists, killing first`);
      this.kill(terminalId);
    }

    // Clear from stopped list since we're re-spawning
    this.stoppedTerminals.delete(terminalId);

    const scrollback = new ScrollbackBuffer();
    this.scrollbacks.set(terminalId, scrollback);

    // Stamp this core's api-server port AND the terminal id into the spawned
    // shell. Hooks/plugins echo ANTGRID_TERMINAL_ID back to /session-title for
    // exact per-PTY correlation; ANTGRID_API_PORT tells them which core to hit.
    // Merge over the caller's env so antgrid keys always win for their slots
    // while unrelated caller keys are preserved.
    const apiPort = this.getApiPort?.();
    const env = buildSpawnEnv(terminalId, apiPort, config.env ?? {});

    const session = new TerminalSession({
      terminalId,
      name: config.name,
      command: config.command,
      args: config.args,
      cwd: config.cwd,
      env,
      cols: config.cols,
      rows: config.rows,
      type: config.type,
      suppressOscNotifications: config.suppressOscNotifications,
      suppressOscTitle: config.suppressOscTitle,
      expectsHookAliveProbe: config.expectsHookAliveProbe,
      onTitle: (title: string) => this.callbacks.onTerminalTitle?.(terminalId, title),
      onMessage: (msg: AbMessage) => {
        if (msg.type === "terminal:output") {
          scrollback.append(msg.data);
          this.callbacks.onTerminalOutput?.(terminalId, msg.data);
          const seq = this.connState.bumpTerminalSeq(terminalId);
          if (this.connState.suppressed) {
            return; // drop outbound; scrollback retained, seq advanced
          }
          this.sendMessage({ ...msg, seq });
          return;
        }
        this.sendMessage(msg);

        if (msg.type === "terminal:notification") {
          this.callbacks.onTerminalNotification?.(terminalId);
        }

        if (msg.type === "terminal:exited") {
          // Preserve metadata so the tab stays visible in status
          this.stoppedTerminals.set(terminalId, {
            name: session.name,
            shell: session.shellBinary,
            cols: session.cols,
            rows: session.rows,
          });
          this.sessions.delete(terminalId);
          this.scrollbacks.delete(terminalId);
          this.connState.clearTerminal(terminalId);
          this.callbacks.onTerminalExited?.(terminalId);
        }
      },
    });

    this.sessions.set(terminalId, session);
    if (config.type) {
      this.terminalTypes.set(terminalId, config.type);
    }
    for (const fn of this.sessionObservers) {
      try { fn(session); } catch { /* ignore */ }
    }
    session.spawn();
    logger.info(`Terminal "${terminalId}" spawned (${config.name ?? "shell"})`);
    return terminalId;
  }

  kill(terminalId: string): void {
    const session = this.sessions.get(terminalId);
    if (!session) {
      logger.warn(`Terminal "${terminalId}" not found`);
      return;
    }
    session.kill();
    // Session removal happens in the onMessage exit handler
  }

  killAll(): void {
    for (const session of this.sessions.values()) {
      session.kill();
    }
    this.sessions.clear();
    this.scrollbacks.clear();
    this.terminalTypes.clear();
    this.stoppedTerminals.clear();
  }

  async killAllGracefully(timeoutMs = 5000): Promise<number> {
    const count = this.sessions.size;
    if (count === 0) return 0;

    // Send SIGTERM to all sessions
    for (const session of this.sessions.values()) {
      session.killGracefully();
    }

    // Poll until all sessions exit or timeout
    const start = Date.now();
    while (this.sessions.size > 0 && Date.now() - start < timeoutMs) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    // Force-kill survivors
    if (this.sessions.size > 0) {
      logger.warn("Force-killing %d surviving terminal(s)", this.sessions.size);
      this.killAll();
    }

    return count;
  }

  resize(
    terminalId: string,
    clientId: string,
    cols: number,
    rows: number,
    baseDriverClientId?: string,
  ): void {
    const session = this.sessions.get(terminalId);
    if (!session) {
      logger.warn(`Terminal "${terminalId}" not found for resize`);
      return;
    }
    const prevCols = session.cols;
    const prevRows = session.rows;
    const prevDriver = session.driverClientId;
    if (
      baseDriverClientId !== undefined &&
      prevDriver !== null &&
      clientId !== prevDriver &&
      baseDriverClientId !== prevDriver
    ) {
      logger.info(
        `Ignoring stale resize for terminal "${terminalId}" from ${clientId}; ` +
          `based on ${baseDriverClientId}, current driver is ${prevDriver}`,
      );
      return;
    }
    // Skip the broadcast when nothing observable changed — same size AND same
    // driver. A client re-sending its current geometry (or re-claiming driver
    // it already holds) shouldn't fan a no-op resize out to every viewer.
    if (
      cols === prevCols &&
      rows === prevRows &&
      clientId === prevDriver
    ) {
      return;
    }
    session.resize(clientId, cols, rows);
    this.sendMessage(
      createMessage("terminal:size", {
        terminalId,
        cols: session.cols,
        rows: session.rows,
        driverClientId: clientId,
      }),
    );
  }

  write(terminalId: string, data: string): void {
    const session = this.sessions.get(terminalId);
    if (!session) {
      logger.warn(`Terminal "${terminalId}" not found for write`);
      return;
    }
    session.write(data);
  }

  getScrollback(terminalId: string): { text: string; seq: number } | null {
    const buf = this.scrollbacks.get(terminalId);
    if (!buf) return null;
    return { text: buf.getContents(), seq: this.connState.terminalSeq(terminalId) };
  }

  getStatus(): Array<{
    terminalId: string;
    name: string;
    running: boolean;
    shell: string;
    cols: number;
    rows: number;
    type?: "agent" | "service";
    driverClientId?: string;
  }> {
    const live = Array.from(this.sessions.entries()).map(([id, session]) => ({
      terminalId: id,
      name: session.name,
      running: session.isRunning,
      shell: session.shellBinary,
      cols: session.cols,
      rows: session.rows,
      type: this.terminalTypes.get(id),
      driverClientId: session.driverClientId ?? undefined,
    }));

    const stopped = Array.from(this.stoppedTerminals.entries())
      .filter(([id]) => !this.sessions.has(id))
      .map(([id, info]) => ({
        terminalId: id,
        name: info.name,
        running: false,
        shell: info.shell,
        cols: info.cols,
        rows: info.rows,
        type: this.terminalTypes.get(id),
      }));

    return [...live, ...stopped];
  }

  has(terminalId: string): boolean {
    return this.sessions.has(terminalId);
  }

  get size(): number {
    return this.sessions.size;
  }
}
