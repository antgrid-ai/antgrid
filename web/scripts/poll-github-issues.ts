// web/scripts/poll-github-issues.ts
//
// Reads GitHub issues that no webhook ever delivered, invoked from OUTSIDE the
// process — a systemd timer, a platform cron, a scheduled container.
//
// Two jobs, one walk. A repository the user has just switched on has a backlog
// GitHub will never send a delivery for, because a webhook only ever describes
// the future; and a delivery lost to an outage, or one that spent
// `MAX_WEBHOOK_ATTEMPTS`, is gone for good unless something re-reads the source.
// Run it every few minutes: the first import is a user watching an empty list,
// the reconcile behind it is a background repair.
//
// Not an in-process `setInterval` in src/index.ts, for the same two reasons the
// two drains are not: a long provider-bound job on the event loop that also
// answers GitHub inside its delivery timeout makes the service slowest exactly
// when it is furthest behind, and a timer callback that throws leaves the
// interval armed with nothing exiting non-zero, so nothing pages. A scheduled
// process has an exit code, which is the only alerting channel this service has.
//
// Concurrent invocations are safe: each repository is claimed under a
// transaction-scoped try-lock, so a second instance moves on rather than
// re-walking, and the import behind it is idempotent on
// `[accountId, externalProvider, externalId]` whatever the claim did.
//
// Exits 1 on `githubPollNeedsAttention` — see the contract written out beside
// it. A bound cutting the run short is a warning, not an exit code: the cursor
// this run left is where the next one resumes.

import { loadEnv } from "../src/env.js";
import { createDb } from "../src/db/index.js";
import { githubAppConfig } from "../src/integrations/github-app.js";
import { pollDueRepos } from "../src/integrations/github-poll.js";
import {
  githubPollDeps,
  githubPollNeedsAttention,
} from "../src/integrations/github-poll-loop.js";

const env = loadEnv();
const config = githubAppConfig(env);

// Not an alarm. There is nothing to poll until the install flow has run, and
// that flow needs this same config — so a deployment without it has no
// repositories to read, and paging every few minutes for a feature nobody turned
// on is how a job gets muted.
if (config === null) {
  console.warn("[poll-github-issues] no GitHub App configured; nothing to poll");
  process.exit(0);
}

const db = createDb(env.PG_DATABASE_URL);

try {
  const report = await pollDueRepos(db, githubPollDeps(db, { config }));

  // The whole report, not a summary: a repository's cursor and its stop reason
  // are the only record of how far this run read, and the next run's behaviour
  // is unexplainable without them.
  console.log(JSON.stringify(report, null, 2));
  console.log(
    `[poll-github-issues] scanned ${report.scanned}, walked ${report.walked}, ` +
      `skipped ${report.skipped}, caught up ${report.completed}, seen ${report.seen}, ` +
      `imported ${report.imported}, merged ${report.merged}, dropped ${report.dropped}, ` +
      `invalid ${report.invalid}, failed ${report.failed}, stopped: ${report.stoppedBecause}`
  );

  if (report.backlogRemains) {
    console.warn(
      `[poll-github-issues] stopped at the ${report.stoppedBecause} bound with repositories ` +
        `still behind — the next run resumes from the cursors this one left`
    );
  }
  for (const repo of report.repos) {
    if (repo.stoppedBecause === "refused" || repo.stoppedBecause === "unroutable") {
      console.error(
        `[poll-github-issues] ${repo.repoKey ?? repo.repoId} stopped importing ` +
          `(${repo.stoppedBecause})${repo.error === null ? "" : `: ${repo.error}`}`
      );
    }
  }
  if (report.invalid > 0) {
    console.error(`[poll-github-issues] ${report.invalid} issue(s) could not be imported`);
  }

  if (githubPollNeedsAttention(report)) process.exitCode = 1;
} finally {
  await db.$disconnect();
}
