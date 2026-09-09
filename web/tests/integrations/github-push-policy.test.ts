import { describe, expect, test } from "bun:test";
import {
  GITHUB_POINTS_PER_MINUTE,
  GITHUB_READ_POINTS,
  GITHUB_WRITE_POINTS,
  GITHUB_WRITES_PER_HOUR,
  GITHUB_WRITES_PER_MINUTE,
  MIN_THROTTLE_WAIT_MS,
  SECONDARY_LIMIT_MIN_WAIT_MS,
  createPointsBudget,
  createWriteBudget,
  pushOutcome,
  readRateHeaders,
} from "../../src/integrations/github-push-policy.js";

const T0 = new Date("2026-01-02T03:00:00.000Z");

/** Nothing here touches the wall clock: every wait is asserted as an exact
 *  instant, which is only possible with the clock injected. */
function at(offsetMs: number): Date {
  return new Date(T0.getTime() + offsetMs);
}

function res(status: number, headers: Record<string, string> = {}) {
  return { status, headers: new Headers(headers) };
}

describe("readRateHeaders", () => {
  test("every header absent reads as null rather than an unusable date", () => {
    expect(readRateHeaders(new Headers())).toEqual({
      remaining: null,
      resetAt: null,
      retryAfter: null,
    });
  });

  test("the numeric headers are read in their documented units", () => {
    const parsed = readRateHeaders(
      new Headers({
        "x-ratelimit-remaining": "17",
        "x-ratelimit-reset": String(Math.floor(at(90_000).getTime() / 1000)),
        "retry-after": "42",
      })
    );
    expect(parsed.remaining).toBe(17);
    expect(parsed.resetAt?.toISOString()).toBe(at(90_000).toISOString());
    expect(parsed.retryAfter).toBe(42);
  });

  test("Retry-After as an HTTP-date folds to seconds from now", () => {
    const parsed = readRateHeaders(
      new Headers({ "retry-after": new Date(at(30_000)).toUTCString() }),
      T0
    );
    expect(parsed.retryAfter).toBe(30);
  });

  test("garbage is dropped rather than propagated as NaN", () => {
    const parsed = readRateHeaders(
      new Headers({ "x-ratelimit-remaining": "soon", "x-ratelimit-reset": "", "retry-after": "-" })
    );
    expect(parsed).toEqual({ remaining: null, resetAt: null, retryAfter: null });
  });
});

describe("pushOutcome", () => {
  test("any 2xx is a success", () => {
    for (const status of [200, 201, 204]) {
      expect(pushOutcome(res(status), T0)).toEqual({ kind: "success", status });
    }
  });

  test("a 403 with no rate headers waits at least a minute", () => {
    const outcome = pushOutcome(res(403), T0);
    expect(outcome.kind).toBe("throttled");
    if (outcome.kind !== "throttled") throw new Error("unreachable");
    expect(outcome.limit).toBe("secondary");
    expect(outcome.retryAt.getTime() - T0.getTime()).toBeGreaterThanOrEqual(60_000);
    expect(outcome.retryAt).toEqual(at(SECONDARY_LIMIT_MIN_WAIT_MS));
  });

  test("Retry-After sets the wait exactly", () => {
    const outcome = pushOutcome(res(403, { "retry-after": "120" }), T0);
    expect(outcome).toEqual({
      kind: "throttled",
      status: 403,
      retryAt: at(120_000),
      limit: "secondary",
    });
  });

  test("an exhausted primary window wakes at x-ratelimit-reset", () => {
    const resetAt = at(15 * 60_000);
    const outcome = pushOutcome(
      res(403, {
        "x-ratelimit-remaining": "0",
        "x-ratelimit-reset": String(Math.floor(resetAt.getTime() / 1000)),
      }),
      T0
    );
    expect(outcome).toEqual({ kind: "throttled", status: 403, retryAt: resetAt, limit: "primary" });
  });

  test("a reset header already in the past cannot re-arm the op immediately", () => {
    // `x-ratelimit-reset: 0` parses to the epoch, and a stale or skewed header
    // does the same thing less obviously. Honouring it is a hot loop against the
    // limit it reports.
    const outcome = pushOutcome(
      res(403, { "x-ratelimit-remaining": "0", "x-ratelimit-reset": "0" }),
      T0
    );
    expect(outcome).toEqual({
      kind: "throttled",
      status: 403,
      retryAt: at(MIN_THROTTLE_WAIT_MS),
      limit: "primary",
    });
  });

  test("Retry-After: 0 is floored the same way", () => {
    const outcome = pushOutcome(res(429, { "retry-after": "0" }), T0);
    expect(outcome).toEqual({
      kind: "throttled",
      status: 429,
      retryAt: at(MIN_THROTTLE_WAIT_MS),
      limit: "secondary",
    });
  });

  test("remaining 0 with no reset still gets the 60s floor", () => {
    const outcome = pushOutcome(res(429, { "x-ratelimit-remaining": "0" }), T0);
    expect(outcome).toEqual({
      kind: "throttled",
      status: 429,
      retryAt: at(SECONDARY_LIMIT_MIN_WAIT_MS),
      limit: "primary",
    });
  });

  test("a 403 carrying rate headers with budget left is a permission refusal", () => {
    // The discriminator that keeps a permission 403 out of the throttle arm: an
    // op parked as throttled never increments `attempts`, so it would retry for
    // ever without the ceiling retiring it.
    const outcome = pushOutcome(
      res(403, {
        "x-ratelimit-remaining": "4931",
        "x-ratelimit-reset": String(Math.floor(at(600_000).getTime() / 1000)),
      }),
      T0
    );
    expect(outcome).toEqual({ kind: "refused", status: 403 });
  });

  test("a throttle is not a failure", () => {
    for (const outcome of [pushOutcome(res(403), T0), pushOutcome(res(429), T0)]) {
      expect(outcome.kind).not.toBe("retryable");
      expect(outcome.kind).not.toBe("refused");
      expect(outcome.kind).toBe("throttled");
    }
  });

  test("a 4xx that replays identically is a refusal", () => {
    for (const status of [400, 404, 410, 422]) {
      expect(pushOutcome(res(status), T0)).toEqual({ kind: "refused", status });
    }
  });

  test("401 is retryable, because on this path it means the token aged out", () => {
    expect(pushOutcome(res(401), T0)).toEqual({ kind: "retryable", status: 401, retryAt: null });
  });

  test("5xx is retryable and honours Retry-After when one is sent", () => {
    expect(pushOutcome(res(500), T0)).toEqual({ kind: "retryable", status: 500, retryAt: null });
    expect(pushOutcome(res(503, { "retry-after": "5" }), T0)).toEqual({
      kind: "retryable",
      status: 503,
      retryAt: at(5_000),
    });
  });
});

describe("createWriteBudget", () => {
  test("the hourly budget binds: the 501st write in an hour is refused", () => {
    const budget = createWriteBudget();
    // Seven seconds apart is ~8.5 writes/minute — comfortably inside the 80/min
    // burst ceiling, so the only limit under test is the hourly one.
    const spacingMs = 7_000;
    for (let i = 0; i < GITHUB_WRITES_PER_HOUR; i++) {
      expect(budget.take(at(i * spacingMs)).ok).toBe(true);
    }
    const lastAt = (GITHUB_WRITES_PER_HOUR - 1) * spacingMs;
    expect(lastAt).toBeLessThan(3_600_000);

    const refused = budget.take(at(lastAt));
    expect(refused.ok).toBe(false);
    if (refused.ok) throw new Error("unreachable");
    // Resumes when the oldest write ages out of the rolling hour, not "in an hour".
    expect(refused.retryAt).toEqual(at(3_600_000));
    expect(budget.take(at(3_600_000)).ok).toBe(true);
  });

  test("80/minute is a burst ceiling, not the sustained rate", () => {
    const budget = createWriteBudget();
    for (let i = 0; i < GITHUB_WRITES_PER_MINUTE; i++) {
      expect(budget.take(T0).ok).toBe(true);
    }
    const refused = budget.take(T0);
    expect(refused.ok).toBe(false);
    if (refused.ok) throw new Error("unreachable");
    expect(refused.retryAt).toEqual(at(60_000));
    expect(budget.take(at(59_999)).ok).toBe(false);
    expect(budget.take(at(60_000)).ok).toBe(true);
  });

  test("a refusal never partially spends, so the later limit is the one reported", () => {
    const budget = createWriteBudget({ perHour: 3, perMinute: 2 });
    expect(budget.take(T0).ok).toBe(true);
    expect(budget.take(T0).ok).toBe(true);
    expect(budget.take(T0).ok).toBe(false);
    // The minute window has reopened; the hourly one has one write left.
    expect(budget.take(at(60_000)).ok).toBe(true);
    const exhausted = budget.take(at(60_001));
    expect(exhausted.ok).toBe(false);
    if (exhausted.ok) throw new Error("unreachable");
    expect(exhausted.retryAt).toEqual(at(3_600_000));
  });
});

describe("createPointsBudget", () => {
  test("modelled separately, and it never binds a write", () => {
    // 900 points admits 180 writes/minute, more than twice the 80/min burst
    // ceiling — so the write budget always refuses first.
    expect(GITHUB_POINTS_PER_MINUTE / GITHUB_WRITE_POINTS).toBeGreaterThan(
      GITHUB_WRITES_PER_MINUTE
    );

    const points = createPointsBudget();
    const writes = GITHUB_POINTS_PER_MINUTE / GITHUB_WRITE_POINTS;
    for (let i = 0; i < writes; i++) {
      expect(points.take(T0, GITHUB_WRITE_POINTS).ok).toBe(true);
    }
    const refused = points.take(T0, GITHUB_READ_POINTS);
    expect(refused.ok).toBe(false);
    if (refused.ok) throw new Error("unreachable");
    expect(refused.retryAt).toEqual(at(60_000));
  });

  test("a read costs a fifth of a write against the same window", () => {
    const points = createPointsBudget(10);
    expect(points.take(T0, GITHUB_WRITE_POINTS).ok).toBe(true);
    expect(points.take(T0, GITHUB_WRITE_POINTS).ok).toBe(true);
    expect(points.take(T0, GITHUB_READ_POINTS).ok).toBe(false);
  });
});
