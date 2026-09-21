// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

// Local-dev stand-in for the cron that runs the GitHub sync jobs in a deployed
// environment (docs/commands.md). Without something running them, a webhook is
// recorded and a task edit is queued but neither is ever applied, so GitHub and
// the app look unsynced.
//
// A separate process, never a timer inside src/index.ts: the jobs are
// provider-bound and belong off the event loop that must answer GitHub inside
// its delivery timeout, and each child keeps its own exit code.
//
// Usage: bun run dev:sync   (SYNC_LOOP_INTERVAL_MS overrides the 30s tick)

const INTERVAL_MS = Number(process.env.SYNC_LOOP_INTERVAL_MS ?? 30_000);
// The reconcile poll re-lists every enabled repository, so it runs far less
// often than the two drains; webhooks cover the live path between its runs.
const POLL_EVERY_TICKS = 10;

async function run(script: string): Promise<number> {
  const proc = Bun.spawn(["bun", "run", `scripts/${script}`], {
    cwd: `${import.meta.dir}/..`,
    stdout: "ignore",
    stderr: "inherit",
    stdin: "ignore",
    env: process.env,
  });
  return await proc.exited;
}

let tick = 0;
console.log(`[dev-sync] every ${INTERVAL_MS / 1000}s: webhooks, then outbox; poll every ${POLL_EVERY_TICKS} ticks`);

while (true) {
  const jobs = ["drain-github-webhooks.ts", "drain-task-sync.ts"];
  if (tick % POLL_EVERY_TICKS === 0) jobs.push("poll-github-issues.ts");
  tick += 1;

  const failed: string[] = [];
  for (const job of jobs) {
    // Sequential: inbound first so a queued edit is diffed against a task the
    // webhook has already brought up to date.
    const code = await run(job);
    if (code !== 0) failed.push(`${job} (exit ${code})`);
  }
  if (failed.length > 0) console.warn(`[dev-sync] tick ${tick}: ${failed.join(", ")}`);

  await Bun.sleep(INTERVAL_MS);
}
