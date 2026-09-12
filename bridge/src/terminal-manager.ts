import { mkdirSync, rmSync, chmodSync } from "node:fs";
import { dirname } from "node:path";
import {
  TerminalSession,
  buildSpawnEnv,
  WINDOWS_SHUTDOWN_GRACE_MS,
} from "./terminal-session";
import type { GracefulExitAsk } from "./agents/types";
import { ScrollbackBuffer } from "./scrollback";
import { TerminalModeTracker } from "./terminal-modes";
import { TerminalScreen } from "./terminal-screen";
import { TerminalFrameSource } from "./terminal-frames/source";
import { TerminalHistoryStore, type HistoryPage, type TerminalRunHistory } from "./terminal-frames/history";
import {
  TERMINAL_FRAME_INTERVAL_MS,
  type TerminalHistoryBoundary, type TerminalHistoryRow,
} from "./terminal-frames/protocol";
import { resolveTerminalHistoryPath } from "./antgrid-dir";
import { ANTGRID_QUERY_COLORS } from "./vt-capability-responder";
import { logger } from "./logger";
const log = logger.child({ component: "terminal-manager" });

import { createMessage, type AbMessage } from "./protocol";
import type { ConnState } from "./conn-state";


/**
 * How long a `TerminalFrameSource` outlives the PTY it was serializing.
 *
 * A program that prints its last line on the tick it exits leaves those bytes
 * in xterm's write buffer — the parser works in slices, and `dispose()`
 * discards whatever it has not reached — so a teardown on the exit itself
 * publishes a final screen missing everything the program said on its way out.
 * This window is what a frame consumer gets, through `onRunExited`, to settle
 * that parse and ship the result.
 *
 * Bounded because neither half can be waited on for as long as it might want:
 * a guest that outran the parser can leave the source's whole pending-character
 * budget queued, and a viewer's transport can stall indefinitely. Draining that
 * full budget measures at well under 100 ms, so five frame slots is several
 * times the worst honest drain and still leaves room for the frame to go out.
 * Nothing user-visible waits on it — `terminal:exited` and the stopped-tab
 * metadata both land on the exit tick.
 *
 * EVERY terminal pays this, not just one a viewer is watching frames of:
 * `constructScreen` builds a `TerminalFrameSource` for every PTY and falls back
 * to a plain screen only where the xterm build refuses one. So an exit holds
 * the emulator, scrollback and mode tracker for this long whatever display mode
 * the app is in, and `TerminalFrameHub.finish` serializes one final frame per
 * exit even with no attachment on the run.
 */
const EXIT_DRAIN_MS = 5 * TERMINAL_FRAME_INTERVAL_MS;

// --- Terminal history store (D3: the real run lifecycle) ---------------------
//
// One SQLite-backed row archive, shared by every `TerminalManager` on the
// process (one per project core): a run's rowIds mean nothing outside this
// one store, and its machine-wide 2GiB cap (`TerminalHistoryStore.evict`) has
// to see every project's rows for the cap to mean anything.

/**
 * Bun sets `NODE_ENV=test` for every `bun test` run. A bare terminal test
 * must not have spawning a terminal start writing a SQLite file into a
 * developer's real `~/.antgrid` the moment this module lazily opens the
 * store — that rules out gating on `ANTGRID_DIR` alone: plenty of test files
 * across this suite override it for unrelated reasons (an isolated-checkout
 * sandbox, a session store) with no idea a terminal-history store exists,
 * and never call `closeTerminalHistoryStore()`. Since the store is a
 * process-wide singleton (by design — see the block comment above), such a
 * test would leak an open SQLite handle under whatever temp directory it
 * mounts, which its own `afterEach` then fails to `rmSync` on Windows
 * (EBUSY: a directory with an open file handle inside it cannot be removed).
 * So opting in under test needs a SEPARATE, explicit flag, set only by the
 * test file that actually means to exercise the store and that takes on the
 * matching duty of closing it — see `terminal-manager-history.test.ts`.
 */
function historyStoreAllowed(): boolean {
  return process.env.NODE_ENV !== "test" || process.env.ANTGRID_TERMINAL_HISTORY_TEST === "1";
}

let historyStore: { path: string; store: TerminalHistoryStore } | undefined;

/** Opens the durable archive without discarding runs from earlier host processes. */
function openHistoryStore(path: string): TerminalHistoryStore {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const retention = (name: string): number | undefined => {
    const value = process.env[name];
    return value === undefined ? undefined : Number(value);
  };
  const store = new TerminalHistoryStore(path, {
    runBytes: retention("ANTGRID_TERMINAL_HISTORY_RUN_BYTES"),
    machineBytes: retention("ANTGRID_TERMINAL_HISTORY_MACHINE_BYTES"),
  });
  if (process.platform !== "win32") {
    // The directory mode above only applies to a directory `mkdirSync` CREATES,
    // and abDir already exists on every install that has run setup or paired a
    // phone — so narrow it explicitly. The `-wal`/`-shm` siblings need the same
    // treatment for a different reason: WAL mode means the most RECENT rows
    // (i.e. what the user just typed and what it printed) live in `-wal` until
    // a checkpoint moves them, and SQLite creates it under the process umask.
    for (const target of [dirname(path), path, path + "-wal", path + "-shm"]) {
      try {
        chmodSync(target, target === dirname(path) ? 0o700 : 0o600);
      } catch { /* best-effort, matches sibling stores */ }
    }
  }
  return store;
}

/**
 * The shared store, opened lazily so a host that spawns no terminal never
 * touches disk for it. Re-opens whenever the resolved path changes rather
 * than caching unconditionally by import: only a test changes `ANTGRID_DIR`
 * mid-process (each file points it at its own temp dir), and reusing a handle
 * whose file a previous test's cleanup may already have removed would
 * silently read and write nothing rather than the current test's intent.
 */
function terminalHistoryStore(): TerminalHistoryStore | undefined {
  if (!historyStoreAllowed()) return undefined;
  const path = resolveTerminalHistoryPath();
  if (historyStore && historyStore.path !== path) {
    historyStore.store.close();
    historyStore = undefined;
  }
  historyStore ??= { path, store: openHistoryStore(path) };
  return historyStore.store;
}

/**
 * The store only if one is already open — never opens one. For cleanup paths,
 * which want to delete a run's rows but have no business creating the file to
 * do it: `openHistoryStore` SWEEPS on open, so a dispose landing after
 * `closeTerminalHistoryStore()` (a PTY exit callback or a checkout teardown
 * outliving `HostServer.shutdown`'s 5s grace) would re-create the database
 * empty, undoing the checkpoint that just ran and leaving a connection
 * nothing closes for the rest of the process. With no store open there is
 * nothing to delete from anyway — the next boot's sweep discards the file
 * whole.
 */
function liveTerminalHistoryStore(): TerminalHistoryStore | undefined {
  return historyStore?.store;
}

/**
 * Closes the shared store, if one is open. Call exactly once, after every
 * `TerminalManager` on the process has stopped using it — see
 * `HostServer.shutdown` for the real host-shutdown call site, and any test
 * that opts into `ANTGRID_DIR` for the per-test one. `close()` already
 * tolerates a failing checkpoint/vacuum on its own; safe to call when nothing
 * was ever opened.
 */
export function closeTerminalHistoryStore(): void {
  historyStore?.store.close();
  historyStore = undefined;
}


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
  /** A fresh `TerminalFrameSource` now owns `terminalId`'s slot under `runId` —
   *  register it with the terminal-frame hub. Fired at every spawn (same-id
   *  respawn included, under a NEW runId) and at every `ensureLiveScreen`
   *  rebuild (the SAME runId, a new emulator instance) — see `TerminalManager`'s
   *  own `runIds` doc for why identity lives with the screen. Never fired for
   *  the plain-`TerminalScreen` construction fallback: there is no frame source
   *  to capture from, so there is nothing for the hub to hold. This class has no
   *  checkout/project context to build a `TerminalAddress` from — only the
   *  caller (agent-core.ts, via `terminalOwner`) does. */
  onRunStarted?: (terminalId: string, runId: string, source: TerminalFrameSource) => void;
  /** `terminalId`'s current run is over — evict it from the hub. Fired from
   *  `disposeScreen`, which is already the single "this run is over" signal
   *  (see its own doc): a same-id respawn's old run, `forget()`'s teardown, and
   *  a non-retained exit. Ordering matters here the same way it does for the
   *  history-row delete `disposeScreen` performs right beside this: a late exit
   *  for an ALREADY-REPLACED run never reaches `disposeScreen` at all (the
   *  `terminal:exited` handler's own `current !== session` guard returns
   *  first), so this can never fire for a run a fresh `onRunStarted` has
   *  already superseded at the same terminal id. */
  onRunEnded?: (terminalId: string, runId: string, exitCode?: number | null) => void;
  /** The PTY has exited and the emulator is still alive — settle the run
   *  against its real final screen here, the only point at which that screen
   *  still exists. Fired for BOTH exit shapes: under `retainScrollbackOnExit`
   *  the emulator outlives the exit with no expiry, and without it the emulator
   *  is held open for `EXIT_DRAIN_MS` for exactly this callback's benefit
   *  before `onRunEnded` follows. A consumer may therefore await the screen,
   *  but only for that long — past the window it is disposed and its write
   *  callbacks never fire again. */
  onRunExited?: (terminalId: string, runId: string, exitCode: number | null) => void | Promise<void>;
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
  /** Identity of the CURRENT PTY run, for Wave 4 (history's `z.uuid().parse`)
   *  and Wave 5 (subscription identity). Lives with the SCREEN, not the
   *  session — set at every spawn (fresh on a same-id respawn too) and
   *  cleared only where `disposeScreen` clears the screen, so it survives
   *  `retainScrollbackOnExit` exactly as the screen it identifies does. */
  private runIds = new Map<string, string>();
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
  /** Exit codes whose teardown is still inside its `EXIT_DRAIN_MS` window —
   *  see `dropAfterFinalFrame`. The code is the one thing the deferral can
   *  lose: whichever teardown reaches the slot first inside the window
   *  (`spawn`'s same-id respawn, `forget`, `killAll`) calls `disposeScreen`
   *  with no code of its own, and the run's viewers would be told it ENDED
   *  with `exitCode: null` for a process that exited 7. */
  private drains = new Map<string, number | null>();
  private finalCaptures = new Map<string, Promise<void>>();
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
    private readonly historyScope = "default",
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
    // Assigned below, before `spawn()`, so no output can reach the handler
    // while it is null. Captured rather than looked up for the same reason
    // `scrollback` and `modes` are: a replaced PTY keeps emitting until its
    // tree is reaped, and a lookup would file those bytes in the REPLACEMENT's
    // screen while its scrollback and modes go to the dead run's own.
    let screen: TerminalScreen | null = null;

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
          modes.feed(msg.data);
          // Rebuild only while THIS generation still owns the map slot, by
          // SESSION identity rather than by comparing `screen` against the
          // map entry: `ensureLiveScreen` is ALSO called from
          // `getAttachSnapshot`, which swaps `this.screens` without touching
          // this closure's `screen`. A same-object guard then reads that
          // outside rebuild as "someone else already owns this slot" and
          // never calls `ensureLiveScreen` from here again for the rest of
          // the run — the closure keeps feeding the screen the attach path
          // just disposed, and the live replacement it built never receives
          // another byte. `!this.sessions.has` covers a retained, already
          // -exited run (the session row is gone but the screen lives on);
          // there is no OTHER generation there for a same-id respawn to
          // protect against.
          if (this.sessions.get(terminalId) === session || !this.sessions.has(terminalId)) {
            screen = this.ensureLiveScreen(terminalId) ?? screen;
          }
          screen?.feed(msg.data);
          // Appended after the rebuild above, not before it: `ensureLiveScreen`
          // reseeds a replacement from THIS scrollback, and appending first
          // would hand it a seed already ending with the very chunk the feed
          // then writes into the replacement a second time.
          //
          // BEFORE the suppression drop below either way. This placement is
          // what makes a suppressed window recoverable at all: a socket drop
          // and a backgrounded app both stop the outbound frame below, and
          // only an emulator (and a scrollback) that stayed current through
          // it can hand the app back the screen it missed. The screen also
          // stays current through a remote-access flip, which drops at the
          // stream's `mayDeliver` instead — but nothing raises a recovery for
          // that edge, since it neither re-establishes the transport nor
          // moves the app's declared focus, so that window is still stale
          // until the guest repaints of its own accord.
          scrollback.append(msg.data);
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
            this.disposeScreen(terminalId, msg.exitCode);
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
          if (this.retainScrollback.has(terminalId)) {
            const retainedRunId = this.runIds.get(terminalId);
            if (retainedRunId) {
              try {
                void Promise.resolve(this.callbacks.onRunExited?.(terminalId, retainedRunId, msg.exitCode)).catch((error) => {
                  log.warn(`Terminal "${terminalId}" final capture failed: %s`, error);
                });
              } catch (error) {
                log.warn(`Terminal "${terminalId}" run-exited callback failed for run ${retainedRunId}: %s`, error);
              }
            }
          } else {
            this.dropAfterFinalFrame(terminalId, msg.exitCode);
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
    // in the exit handler returns before the bookkeeping) — `disposeScreen`
    // below also deletes the OLD run's history rows, which is why the new run
    // id is minted AFTER it, not before: `disposeScreen` reads the id out of
    // `runIds`, so the delete must still find the run this respawn is
    // REPLACING there, never the one it is about to start.
    this.disposeScreen(terminalId);
    // Fresh identity every spawn, same-id respawn included — a new PTY run
    // even when nothing else about the slot changed.
    const runId = crypto.randomUUID();
    this.runIds.set(terminalId, runId);
    try {
      screen = this.constructScreen(terminalId, session.cols, session.rows, this.openHistoryRun(terminalId, runId));
    } catch (error) {
      this.sessions.delete(terminalId);
      this.scrollbacks.delete(terminalId);
      this.modeTrackers.delete(terminalId);
      this.runIds.delete(terminalId);
      this.retainScrollback.delete(terminalId);
      this.terminalTypes.delete(terminalId);
      liveTerminalHistoryStore()?.deleteRun(runId);
      throw error;
    }
    this.screens.set(terminalId, screen);
    if (screen instanceof TerminalFrameSource) this.callbacks.onRunStarted?.(terminalId, runId, screen);
    // Before `session.spawn()`, which is what actually starts the PTY: the
    // session's own byte-level responder must already be narrowed to
    // OSC-colors-only by the time the guest's first query byte can arrive,
    // or that first chunk answers everything twice.
    this.wireFrameQueries(session, screen);
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
    // Snapshotted before iterating: `disposeScreen` deletes from
    // `this.screens` as it goes, and each call is independently guarded, so
    // one throwing dispose does not stop the rest from being reached.
    for (const terminalId of [...this.screens.keys()]) this.disposeScreen(terminalId);
    this.retainScrollback.clear();
    this.forgotten.clear();
    this.terminalTypes.clear();
    this.stoppedTerminals.clear();
  }

  // Capture completion, rather than elapsed time, owns disposal: parser backlog
  // and transport congestion can both exceed the minimum drain window.
  private dropAfterFinalFrame(terminalId: string, exitCode: number | null): void {
    const screen = this.screens.get(terminalId);
    const runId = this.runIds.get(terminalId);
    if (!(screen instanceof TerminalFrameSource) || !runId) {
      this.scrollbacks.delete(terminalId);
      this.modeTrackers.delete(terminalId);
      this.disposeScreen(terminalId, exitCode);
      return;
    }
    this.drains.set(terminalId, exitCode);
    const grace = new Promise<void>((resolve) => { setTimeout(resolve, EXIT_DRAIN_MS).unref?.(); });
    let finalCapture: void | Promise<void>;
    try {
      finalCapture = this.callbacks.onRunExited?.(terminalId, runId, exitCode);
    } catch (error) {
      log.warn(`Terminal "${terminalId}" run-exited callback failed for run ${runId}: %s`, error);
    }
    const draining = Promise.all([grace, screen.settle(), finalCapture!]).catch((error) => {
      log.warn(`Terminal "${terminalId}" final drain failed: %s`, error);
    }).then(() => {
      if (this.runIds.get(terminalId) !== runId) return;
      this.scrollbacks.delete(terminalId);
      this.modeTrackers.delete(terminalId);
      this.disposeScreen(terminalId, exitCode);
    }).finally(() => {
      this.finalCaptures.delete(runId);
    });
    this.finalCaptures.set(runId, draining);
  }

  // Persist before releasing the emulator; run history remains readable until
  // retention eviction or explicit terminal deletion.
  private disposeScreen(terminalId: string, exitCode?: number | null): void {
    const runId = this.runIds.get(terminalId);
    // Claims the open drain window, if this call is what closed it early. A
    // caller's own exit code always wins — an exit reported here is the truth,
    // and a drain record is the fallback for the teardown paths that never saw
    // one (see `drains`). The record is dropped, never the timer: the timer's
    // own run-id check is the ONE thing that decides whether a drain still owns
    // the slot, and cancelling here would make it unreachable and so unable to
    // fail loudly.
    const drain = this.drains.get(terminalId);
    this.drains.delete(terminalId);
    const endedWith = exitCode !== undefined ? exitCode : drain;
    try {
      const screen = this.screens.get(terminalId);
      if (runId && screen instanceof TerminalFrameSource) {
        const frame = screen.capture(performance.now(), { final: true });
        if (frame) liveTerminalHistoryStore()?.saveFinal(runId, frame);
      }
    } catch (error) {
      log.warn(`Terminal "${terminalId}" final screen persistence failed: %s`, error);
    }
    try {
      this.screens.get(terminalId)?.dispose();
    } catch (error) {
      log.warn(`Terminal "${terminalId}" screen dispose failed: %s`, error);
    }
    this.screens.delete(terminalId);
    this.runIds.delete(terminalId);
    if (runId) {
      try {
        this.callbacks.onRunEnded?.(terminalId, runId, endedWith);
      } catch (error) {
        log.warn(`Terminal "${terminalId}" run-ended callback failed for run ${runId}: %s`, error);
      }
    }
    if (runId) {
      try {
        liveTerminalHistoryStore()?.releaseRun(runId);
      } catch (error) {
        log.warn(`Terminal "${terminalId}" history cleanup failed for run ${runId}: %s`, error);
      }
    }
  }

  private constructScreen(
    terminalId: string, cols: number, rows: number, history?: TerminalRunHistory,
  ): TerminalFrameSource {
    try {
      return new TerminalFrameSource(cols, rows, history);
    } catch (error) {
      log.error(
        `Terminal "${terminalId}" frame source construction failed: %s`,
        error,
      );
      throw error;
    }
  }

  /**
   * Opens `runId`'s history handle with an `onFailure` that records the
   * failure without touching the terminal itself — D3's guarantee that a
   * disk problem degrades ONE run's history, never the terminal it belongs
   * to (`TerminalRunHistory` already guarantees its own methods never throw
   * once opened; this guards the OPEN itself, which can still fail — a
   * literally-full disk on the very first write, most plausibly). Returns
   * `undefined` in a bare test run (`historyStoreAllowed`) or when opening
   * genuinely fails; either way the terminal spawns exactly as it would with
   * no history feature at all.
   */
  private openHistoryRun(terminalId: string, runId: string): TerminalRunHistory | undefined {
    // `terminalHistoryStore()` does the real work of a lazy open (mkdir, the
    // sweep, `new Database`) and so can throw exactly like `store.openRun`
    // below — it belongs INSIDE this try, not resolved beforehand. Spawning a
    // terminal must degrade to "no history for this run", never fail outright,
    // over a disk problem that has nothing to do with the PTY.
    try {
      const store = terminalHistoryStore();
      if (!store) return undefined;
      const handle = store.openRun(runId, (error) => {
        log.warn(`Terminal "${terminalId}" history unavailable for run "${runId}": %s`, error);
      });
      store.bindRun(runId, this.historyScope, terminalId);
      return handle;
    } catch (error) {
      log.warn(`Terminal "${terminalId}" failed to open history for run "${runId}": %s`, error);
      return undefined;
    }
  }

  /**
   * Installs the frame source's parser-boundary query responder and narrows
   * the session's own byte-level one down to OSC 10/11/12 — see the doc
   * comments on `TerminalFrameSource.answerQueries` and
   * `TerminalSession.narrowCapabilityResponder` for why `session.write` is
   * the only legal reply path and why the order (install, then narrow)
   * matters. Also re-flushes the session's held OSC replies at the same
   * parser boundary the frame source answers everything else from
   * (`onParsed`) — see `TerminalSession.flushCapabilityReplies`.
   */
  private wireFrameQueries(session: TerminalSession, screen: TerminalScreen): void {
    if (!(screen instanceof TerminalFrameSource)) {
      return;
    }
    screen.answerQueries((data) => session.write(data), ANTGRID_QUERY_COLORS);
    session.narrowCapabilityResponder();
  }

  /** A raw tail cannot reconstruct authoritative state after parser failure. */
  private ensureLiveScreen(terminalId: string): TerminalScreen | undefined {
    return this.screens.get(terminalId);
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
    this.disposeScreen(terminalId);
    try {
      terminalHistoryStore()?.deleteTerminal(this.historyScope, terminalId);
    } catch (error) {
      log.warn(`Terminal "${terminalId}" history deletion failed: %s`, error);
    }
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
    await Promise.all([...this.screens.values()].map((screen) => screen.settle()));
    await Promise.all(this.finalCaptures.values());

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
    // A TerminalFrameSource defers this into a parser write callback, so the
    // new geometry is NOT applied when this call returns — but the
    // `terminal:size` announcement below is PTY truth (session.cols/rows)
    // regardless of when the emulator catches up, and `getAttachSnapshot`'s
    // `settle()` already drains any deferred resize before it ever
    // serializes, so an attach never observes the gap.
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

  submit(terminalId: string, line: string): void {
    const session = this.sessions.get(terminalId);
    if (!session) {
      log.warn(`Terminal "${terminalId}" not found for submit`);
      return;
    }
    session.submit(line);
  }

  /**
   * Raw scrollback tail, for readers that want the program's OUTPUT — the
   * handler's LLM context and the local API. App viewing uses frame subscriptions.
   */
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

    const known = new Set([...live, ...stopped].map((terminal) => terminal.terminalId));
    const archived = this.archivedTerminalIds().filter((id) => !known.has(id)).map((terminalId) => ({
      terminalId, name: terminalId, running: false, shell: "", cols: 80, rows: 24,
      type: this.terminalTypes.get(terminalId),
    }));
    return [...live, ...stopped, ...archived];
  }

  private archivedTerminalIds(): string[] {
    try { return terminalHistoryStore()?.terminalIds(this.historyScope) ?? []; }
    catch { return []; }
  }

  has(terminalId: string): boolean {
    return this.sessions.has(terminalId);
  }

  /** The current PTY run's identity, or undefined once its screen is gone —
   *  see `runIds`. */
  runId(terminalId: string): string | undefined {
    return this.runIds.get(terminalId);
  }

  /** Serve one page of `runId`'s row history — Wave 5's
   *  `terminal:history:request`. Reads from the STORE rather than from any live
   *  source's own handle: mid-rebuild, a source's handle is a
   *  `ReplayGuardedHistory` composed over this same underlying
   *  `TerminalRunHistory`, and `openRun` returns that identical cached instance
   *  — see its doc. `undefined` only when no history store is open at all (a
   *  bare test run, or the feature disabled); an unknown or exhausted runId is
   *  `page()`'s own job to answer (`expired: true`), never this method's. */
  historyPage(runId: string, epoch: number, beforeRowId: number): HistoryPage | undefined {
    const store = terminalHistoryStore();
    if (!store?.record(runId)) return undefined;
    return store.openRun(runId).page(epoch, beforeRowId);
  }

  ownsHistoryRun(terminalId: string, runId: string): boolean {
    return terminalHistoryStore()?.ownsRun(runId, this.historyScope, terminalId) === true;
  }

  async restoreArchivedTerminal(terminalId: string): Promise<void> {
    if (this.runIds.has(terminalId)) return;
    const store = terminalHistoryStore();
    const saved = store?.latestFinal(this.historyScope, terminalId);
    if (!saved || !store) return;
    const history = store.openRun(saved.runId);
    // A saved display is not PTY output and must never archive rows or replay
    // a history clear while reconstructing the stopped viewport.
    const readOnlyHistory = {
      runId: saved.runId, append: () => {}, clear: () => {},
      flush: () => history.flush(), boundary: () => history.boundary(),
    } as unknown as TerminalRunHistory;
    const source = new TerminalFrameSource(saved.frame?.cols ?? 80, saved.frame?.rows ?? 24, readOnlyHistory);
    if (saved.frame) source.feed(saved.frame.ansi);
    await source.settle();
    if (this.runIds.has(terminalId) || !store.ownsRun(saved.runId, this.historyScope, terminalId)) {
      source.dispose(); return;
    }
    this.screens.set(terminalId, source);
    this.runIds.set(terminalId, saved.runId);
    this.callbacks.onRunStarted?.(terminalId, saved.runId, source);
  }

  get size(): number {
    return this.sessions.size;
  }
}
