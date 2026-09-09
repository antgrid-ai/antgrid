// web/src/integrations/github-drain-loop.ts
//
// The runner around `drainGithubWebhooks`, which applies one batch and returns.
//
// A single batch is the wrong unit for a scheduled job: a repository that was
// disabled over a weekend, or an outage the provider redelivered through, leaves
// more rows queued than one pass claims, and a runner that stops there falls
// further behind on every tick. Draining until a pass claims nothing clears that
// in one invocation — bounded, because "until empty" against a queue something
// is still filling is a job with no end.

import type { DB } from "../db/index.js";
import { GITHUB_PROVIDER } from "./github-events.js";
import { drainGithubWebhooks, type GithubDrainReport } from "./github-inbound.js";
import { purgeProcessedWebhookEvents, retentionCutoff } from "./webhook-events.js";

/**
 * Passes one invocation may run.
 *
 * Each pass claims at most `DEFAULT_BATCH_SIZE` rows, so this is really a
 * ceiling on deliveries applied per invocation. Well above any backlog a
 * connected repository produces between ticks, and low enough that a queue
 * something is filling faster than we drain it ends the invocation with a
 * report rather than never ending.
 */
export const DEFAULT_MAX_PASSES = 20;

/**
 * Wall clock one invocation may spend.
 *
 * The pass bound alone does not bound duration: a pass whose deliveries each
 * hit a slow or hanging provider-side write can take arbitrarily long, and a
 * scheduled job that never exits is one nobody notices is stuck — no exit code,
 * no report, and every later tick piling up behind it.
 */
export const DEFAULT_TIME_BUDGET_MS = 60_000;

/** Why the loop stopped. Only `queue_empty` means the backlog was cleared; the
 *  other two mean a bound cut the invocation short. */
export type GithubDrainStop = "queue_empty" | "pass_limit" | "time_budget";

export type GithubDrainLoopDeps = {
  db: DB;
  /** Injected so the loop can be exercised without Postgres, and so a test can
   *  make a pass's outcome and its duration whatever the case needs. */
  drain: (db: DB) => Promise<GithubDrainReport>;
  purge: (db: DB, args: { provider: string; before: Date }) => Promise<number>;
  /** Passed in rather than called directly, so a report is reproducible and the
   *  wall-clock bound is reachable without sleeping. */
  now: () => Date;
  maxPasses?: number;
  timeBudgetMs?: number;
};

export type GithubDrainLoopReport = {
  startedAt: Date;
  finishedAt: Date;
  passes: number;
  /** Rows the claim queries returned, summed — the work this invocation saw. */
  scanned: number;
  /** Rows this loop closed: applied, dropped as nothing we own, or closed as
   *  unparseable. Excludes `skipped`, which another drainer had already
   *  finished, and `failed`, which stays claimable. */
  processed: number;
  applied: number;
  dropped: number;
  skipped: number;
  invalid: number;
  failed: number;
  /** Failures that took a row to `MAX_WEBHOOK_ATTEMPTS`. Nothing claims those
   *  again; `listGivenUpDeliveries` is where they are read afterwards. */
  gaveUp: number;
  stoppedBecause: GithubDrainStop;
  /** A bound ended the invocation before a pass came back empty, so deliveries
   *  are likely still queued. Derived from the stop reason rather than from a
   *  re-count, which errs towards claiming a backlog that has just cleared and
   *  never towards hiding one that has not. */
  backlogRemains: boolean;
  /** Processed rows retention deleted. Zero when `purgeError` is set. */
  purgedProcessed: number;
  /** Retention is reported, never thrown: it runs after the deliveries are
   *  already committed, and losing the report of that work to a DELETE that
   *  failed would cost more than the retention did. */
  purgeError: string | null;
};

const PASS_TOTALS = [
  "scanned",
  "applied",
  "dropped",
  "skipped",
  "invalid",
  "failed",
  "gaveUp",
] as const satisfies readonly (keyof GithubDrainReport)[];

/**
 * Drain until a pass claims nothing, or until a bound says stop.
 *
 * Both bounds are checked before a pass rather than after, so `maxPasses` is the
 * number of passes run and the time budget is never overshot by a whole pass on
 * the way out.
 */
export async function drainGithubBacklog(
  deps: GithubDrainLoopDeps
): Promise<GithubDrainLoopReport> {
  const { db, drain, purge, now } = deps;
  const maxPasses = deps.maxPasses ?? DEFAULT_MAX_PASSES;
  const timeBudgetMs = deps.timeBudgetMs ?? DEFAULT_TIME_BUDGET_MS;
  const startedAt = now();

  const totals: Record<(typeof PASS_TOTALS)[number], number> = {
    scanned: 0,
    applied: 0,
    dropped: 0,
    skipped: 0,
    invalid: 0,
    failed: 0,
    gaveUp: 0,
  };
  let passes = 0;
  let stoppedBecause: GithubDrainStop = "pass_limit";

  for (;;) {
    if (passes >= maxPasses) {
      stoppedBecause = "pass_limit";
      break;
    }
    if (now().getTime() - startedAt.getTime() >= timeBudgetMs) {
      stoppedBecause = "time_budget";
      break;
    }

    const pass = await drain(db);
    passes += 1;
    for (const key of PASS_TOTALS) totals[key] += pass[key];

    // The claim query is the only thing that knows whether anything is left, and
    // it answers by returning nothing. A pass that scanned rows and applied none
    // of them still counts as work seen: those rows failed and stay claimable.
    if (pass.scanned === 0) {
      stoppedBecause = "queue_empty";
      break;
    }
  }

  // Retention runs on every invocation rather than on a schedule of its own: it
  // is one DELETE along the `[provider, processed_at]` index that removes
  // nothing on a normal day, and it cannot contend with the drain, which claims
  // only rows whose `processed_at` is null. A second scheduler entry buys
  // nothing and is one more thing to forget when the job moves.
  //
  // It is retention over APPLIED rows and nothing else, by construction:
  // `purgeProcessedWebhookEvents` matches `processed_at IS NOT NULL`. The
  // deferred event types are recorded unprocessed on purpose and are left, as
  // are rows that exhausted `MAX_WEBHOOK_ATTEMPTS` — a backlog a later phase is
  // meant to drain, and evidence nobody has read yet. Neither expires here.
  let purgedProcessed = 0;
  let purgeError: string | null = null;
  try {
    purgedProcessed = await purge(db, {
      provider: GITHUB_PROVIDER,
      before: retentionCutoff(now()),
    });
  } catch (e) {
    purgeError = e instanceof Error ? e.message : String(e);
  }

  return {
    startedAt,
    finishedAt: now(),
    passes,
    ...totals,
    processed: totals.applied + totals.dropped + totals.invalid,
    stoppedBecause,
    backlogRemains: stoppedBecause !== "queue_empty",
    purgedProcessed,
    purgeError,
  };
}

/** The production dependencies: the real drain and the real retention DELETE. */
export function githubDrainLoopDeps(db: DB): GithubDrainLoopDeps {
  return {
    db,
    drain: drainGithubWebhooks,
    purge: purgeProcessedWebhookEvents,
    now: () => new Date(),
  };
}
