import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestSubscription, createTestUser } from "../helpers/fixtures.js";
import { upsertIntegration } from "../../src/models/integration.js";
import { createTask } from "../../src/models/task.js";
import type { Tx } from "../../src/db/index.js";
import {
  ARRAY_VALUED_OP_KINDS,
  cancelPendingOps,
  claimNextOps,
  completeOp,
  enqueueSyncOp,
  failOp,
  isArrayValuedOpKind,
  markOpAttempted,
  MAX_SYNC_OP_ATTEMPTS,
  throttleOp,
  type EnqueueSyncOpArgs,
  type EnqueueSyncOpResult,
  type TaskSyncOpPayload,
} from "../../src/tasks/sync-op.js";

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

type Fixture = { accountId: string; userId: string; integrationId: string };

let installations = 0;

async function makeFixture(): Promise<Fixture> {
  const user = await createTestUser(pg.db);
  await createTestSubscription(pg.db, user.id);
  const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
  const integration = await upsertIntegration(pg.db, {
    accountId: account.id,
    provider: "github",
    externalAccountId: `org-${++installations}`,
    installationId: `${installations}`,
    displayName: "acme",
    installedBy: user.id,
  });
  if (integration.kind !== "ok") throw new Error(`upsertIntegration: ${integration.kind}`);
  return { accountId: account.id, userId: user.id, integrationId: integration.integration.id };
}

async function makeTask(fixture: Fixture, title = "a task"): Promise<string> {
  const created = await createTask(pg.db, {
    accountId: fixture.accountId,
    createdBy: fixture.userId,
    title,
  });
  if (created.kind !== "ok") throw new Error(`createTask: ${created.kind}`);
  return created.task.id;
}

/** The lock every caller of `enqueueSyncOp` is required to be holding. Taking
 *  it here is what makes these tests exercise the real precondition rather than
 *  a relaxed one. */
async function underTaskLock<T>(taskId: string, fn: (tx: Tx) => Promise<T>): Promise<T> {
  return pg.db.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${taskId}`}))`;
    return fn(tx);
  });
}

const title = (value: string): TaskSyncOpPayload => ({ kind: "issue.patch.title", title: value });
const body = (value: string): TaskSyncOpPayload => ({ kind: "issue.patch.body", body: value });
const create = (): TaskSyncOpPayload => ({
  kind: "issue.create",
  title: "a task",
  body: "",
  state: "open",
  stateReason: null,
  labels: [],
});

async function enqueue(
  fixture: Fixture,
  taskId: string,
  payload: TaskSyncOpPayload
): Promise<EnqueueSyncOpResult> {
  const args: EnqueueSyncOpArgs = {
    taskId,
    integrationId: fixture.integrationId,
    provider: "github",
    payload,
  };
  return underTaskLock(taskId, (tx) => enqueueSyncOp(tx, args));
}

function ok(result: EnqueueSyncOpResult) {
  if (result.kind !== "ok") throw new Error(`enqueueSyncOp: ${result.kind}`);
  return result;
}

async function opsOf(taskId: string) {
  return pg.db.taskSyncOp.findMany({ where: { taskId }, orderBy: { seq: "asc" } });
}

describe("op kinds", () => {
  // The rule this set exists for — "never replay an array-valued PATCH without
  // recomputing it" — is enforced far from here, and a `kind.endsWith("labels")`
  // test at the call site would silently stop covering a future kind.
  test("only issue.labels is array-valued", () => {
    expect([...ARRAY_VALUED_OP_KINDS]).toEqual(["issue.labels"]);
    expect(isArrayValuedOpKind("issue.labels")).toBe(true);
    expect(isArrayValuedOpKind("issue.patch.title")).toBe(false);
  });
});

describe("enqueueSyncOp", () => {
  test("a second write of the same kind supersedes rather than queues", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);

    const first = ok(await enqueue(fixture, taskId, title("T2")));
    const second = ok(await enqueue(fixture, taskId, title("T3")));

    expect(second.superseded).toBe(first.op.id);
    const rows = await opsOf(taskId);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.id).toBe(first.op.id);
    expect(rows[0]!.payload).toMatchObject({ title: "T3" });
    // The drain decides on an op in one critical section and writes the result
    // in another; a fresh key is how it notices the payload moved in the gap.
    expect(rows[0]!.opKey).not.toBe(first.op.opKey);
  });

  test("a different kind is queued beside it, not over it", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);

    ok(await enqueue(fixture, taskId, title("T2")));
    const second = ok(await enqueue(fixture, taskId, body("B")));

    expect(second.superseded).toBeNull();
    expect(await opsOf(taskId)).toHaveLength(2);
  });

  // An op already handed to the provider has an unknown outcome, so rewriting
  // it in place would erase the only evidence that a request may have landed.
  test("an already-attempted op is queued behind rather than superseded", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);

    const first = ok(await enqueue(fixture, taskId, title("T2")));
    await markOpAttempted(pg.db, first.op.id, new Date());
    const second = ok(await enqueue(fixture, taskId, title("T3")));

    expect(second.superseded).toBeNull();
    const rows = await opsOf(taskId);
    expect(rows.map((row) => row.seq)).toEqual([1, 2]);
  });

  test("seq is per task and monotonic", async () => {
    const fixture = await makeFixture();
    const one = await makeTask(fixture, "one");
    const two = await makeTask(fixture, "two");

    expect(ok(await enqueue(fixture, one, title("a"))).op.seq).toBe(1);
    expect(ok(await enqueue(fixture, one, body("b"))).op.seq).toBe(2);
    expect(ok(await enqueue(fixture, two, title("c"))).op.seq).toBe(1);

    ok(await enqueue(fixture, one, create()));
    expect((await opsOf(one)).map((row) => row.seq)).toEqual([1, 2, 3]);
  });

  // The duplicate a second create would post is public and permanent, so the
  // guard is local and unconditional rather than a consequence of the marker
  // the drain resolves an unknown outcome with.
  test("issue.create is refused for a task that already has an externalId", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    await pg.db.task.update({
      where: { id: taskId },
      data: { externalProvider: "github", externalId: "42" },
    });

    expect((await enqueue(fixture, taskId, create())).kind).toBe("already_created");
    expect(await opsOf(taskId)).toHaveLength(0);

    // A field write on a linked task is exactly what the outbox is for.
    expect(ok(await enqueue(fixture, taskId, title("T"))).op.seq).toBe(1);
  });

  test("opKey is unique per task", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    const first = ok(await enqueue(fixture, taskId, title("T")));

    let violated = false;
    try {
      await pg.db.taskSyncOp.create({
        data: {
          taskId,
          integrationId: fixture.integrationId,
          provider: "github",
          kind: "issue.patch.body",
          payload: body("B"),
          opKey: first.op.opKey,
          seq: 2,
          status: "pending",
        },
      });
    } catch {
      violated = true;
    }
    expect(violated).toBe(true);
    expect(await opsOf(taskId)).toHaveLength(1);
  });

  test("a task that does not exist is refused", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    await pg.db.task.delete({ where: { id: taskId } });

    expect((await enqueue(fixture, taskId, title("T"))).kind).toBe("task_not_found");
  });
});

describe("claimNextOps", () => {
  // The regression the ordering rule exists for: op1 fails once and backs off
  // past op2, so a claim ordered by due time applies T3 and then T2 — and the
  // value the user replaced is the one that survives.
  test("a task's ops claim in seq order even when the later one is due first", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);

    const first = ok(await enqueue(fixture, taskId, title("T2")));
    const second = ok(await enqueue(fixture, taskId, body("B")));

    const now = new Date();
    await pg.db.taskSyncOp.update({
      where: { id: first.op.id },
      data: { nextAttemptAt: new Date(now.getTime() - 1_000) },
    });
    await pg.db.taskSyncOp.update({
      where: { id: second.op.id },
      data: { nextAttemptAt: new Date(now.getTime() - 60_000) },
    });

    const claimed = await claimNextOps(pg.db, { now, limit: 10 });
    expect(claimed.map((op) => op.id)).toEqual([first.op.id]);
  });

  test("a task whose head op is not due yields nothing at all", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);

    const first = ok(await enqueue(fixture, taskId, title("T2")));
    const second = ok(await enqueue(fixture, taskId, body("B")));

    const now = new Date();
    await pg.db.taskSyncOp.update({
      where: { id: first.op.id },
      data: { nextAttemptAt: new Date(now.getTime() + 60_000) },
    });
    await pg.db.taskSyncOp.update({
      where: { id: second.op.id },
      data: { nextAttemptAt: new Date(now.getTime() - 60_000) },
    });

    expect(await claimNextOps(pg.db, { now, limit: 10 })).toEqual([]);
  });

  test("at most one op per task per call, and one per task across tasks", async () => {
    const fixture = await makeFixture();
    const one = await makeTask(fixture, "one");
    const two = await makeTask(fixture, "two");
    ok(await enqueue(fixture, one, title("a")));
    ok(await enqueue(fixture, one, body("b")));
    ok(await enqueue(fixture, two, title("c")));

    const claimed = await claimNextOps(pg.db, { now: new Date(), limit: 10 });
    expect(claimed).toHaveLength(2);
    expect(new Set(claimed.map((op) => op.taskId))).toEqual(new Set([one, two]));
  });

  // The lease, not the advisory lock: the lock dies with the claiming
  // transaction, and the provider call happens after it commits.
  test("a claimed op is not re-claimed while its lease holds", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    ok(await enqueue(fixture, taskId, title("T")));

    const now = new Date();
    expect(await claimNextOps(pg.db, { now, limit: 10 })).toHaveLength(1);
    expect(await claimNextOps(pg.db, { now, limit: 10 })).toEqual([]);
  });

  // Multiple web instances are the expected deployment, and the try-lock is why
  // the second one moves on to other tasks instead of queueing behind the first.
  test("a task another claimer holds is skipped, not waited on", async () => {
    const fixture = await makeFixture();
    const held = await makeTask(fixture, "held");
    const free = await makeTask(fixture, "free");
    ok(await enqueue(fixture, held, title("a")));
    ok(await enqueue(fixture, free, title("b")));

    let locked!: () => void;
    let release!: () => void;
    const lockTaken = new Promise<void>((resolve) => {
      locked = resolve;
    });
    const releaseLock = new Promise<void>((resolve) => {
      release = resolve;
    });

    const holder = pg.db.$transaction(
      async (tx) => {
        await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${held}`}))`;
        locked();
        await releaseLock;
      },
      { timeout: 20_000 }
    );
    await lockTaken;

    const claimed = await claimNextOps(pg.db, { now: new Date(), limit: 10 });
    expect(claimed.map((op) => op.taskId)).toEqual([free]);

    release();
    await holder;
  });

  test("a stored payload no schema accepts is given up rather than retried", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    const op = ok(await enqueue(fixture, taskId, title("T")));
    await pg.db.taskSyncOp.update({
      where: { id: op.op.id },
      data: { payload: { kind: "issue.patch.title" } },
    });

    expect(await claimNextOps(pg.db, { now: new Date(), limit: 10 })).toEqual([]);
    const row = await pg.db.taskSyncOp.findUniqueOrThrow({ where: { id: op.op.id } });
    expect(row.status).toBe("given_up");
  });
});

describe("outcomes", () => {
  test("a throttle defers the op without counting an attempt", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    const op = ok(await enqueue(fixture, taskId, title("T")));

    const retryAt = new Date(Date.now() + 120_000);
    await throttleOp(pg.db, op.op.id, retryAt);

    const row = await pg.db.taskSyncOp.findUniqueOrThrow({ where: { id: op.op.id } });
    expect(row.attempts).toBe(0);
    expect(row.status).toBe("pending");
    expect(row.nextAttemptAt.getTime()).toBe(retryAt.getTime());
  });

  test("a failure counts an attempt and backs the op off", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    const op = ok(await enqueue(fixture, taskId, title("T")));

    const before = new Date();
    const result = await failOp(pg.db, op.op.id, "502 from provider");
    expect(result).toEqual({ attempts: 1, gaveUp: false });

    const row = await pg.db.taskSyncOp.findUniqueOrThrow({ where: { id: op.op.id } });
    expect(row.status).toBe("pending");
    expect(row.lastError).toBe("502 from provider");
    expect(row.nextAttemptAt.getTime()).toBeGreaterThan(before.getTime());
  });

  test("backoff grows with each failure", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    const op = ok(await enqueue(fixture, taskId, title("T")));

    await failOp(pg.db, op.op.id, "one");
    const first = (await pg.db.taskSyncOp.findUniqueOrThrow({ where: { id: op.op.id } }))
      .nextAttemptAt;
    await failOp(pg.db, op.op.id, "two");
    const second = (await pg.db.taskSyncOp.findUniqueOrThrow({ where: { id: op.op.id } }))
      .nextAttemptAt;

    expect(second.getTime()).toBeGreaterThan(first.getTime());
  });

  // Terminal, and deliberately not a delete: an abandoned write is something a
  // person has to be able to find, with the error that stopped it attached.
  test("the attempt ceiling gives the op up instead of looping", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    const op = ok(await enqueue(fixture, taskId, title("T")));

    for (let attempt = 1; attempt < MAX_SYNC_OP_ATTEMPTS; attempt += 1) {
      expect((await failOp(pg.db, op.op.id, `failure ${attempt}`)).gaveUp).toBe(false);
    }
    expect(await failOp(pg.db, op.op.id, "last")).toEqual({
      attempts: MAX_SYNC_OP_ATTEMPTS,
      gaveUp: true,
    });

    const row = await pg.db.taskSyncOp.findUniqueOrThrow({ where: { id: op.op.id } });
    expect(row.status).toBe("given_up");
    expect(row.lastError).toBe("last");
    expect(await claimNextOps(pg.db, { now: new Date(Date.now() + 86_400_000), limit: 10 })).toEqual(
      []
    );
  });

  test("a throttle after a failure still leaves attempts alone", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    const op = ok(await enqueue(fixture, taskId, title("T")));

    await failOp(pg.db, op.op.id, "502");
    await throttleOp(pg.db, op.op.id, new Date(Date.now() + 60_000));

    expect(
      (await pg.db.taskSyncOp.findUniqueOrThrow({ where: { id: op.op.id } })).attempts
    ).toBe(1);
  });

  test("completing an op clears its error and takes it out of the queue", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    const op = ok(await enqueue(fixture, taskId, title("T")));

    await failOp(pg.db, op.op.id, "502");
    await completeOp(pg.db, op.op.id);

    const row = await pg.db.taskSyncOp.findUniqueOrThrow({ where: { id: op.op.id } });
    expect(row.status).toBe("processed");
    expect(row.lastError).toBeNull();
    // Kept, not reset: it is the record of what the write took.
    expect(row.attempts).toBe(1);
  });
});

describe("cancelPendingOps", () => {
  // An attempted create may already have posted a public issue with nothing
  // linking to it. Cancelling it blind leaves an orphan our own retry created
  // and our own delete forgot.
  test("an attempted create survives while everything else is cancelled", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);

    const created = ok(await enqueue(fixture, taskId, create()));
    await markOpAttempted(pg.db, created.op.id, new Date());
    const titleOp = ok(await enqueue(fixture, taskId, title("T")));
    const bodyOp = ok(await enqueue(fixture, taskId, body("B")));

    const result = await underTaskLock(taskId, (tx) => cancelPendingOps(tx, taskId));

    expect(result.keptCreate).toEqual({ id: created.op.id, opKey: created.op.opKey });
    expect(new Set(result.cancelled.map((op) => op.id))).toEqual(
      new Set([titleOp.op.id, bodyOp.op.id])
    );
    const rows = await opsOf(taskId);
    expect(rows.find((row) => row.id === created.op.id)!.status).toBe("pending");
    expect(rows.filter((row) => row.status === "cancelled")).toHaveLength(2);
  });

  test("an unattempted create is cancelled like any other op", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    const created = ok(await enqueue(fixture, taskId, create()));

    const result = await underTaskLock(taskId, (tx) => cancelPendingOps(tx, taskId));

    expect(result.keptCreate).toBeNull();
    expect(result.cancelled.map((op) => op.kind)).toEqual(["issue.create"]);
  });

  test("terminal ops are left as they are", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    const done = ok(await enqueue(fixture, taskId, title("T")));
    await completeOp(pg.db, done.op.id);
    ok(await enqueue(fixture, taskId, body("B")));

    const result = await underTaskLock(taskId, (tx) => cancelPendingOps(tx, taskId));

    expect(result.cancelled).toHaveLength(1);
    expect(
      (await pg.db.taskSyncOp.findUniqueOrThrow({ where: { id: done.op.id } })).status
    ).toBe("processed");
  });

  test("cancelled ops are never claimed", async () => {
    const fixture = await makeFixture();
    const taskId = await makeTask(fixture);
    ok(await enqueue(fixture, taskId, title("T")));

    await underTaskLock(taskId, (tx) => cancelPendingOps(tx, taskId));

    expect(await claimNextOps(pg.db, { now: new Date(), limit: 10 })).toEqual([]);
  });
});
