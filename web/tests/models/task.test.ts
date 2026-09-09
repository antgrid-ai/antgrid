import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser, createTestSubscription, addTestMember } from "../helpers/fixtures.js";
import {
  createTask,
  getTaskByNumber,
  listTasks,
  moveTask,
  resolveTaskConflict,
  softDeleteTask,
  updateTask,
} from "../../src/models/task.js";
import type { TaskStatus } from "../../src/tasks/merge.js";
import {
  attachLabel,
  detachLabel,
  getOrCreateLabel,
  setTaskLabels,
} from "../../src/models/label.js";
import { upsertIntegration, upsertIntegrationRepo } from "../../src/models/integration.js";

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

async function makeProject(accountId: string, repoKey = `github.com/acme/${crypto.randomUUID()}`) {
  return pg.db.project.create({
    data: { accountId, repoKey, displayName: "acme" },
    select: { id: true },
  });
}

function ok<T extends { kind: string }>(result: T): Extract<T, { kind: "ok" }> {
  expect(result.kind).toBe("ok");
  return result as Extract<T, { kind: "ok" }>;
}

describe("createTask", () => {
  test("numbers are per account, start at one, and have no gaps", async () => {
    const a = await makeAccount();
    const b = await makeAccount();

    const first = ok(await createTask(pg.db, { ...owner(a), title: "one" }));
    const second = ok(await createTask(pg.db, { ...owner(a), title: "two" }));
    const other = ok(await createTask(pg.db, { ...owner(b), title: "elsewhere" }));

    expect(first.task.number).toBe(1);
    expect(second.task.number).toBe(2);
    expect(other.task.number).toBe(1);
  });

  test("concurrent creates on one account get distinct numbers", async () => {
    const a = await makeAccount();

    // The advisory lock is the only thing between these two and a shared max.
    const results = await Promise.all([
      createTask(pg.db, { ...owner(a), title: "left" }),
      createTask(pg.db, { ...owner(a), title: "right" }),
      createTask(pg.db, { ...owner(a), title: "middle" }),
    ]);
    const numbers = results.map((result) => ok(result).task.number).sort();
    expect(numbers).toEqual([1, 2, 3]);
  });

  test("a soft-deleted task keeps its number rather than handing it on", async () => {
    const a = await makeAccount();
    ok(await createTask(pg.db, { ...owner(a), title: "one" }));
    expect(await softDeleteTask(pg.db, { accountId: a.accountId, number: 1 })).toMatchObject({
      kind: "ok",
    });

    const next = ok(await createTask(pg.db, { ...owner(a), title: "two" }));
    expect(next.task.number).toBe(2);
  });

  test("a project belonging to another account is refused, not written", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const foreign = await makeProject(b.accountId);

    const result = await createTask(pg.db, { ...owner(a), title: "x", projectId: foreign.id });

    expect(result).toEqual({ kind: "project_not_found" });
    expect(await pg.db.task.count()).toBe(0);
  });

  test("a label belonging to another account is refused, not written", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const foreign = ok(
      await getOrCreateLabel(pg.db, { accountId: b.accountId, name: "bug", color: "d73a4a" })
    );

    const result = await createTask(pg.db, {
      ...owner(a),
      title: "x",
      labelIds: [foreign.label.id],
    });

    expect(result).toEqual({ kind: "label_not_found", labelId: foreign.label.id });
    expect(await pg.db.task.count()).toBe(0);
  });

  test("a repo-scoped label from another project is refused", async () => {
    const a = await makeAccount();
    const home = await makeProject(a.accountId);
    const elsewhere = await makeProject(a.accountId);
    const scoped = ok(
      await getOrCreateLabel(pg.db, {
        accountId: a.accountId,
        projectId: elsewhere.id,
        name: "area/relay",
        color: "0e8a16",
      })
    );

    const result = await createTask(pg.db, {
      ...owner(a),
      title: "x",
      projectId: home.id,
      labelIds: [scoped.label.id],
    });

    expect(result).toEqual({ kind: "label_out_of_scope", labelId: scoped.label.id });
  });

  test("a malformed project id is a refusal, not a driver error", async () => {
    const a = await makeAccount();
    expect(await createTask(pg.db, { ...owner(a), title: "x", projectId: "not-a-uuid" })).toEqual({
      kind: "project_not_found",
    });
  });

  test("closing at creation stamps closedAt", async () => {
    const a = await makeAccount();
    const created = ok(await createTask(pg.db, { ...owner(a), title: "x", status: "done" }));
    expect(created.task.closedAt).not.toBeNull();
  });
});

describe("assignee", () => {
  test("a member assignee clears every snapshot column in the same write", async () => {
    const a = await makeAccount();
    const created = ok(
      await createTask(pg.db, {
        ...owner(a),
        title: "x",
        assignee: { kind: "external", externalId: "42", login: "octocat", avatarUrl: "https://x" },
      })
    );

    const updated = ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: created.task.number,
        patch: { assignee: { kind: "member", userId: a.userId } },
      })
    );

    expect(updated.task.assignee).toEqual({ kind: "member", userId: a.userId });
    const row = await pg.db.task.findUniqueOrThrow({ where: { id: created.task.id } });
    expect(row.assigneeExternalId).toBeNull();
    expect(row.assigneeLogin).toBeNull();
    expect(row.assigneeAvatarUrl).toBeNull();
  });

  test("an external assignee clears the member column in the same write", async () => {
    const a = await makeAccount();
    const created = ok(
      await createTask(pg.db, {
        ...owner(a),
        title: "x",
        assignee: { kind: "member", userId: a.userId },
      })
    );

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: created.task.number,
        patch: { assignee: { kind: "external", externalId: "42", login: "octocat" } },
      })
    );

    const row = await pg.db.task.findUniqueOrThrow({ where: { id: created.task.id } });
    expect(row.assigneeUserId).toBeNull();
    expect(row.assigneeExternalId).toBe("42");
  });

  test("the CHECK constraint refuses both identities even from raw SQL", async () => {
    const a = await makeAccount();
    const created = ok(
      await createTask(pg.db, {
        ...owner(a),
        title: "x",
        assignee: { kind: "member", userId: a.userId },
      })
    );

    // The model is one writer among the several this feature will grow; the
    // constraint is what holds when the next one forgets.
    let refusal: unknown;
    try {
      await pg.db.$executeRawUnsafe(
        `UPDATE tasks SET assignee_external_id = '42' WHERE id = '${created.task.id}'`
      );
    } catch (err) {
      refusal = err;
    }
    expect(String(refusal)).toContain("tasks_assignee_one_identity_check");
  });

  test("a user who is not an active member cannot be assigned", async () => {
    const a = await makeAccount();
    const stranger = await makeAccount();

    expect(
      await createTask(pg.db, {
        ...owner(a),
        title: "x",
        assignee: { kind: "member", userId: stranger.userId },
      })
    ).toEqual({ kind: "assignee_not_member", userId: stranger.userId });
  });

  test("a teammate on the same account can be assigned", async () => {
    const a = await makeAccount();
    const mate = await createTestUser(pg.db);
    await addTestMember(pg.db, a.accountId, mate.id);

    const created = ok(
      await createTask(pg.db, { ...owner(a), title: "x", assignee: { kind: "member", userId: mate.id } })
    );
    expect(created.task.assignee).toEqual({ kind: "member", userId: mate.id });
  });
});

describe("reads and updates", () => {
  test("every read is anchored on the account", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    ok(await createTask(pg.db, { ...owner(a), title: "theirs" }));

    expect(await getTaskByNumber(pg.db, b.accountId, 1)).toBeNull();
    expect(await listTasks(pg.db, { accountId: b.accountId })).toEqual([]);
    expect(
      await updateTask(pg.db, { accountId: b.accountId, number: 1, patch: { title: "mine" } })
    ).toEqual({ kind: "not_found" });
    expect(await softDeleteTask(pg.db, { accountId: b.accountId, number: 1 })).toEqual({
      kind: "not_found",
    });
  });

  test("reopening clears closedAt and closing again re-stamps it", async () => {
    const a = await makeAccount();
    const created = ok(await createTask(pg.db, { ...owner(a), title: "x", status: "done" }));
    const number = created.task.number;

    const reopened = ok(
      await updateTask(pg.db, { accountId: a.accountId, number, patch: { status: "open" } })
    );
    expect(reopened.task.closedAt).toBeNull();

    const closed = ok(
      await updateTask(pg.db, { accountId: a.accountId, number, patch: { status: "cancelled" } })
    );
    expect(closed.task.closedAt).not.toBeNull();
  });

  test("re-filing to another project drops the labels that belonged to the old one", async () => {
    const a = await makeAccount();
    const home = await makeProject(a.accountId);
    const elsewhere = await makeProject(a.accountId);
    const scoped = ok(
      await getOrCreateLabel(pg.db, {
        accountId: a.accountId,
        projectId: home.id,
        name: "area/relay",
        color: "0e8a16",
      })
    );
    const wide = ok(
      await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "needs-triage", color: "ffffff" })
    );

    const created = ok(
      await createTask(pg.db, {
        ...owner(a),
        title: "x",
        projectId: home.id,
        labelIds: [scoped.label.id, wide.label.id],
      })
    );

    const moved = ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: created.task.number,
        patch: { projectId: elsewhere.id },
      })
    );
    expect(moved.task.labels.map((label) => label.name)).toEqual(["needs-triage"]);
  });

  test("a soft-deleted linked task is marked unlinked for the inbound filter to see", async () => {
    const a = await makeAccount();
    const created = ok(await createTask(pg.db, { ...owner(a), title: "x" }));
    await pg.db.task.update({
      where: { id: created.task.id },
      data: { externalProvider: "github", externalId: "123", syncState: "synced" },
    });

    expect(await softDeleteTask(pg.db, { accountId: a.accountId, number: created.task.number }))
      .toMatchObject({ kind: "ok" });

    const row = await pg.db.task.findUniqueOrThrow({ where: { id: created.task.id } });
    expect(row.deletedAt).not.toBeNull();
    expect(row.syncState).toBe("unlinked");
    expect(row.externalId).toBe("123");
  });
});

describe("ordering", () => {
  test("creates append, and a move reorders with one row write", async () => {
    const a = await makeAccount();
    const one = ok(await createTask(pg.db, { ...owner(a), title: "one" })).task;
    const two = ok(await createTask(pg.db, { ...owner(a), title: "two" })).task;
    const three = ok(await createTask(pg.db, { ...owner(a), title: "three" })).task;

    expect((await listTasks(pg.db, { accountId: a.accountId })).map((t) => t.title)).toEqual([
      "one",
      "two",
      "three",
    ]);

    const moved = ok(
      await moveTask(pg.db, {
        accountId: a.accountId,
        number: three.number,
        previousNumber: one.number,
        nextNumber: two.number,
      })
    );
    expect(moved.task.sortKey > one.sortKey).toBe(true);
    expect(moved.task.sortKey < two.sortKey).toBe(true);
    expect((await listTasks(pg.db, { accountId: a.accountId })).map((t) => t.title)).toEqual([
      "one",
      "three",
      "two",
    ]);
    // Only the moved row was rewritten.
    const untouched = await pg.db.task.findUniqueOrThrow({ where: { id: two.id } });
    expect(untouched.sortKey).toBe(two.sortKey);
  });

  test("a neighbour on another account is refused rather than ignored", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const mine = ok(await createTask(pg.db, { ...owner(a), title: "mine" })).task;
    ok(await createTask(pg.db, { ...owner(b), title: "theirs" }));

    expect(
      await moveTask(pg.db, {
        accountId: a.accountId,
        number: mine.number,
        previousNumber: 1,
        nextNumber: null,
      })
    ).not.toEqual({ kind: "not_found" });

    expect(
      await moveTask(pg.db, {
        accountId: a.accountId,
        number: mine.number,
        previousNumber: 99,
        nextNumber: null,
      })
    ).toEqual({ kind: "not_found" });
  });

  test("neighbours in the wrong order are a refusal, not a thrown SortKeyError", async () => {
    const a = await makeAccount();
    const one = ok(await createTask(pg.db, { ...owner(a), title: "one" })).task;
    const two = ok(await createTask(pg.db, { ...owner(a), title: "two" })).task;
    const three = ok(await createTask(pg.db, { ...owner(a), title: "three" })).task;

    expect(
      await moveTask(pg.db, {
        accountId: a.accountId,
        number: three.number,
        previousNumber: two.number,
        nextNumber: one.number,
      })
    ).toEqual({ kind: "neighbours_out_of_order" });

    // One number on both sides resolves to one key, which is the same hole.
    expect(
      await moveTask(pg.db, {
        accountId: a.accountId,
        number: three.number,
        previousNumber: one.number,
        nextNumber: one.number,
      })
    ).toEqual({ kind: "neighbours_out_of_order" });

    const untouched = await pg.db.task.findUniqueOrThrow({ where: { id: three.id } });
    expect(untouched.sortKey).toBe(three.sortKey);
  });

  test("the database orders sort keys the way JavaScript does", async () => {
    const a = await makeAccount();
    for (let i = 0; i < 30; i++) ok(await createTask(pg.db, { ...owner(a), title: `t${i}` }));
    // Prepend and interleave so the keys stop being uniform in length.
    const tasks = await listTasks(pg.db, { accountId: a.accountId });
    await moveTask(pg.db, {
      accountId: a.accountId,
      number: tasks[29]!.number,
      previousNumber: null,
      nextNumber: tasks[0]!.number,
    });
    await moveTask(pg.db, {
      accountId: a.accountId,
      number: tasks[15]!.number,
      previousNumber: tasks[0]!.number,
      nextNumber: tasks[1]!.number,
    });

    const ordered = await listTasks(pg.db, { accountId: a.accountId });
    const keys = ordered.map((t) => t.sortKey);
    expect([...keys].sort()).toEqual(keys);
  });
});

/**
 * The outbox seam: which local edits become a `TaskSyncOp` and which do not.
 *
 * Three gates decide it — linked, push-enabled, and a kind the outbox carries —
 * and each of the three is a separate promise to the user, so each is tested on
 * its own rather than through one happy path.
 */
describe("sync ops", () => {
  let installations = 0;

  type Repo = { integrationId: string; repoId: string };

  async function makeRepo(account: Account, pushEnabled: boolean): Promise<Repo> {
    const n = ++installations;
    const integration = await upsertIntegration(pg.db, {
      accountId: account.accountId,
      provider: "github",
      externalAccountId: `org-${n}`,
      installationId: `${n}`,
      displayName: "acme",
      installedBy: account.userId,
    });
    if (integration.kind !== "ok") throw new Error(`upsertIntegration: ${integration.kind}`);
    const repo = await upsertIntegrationRepo(pg.db, {
      accountId: account.accountId,
      integrationId: integration.integration.id,
      repoKey: `github.com/acme/repo-${n}`,
      externalRepoId: `${n}`,
      visibility: "private",
      syncEnabled: true,
      pushEnabled,
    });
    if (repo.kind !== "ok") throw new Error(`upsertIntegrationRepo: ${repo.kind}`);
    return { integrationId: integration.integration.id, repoId: repo.repo.id };
  }

  /** What the inbound importer leaves on a task it linked — the external
   *  columns plus the repository the issue lives in. */
  async function link(taskId: string, repo: Repo, syncState = "synced"): Promise<void> {
    await pg.db.task.update({
      where: { id: taskId },
      data: {
        integrationRepoId: repo.repoId,
        externalProvider: "github",
        externalId: crypto.randomUUID(),
        externalKey: "acme/repo#1",
        syncState,
      },
    });
  }

  async function linkedTask(
    account: Account,
    pushEnabled: boolean,
    args: { title?: string; body?: string; status?: TaskStatus } = {}
  ) {
    const repo = await makeRepo(account, pushEnabled);
    const created = ok(
      await createTask(pg.db, {
        ...owner(account),
        title: args.title ?? "linked",
        body: args.body,
        status: args.status,
      })
    ).task;
    await link(created.id, repo);
    return { task: created, repo };
  }

  async function ops(taskId: string) {
    return pg.db.taskSyncOp.findMany({ where: { taskId }, orderBy: { seq: "asc" } });
  }

  test("an edit to an unlinked task enqueues nothing", async () => {
    const a = await makeAccount();
    const created = ok(await createTask(pg.db, { ...owner(a), title: "local only" })).task;

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: created.number,
        patch: { title: "renamed" },
      })
    );

    expect(await ops(created.id)).toEqual([]);
  });

  test("a linked task whose repo has pushEnabled off enqueues nothing", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, false);

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { title: "renamed" },
      })
    );

    expect(await ops(task.id)).toEqual([]);
  });

  test("an unlinked tombstone still carrying its external columns enqueues nothing", async () => {
    const a = await makeAccount();
    const { task, repo } = await linkedTask(a, true);
    await link(task.id, repo, "unlinked");

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { title: "renamed" },
      })
    );

    expect(await ops(task.id)).toEqual([]);
  });

  test("a title edit on a linked push-enabled task queues exactly one op", async () => {
    const a = await makeAccount();
    const { task, repo } = await linkedTask(a, true);

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { title: "renamed" },
      })
    );

    const queued = await ops(task.id);
    expect(queued).toHaveLength(1);
    expect(queued[0]!.kind).toBe("issue.patch.title");
    expect(queued[0]!.payload).toEqual({ kind: "issue.patch.title", title: "renamed" });
    expect(queued[0]!.integrationId).toBe(repo.integrationId);
    expect(queued[0]!.provider).toBe("github");
    expect(queued[0]!.status).toBe("pending");
  });

  test("a status edit is queued in provider space, never Antgrid vocabulary", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true);

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { status: "cancelled" },
      })
    );

    const queued = await ops(task.id);
    expect(queued).toHaveLength(1);
    expect(queued[0]!.payload).toEqual({
      kind: "issue.state",
      state: "closed",
      stateReason: "not_planned",
    });
  });

  // The cheapest available test for the no-op push loop: `in_progress` and
  // `blocked` both project onto GitHub `open`, and both are what the automatic
  // status writers move between. An op here means the provider-space rule has
  // been lost somewhere.
  test("a status move within one provider state queues nothing", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true, { status: "in_progress" });

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { status: "blocked" },
      })
    );

    expect(await ops(task.id)).toEqual([]);
  });

  test("an assignee change enqueues nothing", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true);

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { assignee: { kind: "member", userId: a.userId } },
      })
    );

    expect(await ops(task.id)).toEqual([]);
  });

  test("a labels edit queues the whole current set", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true);
    const bug = ok(
      await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "ff0000" })
    ).label;
    const chore = ok(
      await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "chore", color: "00ff00" })
    ).label;

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { labelIds: [bug.id, chore.id] },
      })
    );

    const queued = await ops(task.id);
    expect(queued).toHaveLength(1);
    expect(queued[0]!.kind).toBe("issue.labels");
    const payload = queued[0]!.payload as { kind: string; labels: string[] };
    expect(payload.kind).toBe("issue.labels");
    expect([...payload.labels].sort()).toEqual(["bug", "chore"]);
  });

  test("a patch restating the values it is not changing queues nothing", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true, { title: "same", body: "unchanged" });

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { title: "same", body: "unchanged", status: "open" },
      })
    );

    expect(await ops(task.id)).toEqual([]);
  });

  test("two edits of one field supersede rather than queue", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true);

    for (const title of ["first", "second"]) {
      ok(
        await updateTask(pg.db, { accountId: a.accountId, number: task.number, patch: { title } })
      );
    }

    const queued = await ops(task.id);
    expect(queued).toHaveLength(1);
    expect(queued[0]!.seq).toBe(1);
    expect(queued[0]!.payload).toEqual({ kind: "issue.patch.title", title: "second" });
  });

  test("edits to two fields queue two ops with increasing seq", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true);

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { title: "renamed" },
      })
    );
    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { body: "rewritten" },
      })
    );

    const queued = await ops(task.id);
    expect(queued.map((op) => op.kind)).toEqual(["issue.patch.title", "issue.patch.body"]);
    expect(queued.map((op) => op.seq)).toEqual([1, 2]);
  });

  test("one patch touching several fields queues one op each", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true);

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { title: "renamed", body: "rewritten", status: "done" },
      })
    );

    const queued = await ops(task.id);
    expect(queued.map((op) => op.kind)).toEqual([
      "issue.patch.title",
      "issue.patch.body",
      "issue.state",
    ]);
  });

  test("a task linked to another account's repo enqueues nothing", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const foreign = await makeRepo(b, true);
    const created = ok(await createTask(pg.db, { ...owner(a), title: "x" })).task;
    await link(created.id, foreign);

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: created.number,
        patch: { title: "renamed" },
      })
    );

    expect(await ops(created.id)).toEqual([]);
  });

  test("a delete cancels the pending ops and reports no kept create", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true);
    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { title: "renamed" },
      })
    );

    const deleted = await softDeleteTask(pg.db, { accountId: a.accountId, number: task.number });
    expect(deleted).toEqual({ kind: "ok", keptCreate: null });
    expect((await ops(task.id)).map((op) => op.status)).toEqual(["cancelled"]);
  });

  test("a delete keeps an already-attempted create and hands it back", async () => {
    const a = await makeAccount();
    const { task, repo } = await linkedTask(a, true);
    await pg.db.taskSyncOp.create({
      data: {
        taskId: task.id,
        integrationId: repo.integrationId,
        provider: "github",
        kind: "issue.create",
        payload: {
          kind: "issue.create",
          title: "x",
          body: "",
          state: "open",
          stateReason: null,
          labels: [],
        },
        opKey: "deadbeef",
        seq: 1,
        status: "pending",
        attemptedAt: new Date(),
      },
    });

    const deleted = await softDeleteTask(pg.db, { accountId: a.accountId, number: task.number });
    if (deleted.kind !== "ok") throw new Error(deleted.kind);
    expect(deleted.keptCreate).toEqual({ id: expect.any(String), opKey: "deadbeef" });
    expect((await ops(task.id)).map((op) => op.status)).toEqual(["pending"]);
  });


  test("a revoked installation enqueues nothing, from any path", async () => {
    const a = await makeAccount();
    const { task, repo } = await linkedTask(a, true);
    const bug = ok(
      await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "ff0000" })
    ).label;
    await pg.db.integration.update({
      where: { id: repo.integrationId },
      data: { revokedAt: new Date() },
    });

    ok(
      await updateTask(pg.db, {
        accountId: a.accountId,
        number: task.number,
        patch: { title: "renamed" },
      })
    );
    expect(
      await attachLabel(pg.db, { accountId: a.accountId, taskId: task.id, labelId: bug.id })
    ).toEqual({ kind: "ok" });

    expect(await ops(task.id)).toEqual([]);
  });

  // The label popover writes through `models/label.ts` rather than `updateTask`,
  // and the two must be indistinguishable from outside: a push that depends on
  // which screen the user changed the label from is one nobody can predict.
  test("a label popover replace queues one op with the whole set", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true);
    const bug = ok(
      await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "ff0000" })
    ).label;
    const chore = ok(
      await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "chore", color: "00ff00" })
    ).label;

    expect(
      await setTaskLabels(pg.db, {
        accountId: a.accountId,
        taskId: task.id,
        labelIds: [bug.id, chore.id],
      })
    ).toEqual({ kind: "ok" });

    const queued = await ops(task.id);
    expect(queued).toHaveLength(1);
    expect(queued[0]!.kind).toBe("issue.labels");
    const payload = queued[0]!.payload as { labels: string[] };
    expect([...payload.labels].sort()).toEqual(["bug", "chore"]);
  });

  test("a label popover replace on a pushEnabled-off repo queues nothing", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, false);
    const bug = ok(
      await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "ff0000" })
    ).label;

    expect(
      await setTaskLabels(pg.db, { accountId: a.accountId, taskId: task.id, labelIds: [bug.id] })
    ).toEqual({ kind: "ok" });

    expect(await ops(task.id)).toEqual([]);
  });

  test("attach then detach queues the whole set each time, superseding", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true);
    const bug = ok(
      await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "ff0000" })
    ).label;
    const chore = ok(
      await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "chore", color: "00ff00" })
    ).label;

    await attachLabel(pg.db, { accountId: a.accountId, taskId: task.id, labelId: bug.id });
    await attachLabel(pg.db, { accountId: a.accountId, taskId: task.id, labelId: chore.id });
    await detachLabel(pg.db, { accountId: a.accountId, taskId: task.id, labelId: bug.id });

    const queued = await ops(task.id);
    expect(queued).toHaveLength(1);
    expect(queued[0]!.seq).toBe(1);
    expect((queued[0]!.payload as { labels: string[] }).labels).toEqual(["chore"]);
  });

  test("a label write that does not move the set queues nothing", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true);
    const bug = ok(
      await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "ff0000" })
    ).label;
    await attachLabel(pg.db, { accountId: a.accountId, taskId: task.id, labelId: bug.id });
    await pg.db.taskSyncOp.deleteMany({ where: { taskId: task.id } });

    // A double-tap, and a detach of a label the task never had.
    await attachLabel(pg.db, { accountId: a.accountId, taskId: task.id, labelId: bug.id });
    await detachLabel(pg.db, {
      accountId: a.accountId,
      taskId: task.id,
      labelId: crypto.randomUUID(),
    });

    expect(await ops(task.id)).toEqual([]);
  });

  // Taking the local value leaves the row deliberately ahead of
  // `remoteSnapshot`, and nothing but an op ever sends it: without this the
  // field the user adjudicated diverges permanently.
  test("resolving a conflict onto the local value queues the push", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true, { title: "remote won" });
    await pg.db.task.update({
      where: { id: task.id },
      data: { syncState: "conflict" },
    });

    const resolved = await resolveTaskConflict(pg.db, {
      accountId: a.accountId,
      number: task.number,
      decide: () => ({
        kind: "write",
        patch: { field: "title", value: "mine" },
        nextConflict: null,
        conflictsRemain: false,
      }),
    });
    if (resolved.kind !== "ok") throw new Error(resolved.kind);

    const queued = await ops(task.id);
    expect(queued).toHaveLength(1);
    expect(queued[0]!.payload).toEqual({ kind: "issue.patch.title", title: "mine" });
  });

  test("resolving a conflict onto the remote value queues nothing", async () => {
    const a = await makeAccount();
    const { task } = await linkedTask(a, true, { title: "remote won" });
    await pg.db.task.update({ where: { id: task.id }, data: { syncState: "conflict" } });

    const resolved = await resolveTaskConflict(pg.db, {
      accountId: a.accountId,
      number: task.number,
      decide: () => ({ kind: "write", patch: null, nextConflict: null, conflictsRemain: false }),
    });
    if (resolved.kind !== "ok") throw new Error(resolved.kind);

    expect(await ops(task.id)).toEqual([]);
  });
});

function owner(account: Account): { accountId: string; createdBy: string } {
  return { accountId: account.accountId, createdBy: account.userId };
}
