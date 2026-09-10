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
import { MAX_ATTACH_BLOB, TerminalScreen } from "./terminal-screen";
import { TerminalFrameSource } from "./terminal-frames/source";
import { TerminalHistoryStore, type HistoryPage, type TerminalRunHistory } from "./terminal-frames/history";
import type { TerminalHistoryBoundary, TerminalHistoryRow } from "./terminal-frames/protocol";
import { resolveTerminalHistoryPath } from "./antgrid-dir";
import { ANTGRID_QUERY_COLORS } from "./vt-capability-responder";
import { logger } from "./logger";
const log = logger.child({ component: "terminal-manager" });

/**
 * How many times an attach re-waits on the VT before it settles for replaying
 * an unparsed tail — see `getAttachSnapshot`. One extra round clears an
 * ordinary burst; nothing clears a guest that outruns the parser, so this only
 * needs to be past "briefly behind".
 */
const SETTLE_ROUNDS = 3;
import { createMessage, type AbMessage } from "./protocol";
import type { ConnState } from "./conn-state";

/**
 * Rebuild attempts per PTY run before a latched `TerminalFrameSource` is left
 * as-is — see `ensureLiveScreen`. A run that keeps overflowing the parser
 * backlog is not fixed by trying again, and an unbounded retry would rebuild
 * (and reseed from scrollback) on every single output chunk after that.
 */
const MAX_SCREEN_REBUILDS = 3;

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

/**
 * Opens the store fresh at `path`: directory `0o700`, file `0o600` on POSIX —
 * this file holds terminal OUTPUT (command text, program results), the same
 * sensitivity as a session transcript, so it gets the same treatment as every
 * other per-user store under abDir (see `handler/session-store.ts`,
 * `remote-access-policy.ts`). Windows has no POSIX mode bit; the file
 * inherits the user profile's ACL like the rest of `.antgrid`.
 *
 * Swept before opening, by deleting the file (and WAL mode's `-wal`/`-shm`
 * siblings) rather than by walking its rows: a run id lives only in
 * `TerminalManager.runIds`, in memory, which a fresh process always starts
 * empty — `retainScrollbackOnExit` included, since that flag keeps a *live*
 * process's memory around, not anything that survives a restart. So every row
 * already on disk at open time belongs to a run nothing on THIS boot can ever
 * name again, and deleting the file is the exact sweep the wave 4 spec asks
 * for, not an approximation of one. It is also the only sweep available
 * without widening `TerminalHistoryStore`'s frozen public surface with a
 * list-runs method it has no other reason to carry.
 */
function openHistoryStore(path: string): TerminalHistoryStore {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  for (const suffix of ["", "-wal", "-shm"]) {
    try {
      rmSync(path + suffix);
    } catch (error) {
      // ENOENT is the expected, silent case (a fresh install, or the `-wal`/
      // `-shm` siblings simply not existing). Anything else — another holder
      // has the file open, a permissions problem — means the sweep did
      // nothing, which is exactly the failure mode D3 exists to prevent (see
      // the block comment above): log it so a swept-nothing boot is at least
      // observable instead of indistinguishable from a fresh install.
      if ((error as NodeJS.ErrnoException)?.code !== "ENOENT") {
        log.warn(`Terminal history sweep could not remove "${path}${suffix}": %s`, error);
      }
    }
  }
  const store = new TerminalHistoryStore(path);
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

/**
 * Suppresses `append`/`clear` for exactly the span of a rebuild's reseed.
 * `ensureLiveScreen` replays up to 10,000 chars of RAW scrollback into a
 * fresh `TerminalFrameSource` reattached to the SAME history run, purely to
 * reconstruct the live screen for display — that replayed content was
 * already archived (in full or in part) by the source that just failed, so
 * letting `append`/`clear` through here would re-apply events the real
 * handle already recorded: a duplicate row under a FRESH rowId, or (worse) a
 * clear sitting in the replayed tail deleting rows the original clear
 * already removed itself, taking every row recorded SINCE that clear with
 * it. This is the trap the wave 4 spec calls out by name: wave 3 could not
 * catch it because no history was attached yet.
 *
 * `append` is suppressed only for the rows the FAILED source already
 * archived, not unconditionally: `remaining`, captured before the reseed
 * starts, is exactly how many rows `real` already has. The replayed tail
 * re-derives content in the same order the live source originally produced
 * it, so a genuine duplicate is always among the first `remaining` appends —
 * once they are consumed, anything further is content the failed source
 * never reached at all (most often the tail of `unparsed`, discarded by
 * `TerminalFrameSource.fail()`), which must be archived for real rather than
 * silently lost with it. `clear` has no equivalent partial case — a clear
 * either already ran against `real` or it did not reach it before the
 * failure, and either way replaying it here must not run it a second time —
 * so it stays suppressed for the WHOLE span, exactly like a not-yet-consumed
 * `append`.
 *
 * `flush`/`boundary` pass straight through — flushing is idempotent and
 * boundary reads are never destructive — until `release()`, called once the
 * reseed has actually been PARSED (`settle()`) and the replacement is about
 * to start receiving genuinely new PTY output (see `ensureLiveScreen`).
 *
 * Composition, not a subclass: `TerminalRunHistory`'s constructor takes a
 * store-internal record type `history.ts` does not export, so there is no
 * supported way to build one outside that file. That forces a cast at the
 * construction site, which is exactly the kind that hides a missing member —
 * so every one of `TerminalRunHistory`'s public members is forwarded here,
 * not just the four `TerminalFrameSource` happens to call today. `page` in
 * particular is what wave 5's delivery path exists to call, and `runId` would
 * otherwise answer `undefined` rather than fail.
 */
class ReplayGuardedHistory {
  private suppressed = true;
  private remaining: number;
  readonly runId: string;

  constructor(private readonly real: TerminalRunHistory) {
    this.runId = real.runId;
    this.remaining = real.boundary().nextRowId;
  }

  append(row: Omit<TerminalHistoryRow, "rowId">): void {
    if (this.suppressed && this.remaining > 0) { this.remaining--; return; }
    this.real.append(row);
  }
  flush(): void { this.real.flush(); }
  clear(): void { if (!this.suppressed) this.real.clear(); }
  boundary(): TerminalHistoryBoundary { return this.real.boundary(); }
  page(epoch: number, beforeRowId: number): HistoryPage { return this.real.page(epoch, beforeRowId); }
  retire(): void { this.real.retire(); }

  /**
   * Called once the reseed that motivated this guard has settled. Answers
   * whether the rebuild may have COST rows, which the caller reports as a
   * history gap.
   *
   * `remaining` reaching zero means the replay re-derived at least as many
   * rows as the archive holds, so everything past them — the only place
   * never-archived content can be — was forwarded for real. Anything left
   * over means the replay produced FEWER rows than the archive holds and all
   * of them were suppressed, and nothing here can tell a row the failed
   * source already recorded from one it dropped with `unparsed`. The
   * scrollback is 10,000 chars against a run that may have printed
   * megabytes, so on a long run this is the ordinary answer, not an edge
   * case: a parser-backlog rebuild really does lose the rows between the last
   * archived one and what that tail can reconstruct.
   */
  release(): boolean {
    this.suppressed = false;
    return this.remaining > 0;
  }
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
  /** Rebuild attempts already spent on the CURRENT run — see
   *  `ensureLiveScreen`. Paired 1:1 with `runIds`: both describe the run, not
   *  the terminal, and both reset at the same spawn. */
  private rebuildCounts = new Map<string, number>();
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
          // Appended AFTER the feed above, not before: a rebuild inside
          // `ensureLiveScreen` reseeds from THIS scrollback, and appending
          // first would hand it a seed that already ends with the very chunk
          // `feed` is about to write into the replacement a second time.
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
            this.disposeScreen(terminalId);
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
            this.disposeScreen(terminalId);
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
    screen = this.constructScreen(terminalId, session.cols, session.rows, this.openHistoryRun(terminalId, runId));
    this.screens.set(terminalId, screen);
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

  /**
   * Disposes a terminal's screen, if any, and drops the two per-run map
   * entries that pair with it — the run id (D1) and the rebuild budget (D4).
   * The dispose runs under its own guard so a throw leaves every map
   * consistent anyway: `resetMaps`' loop and all four exit-time cleanup sites
   * route through this rather than repeating `get(id)?.dispose(); delete(id)`.
   *
   * Also deletes the run's history rows (D3), because every ordinary call
   * site is exactly a "this run is over" signal: a same-id respawn's old
   * run, `forget()`'s teardown, and a non-retained exit (the retained case
   * skips this call entirely — see the `retainScrollback` guard around the
   * `terminal:exited` handler's own `disposeScreen` call). A LIVE reattach
   * never routes through here; it is `ensureLiveScreen`'s rebuild, which
   * disposes the failed screen directly and reopens the SAME run. Deleting
   * here doubles as the only eviction `TerminalHistoryStore`'s internal
   * handle map ever gets outside the machine-wide byte cap — without it,
   * every terminal ever spawned in the process's life would leave its handle
   * cached there forever.
   */
  private disposeScreen(terminalId: string): void {
    try {
      this.screens.get(terminalId)?.dispose();
    } catch (error) {
      log.warn(`Terminal "${terminalId}" screen dispose failed: %s`, error);
    }
    this.screens.delete(terminalId);
    const runId = this.runIds.get(terminalId);
    this.runIds.delete(terminalId);
    this.rebuildCounts.delete(terminalId);
    if (runId) {
      try {
        liveTerminalHistoryStore()?.deleteRun(runId);
      } catch (error) {
        log.warn(`Terminal "${terminalId}" history cleanup failed for run ${runId}: %s`, error);
      }
    }
  }

  /**
   * Builds the per-PTY emulator, preferring a `TerminalFrameSource`. Its
   * constructor CAN throw (two `XtermFrameAdapter` API-shape checks, plus
   * `patchScroll`'s "already installed" refusal) where `TerminalScreen`'s
   * cannot — and both callers (`spawn`, `ensureLiveScreen`) need a terminal
   * that still works on a host whose xterm build doesn't support it, so a
   * throw here falls back rather than propagating. `history` is dropped
   * silently on the fallback path: a plain `TerminalScreen` has nowhere to
   * put it, and the caller has already logged the construction failure.
   */
  private constructScreen(
    terminalId: string, cols: number, rows: number, history?: TerminalRunHistory,
  ): TerminalScreen {
    try {
      return new TerminalFrameSource(cols, rows, history);
    } catch (error) {
      log.error(
        `Terminal "${terminalId}" frame source construction failed, falling back to a plain screen: %s`,
        error,
      );
      return new TerminalScreen(cols, rows);
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
      return store.openRun(runId, (error) => {
        log.warn(`Terminal "${terminalId}" history unavailable for run "${runId}": %s`, error);
      });
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
   *
   * WIDENS back to full scope for a plain `TerminalScreen` — the construction
   * fallback at spawn, or a rebuild that fell back to one — since that is the
   * ONLY responder there is in that case; leaving a session narrowed from an
   * earlier, now-gone frame source would answer nothing but OSC 10/11/12 for
   * the rest of the run.
   */
  private wireFrameQueries(session: TerminalSession, screen: TerminalScreen): void {
    if (!(screen instanceof TerminalFrameSource)) {
      session.widenCapabilityResponder();
      return;
    }
    screen.answerQueries((data) => session.write(data), ANTGRID_QUERY_COLORS);
    session.narrowCapabilityResponder();
    screen.onParsed(() => session.flushCapabilityReplies());
  }

  /**
   * Rebuilds `terminalId`'s screen once its `TerminalFrameSource` has latched
   * a failure (`TerminalFrameSource.failure`), and otherwise returns it
   * unchanged. Called from both the `terminal:output` handler (before
   * `screen.feed`) and the head of `getAttachSnapshot`, so a failed source is
   * never fed further bytes and never the reason an attach comes back `null`.
   *
   * Reseeded from the RAW scrollback tail rather than anything the failed
   * source itself holds — the failure is a display failure, not proof of what
   * the emulator last painted, and `ScrollbackBuffer` caps at 10_000 chars,
   * two orders below the parser-backlog ceiling that likely caused the
   * failure, so the reseed cannot retrigger it.
   *
   * Geometry comes from the live session where there is one, or from the
   * stopped-terminal row for a retained, already-exited run (both carry
   * `cols`/`rows`); with neither available there is nothing to rebuild
   * against, so the latched source is left as the answer. Same run id
   * throughout — this is a fresh emulator for the SAME PTY run, not a new
   * one — and rebuilds are capped at `MAX_SCREEN_REBUILDS`: a run that keeps
   * overflowing the parser is not fixed by trying again.
   */
  private ensureLiveScreen(terminalId: string): TerminalScreen | undefined {
    const current = this.screens.get(terminalId);
    if (!(current instanceof TerminalFrameSource) || !current.failure) return current;
    const rebuilds = this.rebuildCounts.get(terminalId) ?? 0;
    if (rebuilds >= MAX_SCREEN_REBUILDS) {
      // Nothing will rebuild this run's screen again, so a session left
      // narrowed from the exhausted source would answer nothing but OSC
      // 10/11/12 for the rest of the run — see `TerminalSession.widenCapabilityResponder`.
      this.sessions.get(terminalId)?.widenCapabilityResponder();
      return current;
    }
    // No widen call here: `geometry` falls back to a live session first, so
    // reaching `undefined` means there IS no live session either — nothing to
    // widen for.
    const geometry = this.sessions.get(terminalId) ?? this.stoppedTerminals.get(terminalId);
    if (!geometry) return current;
    const failure = current.failure;
    this.rebuildCounts.set(terminalId, rebuilds + 1);
    // Reattach to the SAME run (D3) — never a fresh `openHistoryRun`-minted
    // id, since this is a new EMULATOR for the same PTY run, not a new run —
    // but guarded: the reseed below replays raw scrollback that the FAILED
    // source (mostly) already archived, and an unguarded `append` here would
    // duplicate every row the replay re-derives under fresh rowIds. See
    // `ReplayGuardedHistory`'s own doc for the full trap this avoids.
    const runId = this.runIds.get(terminalId);
    const realHistory = runId ? this.openHistoryRun(terminalId, runId) : undefined;
    const historyGuard = realHistory ? new ReplayGuardedHistory(realHistory) : undefined;
    const replacement = this.constructScreen(
      terminalId, geometry.cols, geometry.rows,
      // `ReplayGuardedHistory` composes rather than subclasses `TerminalRunHistory`
      // (see its own doc for why) — safe because `TerminalFrameSource` only
      // calls the four methods this class defines on whatever it is handed.
      historyGuard as unknown as TerminalRunHistory | undefined,
    );
    try {
      current.dispose();
    } catch (error) {
      log.warn(`Terminal "${terminalId}" failed screen dispose during rebuild: %s`, error);
    }
    this.screens.set(terminalId, replacement);
    if (replacement instanceof TerminalFrameSource) {
      // Discard replies until the reseed below has actually been PARSED:
      // `feed` only queues into xterm's write buffer, so wiring the real
      // reply sink now would answer any query sitting in the replayed
      // scrollback tail (a startup DA1/CPR, commonly) as if the guest had
      // just asked it again — straight onto the live PTY as unsolicited
      // input.
      replacement.answerQueries(() => {}, ANTGRID_QUERY_COLORS);
    }
    const seed = this.scrollbacks.get(terminalId)?.getContents();
    if (seed) replacement.feed(seed);
    const session = this.sessions.get(terminalId);
    if (replacement instanceof TerminalFrameSource) {
      void replacement.settle().then(() => {
        // The slot may have moved on by the time the reseed settles — a
        // fast follow-up rebuild or dispose must not wire a live session (or
        // release history archiving) onto a generation it no longer owns.
        if (this.screens.get(terminalId) !== replacement) return;
        // Only now does the replacement start archiving NEW rows — see
        // `ReplayGuardedHistory`. Unconditional (not gated on `session`):
        // the reseed above ran regardless of whether a session is live (a
        // retained, already-exited run has none), so the guard must lift
        // regardless too, or a subsequent respawn's live output through
        // this same generation would stay suppressed forever. Shares the
        // same narrow race the query-wiring below already accepts: a live
        // chunk fed in the instant between this `settle()` call and its own
        // callback firing can be parsed (and so archived or not) before this
        // `.then()` microtask runs — bounded to that one window on one
        // rebuild, never a steady leak.
        // A rebuild that could not re-derive everything the archive already
        // held is a hole in the row history, and the replacement starts with a
        // clean `historyStatus` that would otherwise report the archive as
        // complete — the plan's rule is that a parser overflow must surface as
        // a recoverable error, never as silently-wrong authoritative state.
        if (historyGuard?.release()) replacement.noteHistoryGap();
        if (session) this.wireFrameQueries(session, replacement);
      });
    } else if (session) {
      this.wireFrameQueries(session, replacement);
    }
    log.warn(
      `Terminal "${terminalId}" frame source failed (rebuild %d/%d): %s`,
      rebuilds + 1,
      MAX_SCREEN_REBUILDS,
      failure,
    );
    return replacement;
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
   * `opts.history` asks for the emulator's scrollback as well as the screen,
   * and is the CALLER's call because only the app knows whether its engine
   * holds a deeper copy that a history blob would erase. Pass it for a cold
   * attach — an engine that has rendered nothing for this terminal — and never
   * for a re-attach.
   *
   * The seq and the blob must describe the SAME instant, and the serialize
   * barrier is a real suspension point, so the two are made to agree rather
   * than assumed to. A chunk arriving while the barrier is pending is sent to
   * the app immediately (this is the same ordered channel, so it lands BEFORE
   * the reply) and would then be wiped by the blob's own `2J` — with its seq
   * already above any cutoff read beforehand, so nothing refilters it and
   * nothing re-sends it. Four kilobytes of a streaming build, gone from the tab
   * for good. `pendingTail()` is what closes it: body + tail reconstructs the
   * screen as of the LAST byte counted, so the cutoff can be read afterwards
   * and be exact.
   *
   * The tail must come from xterm rather than from watching the chunks go by.
   * `settle()`'s callback fires from inside the parser's own loop, which then
   * keeps consuming the writes queued behind it, so most chunks that arrive
   * across the barrier are in the body ALREADY — replaying everything seen
   * paints them twice, into the user's scrollback, on every attach.
   */
  async getAttachSnapshot(
    terminalId: string,
    opts: { history?: boolean } = {},
  ): Promise<{ text: string; seq: number } | null> {
    // Head of the method: a latched TerminalFrameSource must never be what
    // this returns `null` for. `null` reads to every caller in agent-core.ts
    // as "unknown terminal", which would show an EMPTY pane over a terminal
    // that is very much alive — worse than the frozen-but-present screen a
    // failed rebuild attempt falls back to.
    const screen = this.ensureLiveScreen(terminalId);
    if (!screen) return null;
    // Settled repeatedly while the parser is merely behind, because a tail is
    // the expensive answer: those bytes have ALREADY gone out live, so
    // replaying them puts a second copy of whatever they scrolled off the
    // screen into the user's history, and the warm preamble stops at `2J`
    // precisely so it never clears that. A chunk the parser catches up on lands
    // in the BODY instead, which repaints the screen and scrolls nothing.
    // Bounded because a guest can outrun the parser indefinitely, and there the
    // duplicate rows are the lesser loss against a screen frozen a slice back.
    for (let round = 0; round < SETTLE_ROUNDS; round++) {
      await screen.settle();
      // The screen can be replaced or disposed across the barrier: an exit and
      // a same-id respawn both swap the map entry, and the barrier still fires
      // on the dead one — whose screen would then be stamped with a seq the new
      // PTY starts below and re-arm a cutoff above everything it will ever
      // emit. A blank pane behind a live process. Re-tested every round, since
      // each one is another suspension.
      if (screen.isDisposed || this.screens.get(terminalId) !== screen) return null;
      if (!screen.hasPendingTail) break;
    }
    // One synchronous run: the body, the chunks it does not yet contain, and
    // the seq that counts both. Nothing can arrive between two statements, so
    // the three describe one instant by construction.
    const blob = screen.serializeNow(opts);
    const tail = screen.pendingTail();
    const seq = this.connState.terminalSeq(terminalId);
    const supplement = this.modeTrackers.get(terminalId)?.supplementalPrelude() ?? "";
    if (tail.length > MAX_ATTACH_BLOB) {
      // `serializeNow` measures the body alone and structurally cannot see
      // this half, which is the half a flood makes large: measured at 0.78 MB
      // of replayed tail behind a 176-byte screen.
      log.warn("attach tail %d bytes replayed after the screen, past the %d mark", tail.length, MAX_ATTACH_BLOB);
    }
    return { text: blob + tail + supplement, seq };
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

  /** The current PTY run's identity, or undefined once its screen is gone —
   *  see `runIds`. */
  runId(terminalId: string): string | undefined {
    return this.runIds.get(terminalId);
  }

  get size(): number {
    return this.sessions.size;
  }
}
