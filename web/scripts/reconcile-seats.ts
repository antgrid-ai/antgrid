// web/scripts/reconcile-seats.ts
//
// Daily seat reconciliation, invoked from OUTSIDE the process — a systemd timer,
// a platform cron, a scheduled container. Run it once a day.
//
// Deliberately not an in-process `setInterval` in src/index.ts. Web runs as N
// instances behind a load balancer, so an in-process timer is N sweeps a day per
// deployment, all firing at once and all fetching the same subscriptions from
// the same gateways. The advisory lock keeps the writes correct, but the reads
// are N times the rate limit at Paddle and Razorpay for no benefit, and the
// obvious fix for that ("elect a leader") is a distributed-systems problem this
// does not have while the scheduler lives outside. A second copy racing this one
// is still safe — it is the same idempotent comparison — it is just wasted.
//
// Exits 1 when any account FAILED, so a cron alerts. NOT when drift was found
// and corrected: that is the tool doing its job, and a job that alerts on
// success gets muted, at which point the failures stop being read too.

import { loadEnv } from "../src/env.js";
import { createDb } from "../src/db/index.js";
import { providerSeatReader, reconcileSeats } from "../src/billing/reconcile-seats.js";

const env = loadEnv();
const db = createDb(env.PG_DATABASE_URL);

try {
  const report = await reconcileSeats({
    db,
    readQuantity: providerSeatReader(env),
    now: () => new Date(),
  });

  // Whole report, not a summary: the drifted rows are an audit trail of money
  // that was being billed wrong, and the operator reading this is the only
  // reader they get.
  console.log(JSON.stringify(report, null, 2));
  console.log(
    `[reconcile-seats] checked ${report.checked}, corrected ${report.drifted.length}, ` +
      `over-subscribed ${report.overSubscribed.length}, skipped ${report.skipped.length}, ` +
      `failed ${report.failed.length}`
  );

  if (report.failed.length > 0) process.exitCode = 1;
} finally {
  await db.$disconnect();
}
