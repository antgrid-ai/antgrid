/**
 * The outbox's rate and backoff policy: pure functions over a response and a
 * clock, so the drain can derive `nextAttemptAt` without a network, a database
 * or a timer.
 *
 * **Throttling is not failure.** `util/rate-limit.ts` is the right shape and the
 * wrong thing to reuse: it answers `boolean`, so a drain built on it has no wait
 * time to write into `nextAttemptAt` and would count a purely local throttle as
 * an attempt — driving exponential backoff, and eventually the attempt ceiling,
 * for a queue that is merely waiting its turn. Everything here returns times.
 *
 * The limits being modelled (installation token): 5,000 requests/hour primary,
 * and on writes a secondary **80 content-creating requests/minute and 500/hour**
 * plus a 900-points/minute budget where a read costs 1 and a write costs 5.
 */

/**
 * The documented fallback when a secondary-limit response carries neither
 * `Retry-After` nor `x-ratelimit-reset`, which is the common case: wait at least
 * a minute, then let the caller's exponential backoff take over. Without a floor
 * the drain hot-loops straight into a longer block.
 */
export const SECONDARY_LIMIT_MIN_WAIT_MS = 60_000;

/**
 * The smallest wait a throttle may express.
 *
 * A `Retry-After: 0`, or an `x-ratelimit-reset` already in the past — stale,
 * zeroed, or a clock skewed the wrong way — would otherwise produce a retry time
 * that has already arrived, which re-arms the op immediately and hot-loops
 * against the very limit being reported. The drain caps consecutive throttles
 * per op, but that is an alarm on a loop already running, not a rate control.
 */
export const MIN_THROTTLE_WAIT_MS = 1_000;

/** Content-creating writes per hour. The binding constraint — see
 *  `createWriteBudget`. */
export const GITHUB_WRITES_PER_HOUR = 500;
/** Content-creating writes per minute: a burst ceiling, not the sustained rate. */
export const GITHUB_WRITES_PER_MINUTE = 80;

export const GITHUB_POINTS_PER_MINUTE = 900;
export const GITHUB_READ_POINTS = 1;
export const GITHUB_WRITE_POINTS = 5;

export type GithubRateHeaders = {
  /** Primary-limit requests left in the current window; `null` when absent. */
  remaining: number | null;
  /** When the primary window resets. */
  resetAt: Date | null;
  /** `Retry-After`, in seconds, from either spelling the RFC allows. */
  retryAfter: number | null;
};

/**
 * Tolerant of every header being absent, because on the responses that matter
 * most they usually are: GitHub's secondary-limit 403 frequently carries none of
 * the three, and a parser that assumed otherwise would produce an `Invalid Date`
 * and a `nextAttemptAt` the drain can never wake from.
 */
export function readRateHeaders(headers: Headers, now?: Date): GithubRateHeaders {
  return {
    remaining: readCount(headers.get("x-ratelimit-remaining")),
    resetAt: readEpochSeconds(headers.get("x-ratelimit-reset")),
    retryAfter: readRetryAfter(headers.get("retry-after"), now),
  };
}

function readCount(raw: string | null): number | null {
  // An empty header is the trap here: `Number("")` is 0, which would read as a
  // reset at the epoch and a wait the drain can never wake from.
  if (raw === null || raw.trim() === "") return null;
  const value = Number(raw.trim());
  return Number.isFinite(value) && value >= 0 ? Math.floor(value) : null;
}

function readEpochSeconds(raw: string | null): Date | null {
  const seconds = readCount(raw);
  return seconds === null ? null : new Date(seconds * 1000);
}

/** `Retry-After` is either delta-seconds or an HTTP-date; GitHub sends the
 *  former and proxies in front of it have been known to rewrite it. */
function readRetryAfter(raw: string | null, now?: Date): number | null {
  if (raw === null) return null;
  const seconds = readCount(raw);
  if (seconds !== null) return seconds;
  const at = Date.parse(raw);
  if (Number.isNaN(at)) return null;
  return Math.max(0, Math.ceil((at - (now?.getTime() ?? Date.now())) / 1000));
}

/**
 * What the drain does next, as a closed union.
 *
 * `throttled` must stay distinct from `retryable`: the first is "come back at
 * this time, nothing was wrong with the request" and must not touch `attempts`;
 * the second is "this failed, back off" and must.
 */
export type GithubPushOutcome =
  | { kind: "success"; status: number }
  | { kind: "throttled"; status: number; retryAt: Date; limit: "primary" | "secondary" }
  | { kind: "refused"; status: number }
  | { kind: "retryable"; status: number; retryAt: Date | null };

/** Enough of a `Response` to classify, so a caller can classify a recorded
 *  status/header pair as easily as a live response. */
export type GithubResponseLike = { status: number; headers: Headers };

/**
 * **How a rate-limit 403 is told apart from a permission 403.** GitHub answers
 * both with 403 and no machine-readable discriminator, and getting it wrong in
 * either direction is a real bug: a permission 403 read as a throttle never
 * increments `attempts`, so the op waits and retries for ever without the ceiling
 * ever retiring it; a throttle read as a refusal drops a user's edit.
 *
 * The only reliable signal is which headers are present. A permission 403 is an
 * ordinary authorized request that was denied, so it carries the normal primary
 * counters with budget left over. A secondary-limit 403 either says so through
 * `Retry-After`, or — the documented common case — carries no rate headers at
 * all. So:
 *
 * - `Retry-After` present → throttled, honour it.
 * - `x-ratelimit-remaining: 0` → the primary limit; wake at `x-ratelimit-reset`.
 * - rate headers present with budget left → a permission refusal.
 * - no rate headers at all → a secondary limit; the 60-second floor.
 *
 * 401 is deliberately `retryable` rather than `refused`: on this path it means
 * the installation token aged out mid-drain, which re-minting fixes. 422 is
 * `refused` — a validation error replays identically for ever.
 */
export function pushOutcome(response: GithubResponseLike, now: Date): GithubPushOutcome {
  const { status } = response;
  if (status >= 200 && status < 300) return { kind: "success", status };

  const rate = readRateHeaders(response.headers, now);

  if (status === 429 || status === 403) {
    if (rate.retryAfter !== null) {
      return throttled(status, "secondary", after(now, rate.retryAfter * 1000), now);
    }
    if (rate.remaining === 0) {
      return throttled(status, "primary", rate.resetAt ?? floor(now), now);
    }
    const hasRateHeaders = rate.remaining !== null || rate.resetAt !== null;
    if (status === 403 && hasRateHeaders) return { kind: "refused", status };
    return throttled(status, "secondary", floor(now), now);
  }

  // 401 sits here rather than with the refusals: on this path it means the
  // installation token aged out mid-drain, and a re-mint is the fix.
  if (status === 401 || status === 408 || status === 409 || status >= 500) {
    return {
      kind: "retryable",
      status,
      retryAt: rate.retryAfter === null ? null : after(now, rate.retryAfter * 1000),
    };
  }
  // A redirect that reached the caller means `fetch` did not follow it (a renamed
  // repository is the usual cause) — worth another pass, not a permanent refusal.
  if (status < 400) return { kind: "retryable", status, retryAt: null };
  return { kind: "refused", status };
}

function throttled(
  status: number,
  limit: "primary" | "secondary",
  retryAt: Date,
  now: Date
): GithubPushOutcome {
  const earliest = now.getTime() + MIN_THROTTLE_WAIT_MS;
  return {
    kind: "throttled",
    status,
    retryAt: retryAt.getTime() < earliest ? new Date(earliest) : retryAt,
    limit,
  };
}

function after(now: Date, ms: number): Date {
  return new Date(now.getTime() + Math.max(0, ms));
}

function floor(now: Date): Date {
  return after(now, SECONDARY_LIMIT_MIN_WAIT_MS);
}

export type BudgetDecision = { ok: true } | { ok: false; retryAt: Date };

export interface GithubBudget {
  /** Spends the cost if the budget allows, and otherwise reports the earliest
   *  time it would. Never partially spends. */
  take(now: Date, cost?: number): BudgetDecision;
}

/**
 * The write budget: 500/hour sustained with 80/minute as a burst ceiling, in
 * that order of importance. A structure sized to 80/minute burns the hourly
 * budget in six minutes and then eats 403s continuously, which for a fifty-repo
 * org happens long before the 5,000/hour primary limit is touched.
 *
 * Rolling windows rather than a leaky token bucket, because a bucket cannot
 * express this limit: capacity `C` refilling at rate `R` admits `C + R·T` in a
 * window `T`, so the only bucket that starts full at 500 admits a thousand writes
 * in its first hour — twice the limit it was sized from. A window over the write
 * timestamps admits exactly 500 in any rolling hour and, as a side effect, knows
 * precisely when the next one is allowed (the oldest write ages out), which is
 * what the drain needs for `nextAttemptAt`.
 *
 * **Process-local and non-durable**: every deploy resets every installation to a
 * full burst. That is tolerable only under a single worker, which the plan is
 * explicit about not relying on — so a later phase persisting this must be able
 * to, hence the injected clock and the absence of any I/O here.
 */
export function createWriteBudget(
  limits: { perHour?: number; perMinute?: number } = {}
): GithubBudget {
  const perHour = limits.perHour ?? GITHUB_WRITES_PER_HOUR;
  const perMinute = limits.perMinute ?? GITHUB_WRITES_PER_MINUTE;
  const hour = createWindow(perHour, 3_600_000);
  const minute = createWindow(perMinute, 60_000);
  return {
    take(now: Date, cost = 1): BudgetDecision {
      const at = now.getTime();
      const blocked = [hour.wouldBlockUntil(at, cost), minute.wouldBlockUntil(at, cost)].filter(
        (t): t is number => t !== null
      );
      if (blocked.length > 0) return { ok: false, retryAt: new Date(Math.max(...blocked)) };
      hour.spend(at, cost);
      minute.spend(at, cost);
      return { ok: true };
    },
  };
}

/**
 * The points budget — reads cost 1, writes cost 5, against 900/minute.
 *
 * Kept separate from the write budget on purpose, and it never binds a write:
 * 900 points admits 180 writes/minute, well above the 80/minute burst ceiling
 * and twenty times the ~8/minute the hourly budget sustains. It bounds the
 * *read* side — a reconcile poll — where the 5,000/hour primary limit (~83
 * requests/minute) is in turn the tighter of the two. So the order that binds is
 * writes/hour, then writes/minute, then the primary hourly limit, and the points
 * budget last; it is modelled so a caller can prove that rather than assume it.
 */
export function createPointsBudget(pointsPerMinute = GITHUB_POINTS_PER_MINUTE): GithubBudget {
  const window = createWindow(pointsPerMinute, 60_000);
  return {
    take(now: Date, cost = GITHUB_WRITE_POINTS): BudgetDecision {
      const at = now.getTime();
      const blockedUntil = window.wouldBlockUntil(at, cost);
      if (blockedUntil !== null) return { ok: false, retryAt: new Date(blockedUntil) };
      window.spend(at, cost);
      return { ok: true };
    },
  };
}

type Window = {
  /** `null` when `cost` fits, otherwise the epoch ms at which it would. */
  wouldBlockUntil(now: number, cost: number): number | null;
  spend(now: number, cost: number): void;
};

/**
 * A weighted rolling window. Entries are appended in clock order and pruned from
 * the front, so the whole structure is at most `limit` entries and the answer to
 * "when may I resume" is a walk over the oldest few rather than an estimate.
 */
function createWindow(limit: number, windowMs: number): Window {
  let entries: { at: number; cost: number }[] = [];
  let used = 0;

  function prune(now: number): void {
    const cutoff = now - windowMs;
    let drop = 0;
    while (drop < entries.length && entries[drop]!.at <= cutoff) {
      used -= entries[drop]!.cost;
      drop++;
    }
    if (drop > 0) entries = entries.slice(drop);
  }

  return {
    wouldBlockUntil(now: number, cost: number): number | null {
      prune(now);
      if (used + cost <= limit) return null;
      let shed = 0;
      for (const entry of entries) {
        shed += entry.cost;
        if (used - shed + cost <= limit) return entry.at + windowMs;
      }
      // Only reachable for a cost larger than the whole limit, which no caller
      // can satisfy by waiting; report the earliest empty window rather than
      // never, so a misconfigured cost stalls loudly instead of silently.
      return now + windowMs;
    },
    spend(now: number, cost: number): void {
      // Appended without re-sorting: the drain's clock is monotonic within a
      // pass, and an out-of-order entry would only ever shorten a wait.
      entries.push({ at: now, cost });
      used += cost;
    },
  };
}
