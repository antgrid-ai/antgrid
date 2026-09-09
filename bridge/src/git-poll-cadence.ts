/**
 * Backoff policy for the periodic `git` backstop poll (`agent-core.ts`).
 *
 * Pure and timer-free on purpose. The whole behaviour is a 10s → 120s ladder,
 * so anything that had to WAIT for a tier to elapse could only be asserted by a
 * multi-minute test; expressed as skipped ticks of a fixed base interval it is
 * assertable synchronously, and agent-core's timers keep the shape teardown
 * already depends on (one `setInterval` per runtime, cleared in one place).
 *
 * The ladder never reaches zero. Nothing sends `session:focus` in headless use
 * — an eval, a CLI-driven bridge, a desktop the user drives from its own
 * terminal — so a hard "nobody is looking ⇒ do not poll" would freeze the Git
 * view there with nothing able to thaw it.
 */

/** Tick multipliers of the base poll period, slowest last. Against the 10s
 *  base these are 10s / 30s / 60s / 120s. */
export const GIT_POLL_TIERS = [1, 3, 6, 12];

/** An unattended, unchanging isolated checkout falls all the way to 120s: it is
 *  the O(worktrees) cost, and nobody is reading its Git view. */
export const CHECKOUT_MAX_TIER_INDEX = GIT_POLL_TIERS.length - 1;

/** Main stops at 30s. Its branch chip is the project header, shown before any
 *  session is focused, so its worst case has to stay short enough that an
 *  out-of-band commit on main is not a visible regression. */
export const MAIN_MAX_TIER_INDEX = 1;

export interface GitPollCadence {
  tierIndex: number;
  /** Ticks still to be swallowed before the next real poll runs. */
  skipsLeft: number;
}

export function createGitPollCadence(): GitPollCadence {
  return { tierIndex: 0, skipsLeft: 0 };
}

/** Whether this tick should actually spawn a refresh. Consumes one skip when
 *  it should not, so a caller must invoke it exactly once per tick. */
export function shouldRunPollTick(cadence: GitPollCadence): boolean {
  if (cadence.skipsLeft > 0) {
    cadence.skipsLeft--;
    return false;
  }
  return true;
}

/** Fold one completed poll into the cadence. A checkout that MOVED, or that
 *  somebody is looking at, goes straight back to the base period; everything
 *  else steps one tier slower, capped by the caller's own ceiling. */
export function noteGitPollResult(
  cadence: GitPollCadence,
  opts: { changed: boolean; attended: boolean; maxTierIndex: number },
): void {
  cadence.tierIndex = opts.changed || opts.attended
    ? 0
    : Math.min(cadence.tierIndex + 1, opts.maxTierIndex);
  cadence.skipsLeft = GIT_POLL_TIERS[cadence.tierIndex]! - 1;
}

/** Put the cadence back on the base period, effective from the very next tick.
 *  Called by every NON-poll refresh trigger: a checkout that just took a commit
 *  is the likeliest to move again, and is exactly where a slow backstop is
 *  felt. */
export function resetGitPollCadence(cadence: GitPollCadence): void {
  cadence.tierIndex = 0;
  cadence.skipsLeft = 0;
}
