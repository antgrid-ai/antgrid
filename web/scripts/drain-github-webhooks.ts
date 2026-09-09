// web/scripts/drain-github-webhooks.ts
//
// Applies the GitHub deliveries the webhook route recorded and answered 202 to,
// invoked from OUTSIDE the process — a systemd timer, a platform cron, a
// scheduled container. Run it every minute or two; the loop clears whatever
// accumulated between ticks.
//
// Deliberately not an in-process `setInterval` in src/index.ts, for reasons that
// are NOT the reconcile-seats script's. Concurrent drainers are safe here by
// construction: every row is claimed under a transaction-scoped advisory lock,
// so N instances racing is correct, merely wasteful. What an in-process timer
// costs instead is the endpoint and the alert:
//
//   - The same process has to verify and record deliveries inside GitHub's
//     delivery timeout. Draining a weekend's backlog beside that puts a long
//     database-bound job on the event loop answering the requests that fill the
//     backlog, so the service gets slowest exactly when it is furthest behind.
//   - A timer callback that throws logs and leaves the interval armed. Nothing
//     exits non-zero, so nothing pages. A scheduled process has an exit code,
//     which is the only alerting channel this service has.
//
// Exits 1 when a delivery GAVE UP — exhausted `MAX_WEBHOOK_ATTEMPTS`, so nothing
// claims it again and only a person gets it back — or when retention itself
// failed. Not on an ordinary failure: those stay claimable and the next tick
// retries them, so alerting on one would page for every transient blip, and a
// job that pages routinely gets muted, at which point the real failures stop
// being read too. A run that fails everything still alerts within a few ticks,
// once the attempts are spent. A bound cutting the run short is a warning, not
// an exit code — the next tick picks the backlog up.

import { loadEnv } from "../src/env.js";
import { createDb } from "../src/db/index.js";
import { drainGithubBacklog, githubDrainLoopDeps } from "../src/integrations/github-drain-loop.js";

const env = loadEnv();
const db = createDb(env.PG_DATABASE_URL);

try {
  const report = await drainGithubBacklog(githubDrainLoopDeps(db));

  // Whole report, not a summary: a delivery is applied once and the row is then
  // deleted by retention, so this is the only record that the issues, comments
  // and installation changes of this window were ever acted on.
  console.log(JSON.stringify(report, null, 2));
  console.log(
    `[drain-github-webhooks] passes ${report.passes}, scanned ${report.scanned}, ` +
      `processed ${report.processed} (applied ${report.applied}, dropped ${report.dropped}, ` +
      `invalid ${report.invalid}), skipped ${report.skipped}, failed ${report.failed}, ` +
      `gave up ${report.gaveUp}, purged ${report.purgedProcessed}, stopped: ${report.stoppedBecause}`
  );

  if (report.backlogRemains) {
    console.warn(
      `[drain-github-webhooks] stopped at the ${report.stoppedBecause} bound with deliveries ` +
        `still queued — the next run continues from here`
    );
  }
  if (report.purgeError) {
    console.error(`[drain-github-webhooks] retention failed: ${report.purgeError}`);
  }

  if (report.gaveUp > 0 || report.purgeError) process.exitCode = 1;
} finally {
  await db.$disconnect();
}
