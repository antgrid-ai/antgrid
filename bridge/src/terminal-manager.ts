import { TerminalSession, buildSpawnEnv } from "./terminal-session";
import { ScrollbackBuffer } from "./scrollback";
import { TerminalModeTracker } from "./terminal-modes";
import { logger } from "./logger";
const log = logger.child({ component: "terminal-manager" });
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
  hookAliveProbeAgent?: string;
  /** Keep this terminal's scrollback replayable after the process exits.
   *  For a transcript whose whole value is what it said — a `worktree.setup`
   *  run, where the log of the step that failed is the only explanation the
   *  user gets, and they read it after the run, not during. Everything else
   *  drops its buffer on exit so a long-lived host does not accumulate the
   *  output of terminals nobody can reattach to. `forget` releases it. */
  retainScrollbackOnExit?: boolean;
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
  /** Paired 1:1 with `scrollbacks` — the tail alone cannot carry mode state. */
  private modeTrackers = new Map<string, TerminalModeTracker>();
  private terminalTypes = new Map<string, "agent" | "service">();
  /** Metadata for exited terminals so they remain visible in status. */
  private stoppedTerminals = new Map<string, StoppedTerminalInfo>();
  /** Terminals whose scrollback survives their own exit — see
   *  `retainScrollbackOnExit`. */
  private retainScrollback = new Set<string>();
  private sendMessage: (msg: AbMessage) => void;
  private callbacks: TerminalManagerCallbacks;
  private connState: ConnState;
  private getApiPort: (() => number | null) | undefined;
  private sessionObservers = new Set<(s: TerminalSession) => void>();
  /**
   * Geometry the current driver last reported. Every terminal in a project
   * renders in the same agent pane, so it is also the size the NEXT one will
   * be shown at — see `spawn`.
   */
  private lastDriverGeometry: { cols: number; rows: number } | null = null;

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
      log.warn(`Terminal "${terminalId}" already exists, killing first`);
      this.kill(terminalId);
    }

    // Clear from stopped list since we're re-spawning
    this.stoppedTerminals.delete(terminalId);
    if (config.retainScrollbackOnExit) this.retainScrollback.add(terminalId);
    else this.retainScrollback.delete(terminalId);

    const scrollback = new ScrollbackBuffer();
    this.scrollbacks.set(terminalId, scrollback);
    const modes = new TerminalModeTracker();
    this.modeTrackers.set(terminalId, modes);

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
      // Spawn at the size the pane is ALREADY showing rather than at 80x24.
      // A fullscreen TUI positions absolutely from its first frame, so every
      // frame it draws before `terminal:resize` round-trips lands against the
      // wrong grid — visible tearing, and worse on a host restart, where the
      // agent boots into a pane whose real size has been known all along.
      cols: config.cols ?? this.lastDriverGeometry?.cols,
      rows: config.rows ?? this.lastDriverGeometry?.rows,
      type: config.type,
      suppressOscNotifications: config.suppressOscNotifications,
      suppressOscTitle: config.suppressOscTitle,
      hookAliveProbeAgent: config.hookAliveProbeAgent,
      onTitle: (title: string) => this.callbacks.onTerminalTitle?.(terminalId, title),
      onMessage: (msg: AbMessage) => {
        if (msg.type === "terminal:output") {
          scrollback.append(msg.data);
          modes.feed(msg.data);
          this.callbacks.onTerminalOutput?.(terminalId, msg.data);
          const seq = this.connState.bumpTerminalSeq(terminalId);
          if (this.connState.suppressed) {
            return; // drop outbound; scrollback retained, seq advanced
          }
          this.sendMessage({ ...msg, seq });
          return;
        }
        if (msg.type === "terminal:exited") {
          // A killed session's exit lands after its tree is reaped, which is
          // long enough for a same-id respawn (`servicesModified`, spawn()'s
          // duplicate path) to have taken the slot. Ungated, the dead
          // session's exit would delete the LIVE one from the map and leave a
          // terminal `has()`/`kill()` can no longer find. An empty slot is not
          // a collision — `killAll` clears the map, and those exits still owe
          // their bookkeeping.
          //
          // The gate covers the SEND too, not just the bookkeeping: an exit
          // frame for a slot a live session now holds tells the app a running
          // terminal is dead, and nothing later corrects it.
          const current = this.sessions.get(terminalId);
          if (current !== undefined && current !== session) return;
          this.sendMessage(msg);
          // Preserve metadata so the tab stays visible in status
          this.stoppedTerminals.set(terminalId, {
            name: session.name,
            shell: session.shellBinary,
            cols: session.cols,
            rows: session.rows,
          });
          this.sessions.delete(terminalId);
          if (!this.retainScrollback.has(terminalId)) {
            this.scrollbacks.delete(terminalId);
            this.modeTrackers.delete(terminalId);
          }
          this.connState.clearTerminal(terminalId);
          this.callbacks.onTerminalExited?.(terminalId);
          return;
        }

        this.sendMessage(msg);

        if (msg.type === "terminal:notification") {
          this.callbacks.onTerminalNotification?.(terminalId);
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
    log.info(`Terminal "${terminalId}" spawned (${config.name ?? "shell"})`);
    return terminalId;
  }

  kill(terminalId: string): void {
    const session = this.sessions.get(terminalId);
    if (!session) {
      log.warn(`Terminal "${terminalId}" not found`);
      return;
    }
    session.kill();
    // Session removal happens in the onMessage exit handler
  }

  /**
   * Same signal as `kill()`; the only difference is that the caller can wait
   * for the tree to actually be gone — for callers that must see the
   * checkout's directory free before Git sweeps it. Waiting for the PTY's
   * *exit* is a different question, answered by `SessionManager.awaitTerminalExit`.
   *
   * `treeKilled()` is the same wait for a session someone else already killed:
   * the promise lives on the session, so it has to be read while the id is
   * still in the map — the exit handler drops it.
   */
  treeKilled(terminalId: string): Promise<void> {
    return this.sessions.get(terminalId)?.treeKilled ?? Promise.resolve();
  }

  killAndAwaitTree(terminalId: string): Promise<void> {
    const session = this.sessions.get(terminalId);
    if (!session) {
      log.warn(`Terminal "${terminalId}" not found`);
      return Promise.resolve();
    }
    session.kill();
    return session.treeKilled;
  }

  killAll(): void {
    for (const session of this.sessions.values()) {
      session.kill();
    }
    this.sessions.clear();
    this.scrollbacks.clear();
    this.retainScrollback.clear();
    this.terminalTypes.clear();
    this.stoppedTerminals.clear();
  }

  /**
   * Drop everything remembered about a terminal that will never come back.
   *
   * The counterpart to `retainScrollbackOnExit`: retention has no expiry of its
   * own, so the site that knows the terminal's owner is gone — a checkout being
   * torn down — has to say so. Also clears the retention flag, so an exit that
   * lands after this call takes the ordinary drop-on-exit path instead of
   * re-retaining a buffer nobody can reach.
   */
  forget(terminalId: string): void {
    this.retainScrollback.delete(terminalId);
    this.scrollbacks.delete(terminalId);
    this.modeTrackers.delete(terminalId);
    this.stoppedTerminals.delete(terminalId);
    this.terminalTypes.delete(terminalId);
  }

  async killAllGracefully(timeoutMs = 5000): Promise<number> {
    const all = [...this.sessions.values()];
    const count = all.length;
    if (count === 0) return 0;

    // Windows gets no graceful phase, because it has none to give: node maps
    // every signal to TerminateProcess, so `killGracefully` takes the leader
    // ALONE — and `killProcessTree` walks parent links, so the children it
    // would have reaped are re-parented out of reach the instant that leader
    // exits (the tree must die BEFORE the leader; see killProcessTree's doc).
    // Asking nicely first would therefore COST the sweep rather than soften
    // it, stranding the conhost/agent orphans whose open handles abort
    // `git worktree remove` — which is the one thing shutdown sweeps trees to
    // prevent. POSIX names a process group, which outlives its leader, so
    // there the ordering is free and the graceful path below is real.
    if (process.platform === "win32") {
      this.killAll();
      await Promise.all(all.map((s) => s.treeKilled));
      return count;
    }

    // Send SIGTERM to all sessions
    for (const session of all) {
      session.killGracefully();
    }

    // Poll until all sessions exit or timeout
    const start = Date.now();
    while (this.sessions.size > 0 && Date.now() - start < timeoutMs) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    // Force-kill survivors
    if (this.sessions.size > 0) {
      log.warn("Force-killing %d surviving terminal(s)", this.sessions.size);
      // Snapshotted before killAll clears the map: shutdown reports "%d
      // terminal(s) closed" off this return, and the trees are still dying.
      const survivors = [...this.sessions.values()];
      this.killAll();
      await Promise.all(survivors.map((s) => s.treeKilled));
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
      log.warn(`Terminal "${terminalId}" not found for resize`);
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
      log.info(
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
    this.lastDriverGeometry = { cols: session.cols, rows: session.rows };
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
      log.warn(`Terminal "${terminalId}" not found for write`);
      return;
    }
    session.write(data);
  }

  /**
   * Raw scrollback tail, for readers that want the program's OUTPUT — the
   * handler's LLM context and the local API. Anything replayed INTO an app's
   * terminal emulator wants `getReplaySnapshot` instead.
   */
  getScrollback(terminalId: string): { text: string; seq: number } | null {
    const buf = this.scrollbacks.get(terminalId);
    if (!buf) return null;
    return { text: buf.getContents(), seq: this.connState.terminalSeq(terminalId) };
  }

  /**
   * What a (re)attaching app must be fed: latched DEC private modes first, then
   * the scrollback tail.
   *
   * The app rebuilds its VT engine per attach and this blob is its ONLY input,
   * so a mode the tail no longer carries is a mode the app does not have —
   * which is how mouse reporting, set once at TUI startup, went missing and
   * took every click with it. Never hand an app plain `getScrollback` output.
   */
  getReplaySnapshot(terminalId: string): { text: string; seq: number } | null {
    const snap = this.getScrollback(terminalId);
    if (!snap) return null;
    const prelude = this.modeTrackers.get(terminalId)?.prelude() ?? "";
    return { ...snap, text: prelude + snap.text };
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
