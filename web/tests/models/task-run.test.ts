import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser, createTestSubscription } from "../helpers/fixtures.js";
import { createTask, updateTask, type TaskRecord } from "../../src/models/task.js";
import {
  applyRunStatusToTask,
  autoTaskStatusFor,
  recordTaskRun,
  RESULT_SUMMARY_MAX,
  type TaskRunStatus,
} from "../../src/models/task-run.js";
import type { TaskStatus } from "../../src/tasks/merge.js";

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});
beforeEach(async () => {
  await pg.truncate();
});

type Account = { userId: string; accountId: string };

async function makeAccount(): Promise<Account> {
  const user = await createTestUser(pg.db);
  await createTestSubscription(pg.db, user.id);
  const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
  return { userId: user.id, accountId: account.id };
}

function ok<T extends { kind: string }>(result: T): Extract<T, { kind: "ok" }> {
  expect(result.kind).toBe("ok");
  return result as Extract<T, { kind: "ok" }>;
}

async function makeTask(account: Account, status: TaskStatus = "open"): Promise<TaskRecord> {
  const created = ok(
    await createTask(pg.db, {
      accountId: account.accountId,
      createdBy: account.userId,
      title: "ship the thing",
      status,
    })
  );
  return created.task;
}

function report(
  account: Account,
  number: number,
  status: TaskRunStatus,
  overrides: Partial<Parameters<typeof recordTaskRun>[1]> = {}
) {
  return recordTaskRun(pg.db, {
    accountId: account.accountId,
    number,
    deviceId: "device-a",
    localProjectId: "abc123",
    sessionId: "session-1",
    status,
    ...overrides,
  });
}

describe("autoTaskStatusFor", () => {
  const cases: [TaskRunStatus, TaskStatus, TaskStatus | null][] = [
    ["working", "open", "in_progress"],
    ["working", "in_progress", null],
    ["working", "blocked", null],
    ["working", "done", null],
    ["working", "cancelled", null],
    ["attention", "open", "blocked"],
    ["attention", "in_progress", "blocked"],
    ["attention", "blocked", null],
    ["attention", "done", null],
    ["attention", "cancelled", null],
    ["done", "open", null],
    ["done", "in_progress", null],
    ["done", "blocked", null],
    ["error", "open", null],
    ["error", "in_progress", null],
  ];

  for (const [runStatus, observed, expected] of cases) {
    test(`${runStatus} observed at ${observed} -> ${expected ?? "no write"}`, () => {
      expect(autoTaskStatusFor(runStatus, observed)).toBe(expected);
    });
  }

  test("an unrecognized observed status writes nothing", () => {
    expect(autoTaskStatusFor("working", "archived")).toBeNull();
  });
});

describe("recordTaskRun: the automatic status writes", () => {
  test("working moves an open task to in_progress", async () => {
    const account = await makeAccount();
    const task = await makeTask(account);

    const result = ok(await report(account, task.number, "working"));

    expect(result.task.status).toBe("in_progress");
    expect(result.run.status).toBe("working");
  });

  test("attention moves an open task to blocked", async () => {
    const account = await makeAccount();
    const task = await makeTask(account);

    const result = ok(await report(account, task.number, "attention"));

    expect(result.task.status).toBe("blocked");
  });

  test("attention moves an in_progress task to blocked", async () => {
    const account = await makeAccount();
    const task = await makeTask(account, "in_progress");

    const result = ok(await report(account, task.number, "attention"));

    expect(result.task.status).toBe("blocked");
  });

  // `WorkStatus.done` means "no turn is open" — a finished agent, an idle one
  // and a freshly-opened chat all report it. Closing on it would close a task
  // every time the user stopped typing.
  test("done never writes the task status, from any source state", async () => {
    const account = await makeAccount();
    for (const status of ["open", "in_progress", "blocked"] as const) {
      const task = await makeTask(account, status);
      const result = ok(
        await report(account, task.number, "done", { sessionId: `session-${task.number}` })
      );
      expect(result.task.status).toBe(status);
    }
  });

  test("error never writes the task status", async () => {
    const account = await makeAccount();
    const task = await makeTask(account);

    const result = ok(await report(account, task.number, "error"));

    expect(result.task.status).toBe("open");
  });

  test("a finished task is not reopened by a new run on it", async () => {
    const account = await makeAccount();
    const done = await makeTask(account, "done");
    const cancelled = await makeTask(account, "cancelled");

    const first = ok(await report(account, done.number, "working"));
    const second = ok(
      await report(account, cancelled.number, "attention", { sessionId: "session-2" })
    );

    expect(first.task.status).toBe("done");
    expect(second.task.status).toBe("cancelled");
  });

  test("the run row is still written when the status write is refused", async () => {
    const account = await makeAccount();
    const task = await makeTask(account, "done");

    ok(await report(account, task.number, "working"));

    const rows = await pg.db.taskRun.findMany({ select: { status: true } });
    expect(rows).toEqual([{ status: "working" }]);
  });
});

describe("applyRunStatusToTask: compare-and-set", () => {
  test("a status that moved under the writer is a silent no-op", async () => {
    const account = await makeAccount();
    const task = await makeTask(account);
    const row = await pg.db.task.findFirstOrThrow({ where: { number: task.number } });

    // The human edit lands between the observation and the write — the whole
    // window the `WHERE` clause exists to close.
    ok(await updateTask(pg.db, { accountId: account.accountId, number: task.number, patch: { status: "done" } }));

    const moved = await applyRunStatusToTask(pg.db, {
      taskId: row.id,
      observed: "open",
      runStatus: "working",
    });

    expect(moved).toBe(false);
    const after = await pg.db.task.findFirstOrThrow({ where: { id: row.id } });
    expect(after.status).toBe("done");
    expect(after.closedAt).not.toBeNull();
  });

  test("a soft-deleted task is never moved", async () => {
    const account = await makeAccount();
    const task = await makeTask(account);
    const row = await pg.db.task.findFirstOrThrow({ where: { number: task.number } });
    await pg.db.task.update({ where: { id: row.id }, data: { deletedAt: new Date() } });

    const moved = await applyRunStatusToTask(pg.db, {
      taskId: row.id,
      observed: "open",
      runStatus: "working",
    });

    expect(moved).toBe(false);
    expect((await pg.db.task.findFirstOrThrow({ where: { id: row.id } })).status).toBe("open");
  });

  test("the observed status still standing is written", async () => {
    const account = await makeAccount();
    const task = await makeTask(account);
    const row = await pg.db.task.findFirstOrThrow({ where: { number: task.number } });

    const moved = await applyRunStatusToTask(pg.db, {
      taskId: row.id,
      observed: "open",
      runStatus: "working",
    });

    expect(moved).toBe(true);
    expect((await pg.db.task.findFirstOrThrow({ where: { id: row.id } })).status).toBe(
      "in_progress"
    );
  });
});

describe("recordTaskRun: identity and scope", () => {
  test("repeated reports for one session update the same row", async () => {
    const account = await makeAccount();
    const task = await makeTask(account);

    ok(await report(account, task.number, "working", { branch: "antgrid/ship-a1b2c3d4" }));
    const second = ok(
      await report(account, task.number, "attention", { prUrl: "https://github.com/a/b/pull/1" })
    );

    expect(await pg.db.taskRun.count()).toBe(1);
    expect(second.run.status).toBe("attention");
    // Absent fields are left alone rather than nulled: one advert carries the
    // status, not the whole run.
    expect(second.run.branch).toBe("antgrid/ship-a1b2c3d4");
    expect(second.run.prUrl).toBe("https://github.com/a/b/pull/1");
  });

  test("the same session id on two machines is two runs", async () => {
    const account = await makeAccount();
    const task = await makeTask(account);

    ok(await report(account, task.number, "working"));
    ok(await report(account, task.number, "working", { deviceId: "device-b" }));

    expect(await pg.db.taskRun.count()).toBe(2);
  });

  test("a session already attached to another task is refused", async () => {
    const account = await makeAccount();
    const first = await makeTask(account);
    const second = await makeTask(account);

    ok(await report(account, first.number, "working"));
    const conflict = await report(account, second.number, "working");

    expect(conflict.kind).toBe("session_task_conflict");
    // The refusal names the task the session is already on, so a reporter can
    // correct itself rather than retry the same wrong number forever.
    expect(conflict).toMatchObject({ boundNumber: first.number });
    expect(await pg.db.taskRun.count()).toBe(1);
  });

  // The session id is the machine's own and carries no tenancy, so the same
  // pair can name a run on a task the caller may not see. It still refuses, and
  // the refusal says nothing about the other account's task.
  test("a session attached to another account's task refuses without naming it", async () => {
    const mine = await makeAccount();
    const theirs = await makeAccount();
    const theirTask = await makeTask(theirs);
    const myTask = await makeTask(mine);

    ok(await report(theirs, theirTask.number, "working"));
    const conflict = await report(mine, myTask.number, "working");

    expect(conflict.kind).toBe("session_task_conflict");
    expect(conflict).toMatchObject({ boundNumber: null });
    expect(await pg.db.taskRun.count()).toBe(1);
  });

  // Whether or not the two overlap, one of them refuses: the advisory lock
  // makes the outcome the same either way, so this asserts the outcome rather
  // than trying to force an interleaving the client will not reproduce on
  // demand.
  test("two reports for one session against two tasks leave exactly one run", async () => {
    const account = await makeAccount();
    const first = await makeTask(account);
    const second = await makeTask(account);

    const results = await Promise.all([
      report(account, first.number, "working"),
      report(account, second.number, "working"),
    ]);

    expect(results.filter((result) => result.kind === "ok")).toHaveLength(1);
    expect(results.filter((result) => result.kind === "session_task_conflict")).toHaveLength(1);
    expect(await pg.db.taskRun.count()).toBe(1);
  });

  test("another account's task is not found", async () => {
    const mine = await makeAccount();
    const theirs = await makeAccount();
    const task = await makeTask(theirs);

    const result = await report(mine, task.number, "working");

    expect(result.kind).toBe("not_found");
    expect(await pg.db.taskRun.count()).toBe(0);
    expect((await pg.db.task.findFirstOrThrow()).status).toBe("open");
  });

  test("a soft-deleted task is not found", async () => {
    const account = await makeAccount();
    const task = await makeTask(account);
    await pg.db.task.updateMany({ where: { number: task.number }, data: { deletedAt: new Date() } });

    expect((await report(account, task.number, "working")).kind).toBe("not_found");
  });

  test("ended stamps endedAt once and a later report does not move it", async () => {
    const account = await makeAccount();
    const task = await makeTask(account);

    ok(await report(account, task.number, "working"));
    const first = ok(await report(account, task.number, "done", { ended: true }));
    const later = ok(await report(account, task.number, "done", { ended: true }));

    expect(first.run.endedAt).not.toBeNull();
    expect(later.run.endedAt?.getTime()).toBe(first.run.endedAt!.getTime());
  });
});

describe("recordTaskRun: resultSummary", () => {
  test("a summary at the cap is stored verbatim", async () => {
    const account = await makeAccount();
    const task = await makeTask(account);
    const summary = "x".repeat(RESULT_SUMMARY_MAX);

    const result = ok(await report(account, task.number, "done", { resultSummary: summary }));

    expect(result.run.resultSummary).toBe(summary);
  });

  // Refused, never truncated: the cap is a trust boundary, and a silent
  // truncation would let a caller believe agent output had been accepted.
  test("a summary over the cap is refused and writes nothing", async () => {
    const account = await makeAccount();
    const task = await makeTask(account);

    const result = await report(account, task.number, "done", {
      resultSummary: "x".repeat(RESULT_SUMMARY_MAX + 1),
    });

    expect(result.kind).toBe("result_summary_too_long");
    expect(await pg.db.taskRun.count()).toBe(0);
  });
});
