// web/src/tasks/sync-drain-loop.ts
//
// The runner around `applyOp`, which executes one outbox op and returns.
//
// Scheduling and credentials are the whole job here: which ops to hand to the
// executor, whose installation token they go out under, and when to stop. Every
// decision about what a push means belongs to `apply-op.ts` and nothing in this
// file reopens one.

import type { DB } from "../db/index.js";
import {
  createGithubAppClient,
  type FetchLike,
  type GithubAppClient,
  type GithubAppConfig,
  type GithubInstallationToken,
} from "../integrations/github-app.js";
import { GITHUB_PROVIDER } from "../integrations/github-events.js";
import {
  createGithubIssueWriter,
  type GithubIssueWriter,
} from "../integrations/github-issues.js";
import { createWriteBudget, type GithubBudget } from "../integrations/github-push-policy.js";
import { applyOp, type ApplyOpDeps, type ApplyOpOutcome } from "./apply-op.js";
import {
  claimNextOps,
  failOp,
  throttleOp,
  SYNC_OP_BACKOFF_MAX_SECONDS,
  type TaskSyncOpRecord,
} from "./sync-op.js";

/**
 * Ops one claim pass may take.
 *
 * Sized against the write budget rather than against a backlog: a patch is two
 * round trips and a create is one content-creating write, and the sustained
 * ceiling is 500 of those an hour with 80 a minute as the burst. This times
 * `DEFAULT_MAX_PASSES` is the per-invocation ceiling, and at a one-minute
 * schedule that lands exactly on the burst ceiling — past which the shared
 * budget refuses anyway, which ends the invocation rather than earning anything.
 */
export const SYNC_DRAIN_BATCH_SIZE = 10;

/** Passes one invocation may run. See `SYNC_DRAIN_BATCH_SIZE` for the product
 *  the two of them are really sized as. */
export const DEFAULT_MAX_PASSES = 8;

/**
 * Wall clock one invocation may spend.
 *
 * The pass bound does not bound duration: every op in a pass is at least one
 * provider round trip, and a scheduled job that never exits is one nobody
 * notices is stuck — no exit code, no report, and every later tick piling up
 * behind it.
 */
export const DEFAULT_TIME_BUDGET_MS = 60_000;

/**
 * Consecutive throttles one op may collect in a single invocation before this
 * loop stops working it.
 *
 * **This is not a politeness bound, it is the only ceiling on a misread 403.**
 * `throttleOp` deliberately never increments `attempts`, so nothing in the
 * outbox retires a throttled op; and `pushOutcome` tells a rate 403 from a
 * permission 403 only by which headers are present, so a permission refusal
 * arriving without rate headers is classified as a secondary limit and retried
 * for ever. `MIN_THROTTLE_WAIT_MS` stops a retry time in the past from making
 * that loop a hot one, which is a separate concern: it bounds the rate, and
 * only this bounds the duration.
 *
 * Three, because a genuine throttle sets a retry time past the end of this
 * invocation's wall clock — so a second throttle of one op inside one
 * invocation already means the wait it was given was not a wait, and a third
 * means it is not going to become one.
 */
export const MAX_CONSECUTIVE_THROTTLES = 3;

/**
 * Passes that claim nothing before the invocation ends.
 *
 * **A single empty pass is not evidence of an empty queue**, which is the one
 * place this loop must not copy the webhook drain. `claimNextOps` applies its
 * `limit` BEFORE the `pg_try_advisory_xact_lock` filter, so a pass whose
 * candidate tasks are all held by another instance claims zero rows while a
 * backlog exists — and stopping there means a second instance silently truncates
 * the first's work every time the two overlap.
 *
 * More than one empty pass, separated by `IDLE_RECHECK_MS`, is evidence: the
 * lock is transaction-scoped and the claim commits before any provider call, so
 * a contending claim is gone within milliseconds and leaves the ops it took
 * leased into the future, where they are correctly not ours. Two is enough
 * because being wrong costs one tick's delay and never a lost op.
 */
export const IDLE_PASSES_BEFORE_STOP = 2;

/**
 * Pause between two passes that claimed nothing.
 *
 * Without it the second pass is the same observation as the first — the point
 * is to let a contending claim transaction commit, and that is a single indexed
 * UPDATE. Paid at most once per invocation, and only on a queue that already
 * looks empty.
 */
export const IDLE_RECHECK_MS = 500;

/** Re-mint an installation token this far before it expires. An invocation is
 *  far shorter than the hour GitHub grants, so this only matters if the wall
 *  clock above is ever raised. */
const INSTALLATION_TOKEN_MARGIN_MS = 60_000;

/**
 * Why the invocation ended.
 *
 * `idle` is deliberately not called `queue_empty`: what it states is that
 * nothing was claimable for `IDLE_PASSES_BEFORE_STOP` passes, which is a weaker
 * claim than an empty queue and the strongest one the claim query can support.
 */
export type TaskSyncDrainStop = "idle" | "pass_limit" | "time_budget" | "budget_exhausted";

export type TaskSyncDrainReport = {
  startedAt: Date;
  finishedAt: Date;
  passes: number;
  /** Ops the claim queries handed over, summed. */
  claimed: number;

  applied: number;
  noEffect: number;
  superseded: number;
  abortedToMerge: number;
  throttled: number;
  failed: number;
  refused: number;
  skipped: number;

  /** Failures that took an op to `MAX_SYNC_OP_ATTEMPTS`. Nothing claims those
   *  again — a user's edit was abandoned and only a person gets it back. */
  gaveUp: number;
  /** Ops that hit `MAX_CONSECUTIVE_THROTTLES`. By construction these can never
   *  reach the attempt ceiling, so this counter is their only alarm. */
  throttleCapped: number;
  /** Integrations whose credentials could not be resolved. Their ops are failed
   *  individually and counted in `failed`; this counts the installations, not
   *  the ops. */
  tokenErrors: number;
  /** Ops whose execution threw where the executor should have classified.
   *  Always a bug in the layer below, never a provider condition. */
  opErrors: number;

  stoppedBecause: TaskSyncDrainStop;
  /** A bound ended the invocation before the queue went quiet, so ops are
   *  likely still due. Derived from the stop reason rather than re-counted,
   *  which errs towards claiming a backlog that has just cleared and never
   *  towards hiding one that has not. */
  backlogRemains: boolean;
};

export type TaskSyncDrainDeps = {
  db: DB;
  /** Injected so the loop can be exercised without Postgres, and so a test can
   *  make a pass's claim and its duration whatever the case needs. */
  claim: (db: DB, args: { now: Date; limit: number }) => Promise<TaskSyncOpRecord[]>;
  apply: (deps: ApplyOpDeps, op: TaskSyncOpRecord) => Promise<ApplyOpOutcome>;
  /** Credentials for one integration. Called at most once per integration per
   *  invocation — the loop owns that cache, because the failure has to be
   *  memoized too. */
  resolveWriter: (integrationId: string) => Promise<GithubIssueWriter>;
  fail: (db: DB, opId: string, error: string) => Promise<void>;
  defer: (db: DB, opId: string, retryAt: Date) => Promise<void>;
  appSlug: string;
  /** **One budget for the whole invocation.** It is a rolling window over write
   *  timestamps and is process-local by design, so a budget built per pass — or
   *  per op — admits `passes × 500` writes an hour and enforces nothing. */
  budget: GithubBudget;
  now: () => Date;
  sleep: (ms: number) => Promise<void>;
  batchSize?: number;
  maxPasses?: number;
  timeBudgetMs?: number;
  maxConsecutiveThrottles?: number;
  idlePassesBeforeStop?: number;
  idleRecheckMs?: number;
};

/**
 * Claim and execute outbox ops until nothing is claimable, or until a bound
 * says stop.
 *
 * Both bounds are checked before a pass rather than after, so `maxPasses` is
 * the number of passes run and the time budget is never overshot by a whole
 * pass on the way out.
 */
export async function drainTaskSyncOutbox(
  deps: TaskSyncDrainDeps
): Promise<TaskSyncDrainReport> {
  const { db, now } = deps;
  const batchSize = deps.batchSize ?? SYNC_DRAIN_BATCH_SIZE;
  const maxPasses = deps.maxPasses ?? DEFAULT_MAX_PASSES;
  const timeBudgetMs = deps.timeBudgetMs ?? DEFAULT_TIME_BUDGET_MS;
  const maxThrottles = deps.maxConsecutiveThrottles ?? MAX_CONSECUTIVE_THROTTLES;
  const idlePassesBeforeStop = deps.idlePassesBeforeStop ?? IDLE_PASSES_BEFORE_STOP;
  const idleRecheckMs = deps.idleRecheckMs ?? IDLE_RECHECK_MS;
  const startedAt = now();

  const totals = emptyTotals();
  const writers = new Map<string, Promise<GithubIssueWriter>>();
  const credentialErrors = new Map<string, string>();
  /** Consecutive throttles per op, this invocation only. Reset by any other
   *  outcome, because the sequence is what says the wait time is not real. */
  const throttles = new Map<string, number>();
  /** Ops this invocation has given up pacing. The durable push-out below is the
   *  primary guard; this covers the case where that write itself failed. */
  const parked = new Set<string>();

  let passes = 0;
  let idlePasses = 0;
  let claimed = 0;
  let stoppedBecause: TaskSyncDrainStop = "pass_limit";

  function writerFor(integrationId: string): Promise<GithubIssueWriter> {
    const cached = writers.get(integrationId);
    if (cached) return cached;
    // The rejection is memoized alongside the success: a mint that failed once
    // in this invocation fails every op of that integration the same way, and
    // re-minting per op would spend an App-JWT round trip per op to learn it.
    const pending = deps.resolveWriter(integrationId).catch((err: unknown) => {
      credentialErrors.set(integrationId, errorMessage(err));
      throw err;
    });
    writers.set(integrationId, pending);
    return pending;
  }

  loop: for (;;) {
    if (passes >= maxPasses) {
      stoppedBecause = "pass_limit";
      break;
    }
    if (now().getTime() - startedAt.getTime() >= timeBudgetMs) {
      stoppedBecause = "time_budget";
      break;
    }

    const ops = await deps.claim(db, { now: now(), limit: batchSize });
    passes += 1;

    if (ops.length === 0) {
      idlePasses += 1;
      if (idlePasses >= idlePassesBeforeStop) {
        stoppedBecause = "idle";
        break;
      }
      await deps.sleep(idleRecheckMs);
      continue;
    }
    idlePasses = 0;
    claimed += ops.length;

    for (const op of ops) {
      if (parked.has(op.id)) continue;

      let outcome: ApplyOpOutcome;
      try {
        outcome = await deps.apply(
          {
            db,
            writer: lazyWriter(() => writerFor(op.integrationId)),
            appSlug: deps.appSlug,
            budget: deps.budget,
            now,
          },
          op
        );
      } catch (err) {
        // The executor classifies every provider condition itself, so a throw
        // reaching here is a bug rather than a state. Contained per op — one
        // unexpected row must not cost the rest of the pass its work — and
        // counted as a failure so it backs off and eventually retires instead
        // of being re-claimed every tick for ever.
        totals.opErrors += 1;
        await swallow(deps.fail(db, op.id, errorMessage(err)));
        continue;
      }

      count(totals, outcome);

      if (outcome.kind !== "throttled") {
        throttles.delete(op.id);
        continue;
      }

      // A local budget refusal is this process pacing itself, not the provider
      // refusing this op, so it must not count against the op. Nothing later in
      // the pass can pass a budget the first op just failed, and the window it
      // is waiting on outlives this invocation's wall clock, so the invocation
      // ends here rather than claiming ops only to defer them.
      if (outcome.limit === "local") {
        stoppedBecause = "budget_exhausted";
        break loop;
      }

      const consecutive = (throttles.get(op.id) ?? 0) + 1;
      throttles.set(op.id, consecutive);
      if (consecutive >= maxThrottles) {
        parked.add(op.id);
        totals.throttleCapped += 1;
        // Pushed out by the failure backoff's own ceiling, and deliberately
        // through `throttleOp` rather than `failOp`: the op may be perfectly
        // valid and a wait is not an attempt. The durable write is what stops
        // the next invocation repeating these round trips immediately.
        await swallow(
          deps.defer(db, op.id, new Date(now().getTime() + SYNC_OP_BACKOFF_MAX_SECONDS * 1000))
        );
      }
    }
  }

  return {
    startedAt,
    finishedAt: now(),
    passes,
    claimed,
    ...totals,
    tokenErrors: credentialErrors.size,
    stoppedBecause,
    backlogRemains: stoppedBecause !== "idle",
  };
}

/**
 * Does this report need a person?
 *
 * The exit-code contract, kept beside the report it reads so the script and its
 * test agree on one predicate. Three terminal conditions, and nothing else:
 *
 * - `gaveUp` — the attempt ceiling abandoned a user's edit; nothing claims it
 *   again. The inbound drain's signal, for the same reason.
 * - `refused` — the provider rejected the write permanently on the first
 *   response. The same abandonment, reached faster.
 * - `throttleCapped` — an op this loop stopped pacing. It is the ONLY alarm for
 *   the misread-403 path, because a throttle never increments `attempts` and so
 *   can never surface as `gaveUp`.
 *
 * Ordinary failures are excluded on purpose: they stay claimable and the next
 * tick retries them, so alerting on one pages for every transient blip — and a
 * job that pages routinely gets muted, at which point the terminal conditions
 * stop being read too. A total outage still alerts within a few ticks, once the
 * attempts are spent. A bound cutting the run short is a warning, not an alarm.
 */
export function taskSyncDrainNeedsAttention(report: TaskSyncDrainReport): boolean {
  return report.gaveUp > 0 || report.refused > 0 || report.throttleCapped > 0;
}

type Totals = Omit<
  TaskSyncDrainReport,
  | "startedAt"
  | "finishedAt"
  | "passes"
  | "claimed"
  | "tokenErrors"
  | "stoppedBecause"
  | "backlogRemains"
>;

function emptyTotals(): Totals {
  return {
    applied: 0,
    noEffect: 0,
    superseded: 0,
    abortedToMerge: 0,
    throttled: 0,
    failed: 0,
    refused: 0,
    skipped: 0,
    gaveUp: 0,
    throttleCapped: 0,
    opErrors: 0,
  };
}

function count(totals: Totals, outcome: ApplyOpOutcome): void {
  switch (outcome.kind) {
    case "applied":
      totals.applied += 1;
      return;
    case "no_effect":
      totals.noEffect += 1;
      return;
    case "superseded":
      totals.superseded += 1;
      return;
    case "aborted_to_merge":
      totals.abortedToMerge += 1;
      return;
    case "throttled":
      totals.throttled += 1;
      return;
    case "failed":
      totals.failed += 1;
      if (outcome.gaveUp) totals.gaveUp += 1;
      return;
    case "refused":
      totals.refused += 1;
      return;
    case "skipped":
      totals.skipped += 1;
      return;
    default: {
      // A new outcome kind is a compile error here rather than a silently
      // uncounted one, which is the whole reason the union is closed.
      const exhaustive: never = outcome;
      return exhaustive;
    }
  }
}

/**
 * A writer that resolves its credentials on first use.
 *
 * Lazy rather than resolved before the executor runs, because most reasons an
 * op ends never touch the provider: `applyOp` cancels an op whose installation
 * was revoked, whose repository lost push consent, or whose task was deleted,
 * all before a request exists. Minting first would spend a token on those and,
 * worse, turn a revoked installation's clean cancellation into five failed
 * attempts against credentials that no longer exist.
 *
 * A mint that fails therefore arrives as this op's provider error, which the
 * executor already knows how to record — the failure stays inside the op that
 * needed it instead of taking the pass down.
 */
function lazyWriter(load: () => Promise<GithubIssueWriter>): GithubIssueWriter {
  return {
    getIssue: async (ref) => (await load()).getIssue(ref),
    patchIssue: async (ref, patch) => (await load()).patchIssue(ref, patch),
    createIssue: async (ref, input) => (await load()).createIssue(ref, input),
    listAppIssuesSince: async (ref, args) => (await load()).listAppIssuesSince(ref, args),
  };
}

/** The bookkeeping write is best-effort: it runs after the outcome it records
 *  is already decided, and losing the whole pass to it would cost more than the
 *  record does. */
async function swallow(work: Promise<unknown>): Promise<void> {
  try {
    await work;
  } catch {
    // Intentionally empty.
  }
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** The production dependencies: the real claim, the real executor, and one
 *  installation token per integration. */
export function taskSyncDrainDeps(
  db: DB,
  opts: { config: GithubAppConfig; fetch?: FetchLike }
): TaskSyncDrainDeps {
  const client = createGithubAppClient({ config: opts.config, fetch: opts.fetch });
  return {
    db,
    claim: claimNextOps,
    apply: applyOp,
    resolveWriter: (integrationId) => installationWriter(db, client, integrationId, opts.fetch),
    fail: async (handle, opId, error) => {
      await handle.$transaction((tx) => failOp(tx, opId, error));
    },
    defer: (handle, opId, retryAt) => handle.$transaction((tx) => throttleOp(tx, opId, retryAt)),
    appSlug: opts.config.slug,
    budget: createWriteBudget(),
    now: () => new Date(),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  };
}

/**
 * One integration's writer, signed with an installation token.
 *
 * `revokedAt` is deliberately not checked here. A revoked installation's ops
 * have a clean terminal state — `applyOp` cancels them — and refusing at the
 * credential seam would convert that into five failed attempts and a `given_up`
 * row, which reads as a write we lost rather than one we retired.
 */
async function installationWriter(
  db: DB,
  client: GithubAppClient,
  integrationId: string,
  fetchImpl?: FetchLike
): Promise<GithubIssueWriter> {
  const row = await db.integration.findUnique({
    where: { id: integrationId },
    select: { provider: true, installationId: true },
  });
  if (!row) throw new Error(`integration ${integrationId} no longer exists`);
  if (row.provider !== GITHUB_PROVIDER) {
    throw new Error(`integration ${integrationId} is not a GitHub installation`);
  }
  const installationId = row.installationId;
  if (!installationId) {
    throw new Error(`integration ${integrationId} carries no installation id`);
  }

  let minted: GithubInstallationToken | null = null;
  return createGithubIssueWriter({
    token: async () => {
      if (
        minted === null ||
        minted.expiresAt.getTime() - Date.now() <= INSTALLATION_TOKEN_MARGIN_MS
      ) {
        minted = await client.createInstallationToken(installationId);
      }
      return minted.token;
    },
    fetch: fetchImpl,
  });
}
