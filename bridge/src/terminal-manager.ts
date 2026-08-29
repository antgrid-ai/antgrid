import {
  TerminalSession,
  buildSpawnEnv,
  WINDOWS_SHUTDOWN_GRACE_MS,
} from "./terminal-session";
import type { GracefulExitAsk } from "./agents/types";
import { ScrollbackBuffer } from "./scrollback";
import { TerminalModeTracker } from "./terminal-modes";
import { TerminalScreen } from "./terminal-screen";
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
  /** This agent's measured refinement of the platform's soft ask; see
   *  `GracefulExitAsk`. Absent everywhere but an agent session. */
  gracefulAsk?: GracefulExitAsk;
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
  /** This terminal is gone for good — not exited, FORGOTTEN: nothing will name
   *  it again and `getStatus` will never report it. The one signal an owner of
   *  per-terminal state outside this class can key its own release on. */
  onTerminalForgotten?: (terminalId: string) => void;
}

/**
 * How long THIS session may be given, under a caller's budget.
 *
 * Only agent PTYs are asked to leave. On Windows the soft ask is a keystroke,
 * which a cooked-mode reader — a `bun install` in a setup PTY, a service
 * running a build tool, a shell blocked on a child — cannot see at all, so
 * asking one would spend the whole budget to change nothing while destroying
 * the parent links the sweep walks. On POSIX they have nothing to flush.
 * `type: "agent"` is stamped at exactly ONE site (`SessionManager.startNow`),
 * which is what makes this a single fact rather than a policy to maintain.
 *
 * `askNonAgents` is the shutdown path, and it is not a widening: POSIX shutdown
 * SIGTERMs every terminal, which withdrawing would be the regression. It stays
 * off on Windows, where the keystroke would not land on a cooked-mode reader
 * anyway.
 *
 * A declared `graceMs` can only SHORTEN the caller's budget — see
 * `GracefulExitAsk.graceMs`.
 */
export function gracefulBudget(
  session: TerminalSession,
  budgetMs: number,
  askNonAgents = false,
): number {
  if (budgetMs <= 0) return 0;
  if (session.type === "agent") return Math.min(budgetMs, session.graceMs ?? budgetMs);
  if (askNonAgents && process.platform !== "win32") return budgetMs;
  return 0;
}

export class TerminalManager {
  private sessions = new Map<string, TerminalSession>();
  private scrollbacks = new Map<string, ScrollbackBuffer>();
  /** Paired 1:1 with `scrollbacks` — the tail alone cannot carry mode state. */
  private modeTrackers = new Map<string, TerminalModeTracker>();
  /** Also paired 1:1 with `scrollbacks`, and the reason an attach can rebuild a
   *  SCREEN rather than replay a slice of the stream that drew one. A live
   *  `Terminal` per PTY costs memory, so every site that drops a scrollback
   *  must dispose one here too. */
  private screens = new Map<string, TerminalScreen>();
  /** Chunk sinks for the snapshots currently mid-barrier — see `getAttachSnapshot`. */
  private snapshotTails = new Map<string, Set<string[]>>();
  private terminalTypes = new Map<string, "agent" | "service">();
  /** Metadata for exited terminals so they remain visible in status. */
  private stoppedTerminals = new Map<string, StoppedTerminalInfo>();
  /** Terminals whose scrollback survives their own exit — see
   *  `retainScrollbackOnExit`. */
  private retainScrollback = new Set<string>();
  /** Terminals `forget()` dropped while their PTY was still live. `forget` is
   *  called from a checkout teardown that has already awaited
   *  `killAndAwaitTree`, which resolves when the tree is reaped — strictly
   *  before node-pty dispatches the exit. Without a tombstone that later exit
   *  re-creates the `stoppedTerminals` row the sweep just deleted, and with the
   *  owner row gone too `terminalOwner()` attributes the corpse to main and
   *  advertises it there forever. */
  private forgotten = new Set<string>();
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
      // The replaced run's exit lands later, on a slot this spawn now owns,
      // where the same-id gate below drops it — its bookkeeping included. So
      // the bookkeeping runs HERE, while the id still means the old run.
      // Ordering is the whole point: `namer.forget` and
      // `handlerEngine.onTerminalExit` are keyed by terminal id, so dispatching
      // them once the replacement has registered would reclaim the LIVE run's
      // state instead of the dead one's. Only the callback fires, never the
      // `terminal:exited` frame — an exit frame for a slot a live session holds
      // tells the app a running terminal is dead, and nothing later corrects it.
      //
      // A grace made this reachable rather than theoretical: the window between
      // the ask and the exit is now seconds, which is long enough for the user
      // to press Stop and then Start (`SessionManager.stopTerminal` ->
      // `startNow`).
      this.callbacks.onTerminalExited?.(terminalId);
    }

    // Clear from stopped list since we're re-spawning
    this.stoppedTerminals.delete(terminalId);
    if (config.retainScrollbackOnExit) this.retainScrollback.add(terminalId);
    else this.retainScrollback.delete(terminalId);
    this.forgotten.delete(terminalId);

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
      gracefulAsk: config.gracefulAsk,
      onTitle: (title: string) => this.callbacks.onTerminalTitle?.(terminalId, title),
      onMessage: (msg: AbMessage) => {
        if (msg.type === "terminal:output") {
          scrollback.append(msg.data);
          modes.feed(msg.data);
          // BEFORE the suppression drop, and looked up rather than captured so
          // the closure has no ordering dependency on when the screen is made.
          // This placement is what makes a suppressed window recoverable at
          // all: a socket drop and a backgrounded app both stop the outbound
          // frame below, and only an emulator that stayed current through it
          // can hand the app back the screen it missed. The screen also stays
          // current through a remote-access flip, which drops at the stream's
          // `mayDeliver` instead — but nothing raises a recovery for that edge,
          // since it neither re-establishes the transport nor moves the app's
          // declared focus, so that window is still stale until the guest
          // repaints of its own accord.
          this.screens.get(terminalId)?.feed(msg.data);
          // A chunk landing while a snapshot is mid-barrier is not in the blob
          // being serialized, so every pending snapshot keeps its own copy to
          // replay after it — see `getAttachSnapshot`.
          const tails = this.snapshotTails.get(terminalId);
          if (tails) for (const tail of tails) tail.push(msg.data);
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
          // Forgotten while still live: the owner row is already gone, so the
          // exit frame would be stamped with main's checkout and the
          // bookkeeping below would resurrect the very rows `forget` deleted.
          if (this.forgotten.delete(terminalId)) {
            this.sessions.delete(terminalId);
            this.scrollbacks.delete(terminalId);
            this.modeTrackers.delete(terminalId);
            this.screens.get(terminalId)?.dispose();
            this.screens.delete(terminalId);
            this.retainScrollback.delete(terminalId);
            this.connState.clearTerminal(terminalId);
            return;
          }
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
            this.screens.get(terminalId)?.dispose();
            this.screens.delete(terminalId);
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
    // Sized from the SESSION, not from `config`: the session applies its own
    // 80x24 defaults, and a VT sized differently from the PTY serializes a
    // screen the guest never drew. A same-id respawn replaces the previous
    // screen, whose own exit lands too late to release it (the duplicate gate
    // in the exit handler returns before the bookkeeping).
    this.screens.get(terminalId)?.dispose();
    this.screens.set(terminalId, new TerminalScreen(session.cols, session.rows));
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

  /**
   * Stop a terminal. `graceMs` is a budget, not a promise: the terminals it
   * actually reaches are decided by `gracefulBudget`, and the sweep runs either
   * way. Default 0 keeps a caller that has no room for one — a kill-then-
   * respawn on the same terminal id, where a grace would overlap two PTYs on
   * one slot — on exactly the path it had before.
   */
  kill(terminalId: string, graceMs = 0): void {
    const session = this.sessions.get(terminalId);
    if (!session) {
      log.warn(`Terminal "${terminalId}" not found`);
      return;
    }
    const grace = gracefulBudget(session, graceMs);
    // Stays void either way: nearly every caller fires this from a message
    // handler and must not be made to wait on the reaping.
    if (grace > 0) void session.close(grace);
    else session.kill();
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

  killAndAwaitTree(terminalId: string, graceMs = 0): Promise<void> {
    const session = this.sessions.get(terminalId);
    if (!session) {
      log.warn(`Terminal "${terminalId}" not found`);
      return Promise.resolve();
    }
    const grace = gracefulBudget(session, graceMs);
    if (grace > 0) return session.close(grace);
    session.kill();
    return session.treeKilled;
  }

  killAll(): void {
    for (const session of this.sessions.values()) {
      session.kill();
    }
    this.resetMaps();
  }

  /** Everything this class remembers about terminals, dropped in one place.
   *  `modeTrackers` pairs 1:1 with `scrollbacks`, so it goes with them — a
   *  tracker left behind for a terminal whose buffer is gone is unreachable
   *  state that lives for the process. */
  private resetMaps(): void {
    this.sessions.clear();
    this.scrollbacks.clear();
    this.modeTrackers.clear();
    // Dropped with the rest, but DISPOSED first: a `TerminalScreen` owns an
    // xterm instance whose internal disposables outlive the map entry.
    for (const screen of this.screens.values()) screen.dispose();
    this.screens.clear();
    this.retainScrollback.clear();
    this.forgotten.clear();
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
    // Only when an exit is still owed — a terminal that already exited has no
    // callback left to tombstone, and an unconsumed one would leak.
    if (this.sessions.has(terminalId)) this.forgotten.add(terminalId);
    this.retainScrollback.delete(terminalId);
    this.scrollbacks.delete(terminalId);
    this.modeTrackers.delete(terminalId);
    this.screens.get(terminalId)?.dispose();
    this.screens.delete(terminalId);
    this.stoppedTerminals.delete(terminalId);
    this.terminalTypes.delete(terminalId);
    this.callbacks.onTerminalForgotten?.(terminalId);
  }

  async killAllGracefully(timeoutMs = 5000): Promise<number> {
    const all = [...this.sessions.values()];
    const count = all.length;
    if (count === 0) return 0;

    // Windows is clamped and POSIX is not, and the asymmetry is the caller's,
    // not the platform's: `HostController.shutdownOwnedHost` force-kills this
    // whole tree ~3s after asking, so anything past that is spent inside a
    // window it has already given up on. POSIX has no such caller, so it keeps
    // the full budget it was given.
    const budget = process.platform === "win32"
      ? Math.min(timeoutMs, WINDOWS_SHUTDOWN_GRACE_MS)
      : timeoutMs;
    // Each chain ends in its own unconditional sweep, so this resolves only
    // once every tree is gone — the property `git worktree remove` and the
    // Windows package destage both depend on. Sessions report their own exits,
    // so no poll loop is needed to notice them.
    await Promise.all(all.map((session) => session.close(gracefulBudget(session, budget, true))));

    // Nothing has closed the inbound door yet — the transport is still
    // attached and the config watcher still armed — so a `session:start` or a
    // `servicesModified` respawn can land a NEW session in the map during the
    // wait above. Clearing from the snapshot would drop it from every map
    // without killing it, orphaning a PTY that no watchdog and no job handle
    // covers. `killAll` reads the LIVE map, which is the whole reason it stays
    // the terminal step.
    const asked = new Set(all);
    const late = [...this.sessions.values()].filter((session) => !asked.has(session));
    this.killAll();
    await Promise.all(late.map((session) => session.treeKilled));

    const answered = all.filter((session) => session.askAnswered === true).length;
    log.info(
      "Closed %d terminal(s): %d exited on request, %d force-killed%s",
      count,
      answered,
      count - answered,
      late.length > 0 ? `, ${late.length} spawned during shutdown` : "",
    );
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
    this.screens.get(terminalId)?.resize(session.cols, session.rows);
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
   * terminal emulator wants `getAttachSnapshot` instead.
   */
  getScrollback(terminalId: string): { text: string; seq: number } | null {
    const buf = this.scrollbacks.get(terminalId);
    if (!buf) return null;
    return { text: buf.getContents(), seq: this.connState.terminalSeq(terminalId) };
  }

  /**
   * What a (re)attaching app must be fed: the serialized SCREEN, then the
   * latched modes the serializer does not carry.
   *
   * The app's engine OUTLIVES the attach and this blob is the only thing that
   * corrects it, so a mode the blob does not carry is a mode the app keeps
   * whatever the guest has since done to it — which is how mouse reporting, set
   * once at TUI startup, went missing and took every click with it. Never hand
   * an app plain `getScrollback` output: it is a suffix of a DIFF stream and
   * reconstructs only the rows the program happened to rewrite most recently.
   *
   * The supplement goes strictly AFTER the whole blob, never interleaved — the
   * serializer ends with a relative cursor restore.
   *
   * The seq and the blob must describe the SAME instant, and the serialize
   * barrier is a real suspension point, so the two are made to agree rather
   * than assumed to. A chunk arriving while the barrier is pending is sent to
   * the app immediately (this is the same ordered channel, so it lands BEFORE
   * the reply), is not in the blob, and would then be wiped by the blob's own
   * `2J` — with its seq already above any cutoff read beforehand, so nothing
   * refilters it and nothing re-sends it. Four kilobytes of a streaming build,
   * gone from the tab for good. Capturing those chunks and replaying them after
   * the body is what closes it: body + tail reconstructs the screen as of the
   * LAST byte counted, so the cutoff can be read afterwards and be exact.
   */
  async getAttachSnapshot(terminalId: string): Promise<{ text: string; seq: number } | null> {
    const screen = this.screens.get(terminalId);
    if (!screen) return null;
    const tail: string[] = [];
    let tails = this.snapshotTails.get(terminalId);
    if (!tails) this.snapshotTails.set(terminalId, (tails = new Set()));
    tails.add(tail);
    try {
      await screen.settle();
      // The screen can be replaced or disposed across the barrier: an exit and
      // a same-id respawn both swap the map entry, and the barrier still fires
      // on the dead one — whose screen would then be stamped with a seq the new
      // PTY starts below and re-arm a cutoff above everything it will ever
      // emit. A blank pane behind a live process.
      if (screen.isDisposed || this.screens.get(terminalId) !== screen) return null;
      const blob = screen.serializeNow();
      const seq = this.connState.terminalSeq(terminalId);
      const supplement = this.modeTrackers.get(terminalId)?.supplementalPrelude() ?? "";
      return { text: blob + tail.join("") + supplement, seq };
    } finally {
      tails.delete(tail);
      if (tails.size === 0) this.snapshotTails.delete(terminalId);
    }
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
