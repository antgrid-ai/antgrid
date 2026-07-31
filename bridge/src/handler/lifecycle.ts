// bridge/src/handler/lifecycle.ts

// Primitives for the Handler park/resume layer: how long to wait, how many
// consecutive transient failures are still a blip, and the per-terminal timers
// that carry a parked session to its wake time.

// Claude's StopFailure hook carries no reset time, so a limit park with no
// detector timestamp waits this long before nudging.
export const LIMIT_FALLBACK_MS = 30 * 60_000;

// Every driver burns its own retry budget first, so a terminal transient
// failure reaching us already means retries were exhausted.
export const TRANSIENT_CEILING = 3;

// A park that wakes instantly is not a park. The resume nudge deliberately
// bypasses the runaway guard, so a detector reporting a reset time already past
// (a stale limit snapshot, a skewed clock) must not become a nudge-fail-nudge
// loop running at full speed with nothing to stop it.
export const MIN_PARK_MS = 30_000;

// Geometric (30s, 2m, 8m …) so raising TRANSIENT_CEILING extends the series
// instead of needing a new table.
export function transientBackoffMs(failureCount: number): number {
  return 30_000 * 4 ** (failureCount - 1);
}

export interface LifecycleDeps {
  now: () => number;
  schedule: (ms: number, fn: () => void) => () => void; // returns cancel
}

// A parked session must never be the reason the bridge stays alive.
export const defaultSchedule: LifecycleDeps["schedule"] = (ms, fn) => {
  const timer = setTimeout(fn, ms) as ReturnType<typeof setTimeout> & { unref?: () => void };
  timer.unref?.();
  return () => clearTimeout(timer);
};

export class TimerRegistry {
  private timers = new Map<string, () => void>();

  constructor(private deps: LifecycleDeps) {}

  /** Replaces any existing timer for the key. Pass ms >= 0. */
  arm(key: string, ms: number, fn: () => void): void {
    this.cancel(key);
    // Drop the entry before the callback runs so fn can re-arm its own key.
    const cancel = this.deps.schedule(ms, () => {
      if (this.timers.get(key) === cancel) this.timers.delete(key);
      fn();
    });
    this.timers.set(key, cancel);
  }

  cancel(key: string): void {
    const cancel = this.timers.get(key);
    if (!cancel) return;
    this.timers.delete(key);
    cancel();
  }

  cancelAll(): void {
    for (const key of [...this.timers.keys()]) this.cancel(key);
  }
}
