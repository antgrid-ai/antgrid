import { describe, expect, test } from "bun:test";
import type { DB } from "../../src/db/index.js";
import type { GithubDrainReport } from "../../src/integrations/github-inbound.js";
import {
  DEFAULT_MAX_PASSES,
  drainGithubBacklog,
  type GithubDrainLoopReport,
} from "../../src/integrations/github-drain-loop.js";
import { WEBHOOK_EVENT_RETENTION_DAYS } from "../../src/integrations/webhook-events.js";

/** Every dependency the loop touches is injected, so the handle is only ever
 *  passed through to the fakes and never dereferenced. */
const DB_STUB = {} as DB;

const START = new Date("2026-08-18T09:00:00.000Z");

/** One scripted pass. `tookMs` is how far the fake clock moves while it runs,
 *  which is how the wall-clock bound is reached without a real one. */
type Pass = Partial<GithubDrainReport> & { tookMs?: number };

const EMPTY_PASS: GithubDrainReport = {
  scanned: 0,
  applied: 0,
  dropped: 0,
  skipped: 0,
  invalid: 0,
  failed: 0,
  gaveUp: 0,
};

/** A pass that claimed a full batch and applied it — the shape of a backlog
 *  that outlives whatever bound is under test. */
const FULL_PASS: Pass = { scanned: 50, applied: 50, tookMs: 400 };

type Harness = {
  run: (opts?: { maxPasses?: number; timeBudgetMs?: number }) => Promise<GithubDrainLoopReport>;
  drainCalls: () => number;
  purgeCalls: () => { provider: string; before: Date }[];
};

/**
 * A loop over scripted passes. Once the script runs out the drain keeps
 * answering with `tail`, so a test states only the passes it cares about and
 * lets the bound decide where the run ends.
 */
function harness(script: Pass[], opts: { tail?: Pass; purge?: () => Promise<number> } = {}): Harness {
  let elapsedMs = 0;
  let drainCalls = 0;
  const purgeCalls: { provider: string; before: Date }[] = [];
  const now = () => new Date(START.getTime() + elapsedMs);

  const drain = async (): Promise<GithubDrainReport> => {
    const { tookMs = 0, ...pass } = script[drainCalls] ?? opts.tail ?? {};
    drainCalls += 1;
    elapsedMs += tookMs;
    return { ...EMPTY_PASS, ...pass };
  };

  const purge = async (_db: DB, args: { provider: string; before: Date }) => {
    purgeCalls.push(args);
    return opts.purge ? opts.purge() : 0;
  };

  return {
    run: (bounds = {}) => drainGithubBacklog({ db: DB_STUB, drain, purge, now, ...bounds }),
    drainCalls: () => drainCalls,
    purgeCalls: () => purgeCalls,
  };
}

describe("drainGithubBacklog — stopping", () => {
  test("keeps draining until a pass claims nothing", async () => {
    const h = harness([
      { scanned: 50, applied: 48, dropped: 2 },
      { scanned: 12, applied: 10, dropped: 1, skipped: 1 },
    ]);

    const report = await h.run();

    expect(h.drainCalls()).toBe(3);
    expect(report).toMatchObject({
      passes: 3,
      scanned: 62,
      applied: 58,
      dropped: 3,
      skipped: 1,
      processed: 61,
      stoppedBecause: "queue_empty",
      backlogRemains: false,
    });
  });

  test("an empty queue costs exactly one pass", async () => {
    const h = harness([], { tail: EMPTY_PASS });

    const report = await h.run();

    expect(h.drainCalls()).toBe(1);
    expect(report).toMatchObject({ passes: 1, scanned: 0, stoppedBecause: "queue_empty" });
  });

  test("stops at the pass bound and says the backlog outlived the run", async () => {
    const h = harness([], { tail: FULL_PASS });

    const report = await h.run({ maxPasses: 3 });

    expect(h.drainCalls()).toBe(3);
    expect(report).toMatchObject({
      passes: 3,
      applied: 150,
      stoppedBecause: "pass_limit",
      backlogRemains: true,
    });
  });

  // The pass bound cannot bound duration on its own: one pass is a batch of
  // deliveries, and how long a batch takes is the provider-side writes' business.
  test("stops at the time budget and says the backlog outlived the run", async () => {
    const h = harness([], { tail: FULL_PASS });

    const report = await h.run({ maxPasses: DEFAULT_MAX_PASSES, timeBudgetMs: 1000 });

    // Passes start at 0ms, 400ms and 800ms; the fourth check sees 1200ms.
    expect(h.drainCalls()).toBe(3);
    expect(report).toMatchObject({
      passes: 3,
      stoppedBecause: "time_budget",
      backlogRemains: true,
    });
    expect(report.finishedAt.getTime() - report.startedAt.getTime()).toBe(1200);
  });

  test("a queue that empties inside both bounds is not reported as a backlog", async () => {
    const h = harness([FULL_PASS, { scanned: 3, applied: 3, tookMs: 400 }]);

    const report = await h.run({ maxPasses: 5, timeBudgetMs: 5000 });

    expect(report).toMatchObject({ passes: 3, stoppedBecause: "queue_empty", backlogRemains: false });
  });
});

describe("drainGithubBacklog — reporting", () => {
  test("a failed delivery surfaces, and does not count as processed", async () => {
    const h = harness([
      { scanned: 3, applied: 1, invalid: 1, failed: 1 },
      { scanned: 1, failed: 1, gaveUp: 1 },
    ]);

    const report = await h.run();

    expect(report).toMatchObject({
      scanned: 4,
      applied: 1,
      invalid: 1,
      failed: 2,
      gaveUp: 1,
      processed: 2,
      stoppedBecause: "queue_empty",
    });
  });

  // Failures leave the row claimable, so the pass that follows one is ordinary
  // work rather than a reason to stop early.
  test("a pass that applied nothing still continues the loop", async () => {
    const h = harness([{ scanned: 2, failed: 2 }, { scanned: 2, applied: 2 }]);

    const report = await h.run();

    expect(h.drainCalls()).toBe(3);
    expect(report).toMatchObject({ passes: 3, failed: 2, applied: 2 });
  });
});

describe("drainGithubBacklog — retention", () => {
  test("purges github rows once per invocation, at the retention cutoff", async () => {
    const h = harness([FULL_PASS], { purge: async () => 7 });

    const report = await h.run();

    const calls = h.purgeCalls();
    expect(calls).toHaveLength(1);
    expect(calls[0]?.provider).toBe("github");
    // Measured from the clock the run ended on, not the one it started with.
    const cutoffAgeMs = START.getTime() + 400 - (calls[0]?.before.getTime() ?? 0);
    expect(cutoffAgeMs).toBe(WEBHOOK_EVENT_RETENTION_DAYS * 24 * 60 * 60 * 1000);
    expect(report.purgedProcessed).toBe(7);
    expect(report.purgeError).toBeNull();
  });

  // The deliveries are already committed by then; a DELETE that failed must not
  // take the record of that work with it.
  test("a failed purge is reported without costing the drain report", async () => {
    const h = harness([{ scanned: 4, applied: 4 }], {
      purge: async () => {
        throw new Error("deadlock detected");
      },
    });

    const report = await h.run();

    expect(report).toMatchObject({
      applied: 4,
      processed: 4,
      purgedProcessed: 0,
      purgeError: "deadlock detected",
      stoppedBecause: "queue_empty",
    });
  });

  test("retention still runs when a bound cut the drain short", async () => {
    const h = harness([], { tail: FULL_PASS });

    await h.run({ maxPasses: 1 });

    expect(h.purgeCalls()).toHaveLength(1);
  });
});
