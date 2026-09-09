// web/scripts/drain-task-sync.ts
//
// Pushes the task edits the outbox queued to GitHub, invoked from OUTSIDE the
// process — a systemd timer, a platform cron, a scheduled container. Run it
// every minute or two; the loop clears whatever the tick before it left.
//
// Not an in-process `setInterval` in src/index.ts, for the same two reasons the
// webhook drain is not: a long provider-bound job on the event loop that also
// answers GitHub inside its delivery timeout makes the service slowest exactly
// when it is furthest behind, and a timer callback that throws leaves the
// interval armed with nothing exiting non-zero, so nothing pages. A scheduled
// process has an exit code, which is the only alerting channel this service has.
//
// Concurrent invocations are safe by construction: every claim is taken under a
// transaction-scoped advisory lock and leases the op it takes, so N instances
// racing is correct rather than merely tolerated.
//
// Exits 1 on `taskSyncDrainNeedsAttention` — see the contract written out
// beside it. A bound cutting the run short is a warning, not an exit code: the
// next tick continues from where this one stopped.

import { loadEnv } from "../src/env.js";
import { createDb } from "../src/db/index.js";
import { githubAppConfig } from "../src/integrations/github-app.js";
import {
  drainTaskSyncOutbox,
  taskSyncDrainDeps,
  taskSyncDrainNeedsAttention,
} from "../src/tasks/sync-drain-loop.js";

const env = loadEnv();
const config = githubAppConfig(env);

// Not an alarm. Ops only exist for an integration, an integration only exists
// once the install flow has run, and the install flow needs this same config —
// so a deployment without it has no outbox to drain, and paging every minute
// for a feature nobody turned on is how a job gets muted.
if (config === null) {
  console.warn("[drain-task-sync] no GitHub App configured; nothing to drain");
  process.exit(0);
}

const db = createDb(env.PG_DATABASE_URL);

try {
  const report = await drainTaskSyncOutbox(taskSyncDrainDeps(db, { config }));

  // The whole report, not a summary: an op is executed once and its row carries
  // only the outcome, so this is the only record that these edits reached — or
  // failed to reach — a public repository in this window.
  console.log(JSON.stringify(report, null, 2));
  console.log(
    `[drain-task-sync] passes ${report.passes}, claimed ${report.claimed}, ` +
      `applied ${report.applied}, no effect ${report.noEffect}, ` +
      `superseded ${report.superseded}, aborted to merge ${report.abortedToMerge}, ` +
      `throttled ${report.throttled}, failed ${report.failed}, refused ${report.refused}, ` +
      `skipped ${report.skipped}, gave up ${report.gaveUp}, throttle-capped ` +
      `${report.throttleCapped}, stopped: ${report.stoppedBecause}`
  );

  if (report.backlogRemains) {
    console.warn(
      `[drain-task-sync] stopped at the ${report.stoppedBecause} bound with ops still ` +
        `queued — the next run continues from here`
    );
  }
  if (report.tokenErrors > 0) {
    console.error(
      `[drain-task-sync] ${report.tokenErrors} installation(s) could not be authenticated; ` +
        `their ops failed and will retry`
    );
  }
  if (report.opErrors > 0) {
    console.error(`[drain-task-sync] ${report.opErrors} op(s) threw outside the executor`);
  }

  if (taskSyncDrainNeedsAttention(report)) process.exitCode = 1;
} finally {
  await db.$disconnect();
}
