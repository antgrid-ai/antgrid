import { describe, expect, test } from "bun:test";
import type { DB } from "../../src/db/index.js";
import type { GithubIssueWriter } from "../../src/integrations/github-issues.js";
import { createWriteBudget } from "../../src/integrations/github-push-policy.js";
import type { ApplyOpDeps, ApplyOpOutcome } from "../../src/tasks/apply-op.js";
import {
  drainTaskSyncOutbox,
  taskSyncDrainNeedsAttention,
  MAX_CONSECUTIVE_THROTTLES,
  SYNC_DRAIN_BATCH_SIZE,
  type TaskSyncDrainDeps,
  type TaskSyncDrainReport,
} from "../../src/tasks/sync-drain-loop.js";
import { SYNC_OP_BACKOFF_MAX_SECONDS, type TaskSyncOpRecord } from "../../src/tasks/sync-op.js";

/** Every dependency the loop touches is injected, so the handle is only ever
 *  passed through to the fakes and never dereferenced. */
const DB_STUB = {} as DB;

const START = new Date("2026-08-18T09:00:00.000Z");

function op(id: string, integrationId = "int-1"): TaskSyncOpRecord {
  return {
    id,
    taskId: `task-${id}`,
    integrationId,
    provider: "github",
    kind: "issue.patch.title",
    payload: { kind: "issue.patch.title", title: id },
    opKey: `key-${id}`,
    seq: 1,
    attempts: 0,
    status: "pending",
    nextAttemptAt: START,
    attemptedAt: null,
  };
}

function applied(record: TaskSyncOpRecord): ApplyOpOutcome {
  return {
    kind: "applied",
    opId: record.id,
    taskId: record.taskId,
    recovered: false,
    pushedHash: "hash",
    cleared: [],
  };
}

function throttled(
  record: TaskSyncOpRecord,
  limit: "primary" | "secondary" | "local"
): ApplyOpOutcome {
  return { kind: "throttled", opId: record.id, taskId: record.taskId, retryAt: START, limit };
}

type Harness = {
  run: (overrides?: Partial<TaskSyncDrainDeps>) => Promise<TaskSyncDrainReport>;
  claims: () => { now: Date; limit: number }[];
  applied: () => string[];
  applyDeps: () => ApplyOpDeps[];
  sleeps: () => number[];
  failed: () => { opId: string; error: string }[];
  deferred: () => { opId: string; retryAt: Date }[];
  writerCalls: () => string[];
};

type Options = {
  /** What each claim pass returns, in order. Once the script runs out the claim
   *  keeps answering with `tail`, so a test states only the passes it cares
   *  about and lets a bound decide where the run ends. */
  passes: TaskSyncOpRecord[][];
  tail?: TaskSyncOpRecord[];
  apply?: (deps: ApplyOpDeps, record: TaskSyncOpRecord) => Promise<ApplyOpOutcome>;
  resolveWriter?: (integrationId: string) => Promise<GithubIssueWriter>;
  /** How far the fake clock moves per applied op, which is how the wall-clock
   *  bound is reached without a real one. */
  tookMs?: number;
};

function harness(opts: Options): Harness {
  let elapsedMs = 0;
  const claims: { now: Date; limit: number }[] = [];
  const appliedIds: string[] = [];
  const applyDeps: ApplyOpDeps[] = [];
  const sleeps: number[] = [];
  const failed: { opId: string; error: string }[] = [];
  const deferred: { opId: string; retryAt: Date }[] = [];
  const writerCalls: string[] = [];
  const now = () => new Date(START.getTime() + elapsedMs);

  const deps: TaskSyncDrainDeps = {
    db: DB_STUB,
    claim: async (_db, args) => {
      claims.push(args);
      return opts.passes[claims.length - 1] ?? opts.tail ?? [];
    },
    apply: async (applyArgs, record) => {
      applyDeps.push(applyArgs);
      appliedIds.push(record.id);
      elapsedMs += opts.tookMs ?? 0;
      return opts.apply ? opts.apply(applyArgs, record) : applied(record);
    },
    resolveWriter: async (integrationId) => {
      writerCalls.push(integrationId);
      if (opts.resolveWriter) return opts.resolveWriter(integrationId);
      return {} as GithubIssueWriter;
    },
    fail: async (_db, opId, error) => {
      failed.push({ opId, error });
    },
    defer: async (_db, opId, retryAt) => {
      deferred.push({ opId, retryAt });
    },
    appSlug: "antgrid",
    budget: createWriteBudget(),
    now,
    sleep: async (ms) => {
      sleeps.push(ms);
    },
  };

  return {
    run: (overrides = {}) => drainTaskSyncOutbox({ ...deps, ...overrides }),
    claims: () => claims,
    applied: () => appliedIds,
    applyDeps: () => applyDeps,
    sleeps: () => sleeps,
    failed: () => failed,
    deferred: () => deferred,
    writerCalls: () => writerCalls,
  };
}

describe("drainTaskSyncOutbox — stopping", () => {
  // `claimNextOps` applies its limit before the try-lock filter, so a pass whose
  // candidates are all held by another instance claims nothing while a backlog
  // exists. Stopping there lets a second instance truncate the first's work.
  test("an empty pass does not end the invocation", async () => {
    const backlog = op("a");
    const h = harness({ passes: [[], [backlog], [], []] });

    const report = await h.run();

    expect(h.applied()).toEqual(["a"]);
    expect(report).toMatchObject({ passes: 4, claimed: 1, applied: 1, stoppedBecause: "idle" });
  });

  test("consecutive empty passes are separated by a recheck pause", async () => {
    const h = harness({ passes: [] });

    const report = await h.run();

    expect(h.sleeps()).toEqual([500]);
    expect(report).toMatchObject({ passes: 2, claimed: 0, backlogRemains: false });
  });

  test("stops at the pass bound and says the backlog outlived the run", async () => {
    const h = harness({ passes: [], tail: [op("a"), op("b")] });

    const report = await h.run({ maxPasses: 3 });

    expect(report).toMatchObject({
      passes: 3,
      claimed: 6,
      applied: 6,
      stoppedBecause: "pass_limit",
      backlogRemains: true,
    });
  });

  test("stops at the time budget", async () => {
    const h = harness({ passes: [], tail: [op("a")], tookMs: 400 });

    const report = await h.run({ maxPasses: 50, timeBudgetMs: 1000 });

    // Passes start at 0ms, 400ms and 800ms; the fourth check sees 1200ms.
    expect(report).toMatchObject({ passes: 3, stoppedBecause: "time_budget", backlogRemains: true });
    expect(report.finishedAt.getTime() - report.startedAt.getTime()).toBe(1200);
  });

  test("claims a full batch by default", async () => {
    const h = harness({ passes: [] });

    await h.run();

    expect(h.claims()[0]?.limit).toBe(SYNC_DRAIN_BATCH_SIZE);
  });
});

describe("drainTaskSyncOutbox — throttling", () => {
  // `throttleOp` never touches `attempts`, so nothing else in the outbox can
  // retire an op the classifier keeps calling a rate limit.
  test("caps consecutive throttles on one op and stops working it", async () => {
    const stuck = op("a");
    const h = harness({
      passes: [],
      tail: [stuck],
      apply: async (_deps, record) => throttled(record, "secondary"),
    });

    const report = await h.run({ maxPasses: 6 });

    expect(h.applied()).toEqual(["a", "a", "a"]);
    expect(report).toMatchObject({
      passes: 6,
      throttled: MAX_CONSECUTIVE_THROTTLES,
      throttleCapped: 1,
      failed: 0,
      stoppedBecause: "pass_limit",
    });
    // Deferred, never failed: a wait is not an attempt.
    expect(h.failed()).toEqual([]);
    expect(h.deferred()).toHaveLength(1);
    expect(h.deferred()[0]?.retryAt.getTime()).toBe(
      START.getTime() + SYNC_OP_BACKOFF_MAX_SECONDS * 1000
    );
  });

  test("a throttle broken by any other outcome does not accumulate", async () => {
    const stuck = op("a");
    let call = 0;
    const h = harness({
      passes: [],
      tail: [stuck],
      apply: async (_deps, record) => {
        call += 1;
        return call === 2 ? applied(record) : throttled(record, "secondary");
      },
    });

    const report = await h.run({ maxPasses: 4 });

    expect(report).toMatchObject({ throttled: 3, applied: 1, throttleCapped: 0 });
  });

  // The local budget is this process pacing itself; counting it against the op
  // would retire ops the provider never refused.
  test("a local budget throttle ends the invocation without counting against the op", async () => {
    const h = harness({
      passes: [],
      tail: [op("a"), op("b")],
      apply: async (_deps, record) =>
        record.id === "a" ? applied(record) : throttled(record, "local"),
    });

    const report = await h.run({ maxPasses: 5 });

    expect(h.applied()).toEqual(["a", "b"]);
    expect(report).toMatchObject({
      passes: 1,
      applied: 1,
      throttled: 1,
      throttleCapped: 0,
      stoppedBecause: "budget_exhausted",
      backlogRemains: true,
    });
  });
});

describe("drainTaskSyncOutbox — credentials", () => {
  test("an integration whose token cannot be minted fails only its own ops", async () => {
    const h = harness({
      passes: [[op("a", "int-bad"), op("b", "int-ok"), op("c", "int-bad")]],
      resolveWriter: async (integrationId) => {
        if (integrationId === "int-bad") throw new Error("installation token refused");
        return { getIssue: async () => ({}) } as unknown as GithubIssueWriter;
      },
      // Stands in for the executor: it reaches for the writer, and reports what
      // the failure to get one cost this op.
      apply: async (deps, record) => {
        try {
          await deps.writer.getIssue({ owner: "o", repo: "r", number: 1 });
        } catch (err) {
          return {
            kind: "failed",
            opId: record.id,
            taskId: record.taskId,
            attempts: 1,
            gaveUp: false,
            error: err instanceof Error ? err.message : String(err),
          };
        }
        return applied(record);
      },
    });

    const report = await h.run();

    expect(report).toMatchObject({ claimed: 3, applied: 1, failed: 2, tokenErrors: 1 });
    // Both the success and the rejection are memoized: one mint per integration
    // per invocation, however many ops name it.
    expect(h.writerCalls().sort()).toEqual(["int-bad", "int-ok"]);
  });

  test("credentials are resolved only for an op that reaches the provider", async () => {
    const h = harness({ passes: [[op("a")]] });

    await h.run();

    expect(h.writerCalls()).toEqual([]);
  });
});

describe("drainTaskSyncOutbox — the shared write budget", () => {
  // Process-local and non-durable by design, so a budget rebuilt per pass admits
  // `passes x 500` writes an hour and enforces nothing.
  test("one budget spans every pass of the invocation", async () => {
    const budget = createWriteBudget({ perHour: 1, perMinute: 1 });
    const h = harness({
      passes: [[op("a")], [op("b")]],
      apply: async (deps, record) => {
        const decision = deps.budget?.take(deps.now?.() ?? START) ?? { ok: true as const };
        return decision.ok ? applied(record) : throttled(record, "local");
      },
    });

    const report = await h.run({ budget });

    expect(report).toMatchObject({ applied: 1, throttled: 1, stoppedBecause: "budget_exhausted" });
    expect(new Set(h.applyDeps().map((deps) => deps.budget)).size).toBe(1);
  });
});

describe("drainTaskSyncOutbox — containment and reporting", () => {
  test("one op's throw costs that op and nothing else", async () => {
    const h = harness({
      passes: [[op("a"), op("b")]],
      apply: async (_deps, record) => {
        if (record.id === "a") throw new Error("prisma exploded");
        return applied(record);
      },
    });

    const report = await h.run();

    expect(report).toMatchObject({ claimed: 2, applied: 1, opErrors: 1 });
    expect(h.failed()).toEqual([{ opId: "a", error: "prisma exploded" }]);
  });

  test("a bookkeeping write that fails does not take the pass with it", async () => {
    const h = harness({
      passes: [[op("a"), op("b")]],
      apply: async (_deps, record) => {
        if (record.id === "a") throw new Error("prisma exploded");
        return applied(record);
      },
    });

    const report = await h.run({
      fail: async () => {
        throw new Error("connection reset");
      },
    });

    expect(report).toMatchObject({ applied: 1, opErrors: 1 });
  });

  test("every outcome kind lands in its own counter", async () => {
    const records = ["a", "b", "c", "d", "e", "f", "g", "h"].map((id) => op(id));
    const outcomes: Record<string, ApplyOpOutcome> = {
      a: applied(records[0]!),
      b: {
        kind: "no_effect",
        opId: "b",
        taskId: "task-b",
        fields: ["title"],
        blocked: ["title"],
        pushedHash: "hash",
      },
      c: { kind: "superseded", opId: "c", taskId: "task-c", reason: "op_key" },
      d: {
        kind: "aborted_to_merge",
        opId: "d",
        taskId: "task-d",
        field: "title",
        detail: "conflict",
      },
      e: throttled(records[4]!, "primary"),
      f: {
        kind: "failed",
        opId: "f",
        taskId: "task-f",
        attempts: 5,
        gaveUp: true,
        error: "boom",
      },
      g: { kind: "refused", opId: "g", taskId: "task-g", status: 422, reason: "invalid" },
      h: { kind: "skipped", opId: "h", taskId: "task-h", reason: "push_disabled" },
    };
    const h = harness({
      passes: [records],
      apply: async (_deps, record) => outcomes[record.id]!,
    });

    const report = await h.run();

    expect(report).toMatchObject({
      claimed: 8,
      applied: 1,
      noEffect: 1,
      superseded: 1,
      abortedToMerge: 1,
      throttled: 1,
      failed: 1,
      gaveUp: 1,
      refused: 1,
      skipped: 1,
      opErrors: 0,
      tokenErrors: 0,
    });
  });
});

describe("taskSyncDrainNeedsAttention", () => {
  const clean: TaskSyncDrainReport = {
    startedAt: START,
    finishedAt: START,
    passes: 2,
    claimed: 4,
    applied: 4,
    noEffect: 0,
    superseded: 0,
    abortedToMerge: 0,
    throttled: 0,
    failed: 0,
    refused: 0,
    skipped: 0,
    gaveUp: 0,
    throttleCapped: 0,
    tokenErrors: 0,
    opErrors: 0,
    stoppedBecause: "idle",
    backlogRemains: false,
  };

  test("a clean run does not page", () => {
    expect(taskSyncDrainNeedsAttention(clean)).toBe(false);
  });

  // Terminal: the ops are abandoned and only a person gets them back.
  test.each([["gaveUp"], ["refused"], ["throttleCapped"]] as const)(
    "%s pages",
    (field) => {
      expect(taskSyncDrainNeedsAttention({ ...clean, [field]: 1 })).toBe(true);
    }
  );

  // Claimable next tick; alerting on these pages for every transient blip, and a
  // job that pages routinely gets muted.
  test.each([["failed"], ["throttled"], ["skipped"], ["opErrors"], ["tokenErrors"]] as const)(
    "%s does not page on its own",
    (field) => {
      expect(taskSyncDrainNeedsAttention({ ...clean, [field]: 3 })).toBe(false);
    }
  );

  test("a bound cutting the run short is a warning, not an alarm", () => {
    expect(
      taskSyncDrainNeedsAttention({ ...clean, stoppedBecause: "pass_limit", backlogRemains: true })
    ).toBe(false);
  });
});
