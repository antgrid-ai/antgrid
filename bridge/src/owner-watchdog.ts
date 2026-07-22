// Parent-death backstop: the host is a machine-level daemon whose only tie to
// the app's lifetime is the app's `didRequestAppExit` teardown — which does NOT
// fire on a force-kill, a crash, OR (observed) a window close under
// `flutter run --machine` (aspire dev). Without a backstop the host orphans and
// accumulates. This watchdog polls the owning app's pid and self-exits the host
// when it disappears, covering every exit path uniformly.

export interface OwnerWatchdog {
  stop(): void;
}

export interface OwnerWatchdogOptions {
  /** Pid of the app process that spawned this host. */
  ownerPid: number;
  /** Called once when the owner is detected gone; wired to graceful shutdown. */
  onOwnerGone: (reason: string) => void;
  /** Liveness probe seam (defaults to {@link pidAlive}). */
  isAlive?: (pid: number) => boolean;
  /** Poll cadence. */
  intervalMs?: number;
  /**
   * Scheduler seam. Registers `cb` to run every `ms` and returns a canceller.
   * Defaults to an unref'd `setInterval` so the watchdog never keeps the event
   * loop alive on its own.
   */
  schedule?: (cb: () => void, ms: number) => () => void;
}

const DEFAULT_INTERVAL_MS = 2000;

/**
 * True if `pid` currently exists. `process.kill(pid, 0)` probes without sending
 * a real signal. Cross-platform on Bun/Node, including Windows.
 *
 * Fail SAFE: only `ESRCH` ("no such process") counts as definitively gone.
 * `EPERM` (alive but owned by another user) and any unexpected/platform errno
 * are treated as alive — a probe quirk must never tear down a live session. A
 * lingering orphan is the tolerable failure here; killing a live host is not.
 */
export function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code !== "ESRCH";
  }
}

/**
 * Start watching `ownerPid`; invoke `onOwnerGone` exactly once when it vanishes,
 * then stop polling. Caller wires `onOwnerGone` to the host's graceful shutdown.
 *
 * Caveat: pid reuse — if the OS reassigns the owner's pid to an unrelated
 * process within one poll interval of the app dying, the host would briefly see
 * it "alive". Acceptable for a dev/lifetime backstop at a 2s cadence.
 */
export function startOwnerWatchdog(opts: OwnerWatchdogOptions): OwnerWatchdog {
  const isAlive = opts.isAlive ?? pidAlive;
  const intervalMs = opts.intervalMs ?? DEFAULT_INTERVAL_MS;
  const schedule =
    opts.schedule ??
    ((cb, ms) => {
      const handle = setInterval(cb, ms);
      if (typeof handle.unref === "function") handle.unref();
      return () => clearInterval(handle);
    });

  let fired = false;
  let cancel: (() => void) | null = null;

  const tick = () => {
    if (fired) return;
    if (isAlive(opts.ownerPid)) return;
    fired = true;
    cancel?.();
    cancel = null;
    opts.onOwnerGone(`owner pid ${opts.ownerPid} exited`);
  };

  cancel = schedule(tick, intervalMs);
  return {
    stop() {
      cancel?.();
      cancel = null;
    },
  };
}
