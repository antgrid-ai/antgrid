// web/src/integrations/github-poll.ts
//
// The reconcile poll: `GET /repos/:owner/:repo/issues?since=` walked per
// repository, importing what it finds through the webhook drain's own
// `importIssue`.
//
// It exists because the webhook alone can only ever deliver the future. A
// repository switched on today generates no delivery for the thousand issues
// already in it, so its first import would otherwise be whatever somebody
// happens to touch afterwards; and a delivery dropped while this service was
// down, or one that spent `MAX_WEBHOOK_ATTEMPTS`, is never re-sent by GitHub and
// is lost for ever. Both are the same walk from a different starting point —
// null for "we have never read this repository", the stored cursor for "read it
// again from here" — which is why there is one implementation and not two.
//
// Nothing here decides what an issue MEANS. Routing, the idempotency lookup, the
// import filter, the tombstone filter and the three-way merge all belong to
// `github-inbound.ts` and this file reopens none of them.

import type { DB, Tx } from "../db/index.js";
import { resolveInstallation, IntegrationStatusSchema } from "../models/integration.js";
import { GITHUB_MAX_PAGES, GITHUB_PER_PAGE, GithubApiError } from "./github-app.js";
import { GITHUB_PROVIDER, isPullRequestIssue, type GithubIssue } from "./github-events.js";
import { githubRepoFromKey, githubRepoFullName, parseGithubTimestamp } from "./github-import.js";
import {
  IMPORT_REPO_SELECT,
  importIssue,
  type ImportIssueOutcome,
  type ImportRoute,
} from "./github-inbound.js";
import type { GithubIssueLister } from "./github-issues.js";
import {
  GITHUB_READ_POINTS,
  pushOutcome,
  type GithubBudget,
} from "./github-push-policy.js";

/**
 * How far back of the stored cursor a resume starts.
 *
 * `since` has one-second resolution and is evaluated against GitHub's clock, not
 * ours, so a cursor sent bare drops any issue whose edit shares its second or
 * lands inside the skew. The trade is asymmetric and that is the whole argument:
 * re-listing an issue that has not moved costs one page slot and writes nothing —
 * the merge sees `remote == base` — while missing one is silent, permanent, and
 * only ever noticed by the user whose issue never appeared.
 */
export const POLL_OVERLAP_SECONDS = 60;

/**
 * Pages one repository may walk per invocation.
 *
 * `GITHUB_MAX_PAGES` because it is already this service's ceiling on any
 * provider-driven pagination, and nothing about a reconcile earns a second
 * number. Unlike the paginated reads in `github-app.ts`, hitting it here is
 * ordinary rather than an error: ascending order means the cursor recorded so
 * far is a valid prefix, so the next invocation continues instead of restarting.
 */
export const DEFAULT_POLL_MAX_PAGES = GITHUB_MAX_PAGES;

/**
 * Repositories one invocation may claim.
 *
 * A ceiling on work, not a fairness scheme: `dueRepos` orders never-synced
 * repositories first, so an account that just connected fifty repositories gets
 * its first imports before anything is re-reconciled, and the tick after this
 * one takes the rest.
 */
export const DEFAULT_POLL_MAX_REPOS = 25;

/**
 * Wall clock one invocation may spend.
 *
 * The page and repository bounds do not bound duration — every page is a
 * provider round trip and every issue on it is a transaction — and a scheduled
 * job that never exits is one nobody notices is stuck: no exit code, no report,
 * and every later tick piling up behind it.
 */
export const DEFAULT_POLL_TIME_BUDGET_MS = 60_000;

/** `hashtext` returns int4 into one global advisory-lock namespace shared with
 *  `ghhook:`, `taskimport:`, `task:` and `tasksync:`, so the prefix is the only
 *  thing keeping a repository claim from colliding with a delivery or a task. */
function lockKey(repoId: string): string {
  return `ghpoll:${repoId}`;
}

/** Why one repository's walk ended. Only `caught_up` proves the repository is
 *  fully read — it is the one ending that saw a short page. */
export type GithubPollRepoStop =
  /** A short page: GitHub has nothing newer, so `lastFullSyncAt` is earned. */
  | "caught_up"
  | "page_limit"
  | "time_budget"
  /** GitHub refused on rate. Ends the whole invocation, not just this walk. */
  | "rate_limited"
  /** Our own read budget refused. Also ends the invocation. */
  | "budget_exhausted"
  /** Another runner held the claim lock. */
  | "locked"
  /** The row stopped qualifying between the due query and the claim — sync
   *  turned off, the repository removed, the installation revoked. */
  | "stale"
  /** The `repoKey` does not fold to an addressable `owner/name`. Counted, never
   *  thrown: one unaddressable row must not stop the other repositories. */
  | "unroutable"
  /** A permanent provider refusal — the installation lost access to the
   *  repository. Nothing here retries it and nothing else will notice. */
  | "refused"
  | "error";

/** Why the invocation ended. `complete` means every claimed repository was
 *  walked to one of its own endings, which is weaker than "everything is caught
 *  up" and the strongest claim the due query can support. */
export type GithubPollStop =
  | "complete"
  | "repo_limit"
  | "time_budget"
  | "rate_limited"
  | "budget_exhausted";

/** Import refusals, keyed by `DropReason` plus this file's own `pull_request`
 *  and `unroutable`. A map rather than a column per reason because the reasons
 *  are `github-inbound.ts`'s vocabulary and this file must not fork it. */
export type PollDropReasons = Record<string, number>;

export type GithubPollRepoReport = {
  repoId: string;
  repoKey: string | null;
  /** Pages fetched. Zero when the claim never succeeded. */
  pages: number;
  /** Listing items the walk saw, pull requests included. */
  seen: number;
  imported: number;
  merged: number;
  dropped: number;
  /** Issues `importIssue` refused as malformed — a create our own validation
   *  rejected, which no retry fixes. */
  invalid: number;
  reasons: PollDropReasons;
  /** The walk reached a short page, so the repository is fully read. */
  completed: boolean;
  stoppedBecause: GithubPollRepoStop;
  /** Set only for `refused` and `error`; never a response body — see
   *  `GithubApiError`, which carries a status and an endpoint and nothing else. */
  error: string | null;
  /** The cursor as this walk left it, so a log line explains where the next one
   *  resumes without a second query. */
  cursor: string | null;
};

export type GithubPollReport = {
  startedAt: Date;
  finishedAt: Date;
  /** Repositories the due query returned — the ceiling on work this pass. */
  scanned: number;
  /** Repositories another runner held the claim lock for. */
  skipped: number;
  walked: number;
  /** Walks that ended on a short page. */
  completed: number;
  seen: number;
  imported: number;
  merged: number;
  dropped: number;
  invalid: number;
  /** Walks that ended on `refused` or `error`. Counts repositories, not issues. */
  failed: number;
  reasons: PollDropReasons;
  repos: GithubPollRepoReport[];
  stoppedBecause: GithubPollStop;
  /** A bound ended the invocation, or some repository is not caught up, so
   *  there is more to read. Derived rather than re-counted, which errs towards
   *  claiming a backlog that has just cleared and never towards hiding one. */
  backlogRemains: boolean;
};

export type GithubPollDeps = {
  /** Credentials for one integration, as a reader. Called at most once per
   *  integration per invocation — `pollDueRepos` owns that cache, because the
   *  failure has to be memoized alongside the success. */
  resolveLister: (integrationId: string) => Promise<GithubIssueLister>;
  /**
   * **One budget for the whole invocation.** It is a rolling window and is
   * process-local, so a budget built per repository — or per page — admits
   * `repos × limit` reads a minute and enforces nothing.
   *
   * The read side spends `GITHUB_READ_POINTS`, never the write budget: this
   * path creates no content, and charging it against the 500-writes-an-hour
   * ceiling would starve the outbox of the budget a user's edit needs.
   */
  budget: GithubBudget;
  now: () => Date;
  maxPages?: number;
  maxRepos?: number;
  timeBudgetMs?: number;
  overlapSeconds?: number;
};

/** A repository the due query picked. Only the id travels: everything the walk
 *  needs is re-read under the claim lock, where it is still true. */
type DueRepo = { id: string };

/**
 * Which repositories are due, never-synced first.
 *
 * `syncEnabled` is consent and `removedAt` is reachability, and both are
 * re-checked under the claim lock — this ordering exists to pick work, not to
 * authorize it. A first import is a user watching an empty list; a reconcile is
 * a background repair, and making the second wait for the first is the only
 * fairness decision this file makes.
 */
export async function dueRepos(db: Tx, limit: number): Promise<DueRepo[]> {
  return db.integrationRepo.findMany({
    where: {
      syncEnabled: true,
      removedAt: null,
      integration: {
        provider: GITHUB_PROVIDER,
        status: IntegrationStatusSchema.enum.active,
        revokedAt: null,
      },
    },
    orderBy: [{ lastFullSyncAt: { sort: "asc", nulls: "first" } }, { createdAt: "asc" }],
    take: limit,
    select: { id: true },
  });
}

/**
 * Claim and walk every due repository, or until a bound says stop.
 *
 * The bounds are checked before a repository rather than after, so the time
 * budget is never overshot by a whole walk on the way out.
 */
export async function pollDueRepos(
  db: DB,
  deps: GithubPollDeps,
  opts: { maxRepos?: number } = {}
): Promise<GithubPollReport> {
  const { now } = deps;
  const startedAt = now();
  const maxRepos = opts.maxRepos ?? deps.maxRepos ?? DEFAULT_POLL_MAX_REPOS;
  const timeBudgetMs = deps.timeBudgetMs ?? DEFAULT_POLL_TIME_BUDGET_MS;
  const deadline = new Date(startedAt.getTime() + timeBudgetMs);

  const due = await dueRepos(db, maxRepos);

  // The rejection is memoized alongside the success: a mint that failed once in
  // this invocation fails every repository of that integration the same way, and
  // re-minting per repository would spend an App-JWT round trip to learn it.
  const listers = new Map<string, Promise<GithubIssueLister>>();
  const cachedLister = (integrationId: string): Promise<GithubIssueLister> => {
    const cached = listers.get(integrationId);
    if (cached) return cached;
    const pending = deps.resolveLister(integrationId);
    listers.set(integrationId, pending);
    return pending;
  };

  const shared: GithubPollDeps = { ...deps, resolveLister: cachedLister };
  const repos: GithubPollRepoReport[] = [];
  let stoppedBecause: GithubPollStop = due.length < maxRepos ? "complete" : "repo_limit";

  for (const row of due) {
    if (now().getTime() >= deadline.getTime()) {
      stoppedBecause = "time_budget";
      break;
    }
    // One repository's throw is its own ending, never the invocation's. A
    // connection blip or a serialization failure inside a single walk would
    // otherwise abandon every repository behind it in the due order, which is
    // the same starvation `unroutable` is counted rather than thrown to avoid.
    let report: GithubPollRepoReport;
    try {
      report = await pollRepo(db, shared, { repoId: row.id, deadline });
    } catch (err) {
      report = { ...emptyRepoReport(row.id), stoppedBecause: "error", error: errorMessage(err) };
    }
    repos.push(report);

    // A rate refusal is the provider telling this process to stop reading, and
    // the local budget is this process telling itself the same thing. Neither is
    // about the repository that hit it, so the invocation ends rather than
    // walking the rest into the same wall.
    if (report.stoppedBecause === "rate_limited") {
      stoppedBecause = "rate_limited";
      break;
    }
    if (report.stoppedBecause === "budget_exhausted") {
      stoppedBecause = "budget_exhausted";
      break;
    }
  }

  return {
    ...totals(repos, startedAt, now(), due.length),
    stoppedBecause,
    repos,
    ...backlog(due.length, repos, stoppedBecause),
  };
}

/**
 * One repository: claim it, then walk it.
 *
 * **The claim lock is taken in a transaction of its own and released before the
 * first HTTP call.** Holding a transaction across a provider round trip is how a
 * pool is exhausted by a hanging remote, and `pg_try_advisory_xact_lock` cannot
 * outlive its transaction anyway. So this collapses two runners that reach the
 * same repository at the same instant — the case a scheduler overlap actually
 * produces — and nothing more; the durable guard against one issue becoming two
 * tasks is `importIssue`'s own `taskimport:` lock and the
 * `[accountId, externalProvider, externalId]` unique behind it, which hold
 * whatever the claim did.
 *
 * `ghpoll:` is the outermost prefix in the fixed lock order
 * (`ghpoll:` → `ghhook:` → `taskimport:` → `task:` → `tasksync:`), and here it
 * is not merely outermost but disjoint: the claim commits before any import
 * transaction opens, so nothing ever holds it alongside another.
 */
export async function pollRepo(
  db: DB,
  deps: GithubPollDeps,
  opts: { repoId: string; deadline?: Date }
): Promise<GithubPollRepoReport> {
  const { now } = deps;
  const empty = emptyRepoReport(opts.repoId);

  const claim = await db.$transaction((tx) => claimRepo(tx, opts.repoId));
  if (claim.kind !== "ok") {
    return { ...empty, stoppedBecause: claim.kind, repoKey: claim.repoKey ?? null };
  }

  const deadline =
    opts.deadline ?? new Date(now().getTime() + (deps.timeBudgetMs ?? DEFAULT_POLL_TIME_BUDGET_MS));
  return walkRepo(db, deps, { ...claim, deadline });
}

type Claim = {
  kind: "ok";
  repoId: string;
  repoKey: string;
  route: ImportRoute;
  target: { owner: string; repo: string };
  cursor: Date | null;
};

type ClaimOutcome = Claim | { kind: "locked" | "stale" | "unroutable"; repoKey: string | null };

async function claimRepo(tx: Tx, repoId: string): Promise<ClaimOutcome> {
  const [lock] = await tx.$queryRaw<{ locked: boolean }[]>`
    SELECT pg_try_advisory_xact_lock(hashtext(${lockKey(repoId)})) AS locked`;
  // A **try** lock, never a blocking one: a second runner that queued here would
  // wake up and re-walk a repository the first has just read, which is a page of
  // provider budget spent to learn nothing. Moving on is the whole point.
  if (lock?.locked !== true) return { kind: "locked", repoKey: null };

  // Re-read under the lock, never before it: the row the due query saw may have
  // had sync turned off, or its installation uninstalled, in between.
  const repo = await tx.integrationRepo.findUnique({
    where: { id: repoId },
    select: {
      ...IMPORT_REPO_SELECT,
      repoKey: true,
      removedAt: true,
      lastCursor: true,
      integration: { select: { installationId: true } },
    },
  });
  if (!repo) return { kind: "stale", repoKey: null };
  if (!repo.syncEnabled || repo.removedAt !== null) return { kind: "stale", repoKey: repo.repoKey };

  // Re-resolved through `resolveInstallation` rather than joined, because that
  // is where the `revokedAt` filter lives — an installation uninstalled since
  // the due query must not have its issues read, let alone imported.
  const installationId = repo.integration.installationId;
  const integration = installationId
    ? await resolveInstallation(tx, GITHUB_PROVIDER, installationId)
    : null;
  if (!integration || integration.status !== IntegrationStatusSchema.enum.active) {
    return { kind: "stale", repoKey: repo.repoKey };
  }

  const target = githubRepoFromKey(repo.repoKey);
  const repositoryFullName = githubRepoFullName(repo.repoKey);
  if (target === null || repositoryFullName === null) {
    return { kind: "unroutable", repoKey: repo.repoKey };
  }

  return {
    kind: "ok",
    repoId,
    repoKey: repo.repoKey,
    route: { integration, repo, repositoryFullName },
    target,
    cursor: parseGithubTimestamp(repo.lastCursor),
  };
}

async function walkRepo(
  db: DB,
  deps: GithubPollDeps,
  claim: Claim & { deadline: Date }
): Promise<GithubPollRepoReport> {
  const { now } = deps;
  const maxPages = deps.maxPages ?? DEFAULT_POLL_MAX_PAGES;
  const overlapMs = (deps.overlapSeconds ?? POLL_OVERLAP_SECONDS) * 1000;
  const report: GithubPollRepoReport = {
    ...emptyRepoReport(claim.repoId),
    repoKey: claim.repoKey,
    cursor: claim.cursor === null ? null : claim.cursor.toISOString(),
  };

  const since = claim.cursor === null ? null : new Date(claim.cursor.getTime() - overlapMs);

  let lister: GithubIssueLister;
  try {
    lister = await deps.resolveLister(claim.route.integration.id);
  } catch (err) {
    report.stoppedBecause = "error";
    report.error = errorMessage(err);
    return report;
  }

  // The cursor stops advancing at the first item whose `updated_at` we cannot
  // read, and never resumes within the walk. Advancing past such an item would
  // skip it for ever on the next run; not advancing costs a re-list the overlap
  // already pays for.
  let cursorBlocked = false;
  let cursor = claim.cursor;
  const advanceCursor = (issue: GithubIssue): void => {
    if (cursorBlocked) return;
    const at = parseGithubTimestamp(issue.updated_at);
    if (at === null) cursorBlocked = true;
    else cursor = at;
  };

  for (let page = 1; page <= maxPages; page++) {
    if (now().getTime() >= claim.deadline.getTime()) {
      report.stoppedBecause = "time_budget";
      return report;
    }
    const spend = deps.budget.take(now(), GITHUB_READ_POINTS);
    if (!spend.ok) {
      report.stoppedBecause = "budget_exhausted";
      return report;
    }

    let items: GithubIssue[];
    try {
      items = await lister.listRepoIssuesSince(claim.target, { since, page });
    } catch (err) {
      const classified = classifyReadFailure(err, now());
      report.stoppedBecause = classified.stop;
      report.error = classified.error;
      return report;
    }
    report.pages += 1;
    report.seen += items.length;

    for (const issue of items) {
      // The listing carries pull requests exactly as the webhook does, and the
      // only discriminator is the key's presence. Unfiltered, a first import
      // turns the whole PR queue into tasks.
      if (isPullRequestIssue(issue)) {
        count(report, "pull_request");
        advanceCursor(issue);
        continue;
      }

      // A transaction per issue, opened after the page is already in hand: one
      // held across the fetch would hold a connection for the provider's latency,
      // and one spanning the page would make a single malformed issue roll back
      // every import before it.
      // A throw here is the database refusing, not the issue being wrong, so it
      // ends this repository's walk without advancing the cursor over the item
      // that raised it — the next run re-lists from where this one last
      // committed, and every import is idempotent whatever this did.
      let outcome: ImportIssueOutcome;
      try {
        outcome = await db.$transaction((tx) => importIssue(tx, claim.route, issue));
      } catch (err) {
        report.stoppedBecause = "error";
        report.error = errorMessage(err);
        return report;
      }
      if (outcome.kind === "ok") {
        if (outcome.created) report.imported += 1;
        else report.merged += 1;
      } else if (outcome.kind === "dropped") {
        count(report, outcome.reason);
      } else {
        report.invalid += 1;
      }

      advanceCursor(issue);
    }

    // Never backwards. The overlap makes a run re-list issues the previous run
    // already passed, so a page can legitimately end earlier than the stored
    // cursor — writing that would re-walk the same ground on every tick.
    const advanced = cursor !== null && (claim.cursor === null || cursor > claim.cursor);
    const complete = items.length < GITHUB_PER_PAGE;
    if (advanced || complete) {
      await db.integrationRepo.update({
        where: { id: claim.repoId },
        data: {
          ...(advanced && cursor !== null ? { lastCursor: cursor.toISOString() } : {}),
          // Only a short page proves the repository is fully read. Every other
          // ending is a prefix, and a `lastFullSyncAt` written there would claim
          // a completeness the walk never established.
          ...(complete ? { lastFullSyncAt: now() } : {}),
        },
      });
      if (advanced && cursor !== null) report.cursor = cursor.toISOString();
    }

    if (complete) {
      report.completed = true;
      report.stoppedBecause = "caught_up";
      return report;
    }
  }

  report.stoppedBecause = "page_limit";
  return report;
}

/**
 * A failed read, as one of this file's endings.
 *
 * `pushOutcome` is reused rather than re-derived because it is the only place
 * that tells a rate 403 from a permission 403, and it does so from which rate
 * headers are present and from nothing else. Read wrong in either direction the
 * poll either hammers a limit it is already inside, or retires a repository that
 * was merely busy.
 */
function classifyReadFailure(
  err: unknown,
  now: Date
): { stop: GithubPollRepoStop; error: string } {
  const error = errorMessage(err);
  if (!(err instanceof GithubApiError)) return { stop: "error", error };
  if (err.status === 0) return { stop: "error", error };

  const outcome = pushOutcome({ status: err.status, headers: err.headers }, now);
  if (outcome.kind === "throttled") return { stop: "rate_limited", error };
  if (outcome.kind === "refused") return { stop: "refused", error };
  return { stop: "error", error };
}

function count(report: GithubPollRepoReport, reason: string): void {
  report.dropped += 1;
  report.reasons[reason] = (report.reasons[reason] ?? 0) + 1;
}

function emptyRepoReport(repoId: string): GithubPollRepoReport {
  return {
    repoId,
    repoKey: null,
    pages: 0,
    seen: 0,
    imported: 0,
    merged: 0,
    dropped: 0,
    invalid: 0,
    reasons: {},
    completed: false,
    stoppedBecause: "error",
    error: null,
    cursor: null,
  };
}

function totals(
  repos: readonly GithubPollRepoReport[],
  startedAt: Date,
  finishedAt: Date,
  scanned: number
): Omit<GithubPollReport, "stoppedBecause" | "repos" | "backlogRemains"> {
  const reasons: PollDropReasons = {};
  const sum = { seen: 0, imported: 0, merged: 0, dropped: 0, invalid: 0 };
  let skipped = 0;
  let completed = 0;
  let failed = 0;
  for (const repo of repos) {
    sum.seen += repo.seen;
    sum.imported += repo.imported;
    sum.merged += repo.merged;
    sum.dropped += repo.dropped;
    sum.invalid += repo.invalid;
    if (repo.stoppedBecause === "locked") skipped += 1;
    if (repo.completed) completed += 1;
    if (repo.stoppedBecause === "refused" || repo.stoppedBecause === "error") failed += 1;
    for (const [reason, n] of Object.entries(repo.reasons)) {
      reasons[reason] = (reasons[reason] ?? 0) + n;
    }
  }
  return {
    startedAt,
    finishedAt,
    scanned,
    skipped,
    walked: repos.length - skipped,
    completed,
    ...sum,
    failed,
    reasons,
  };
}

function backlog(
  scanned: number,
  repos: readonly GithubPollRepoReport[],
  stoppedBecause: GithubPollStop
): { backlogRemains: boolean } {
  // Anything that did not end on a short page is still behind — a page ceiling,
  // a lock another runner held, a refusal, a walk cut off mid-repository. Derived
  // from the endings rather than re-counted against GitHub, which errs towards
  // claiming a backlog that has just cleared and never towards hiding one.
  return {
    backlogRemains:
      stoppedBecause !== "complete" ||
      repos.length < scanned ||
      repos.some((repo) => !repo.completed),
  };
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
