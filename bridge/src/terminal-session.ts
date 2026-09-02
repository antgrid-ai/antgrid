import { spawn as ptySpawn } from "bun-pty";
import type { IPty, IDisposable } from "bun-pty";
import { execFile, execFileSync } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { delimiter, dirname, extname } from "node:path";
import { logger } from "./logger";
import { ETX, type GracefulExitAsk } from "./agents/types";
const log = logger.child({ component: "terminal-session" });
import { createMessage, type AbMessage } from "./protocol";
import { findOnPath } from "./tool-detector";
import { TerminalNotificationScanner, type NotificationEvent } from "./notification-scanner";
import { VtCapabilityResponder } from "./vt-capability-responder";
import { padBareVerb, PtySubmitQueue } from "./pty-submit";
import {
  createKillOnCloseJob,
  snapshotDescendants,
  survivingProcesses,
  type ProcessIdentity,
  type Win32Job,
} from "./win32-process";

/**
 * When ANTGRID_DEBUG_PTY_LOG is set, every PTY output chunk is appended to that
 * file path verbatim (raw bytes, including escape sequences). Used for
 * diagnosing terminal-emulator divergences against native terminals (e.g.
 * the opencode popup-shrink bg-attribute leak in kterm/Ghostty vs WT).
 *
 * Example: ANTGRID_DEBUG_PTY_LOG=C:\Users\bhara\Downloads\opencode-trace.bin
 *
 * Compare with `script(1)` / Windows Terminal's typescript output of the
 * same interaction to find the divergent VT op.
 */
const PTY_LOG_PATH = process.env.ANTGRID_DEBUG_PTY_LOG ?? "";
let ptyLogReady = false;
function logPtyChunk(terminalId: string, data: string): void {
  if (!PTY_LOG_PATH) return;
  if (!ptyLogReady) {
    try {
      mkdirSync(dirname(PTY_LOG_PATH), { recursive: true });
    } catch {
      // best-effort
    }
    ptyLogReady = true;
  }
  try {
    // Tag each chunk with a terminal-prefixed marker so multiple terminals
    // captured in the same file can be split apart later. The marker uses an
    // ESC-DCS sequence so it's a no-op to most parsers if the file is replayed.
    const marker = `\x1bP+|antgrid-pty:${terminalId}|\x1b\\`;
    appendFileSync(PTY_LOG_PATH, marker + data, "binary");
  } catch (e) {
    // Don't let logging failures break the agent.
    log.warn(`PTY log write failed: ${(e as Error).message}`);
  }
}

/**
 * Spawn options that put a child where `killProcessTree` can reach past it.
 *
 * POSIX kills a process GROUP, which exists only if the child leads one, and
 * `detached` is what makes it lead one — so this is not a preference, it is the
 * precondition for the POSIX half of `killProcessTree` doing anything at all.
 * Windows walks parent links instead and needs no such setup, where `detached`
 * would only cost a console window. Keep the two in lockstep.
 *
 * A PTY child needs none of this: its own `setsid` already made it a session
 * leader.
 */
export function processGroupSpawn(platform: NodeJS.Platform = process.platform): { detached: boolean } {
  return { detached: platform !== "win32" };
}

/**
 * Kill `pid` and everything it started.
 *
 * `IPty.kill()` and `ChildProcess.kill()` each signal one process, and it is
 * the survivors that matter. On Windows every one of them holds its working
 * directory open — a shell's children, and the headless `conhost.exe` each
 * console child gets — and a single orphan is enough to make
 * `git worktree remove` abort mid-tree, which strands an isolated session in a
 * state no retry can clear (Git deletes `.git` early in that sweep, a later
 * prune reaps the registration, and what is left is a directory Git will not
 * touch again). POSIX unlinks a directory out from under a running process
 * quite happily, so there an orphan blocks no delete — but it is still a
 * process nobody will ever reap, holding whatever it held.
 *
 * The two platforms are reached differently and fail differently. Windows walks
 * parent links, so the tree must die BEFORE the leader: once the leader exits
 * its children are re-parented out of reach. It walks the LIVE table, so a
 * process whose parent has ALREADY exited is unreachable to it whatever the
 * ordering — and those orphans are the ordinary survivors of an agent session.
 * That half is covered by the kill-on-close job every Windows PTY is also
 * enclosed in (`TerminalSession.spawn`); this function is one of the two
 * sweeps, never the whole of it. POSIX names the process group, which needs no
 * ordering — but a pid that leads no group names no group, and the signal is
 * then a harmless ESRCH that quietly reaches nothing. That is why callers
 * spawning outside a PTY must pass `processGroupSpawn()`.
 *
 * The kill is issued synchronously on both platforms; only the WAITING is
 * deferred. The promise resolves once taskkill has exited, so a caller that
 * needs the handles actually released before Git sweeps the directory awaits
 * it, while a caller that only needs the signal issued ignores it and leaves
 * the event loop free — which is the difference between a delete that streams
 * progress and one that goes dark for seconds. The Windows ordering survives
 * that because the ordering is between the two KILLS, not between the waits:
 * whoever kills the leader chains onto this promise rather than firing beside
 * it. The exit-waiter path is likewise unaffected — `taskkill /T` takes the
 * leader too, so the PTY's exit handler fires from taskkill's own kill and the
 * chained handle kill is only a fallback.
 *
 * It never rejects. Most callers fire and forget, and a rejection there is an
 * unhandled rejection for every ordinary terminal close.
 *
 * Exported because PTYs are not the only thing a checkout's runtime leaves
 * running: `command:run` children are spawned through a shell, so killing the
 * process handle alone reaches the wrapper and nothing under it.
 */
export function killProcessTree(pid: number): Promise<void> {
  if (!Number.isInteger(pid) || pid <= 0) return Promise.resolve();
  if (process.platform !== "win32") {
    try {
      process.kill(-pid, "SIGKILL");
    } catch {
      // No group carries this id, so there is nothing here that the caller's
      // own kill of the leader does not already reach.
    }
    return Promise.resolve();
  }
  return taskkillTrees([pid]);
}

/**
 * One `taskkill /F /T` naming every pid, never one invocation each.
 *
 * The 5s ceiling is per INVOCATION, so a second call is a second 5s the
 * teardown budget has to absorb — and `SessionManager.stopAndAwait` spends one
 * `TEARDOWN_TIMEOUT_MS` on the ask and the whole sweep together. taskkill
 * accepts repeated `/PID`, so the roots of one sweep belong in one call.
 *
 * Resolves on success, failure and timeout alike: already gone, never started,
 * or refused all leave the caller's own kill of the leader as the next step,
 * and a delete that goes on to fail reports why. It never rejects.
 */
function taskkillTrees(pids: readonly number[]): Promise<void> {
  const targets = pids.filter((pid) => Number.isInteger(pid) && pid > 0);
  if (targets.length === 0) return Promise.resolve();
  const args = ["/F", "/T", ...targets.flatMap((pid) => ["/PID", String(pid)])];
  return new Promise<void>((resolve) => {
    execFile("taskkill", args, { timeout: 5_000, windowsHide: true }, () => resolve());
  });
}

/**
 * Kill the processes from a pre-ask snapshot that are STILL the same
 * processes.
 *
 * The reach a graceful exit costs. `taskkill /T` walks live parent links, so a
 * leader that left on its own takes every route to its survivors with it, and
 * the PTY's job does not cover a child created through `ShellExecute`. What is
 * left is the snapshot taken while the tree was whole — filtered through
 * `survivingProcesses`, because a pid on its own may since have been reissued
 * to a stranger.
 *
 * `/T` as well as `/F`: each survivor may have started a tree of its own, and
 * those links ARE live.
 *
 * `alsoKill` carries the roots whose parent links are still whole — the PTY
 * leader when it ignored the ask — so the whole sweep is ONE taskkill and one
 * 5s ceiling rather than two. Naming them alongside the survivors also means
 * the identity filter runs against the process table as it is BEFORE the
 * leader kill, which is the freshest it can be.
 *
 * A snapshot that cannot be verified is not killed: `survivingProcesses`
 * answers null when the process table is unreadable, and a `/PID` that has
 * since been reissued takes a stranger's whole tree with it.
 */
function killSnapshotSurvivors(
  snapshot: readonly ProcessIdentity[],
  alsoKill: readonly number[] = [],
): Promise<void> {
  if (snapshot.length === 0) return taskkillTrees(alsoKill);
  const alive = survivingProcesses(snapshot);
  if (alive === null) {
    log.warn("process table unreadable; %d snapshotted survivor(s) left unswept", snapshot.length);
    return taskkillTrees(alsoKill);
  }
  return taskkillTrees([...alsoKill, ...alive.map((p) => p.pid)]);
}

/**
 * Reported once per distinct reason, at `warn`, naming the terminal it first
 * hit.
 *
 * Without a job or a descendant snapshot the Windows sweep cannot reach an
 * orphan, so a soft ask would COST that sweep rather than soften it and the
 * grace is skipped. Unreported it is skipped silently, on every teardown, for
 * the whole life of the bridge, and the only field symptom is an agent that
 * never gets to flush — which looks exactly like an agent that ignores the
 * ask; those are different bugs with different fixes. Keyed on the reason
 * rather than a single flag so one failure mode cannot mask the others, and
 * per-process rather than per-terminal so a machine that can never do this
 * says so once.
 */
const warnedGraceRefused = new Set<string>();
function warnGraceRefused(terminalId: string, reason: string): void {
  if (process.platform !== "win32" || warnedGraceRefused.has(reason)) return;
  warnedGraceRefused.add(reason);
  log.warn(
    '%s (first seen on terminal "%s"); agents on this machine are force-killed rather than asked to exit',
    reason,
    terminalId,
  );
}

/** A spawned child reachable by `killChildTree`: `ChildProcess` satisfies it. */
export interface KillableChild {
  readonly pid?: number;
  kill(): unknown;
}

/**
 * Kill a spawned command and everything under it, handle last.
 *
 * `command:run` spawns with `shell: true`, so the handle a caller holds is the
 * `cmd.exe`/`sh` wrapper and the real command lives beneath it with its cwd
 * inside the checkout. Killing the wrapper alone leaves that child holding the
 * very directory `git worktree remove` is about to delete.
 */
export function killChildTree(proc: KillableChild): Promise<void> {
  if (proc.pid === undefined) {
    try {
      proc.kill();
    } catch {
      // Same contract as the chained branch below: callers collect these into
      // a Promise.all and a throw here would abort the loop that is still
      // issuing the remaining kills.
    }
    return Promise.resolve();
  }
  return killProcessTree(proc.pid).then(() => {
    try {
      proc.kill();
    } catch {
      // The tree kill usually took this handle too; it is a fallback.
    }
  });
}

/**
 * Builds the env record for a spawned PTY. Merges caller keys first so
 * ANTGRID_TERMINAL_ID and ANTGRID_API_PORT always win for their own slots,
 * while unrelated caller keys are preserved. ANTGRID_API_PORT is omitted when
 * no port is available so the absence is unambiguous to consumers.
 */
export function buildSpawnEnv(
  terminalId: string,
  apiPort: number | null | undefined,
  callerEnv: Record<string, string>,
): Record<string, string> {
  return {
    ...callerEnv,
    ANTGRID_TERMINAL_ID: terminalId,
    ...(apiPort != null ? { ANTGRID_API_PORT: String(apiPort) } : {}),
  };
}

/** Scanner event kinds that route to the notification path (never "title"). */
export type NotificationRouteEvent = NotificationEvent & {
  kind: "osc9" | "osc777";
};

/**
 * Routes a single scanner event to the appropriate sink. Title events are
 * directed to the title callback so they never enter the notification/drawer
 * path; every other kind goes to the notification sink.
 *
 * Extracted as a pure function so the routing contract can be unit-tested
 * without spawning a PTY (mirrors `stripInheritedCertOverrides`).
 */
export function routeScannerEvent(
  ev: NotificationEvent,
  onTitle: ((title: string) => void) | undefined,
  onNotification: (ev: NotificationRouteEvent) => void,
): void {
  if (ev.kind === "title") {
    // Empty title = clear request; ignore so it never wipes a good name.
    if (ev.title) onTitle?.(ev.title);
    return;
  }
  onNotification(ev as NotificationRouteEvent);
}

/**
 * How long an agent PTY is given to leave on its own before the sweep runs.
 *
 * Sized against the path that pays for it. `session:stop`, `session:archive`
 * and `terminal:stop` are answered on the wire before the process is gone, so
 * the only cost there is how long a stopped row takes to stop rendering. The
 * binding budget is the delete: `SessionManager.stopAndAwait` spends ONE
 * `TEARDOWN_TIMEOUT_MS` (15s) on the exit and the tree together, and a false
 * answer there is converted into a user-visible `WORKTREE_DELETE_FAILED`, and
 * `stopAndAwait`'s trailing tree wait has no bound of its own. Every term of
 * that sum belongs here, because leaving one out is how the budget silently
 * fills: this grace, PLUS `taskkill`'s 5s ceiling — one invocation, which is
 * why `taskkillTrees` names every root in a single call — PLUS
 * `awaitSnapshotGone`'s 1s poll. The app's mode-flip reply timeout (25s) has
 * to stay above the whole of it.
 *
 * The floor is what an agent actually takes: measured against the installed
 * claude-code on Windows, ask→exit ran 1.4-3.0s across runs in a large repo. A
 * budget under that spends the whole grace and force-kills anyway, which is
 * the bug wearing a longer stopwatch.
 */
export const AGENT_GRACE_MS = 4000;

/**
 * Ceiling on the shutdown grace, on Windows only.
 *
 * `HostController.shutdownOwnedHost` posts `host:shutdown`, polls for 3s and
 * then force-kills the tree unconditionally, so this is sized to leave room in
 * those 3s for everything downstream of the ask: the sweep, the awaited
 * `teardownServices`, and the in-flight git refreshes that must be waited out
 * rather than abandoned. It does NOT guarantee they fit — a chat runtime's own
 * dispose has its own budget (codex: a 2s EOF wait, then a kill and a bounded
 * reap) and a machine with one live can overrun the poll. That is survivable
 * only because the force-kill it runs into sweeps the same tree by other means;
 * anything added here whose VALUE depends on completing before `process.exit`
 * has to be bounded at its own site. Raising this without raising that poll
 * buys nothing: the extra time is spent inside a window the caller has already
 * given up on. It also stays inside the up-to-5s drain root CLAUDE.md sizes the
 * MSIX destage risk against, so the documented figure there still holds.
 *
 * POSIX keeps the caller's own budget: shutdown there already polled for the
 * full 5s before force-killing, and cutting it would take grace away from a
 * platform that had it.
 *
 * So app-quit is the one path where the ask is genuinely best-effort: it sits
 * below the measured claude-code exit range and cannot be raised to cover it
 * without eating the sweep's share of the same 3s. The per-session paths,
 * which answer to `TEARDOWN_TIMEOUT_MS` instead, are where an agent reliably
 * gets to run its own exit path.
 */
export const WINDOWS_SHUTDOWN_GRACE_MS = 2000;

const DEFAULT_SIGNAL: NodeJS.Signals = "SIGTERM";
const DEFAULT_KEYSTROKES: readonly string[] = [ETX];
const DEFAULT_KEYSTROKE_GAP_MS = 300;

export interface TerminalSessionOptions {
  terminalId?: string;
  name?: string;
  shell?: string;
  command?: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  cols?: number;
  rows?: number;
  type?: "agent" | "service";
  onMessage: (msg: AbMessage) => void;
  /** Called with the agent's OSC 0/2 terminal title (non-empty only). Routed
   *  here instead of terminal:notification so a title never triggers the
   *  desktop-notification/drawer-float path. */
  onTitle?: (title: string) => void;
  /** When true, OSC 9/777 events from the scanner are NOT emitted as
   *  terminal:notification (titles still route). Set for plugin-source agents
   *  whose hooks own notifications, to prevent double-firing. */
  suppressOscNotifications?: boolean;
  /** When true, OSC 0/2 title events from the scanner are NOT forwarded to
   *  onTitle (notifications still route independently). Set for agents whose
   *  hook/plugin already correlates a structured session name, so a stale or
   *  mid-typed terminal-title guess never races the real one. Independent of
   *  suppressOscNotifications — see titleSourceFor vs notificationSourceFor in
   *  known-agents.ts. */
  suppressOscTitle?: boolean;
  /** The agent whose per-spawn injection includes a SessionStart hook pinging
   *  /hook-alive, or absent when this spawn's agent declares no such probe
   *  (`injectsHookAliveProbe`). Carries the key rather than a flag so the drift
   *  probe's warning can name the agent that actually went quiet. Distinct from
   *  suppressOscNotifications, which is set for every plugin-source agent. */
  hookAliveProbeAgent?: string;
  /** This agent's measured refinement of the platform's soft ask, or absent for
   *  the platform default. See {@link GracefulExitAsk}. */
  gracefulAsk?: GracefulExitAsk;
}

const BATCH_INTERVAL_MS = 16;
const BATCH_MAX_BYTES = 4096;

/**
 * Some dev orchestrators inject network overrides into every child process
 * that break a spawned tool's TLS to the public internet, depending on which
 * env vars that tool's HTTP stack honors:
 *  - SSL_CERT_DIR / SSL_CERT_FILE (OpenSSL-style cert-bundle override,
 *    pointing at a private dev/OTLP cert dir with none of the public root
 *    CAs): honored by Codex's rustls WebSocket transport (rustls-native-certs)
 *    → `invalid peer certificate: UnknownIssuer`. Go's crypto/x509 does NOT
 *    read these on Windows (root_unix.go-only upstream), so this half is a
 *    no-op for a Go-built tool like antigravity's `agy`.
 *  - HTTP_PROXY / HTTPS_PROXY: honored by net/http on every platform
 *    (http.ProxyFromEnvironment) — including Go, unlike the cert-bundle vars
 *    above. If the orchestrator's injected proxy TLS-intercepts with a cert
 *    the child doesn't trust, this is the vector that actually bites a Go
 *    binary: confirmed as agy's `tls: failed to verify certificate: x509:
 *    certificate signed by unknown authority` calling
 *    daily-cloudcode-pa.googleapis.com when spawned under aspire, while a
 *    plain terminal (no inherited proxy) authenticates fine.
 * schannel-based HTTPS (which ignores SSL_CERT_*) still works either way.
 * Spawned terminals/agents talk to the public internet and the relay, never
 * to the orchestrator's services over TLS, so every one of these overrides is
 * pure downside for them.
 *
 * When the orchestrator opts in by setting ANTGRID_STRIP_INHERITED_CERT_OVERRIDES,
 * drop all of them so children fall back to the system trust store and a
 * direct connection. This is a generic mechanism; the dev launcher owns the
 * decision to enable it (the shipped app never sets the flag, so a user's
 * deliberate SSL_CERT_* / *_PROXY config is always preserved).
 */
const OVERRIDE_VARS = [
  "SSL_CERT_DIR",
  "SSL_CERT_FILE",
  "HTTP_PROXY",
  "HTTPS_PROXY",
  "ALL_PROXY",
  "http_proxy",
  "https_proxy",
  "all_proxy",
] as const;

export function stripInheritedCertOverrides(
  env: Record<string, string>,
): Record<string, string> {
  if (!process.env.ANTGRID_STRIP_INHERITED_CERT_OVERRIDES) return env;
  const out = { ...env };
  for (const k of OVERRIDE_VARS) delete out[k];
  return out;
}

/**
 * True for antigravity's `agy`/`agy.EXE` shim, bare or pathful. agy.EXE is a
 * real PE binary but is deliberately routed through cmd.exe on Windows rather
 * than direct-ConPTY-spawned like other .exe agents — see the isAgy usage in
 * spawn() for why (confirmed A/B: agy launched directly, outside any
 * ConPTY-attached spawn, completes its OAuth/eligibility check fine; the
 * identical binary, same user/machine/moment, fails every outbound HTTPS call
 * with `tls: ... certificate signed by unknown authority` only when bun-pty
 * makes it the direct ConPTY child).
 */
export function isAntigravityBinary(command: string): boolean {
  return /(^|[\\/])agy(\.exe)?$/i.test(command);
}

/**
 * Warms Windows' CryptoAPI intermediate-certificate cache for agy's target
 * host before spawning it. Go's crypto/x509 on Windows verifies via
 * CertGetCertificateChain with CACHE-ONLY lookups — unlike browsers/.NET, it
 * never fetches a missing intermediate CA over the network. If the
 * intermediate for daily-cloudcode-pa.googleapis.com isn't already cached in
 * this Windows profile, agy fails outright with `certificate signed by
 * unknown authority`. Confirmed live: with SSL_CERT_* / proxy vars already
 * stripped and the env otherwise identical, a plain PowerShell request
 * (Invoke-WebRequest → .NET → SChannel, which DOES fetch-and-cache missing
 * intermediates) against the same host succeeds every time — the failure is
 * specific to Go's cache-only lookup, not the environment or network path.
 *
 * Synchronous and blocking (not fire-and-forget): agy can fire its own HTTPS
 * call within ~1-2s of spawn, faster than an async priming request reliably
 * wins the race (that's what the async version of this probe demonstrated —
 * it usually completed just AFTER agy's own failing call). The priming has
 * to land before the PTY exists, not concurrently with it. Bounded by a
 * short timeout and fails open — a network hiccup here must never block
 * opening the terminal, since agy would then just show its normal error.
 *
 * Windows' CryptoAPI intermediate cache is machine/profile-level, so one
 * successful prime serves every agy spawn for this bridge's lifetime. We
 * memoize on success to pay the (event-loop-blocking) PowerShell cost at most
 * once per process — a failed prime is NOT recorded, so a later spawn retries.
 */
let antigravityCertCachePrimed = false;
function primeAntigravityCertCache(env: Record<string, string>): void {
  if (process.platform !== "win32" || antigravityCertCachePrimed) return;
  const script =
    "try { Invoke-WebRequest -UseBasicParsing -Uri https://daily-cloudcode-pa.googleapis.com -Method Head -TimeoutSec 4 | Out-Null; Write-Output 'CERT-CACHE-PRIME-OK' } catch { Write-Output ('CERT-CACHE-PRIME-DONE ' + $_.Exception.Message) }";
  try {
    const out = execFileSync(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", script],
      { env, timeout: 5_000, encoding: "utf8" },
    ).trim();
    antigravityCertCachePrimed = true;
    logger.info(`antigravity cert-cache prime: ${out}`);
  } catch (e) {
    logger.warn(`antigravity cert-cache prime failed, continuing spawn anyway: ${(e as Error).message}`);
  }
}

/**
 * Resolve a bare Windows command (no path separator, no extension) against
 * PATH + PATHEXT, returning the first match and its extension. The extension
 * tells us whether the resolved target is a real PE binary (`.exe`/`.com` →
 * ConPTY can exec it directly) or a shim/script (`.cmd`/`.bat`/`.ps1`/… → must
 * go through cmd.exe). Reuses `findOnPath` so the directory/extension search
 * order and the `isFile()` guard stay consistent with tool detection. Returns
 * null if the command isn't found on PATH.
 */
function resolveWinExecutable(command: string): { path: string; ext: string } | null {
  const pathExt = (process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD")
    .split(";")
    .map((e) => e.trim())
    .filter(Boolean);
  const dirs = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
  const found = findOnPath(command, dirs, pathExt);
  return found ? { path: found, ext: extname(found).toLowerCase() } : null;
}

export class TerminalSession {
  readonly terminalId: string;
  readonly name: string;
  private shell: string;
  private _cols: number;
  private _rows: number;
  private _driverClientId: string | null = null;
  private command: string | undefined;
  private args: string[];
  private cwd: string | undefined;
  private extraEnv: Record<string, string>;
  readonly type: "agent" | "service" | undefined;
  private onMessage: (msg: AbMessage) => void;
  private onTitle?: (title: string) => void;
  private _running = false;

  private pty: IPty | null = null;
  private disposables: IDisposable[] = [];
  private treeKilledPromise: Promise<void> = Promise.resolve();
  /** Windows only, and only while this session owns a live tree — see
   *  `encloseInJob`. Null everywhere else. */
  private job: Win32Job | null = null;
  /** Whether a job was ever assigned, which is a different question from
   *  whether one is still held: `closeJob` nulls the handle on a natural exit,
   *  and the Windows grace is gated on the SWEEP being job-backed, not on the
   *  handle still being open. Conflating them makes a session that has already
   *  closed once report the FFI as unavailable. */
  private hadJob = false;
  /** A soft ask is in flight. Makes `close` idempotent: a stop racing a delete
   *  is ordinary, and a second ask that restarts the timer would push the real
   *  teardown out for as long as the user keeps pressing. */
  private closing = false;
  /** The in-flight grace, so a later caller with a TIGHTER budget can cut it —
   *  see `shortenGrace`. Undefined whenever no ask is waiting. */
  private graceTimer: ReturnType<typeof setTimeout> | undefined;
  private graceExpire: (() => void) | undefined;
  private graceDeadline = Infinity;
  /** Whether the ask was answered, once one has been made. Read by shutdown so
   *  its log can tell a machine where agents exit on request from one where
   *  every ask is ignored. */
  private _askAnswered: boolean | undefined;
  /** Set once a sweep has actually run for this session's tree. A later `kill`
   *  must not re-issue `taskkill` against the leader's pid: the process is gone
   *  and Windows may have reissued that pid to a stranger. */
  private swept = false;
  /** Resolved by the PTY's own exit, so a grace period never polls a map. */
  private exitWaiters = new Set<() => void>();
  private ask: GracefulExitAsk;

  // Output batching — collect chunks, join on flush
  private batchChunks: string[] = [];
  private batchBytes = 0;
  private batchTimer: ReturnType<typeof setTimeout> | null = null;

  private outputObservers = new Set<(data: string) => void>();
  private notificationScanner = new TerminalNotificationScanner();
  private suppressOscNotifications = false;
  private suppressOscTitle = false;
  private _hookAliveProbeAgent?: string;

  onOutput(fn: (data: string) => void): () => void {
    this.outputObservers.add(fn);
    return () => {
      this.outputObservers.delete(fn);
    };
  }

  private notifyObservers(data: string): void {
    for (const fn of this.outputObservers) {
      try {
        fn(data);
      } catch {
        // observer errors must not break PTY streaming
      }
    }
  }

  constructor(opts: TerminalSessionOptions) {
    this.terminalId = opts.terminalId ?? "default";
    this._cols = opts.cols ?? 80;
    this._rows = opts.rows ?? 24;
    this.command = opts.command;
    this.args = opts.args ?? [];
    this.cwd = opts.cwd;
    this.extraEnv = opts.env ?? {};
    this.type = opts.type;
    this.onMessage = opts.onMessage;
    this.onTitle = opts.onTitle;
    this.suppressOscNotifications = opts.suppressOscNotifications ?? false;
    this.suppressOscTitle = opts.suppressOscTitle ?? false;
    this._hookAliveProbeAgent = opts.hookAliveProbeAgent;
    this.ask = opts.gracefulAsk ?? {};

    this.shell = opts.shell ?? this.detectShell();
    this.name = opts.name ?? opts.command ?? this.shell;
  }

  get cols(): number { return this._cols; }
  get rows(): number { return this._rows; }
  get driverClientId(): string | null { return this._driverClientId; }
  /** A PTY that has been ASKED to leave is on its way out, not running. It has
   *  to answer the same way `SessionManager.isRunning` does — `agent:status`
   *  and the session rows are two channels of the same client, and for the
   *  seconds a grace is worth they would otherwise contradict each other. */
  get isRunning(): boolean { return this._running && !this.closing; }
  get shellBinary(): string { return this.command ?? this.shell; }
  // The agent whose injection includes a SessionStart /hook-alive ping — the
  // drift probe arms for these and no others, and names this in its warning.
  get hookAliveProbeAgent(): string | undefined { return this._hookAliveProbeAgent; }
  /** This agent's declared grace, or undefined for the platform default. */
  get graceMs(): number | undefined { return this.ask.graceMs; }
  /** Whether a sweep of this session's tree reaches the orphans a parent-link
   *  walk cannot. False off Windows, where nothing needs it, and on a machine
   *  whose Win32 layer refused to load — which is the one case where a soft ask
   *  would still cost the sweep, so the grace is gated on it. */
  get jobBacked(): boolean { return this.hadJob; }
  /** Undefined until this session has been asked to leave. */
  get askAnswered(): boolean | undefined { return this._askAnswered; }

  // Re-enable the OSC scanner after it was suppressed for a plugin-owned agent.
  // Self-healing fallback for when the plugin's hooks never check in: restores
  // the terminal scanner as a best-effort notification net instead of leaving
  // the session permanently muted.
  enableOscNotifications(): void { this.suppressOscNotifications = false; }

  // Re-enable the OSC title scanner after it was suppressed for an agent whose
  // hook was expected to supply the structured name. Same self-healing intent
  // as enableOscNotifications, kept as a separate toggle since the two signals
  // are suppressed independently (see titleSourceFor vs notificationSourceFor).
  enableOscTitle(): void { this.suppressOscTitle = false; }

  private detectShell(): string {
    return process.env.SHELL || (process.platform === "win32" ? "powershell.exe" : "/bin/bash");
  }

  spawn(): void {
    let cmd: string;
    let args: string[];
    if (this.command) {
      // Shell-wrap rules:
      //  - Free-form commands with whitespace (e.g. "npm run serve") need a
      //    shell because PTY treats arg 0 as a literal executable path.
      //  - On Windows, ConPTY can only directly exec a PE binary — it can't run
      //    `.cmd`/`.bat` shims (e.g. `npm`, `claude`, `opencode` under
      //    `~/.bun/bin` or `~/AppData/Roaming/npm`), which must go through
      //    cmd.exe. So we resolve bare names against PATH and direct-spawn
      //    anything that's a true `.exe`/`.com`, reserving the shell wrap for
      //    genuine shims, free-form lines, and unresolved commands.
      //  - WHY prefer direct spawn beyond shim support: bun-pty does not use
      //    Windows CommandLineToArgvW quoting. It serializes argv POSIX-style
      //    (single-quote each token, then `shell_words::split` on the Rust
      //    side) and re-joins for CreateProcess. A pre-joined, hand-quoted
      //    cmd.exe line gets processed twice and corrupted — e.g.
      //    `node -e "console.log('x')"` reaches node with the inner quoting
      //    mangled and prints nothing. Direct-spawning the resolved exe with a
      //    plain argv array skips the cmd.exe re-parse entirely. For the shims
      //    that genuinely need cmd.exe we pass argv as SEPARATE elements (not a
      //    pre-joined line) so each token survives the round-trip; see below.
      const isWin = process.platform === "win32";
      const hasWhitespace = this.args.length === 0 && /\s/.test(this.command);
      let directCmd: string | null = null; // resolved exe to spawn directly
      let needsShell = hasWhitespace;
      if (isWin && !hasWhitespace) {
        const pathful = this.command.includes("\\") || this.command.includes("/");
        if (/\.(cmd|bat)$/i.test(this.command) || isAntigravityBinary(this.command)) {
          needsShell = true; // explicit shim / ConPTY-direct-spawn workaround (see isAntigravityBinary)
        } else if (/\.(exe|com)$/i.test(this.command) || pathful) {
          // Already a concrete target (explicit .exe/.com, or a path) — leave
          // it for direct spawn below.
        } else {
          // Bare name: resolve via PATH to tell a real exe from a shim.
          const resolved = resolveWinExecutable(this.command);
          if (resolved && (resolved.ext === ".exe" || resolved.ext === ".com")) {
            directCmd = resolved.path; // real executable — exec it directly
          } else {
            needsShell = true; // .cmd/.bat shim, assoc-run script, or not found
          }
        }
      }
      if (needsShell) {
        if (isWin) {
          // Pass command + args as SEPARATE argv elements, NOT a pre-joined,
          // hand-quoted line. bun-pty's POSIX-style serialization + Rust
          // re-join (see the comment above) corrupts a pre-quoted line —
          // splitting `"a b"` into two tokens and leaking literal quotes.
          // Separate elements survive intact; cmd.exe /c then runs
          // `<command> <args…>`. The free-form whitespace case has no args, so
          // the command travels as a single token. Caveat: raw cmd
          // metacharacters (& | < > ^) inside a discrete arg still aren't
          // escaped — a limitation of bun-pty's POSIX-oriented pipeline, not
          // reachable through the structured args[] our callers use.
          cmd = process.env.ComSpec ?? "cmd.exe";
          args = ["/d", "/s", "/c", this.command, ...this.args];
        } else {
          // POSIX only reaches here for the whitespace free-form case (args is
          // empty), so the command is already a complete `sh -c` line.
          cmd = process.env.SHELL ?? "/bin/sh";
          args = ["-c", this.command];
        }
      } else {
        cmd = directCmd ?? this.command;
        args = this.args;
      }
    } else {
      cmd = this.shell;
      args = [];
    }
    log.info(`Spawning terminal "${this.terminalId}": ${cmd} ${args.join(" ")} (${this._cols}x${this._rows})`);

    // Announce a terminal identity that agents recognize as OSC-9-capable so
    // they emit rich desktop notifications (with a message) instead of bare
    // BEL. Ghostty is fitting — the app renderer is ghostty-VTE. See design
    // doc; revisit if kitty-graphics attempts cause rendering issues.
    const env = stripInheritedCertOverrides({
      ...process.env,
      TERM_PROGRAM: "ghostty",
      TERM_PROGRAM_VERSION: "1.0.0",
      ...this.extraEnv,
    } as Record<string, string>);

    if (isAntigravityBinary(this.command ?? "")) {
      primeAntigravityCertCache(env);
    }

    this.pty = ptySpawn(cmd, args, {
      cols: this._cols,
      rows: this._rows,
      cwd: this.cwd ?? process.cwd(),
      env,
      name: "xterm-256color",
    });

    // First statement after the pid exists, and nothing may await before it:
    // the child is already running, and anything it spawns ahead of the
    // assignment is created outside the job and stays beyond every sweep.
    this.encloseInJob(this.pty.pid);

    this.closing = false;
    this.swept = false;
    this._askAnswered = undefined;
    this._running = true;

    this.onMessage(
      createMessage("terminal:started", {
        terminalId: this.terminalId,
        shell: cmd,
        cols: this._cols,
        ...(this.type ? { terminalType: this.type } : {}),
        rows: this._rows,
      })
    );

    this.disposables.push(
      this.pty.onData((data) => {
        logPtyChunk(this.terminalId, data);
        this.respondToCapabilityQueries(data);
        try {
          for (const ev of this.notificationScanner.feed(data, Date.now())) {
            routeScannerEvent(ev, (title) => {
              if (this.suppressOscTitle) return; // hook owns the structured title
              this.onTitle?.(title);
            }, (notifEv) => {
              if (this.suppressOscNotifications) return; // plugin owns notifications
              this.onMessage(
                createMessage("terminal:notification", {
                  terminalId: this.terminalId,
                  kind: notifEv.kind,
                  ...(notifEv.title !== undefined ? { title: notifEv.title } : {}),
                  ...(notifEv.body !== undefined ? { body: notifEv.body } : {}),
                })
              );
            });
          }
        } catch {
          // scanner must never break PTY streaming
        }
        this.notifyObservers(data);
        this.enqueueBatch(data);
      })
    );

    this.disposables.push(
      this.pty.onExit(({ exitCode }) => {
        this._running = false;
        this.flushBatch();
        this.dispose();
        // Before the job close below, so a grace period waiting on this exit
        // resolves into a microtask that already finds the tree reaped.
        this.settleExitWaiters();
        // An exit nobody asked for takes the tree with it too: an agent that
        // finishes on its own is the common case, and the helpers it leaves
        // behind hold a checkout subdirectory open — which on Windows is
        // exactly what makes that checkout undeletable.
        this.closeJob();
        log.info(`Terminal "${this.terminalId}" exited with code ${exitCode}`);
        this.onMessage(
          createMessage("terminal:exited", {
            terminalId: this.terminalId,
            exitCode,
          })
        );
      })
    );
  }

  /**
   * Enclose the PTY's tree in a job the kernel empties when this session is
   * finished with it.
   *
   * `killProcessTree` walks live parent links, which by construction cannot
   * reach a process whose parent has already exited — and those are the
   * ordinary survivors here. An agent's helpers (sandbox command runners,
   * analysis servers) outlive the PTY holding a checkout subdirectory as their
   * current directory, and Windows refuses to delete a directory that is any
   * process's cwd, so `git worktree remove` aborts and the isolated session
   * becomes undeletable. Job membership is inherited at `CreateProcess` and
   * survives the parent's death, so a job reaches exactly what the walk
   * cannot. It narrows the failure rather than closing it: a child created
   * through `ShellExecute` is spawned by another process entirely and joins
   * that one's job.
   *
   * The pid is the right root: bun-pty reports the SHELL it spawned, and the
   * ConPTY's `conhost.exe` is a sibling created by this process that carries
   * our cwd, not the PTY's — measured, so it holds no checkout to begin with.
   *
   * Inert off Windows, where the process group already reaches the tree and an
   * orphan blocks no delete, and inert whenever the Win32 layer failed to
   * load: `createKillOnCloseJob` answers null for both, so a spawn proceeds
   * exactly as it does with no job at all.
   */
  private encloseInJob(pid: number): void {
    // A second spawn into this session replaces the tree the old handle owns.
    this.closeJob();
    this.hadJob = false;
    const job = createKillOnCloseJob();
    if (job === null) {
      warnGraceRefused(this.terminalId, "the kill-on-close job could not be created");
      return;
    }
    // A kill-on-close job with no members is a kernel object with nothing to
    // reap — drop it rather than hold a handle for a tree it does not own.
    if (!job.assign(pid)) {
      job.close();
      warnGraceRefused(this.terminalId, "this PTY could not be assigned to a kill-on-close job");
      return;
    }
    this.job = job;
    this.hadJob = true;
  }

  /**
   * Closing the handle IS the reap: every member still running dies with it,
   * orphans included. Cleared from the session in the same step, so the handle
   * is closed exactly once however many teardown paths reach it.
   *
   * Nothing here runs when the bridge is force-killed, and nothing needs to —
   * the kernel closes our handles as it reaps us, which sweeps every PTY tree
   * on the one path that skips all shutdown code.
   */
  private closeJob(): void {
    this.job?.close();
    this.job = null;
  }

  private enqueueBatch(data: string): void {
    this.batchChunks.push(data);
    this.batchBytes += data.length;

    if (this.batchBytes >= BATCH_MAX_BYTES) {
      this.flushBatch();
      return;
    }

    if (!this.batchTimer) {
      this.batchTimer = setTimeout(() => this.flushBatch(), BATCH_INTERVAL_MS);
    }
  }

  private flushBatch(): void {
    if (this.batchTimer) {
      clearTimeout(this.batchTimer);
      this.batchTimer = null;
    }
    if (this.batchChunks.length === 0) return;

    const data = this.batchChunks.length === 1
      ? this.batchChunks[0]
      : this.batchChunks.join("");
    this.batchChunks.length = 0;
    this.batchBytes = 0;

    this.onMessage(
      createMessage("terminal:output", {
        terminalId: this.terminalId,
        data,
      })
    );
  }

  private dispose(): void {
    for (const d of this.disposables) d.dispose();
    this.disposables.length = 0;
  }

  resize(clientId: string, cols: number, rows: number): void {
    this._driverClientId = clientId;
    this._cols = cols;
    this._rows = rows;
    log.info(`Terminal "${this.terminalId}" resized to ${cols}x${rows} by ${clientId}`);
    try {
      this.pty?.resize(cols, rows);
    } catch {
      // PTY may have already exited
    }
  }

  /** Serializes this session's writes. Built once: a per-write queue would
   *  order nothing. The writer reads `this.pty` at call time because the pty is
   *  assigned at spawn, long after this field. */
  private submitQueue = new PtySubmitQueue({
    write: (data) => {
      try {
        this.pty?.write(data);
      } catch {
        // PTY may have already exited
      }
    },
  });

  write(data: string): void {
    this.submitQueue.write(data);
  }

  /**
   * Send `line` as a prompt. The caller hands over the line WITHOUT its CR and
   * the queue writes the CR as a separate read — see `pty-submit.ts` for why a
   * CR sharing a read with the line it submits is inserted as literal text.
   */
  submit(line: string): void {
    // Only an agent TUI has a slash-command suggestion list to trip; a shell
    // must receive exactly what was typed.
    this.submitQueue.submit(this.type === "agent" ? padBareVerb(line) : line);
  }

  /**
   * Answer the VT capability queries the spawned process emits at startup.
   * The responder is stateful (it carries a query split across PTY chunks and
   * follows the guest's own mode changes), so it must live for the whole
   * session — see `vt-capability-responder.ts` for why this side answers at
   * all and why it is the only side that does.
   *
   * The colours are Antgrid's design tokens and must stay in lockstep with
   * `AbColors` (`app/lib/design/ab_colors.dart`): they are what the guest
   * picks its own contrast against.
   */
  private capabilityResponder = new VtCapabilityResponder({
    foreground: "rgb:fafa/fafa/fafa", // ≈ textPrimary
    background: "rgb:0909/0909/0b0b", // ≈ bgDeepest
    cursor: "rgb:8181/8c8c/f8f8", //     ≈ accent indigo
  });

  private respondToCapabilityQueries(data: string): void {
    const replies = this.capabilityResponder.feed(data);
    if (replies === "") return;
    // Through the queue like every other writer: a reply written raw would be the one
    // thing that can land BETWEEN an injected line and its deferred CR, which is the
    // interleave `pty-submit.ts` exists to make impossible. It costs these replies
    // nothing in the case that matters — the queue is a synchronous pass-through while
    // no submit is in flight, which is the whole startup burst these queries arrive in —
    // and query protocols are FIFO, an order the queue preserves.
    this.write(replies);
  }

  /** Resolves once this session's process tree is gone — see `killProcessTree`
   *  for who needs to wait and why. Already-resolved before any `kill()`. */
  get treeKilled(): Promise<void> {
    return this.treeKilledPromise;
  }

  /**
   * Ask this session's process to leave, and sweep whatever is left of its tree
   * once it has, or once `graceMs` has passed.
   *
   * NOT `async`, and it may not become one. `SessionManager.stopAndAwait` reads
   * `treeKilled` immediately after asking for the stop, deliberately — the exit
   * handler drops the session from the map, so there is no later chance to read
   * it. A `close` that assigned `treeKilledPromise` after any suspension would
   * hand that read the already-resolved placeholder, the tree wait would be
   * vacuous, and `git worktree remove` would then run against a live tree: on
   * Windows a sharing violation, and one no retry can clear.
   *
   * The escalation is UNCONDITIONAL. Nothing branches on whether the ask was
   * answered, which is what makes a wrong guess about an agent cost latency
   * instead of correctness — and an agent that leaves on its own still leaves
   * helpers behind, so the answered branch owes a sweep too.
   */
  close(graceMs: number): Promise<void> {
    if (this.closing) {
      // A later caller may only TIGHTEN a grace already running, never extend
      // it: shutdown clamps to `WINDOWS_SHUTDOWN_GRACE_MS` because the app
      // force-kills this whole tree seconds after asking, and handing it back
      // a per-session 4s chain spends that window on the ask alone.
      this.shortenGrace(graceMs);
      return this.treeKilledPromise;
    }
    const pty = this.pty;
    if (!pty || !this._running || graceMs <= 0) {
      this.kill();
      return this.treeKilledPromise;
    }
    if (process.platform === "win32" && !this.hadJob) {
      // Without the job the parent-link walk is the whole sweep, and asking
      // first is precisely what destroys it. Fall back to what still works.
      warnGraceRefused(this.terminalId, "no kill-on-close job is held for this PTY");
      this.kill();
      return this.treeKilledPromise;
    }
    // Taken while the tree is still whole: see `killSnapshotSurvivors`. A
    // snapshot that could not be taken is the same bargain as a missing job —
    // the only reach a departing leader leaves behind is gone, so the ask
    // would cost the sweep instead of softening it.
    let snapshot: readonly ProcessIdentity[] = [];
    if (process.platform === "win32") {
      const taken = snapshotDescendants(pty.pid);
      if (taken === null) {
        warnGraceRefused(this.terminalId, "this PTY's descendants could not be snapshotted");
        this.kill();
        return this.treeKilledPromise;
      }
      snapshot = taken;
    }
    this.closing = true;
    // Registered BEFORE the ask, so a process that exits inside the ask itself
    // cannot land its exit between the two.
    const exited = this.awaitExitWithin(graceMs);
    // An agent's farewell is not an attention signal — it must not ring a
    // phone on the way out.
    this.suppressOscNotifications = true;
    this.askToExit(pty);
    const previous = this.treeKilledPromise;
    this.treeKilledPromise = exited.then((onOwn) => {
      this._askAnswered = onOwn;
      if (onOwn) {
        log.info(`Terminal "${this.terminalId}" exited on request`);
      } else {
        log.warn(
          `Terminal "${this.terminalId}" ignored the graceful ask after ${graceMs}ms; force-killing`,
        );
      }
      // The exit handler has already done both on the answered branch; this is
      // for the branch where nothing exited, whose batched output would
      // otherwise die with the process.
      this._running = false;
      this.flushBatch();
      return this.gracefulSweep(pty, snapshot, onOwn);
    }).catch((err) => {
      // `treeKilled` must never reject, exactly as `killProcessTree` must not:
      // most callers fire and forget, `killAllGracefully` gathers these in a
      // `Promise.all` whose rejection would skip the shutdown steps after it,
      // and index.ts turns an unhandled rejection into a whole-bridge exit.
      // The flush above is the one throw site — it runs observer callbacks and
      // the transport — and losing a final output chunk must not cost a sweep.
      log.warn(`Terminal "${this.terminalId}" close chain failed: %s`, err);
    }).then(() => previous);
    return this.treeKilledPromise;
  }

  /** Cut an in-flight grace short. Never lengthens one — a caller whose budget
   *  is already covered by the running deadline has nothing to say. */
  private shortenGrace(graceMs: number): void {
    if (this.graceTimer === undefined || this.graceExpire === undefined) return;
    const ms = Math.max(0, graceMs);
    const deadline = Date.now() + ms;
    if (deadline >= this.graceDeadline) return;
    this.graceDeadline = deadline;
    clearTimeout(this.graceTimer);
    this.graceTimer = setTimeout(this.graceExpire, ms);
  }

  kill(): void {
    // Stays void: nearly every caller fires this from a message handler and the
    // signal, not the reaping, is what they are asking for.
    this._running = false;
    this.flushBatch();
    // Captured before the chain so a later respawn reassigning `this.pty`
    // cannot redirect the deferred handle kill at the new PTY.
    const pty = this.pty;
    // Taken off the session for the same reason, and so the exit this kill
    // provokes finds nothing left to close.
    const job = this.job;
    this.job = null;
    if (!pty || this.swept) {
      // A tree already swept must not be walked again: the leader's pid is free
      // by then, and `taskkill /T` against a reissued one takes a stranger's
      // whole tree with it.
      job?.close();
      return;
    }
    // A re-kill finds the job already taken, so its own chain closes nothing —
    // and `treeKilled` is read by whoever asks LAST. Chaining the previous
    // promise in is what keeps that read covering the job close: without it a
    // second kill lands a promise that resolves while the first chain, the only
    // one holding the handle, is still walking the tree.
    const previous = this.treeKilledPromise;
    this.treeKilledPromise = killProcessTree(pty.pid).then(() => {
      try {
        pty.kill();
      } catch {
        // On Windows `taskkill /T` normally reaped the leader already, so this
        // lands on a dead handle by design rather than by accident.
      }
      // Last, so the parent-link walk above still runs against a live tree.
      // The job is the backstop for what that walk cannot see — an orphan
      // whose parent is already gone — never a replacement for it, and
      // `treeKilled` therefore still resolves only once both have been issued.
      job?.close();
      this.swept = true;
      return previous;
    });
  }

  /**
   * The one soft ask each platform actually has.
   *
   * POSIX signals the GROUP, not the bare leader. bun-pty's own `setsid` makes
   * the PTY child a session leader, and the SIGKILL this escalates to names
   * that same group, so signalling the leader alone is strictly narrower than
   * its own escalation — and the leader IS the `sh -c` wrap `spawn()` puts
   * around a free-form command, so the agent underneath it never sees the ask.
   *
   * Windows has no soft signal to send: bun-pty's kill ignores its argument,
   * node maps every signal to TerminateProcess, and `GenerateConsoleCtrlEvent`
   * is unreachable from here — the ConPTY child leads no process group
   * (CTRL_BREAK to its pid answers ERROR_INVALID_PARAMETER), and the
   * AttachConsole + group-0 route reported success and delivered nothing, twice,
   * including against a non-ConPTY control child. What DOES arrive is a
   * KEYSTROKE: a raw-mode reader receives 0x03 verbatim, a cooked-mode one
   * receives nothing at all. That asymmetry is why only agent PTYs are asked —
   * a build tool in a service or setup PTY could not see this if we sent it.
   */
  private askToExit(pty: IPty): void {
    if (process.platform !== "win32") {
      // `-0` is `0`, which names OUR OWN process group — the same floor
      // `killProcessTree` keeps, and for the same reason.
      if (!Number.isInteger(pty.pid) || pty.pid <= 0) return;
      const signal = this.ask.signal ?? DEFAULT_SIGNAL;
      try {
        process.kill(-pty.pid, signal);
      } catch {
        // A leader that somehow leads no group still deserves the ask.
        try {
          process.kill(pty.pid, signal);
        } catch {
          // Already gone; the exit waiter is about to answer.
        }
      }
      return;
    }
    const keystrokes = this.ask.keystrokes ?? DEFAULT_KEYSTROKES;
    const gapMs = this.ask.gapMs ?? DEFAULT_KEYSTROKE_GAP_MS;
    let next = 0;
    const press = (): void => {
      if (!this._running || next >= keystrokes.length) return;
      // `TerminalSession.write`, below the manager's — the work-status fold is
      // fed from agent-core's inbound `terminal:input` handler, so a teardown
      // keystroke can never flip a dying session to "working".
      this.write(keystrokes[next++]!);
      if (next < keystrokes.length) setTimeout(press, gapMs);
    };
    press();
  }

  /** True if this session's PTY exited within `ms`. The timer is kept on the
   *  session so `shortenGrace` can cut it. */
  private awaitExitWithin(ms: number): Promise<boolean> {
    if (!this._running) return Promise.resolve(true);
    this.graceDeadline = Date.now() + ms;
    return new Promise<boolean>((resolve) => {
      const expire = (): void => {
        this.graceTimer = undefined;
        this.graceExpire = undefined;
        this.exitWaiters.delete(waiter);
        resolve(false);
      };
      const waiter = (): void => {
        if (this.graceTimer !== undefined) clearTimeout(this.graceTimer);
        this.graceTimer = undefined;
        this.graceExpire = undefined;
        this.exitWaiters.delete(waiter);
        resolve(true);
      };
      this.graceExpire = expire;
      this.graceTimer = setTimeout(expire, ms);
      this.exitWaiters.add(waiter);
    });
  }

  private settleExitWaiters(): void {
    const waiters = [...this.exitWaiters];
    this.exitWaiters.clear();
    for (const waiter of waiters) waiter();
  }

  /**
   * The sweep that follows a grace period, in the order that makes it work: the
   * reach that still exists first, then the handle, then the job — last, so
   * everything above it ran against a live tree.
   *
   * It resolves only once the tree is actually gone, which the job alone cannot
   * promise: `CloseHandle` initiates the kill and returns, while `git worktree
   * remove` runs the instant this settles.
   */
  private gracefulSweep(
    pty: IPty,
    snapshot: readonly ProcessIdentity[],
    leaderExited: boolean,
  ): Promise<void> {
    // Same floor `kill()` keeps, and for the same reason: a `kill()` landing
    // inside the grace has already walked this tree and provoked the exit that
    // ends it, so the pid `reapAfterGrace` would name is free by now and both
    // its unguarded roots — `taskkill /T` and the POSIX pgid — would then take
    // a stranger's whole tree. The handle and job below are still owed: closing
    // a job twice is a no-op and the handle kill is caught.
    const reaped = this.swept
      ? Promise.resolve()
      : this.reapAfterGrace(pty, snapshot, leaderExited);
    return reaped.then(() => {
      try {
        pty.kill();
      } catch {
        // Ordinary on the answered branch: the handle is already dead.
      }
      this.closeJob();
      this.swept = true;
      return this.awaitSnapshotGone(snapshot);
    });
  }

  private reapAfterGrace(
    pty: IPty,
    snapshot: readonly ProcessIdentity[],
    leaderExited: boolean,
  ): Promise<void> {
    // The leader is still there, so both platforms still have their full reach:
    // the live parent-link walk on Windows, the process group on POSIX. One
    // taskkill carries both roots — a second invocation is a second 5s ceiling
    // the delete's own budget has to absorb.
    if (!leaderExited) {
      return process.platform === "win32"
        ? killSnapshotSurvivors(snapshot, [pty.pid])
        : killProcessTree(pty.pid);
    }
    if (process.platform === "win32") return killSnapshotSurvivors(snapshot);
    if (!Number.isInteger(pty.pid) || pty.pid <= 0) return Promise.resolve();
    // The group id IS the leader's pid, and bun-pty has already reaped that
    // leader — so an empty group is a pgid the kernel may have reissued. A
    // group with any member left still answers, and its id cannot be reused
    // while it does.
    try {
      process.kill(-pty.pid, 0);
    } catch {
      return Promise.resolve();
    }
    return killProcessTree(pty.pid);
  }

  /** Bounded, because both halves of the reap are asynchronous: `taskkill`
   *  returns before its targets have finished exiting, and closing the job only
   *  initiates the sweep. Expiring is not a failure to report here — the delete
   *  that follows names whoever still holds the directory. */
  private async awaitSnapshotGone(snapshot: readonly ProcessIdentity[]): Promise<void> {
    if (snapshot.length === 0) return;
    for (let attempt = 0; attempt < 10; attempt++) {
      // `?.length === 0`, so an unreadable process table (null) keeps polling:
      // a waiter must never read a failed enumeration as proof the tree is
      // gone — `git worktree remove` runs the instant this resolves.
      if (survivingProcesses(snapshot)?.length === 0) return;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
}
