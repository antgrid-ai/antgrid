// Parent-death backstops: the host is a machine-level daemon whose only tie to
// the app's lifetime is the app's `didRequestAppExit` teardown — which does NOT
// fire on a force-kill, a crash, OR (observed) a window close under
// `flutter run --machine` (aspire dev). Without a backstop the host orphans and
// accumulates.
//
// Two run side by side. `watchOwnerStdin` is the prompt one: the app holds our
// stdin pipe open for its life, and the kernel closes it however the app dies,
// so EOF arrives the instant it does. macOS and Linux have nothing like the
// Windows kill-on-close job the app also encloses us in, so this is the
// standard POSIX substitute. `startOwnerWatchdog` polls the owner's pid and is
// kept as the slower floor: EOF never arrives if any other process inherited
// the pipe's write end.

import { finished, type Readable } from "node:stream";
import { logger } from "./logger";

const log = logger.child({ component: "owner-watchdog" });

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

export interface OwnerStdinOptions {
  /** The pipe whose write end the owner holds for its whole life. */
  stdin: Readable;
  /** Called once when the pipe reaches EOF; wired to graceful shutdown. */
  onOwnerGone: (reason: string) => void;
}

/**
 * Invoke `onOwnerGone` once when the owner's end of `stdin` closes.
 *
 * Only a clean end counts. An error or a close without an end is a probe
 * quirk rather than proof of death — the pid watchdog is still running to
 * catch a real one (the same fail-safe rule as {@link pidAlive}).
 */
export function watchOwnerStdin(opts: OwnerStdinOptions): OwnerWatchdog {
  // Attach in the same tick the bootstrap read resolves. Bun's process.stdin
  // never sets `readableEnded`, so `finished` reports one that already ended
  // as a premature close, and that EOF would be lost to the pid poll.
  const cleanup = finished(opts.stdin, (err) => {
    // No cleanup here: its error listener is what keeps a later error from
    // surfacing as an uncaught exception.
    if (err) return log.warn("owner stdin errored (%s); leaving the pid watchdog to decide", err);
    cleanup();
    opts.onOwnerGone("owner stdin closed");
  });
  // Nobody else reads past the bootstrap line; `end` fires only on a flowing stream.
  opts.stdin.resume();
  return { stop: cleanup };
}
