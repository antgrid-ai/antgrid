import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser, createTestSubscription } from "../helpers/fixtures.js";
import {
  attachLabel,
  deleteLabel,
  detachLabel,
  getOrCreateLabel,
  listLabels,
  setTaskLabels,
} from "../../src/models/label.js";
import { createTask, getTaskByNumber } from "../../src/models/task.js";

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

async function makeProject(accountId: string) {
  return pg.db.project.create({
    data: { accountId, repoKey: `github.com/acme/${crypto.randomUUID()}`, displayName: "acme" },
    select: { id: true },
  });
}

function ok<T extends { kind: string }>(result: T): Extract<T, { kind: "ok" }> {
  expect(result.kind).toBe("ok");
  return result as Extract<T, { kind: "ok" }>;
}

async function refusal(write: () => Promise<unknown>): Promise<string> {
  try {
    await write();
  } catch (err) {
    return String(err);
  }
  return "";
}

describe("getOrCreateLabel", () => {
  test("names fold case, so Bug and bug are one label", async () => {
    const a = await makeAccount();
    const first = ok(await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "Bug", color: "d73a4a" }));
    const second = ok(await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "000000" }));

    expect(second.created).toBe(false);
    expect(second.label.id).toBe(first.label.id);
    // The first spelling wins; the second call is a lookup, not an edit.
    expect(second.label.name).toBe("Bug");
    expect(await pg.db.label.count({ where: { accountId: a.accountId } })).toBe(1);
  });

  test("one account's label is not another's", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const mine = ok(await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "d73a4a" }));
    const theirs = ok(await getOrCreateLabel(pg.db, { accountId: b.accountId, name: "bug", color: "d73a4a" }));

    expect(theirs.created).toBe(true);
    expect(theirs.label.id).not.toBe(mine.label.id);
  });

  test("an account-wide and a project-scoped label may share a name", async () => {
    const a = await makeAccount();
    const project = await makeProject(a.accountId);

    const wide = ok(await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "d73a4a" }));
    const scoped = ok(
      await getOrCreateLabel(pg.db, {
        accountId: a.accountId,
        projectId: project.id,
        name: "bug",
        color: "d73a4a",
      })
    );

    expect(scoped.created).toBe(true);
    expect(scoped.label.id).not.toBe(wide.label.id);
  });

  test("a project belonging to another account is refused", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const foreign = await makeProject(b.accountId);

    expect(
      await getOrCreateLabel(pg.db, {
        accountId: a.accountId,
        projectId: foreign.id,
        name: "bug",
        color: "d73a4a",
      })
    ).toEqual({ kind: "project_not_found" });
    expect(await pg.db.label.count()).toBe(0);
  });

  test("a colour that is not six hex digits is refused", async () => {
    const a = await makeAccount();
    expect(await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "#d73a4a" }))
      .toEqual({ kind: "invalid_color" });
    expect(await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "  ", color: "d73a4a" }))
      .toEqual({ kind: "invalid_name" });
  });
});

describe("the indexes behind the model", () => {
  test("two account-wide labels of one name collide", async () => {
    const a = await makeAccount();
    await pg.db.label.create({ data: { accountId: a.accountId, name: "needs-triage", color: "ffffff" } });

    // `@@unique([accountId, projectId, name])` cannot reach this pair —
    // project_id is null and NULL != NULL — so the partial index is the only
    // thing standing between two rows the UI would render twice.
    const message = await refusal(() =>
      pg.db.label.create({ data: { accountId: a.accountId, name: "needs-triage", color: "000000" } })
    );
    expect(message).toContain("Unique constraint failed on the fields: (`account_id`, `name`)");
  });

  test("the account-wide collision folds case too", async () => {
    const a = await makeAccount();
    await pg.db.label.create({ data: { accountId: a.accountId, name: "Needs-Triage", color: "ffffff" } });

    const message = await refusal(() =>
      pg.db.label.create({ data: { accountId: a.accountId, name: "needs-triage", color: "000000" } })
    );
    expect(message).toContain("Unique constraint failed on the fields: (`account_id`, `name`)");
  });

  test("two labels of one name in one project collide", async () => {
    const a = await makeAccount();
    const project = await makeProject(a.accountId);
    await pg.db.label.create({
      data: { accountId: a.accountId, projectId: project.id, name: "area/relay", color: "ffffff" },
    });

    const message = await refusal(() =>
      pg.db.label.create({
        data: { accountId: a.accountId, projectId: project.id, name: "AREA/RELAY", color: "000000" },
      })
    );
    expect(message).toContain("Unique constraint failed on the fields: (`account_id`, `project_id`, `name`)");
  });

  test("deleting a project takes its labels rather than orphaning them", async () => {
    const a = await makeAccount();
    const project = await makeProject(a.accountId);
    // Same name account-wide, which is exactly the pair that would collide if
    // the project delete tried to null the scope out.
    await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "d73a4a" });
    await getOrCreateLabel(pg.db, {
      accountId: a.accountId,
      projectId: project.id,
      name: "bug",
      color: "d73a4a",
    });

    await pg.db.project.delete({ where: { id: project.id } });

    const left = await pg.db.label.findMany({ where: { accountId: a.accountId } });
    expect(left.map((label) => label.projectId)).toEqual([null]);
  });
});

describe("listLabels", () => {
  test("a project sees its own labels plus the account-wide ones", async () => {
    const a = await makeAccount();
    const mine = await makeProject(a.accountId);
    const other = await makeProject(a.accountId);
    await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "needs-triage", color: "ffffff" });
    await getOrCreateLabel(pg.db, {
      accountId: a.accountId,
      projectId: mine.id,
      name: "area/relay",
      color: "0e8a16",
    });
    await getOrCreateLabel(pg.db, {
      accountId: a.accountId,
      projectId: other.id,
      name: "area/app",
      color: "0e8a16",
    });

    expect((await listLabels(pg.db, { accountId: a.accountId, projectId: mine.id })).map((l) => l.name))
      .toEqual(["area/relay", "needs-triage"]);
    // A task with no project can only use the account-wide vocabulary.
    expect((await listLabels(pg.db, { accountId: a.accountId })).map((l) => l.name))
      .toEqual(["needs-triage"]);
  });

  test("labels never cross an account boundary", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    await getOrCreateLabel(pg.db, { accountId: b.accountId, name: "theirs", color: "ffffff" });

    expect(await listLabels(pg.db, { accountId: a.accountId })).toEqual([]);
  });
});

describe("attach and detach", () => {
  test("a label from another account is refused rather than attached", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const task = ok(await createTask(pg.db, { accountId: a.accountId, createdBy: a.userId, title: "x" }));
    const foreign = ok(await getOrCreateLabel(pg.db, { accountId: b.accountId, name: "bug", color: "d73a4a" }));

    expect(await attachLabel(pg.db, { accountId: a.accountId, taskId: task.task.id, labelId: foreign.label.id }))
      .toEqual({ kind: "label_not_found", labelId: foreign.label.id });
    expect(await pg.db.taskLabel.count()).toBe(0);
  });

  test("a task from another account is refused rather than relabelled", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const task = ok(await createTask(pg.db, { accountId: a.accountId, createdBy: a.userId, title: "x" }));
    const theirs = ok(await getOrCreateLabel(pg.db, { accountId: b.accountId, name: "bug", color: "d73a4a" }));

    expect(await attachLabel(pg.db, { accountId: b.accountId, taskId: task.task.id, labelId: theirs.label.id }))
      .toEqual({ kind: "task_not_found" });
  });

  test("attaching twice and detaching what is not there are both no-ops", async () => {
    const a = await makeAccount();
    const task = ok(await createTask(pg.db, { accountId: a.accountId, createdBy: a.userId, title: "x" }));
    const label = ok(await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "d73a4a" }));
    const attach = { accountId: a.accountId, taskId: task.task.id, labelId: label.label.id };

    expect(await attachLabel(pg.db, attach)).toEqual({ kind: "ok" });
    expect(await attachLabel(pg.db, attach)).toEqual({ kind: "ok" });
    expect(await pg.db.taskLabel.count()).toBe(1);

    expect(await detachLabel(pg.db, attach)).toEqual({ kind: "ok" });
    expect(await detachLabel(pg.db, attach)).toEqual({ kind: "ok" });
    expect(await pg.db.taskLabel.count()).toBe(0);
  });

  test("setting the whole set replaces it, and refuses the set wholesale", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const task = ok(await createTask(pg.db, { accountId: a.accountId, createdBy: a.userId, title: "x" }));
    const one = ok(await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "d73a4a" }));
    const two = ok(await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "chore", color: "0e8a16" }));
    const foreign = ok(await getOrCreateLabel(pg.db, { accountId: b.accountId, name: "bug", color: "d73a4a" }));

    ok(await setTaskLabels(pg.db, { accountId: a.accountId, taskId: task.task.id, labelIds: [one.label.id] }));
    ok(await setTaskLabels(pg.db, { accountId: a.accountId, taskId: task.task.id, labelIds: [two.label.id] }));

    const after = await getTaskByNumber(pg.db, a.accountId, task.task.number);
    expect(after?.labels.map((label) => label.name)).toEqual(["chore"]);

    // One foreign id refuses the whole write; a partial apply would be worse
    // than a refusal.
    expect(
      await setTaskLabels(pg.db, {
        accountId: a.accountId,
        taskId: task.task.id,
        labelIds: [one.label.id, foreign.label.id],
      })
    ).toEqual({ kind: "label_not_found", labelId: foreign.label.id });
    expect((await getTaskByNumber(pg.db, a.accountId, task.task.number))?.labels.map((l) => l.name))
      .toEqual(["chore"]);
  });

  test("deleting a label takes it off every task", async () => {
    const a = await makeAccount();
    const task = ok(await createTask(pg.db, { accountId: a.accountId, createdBy: a.userId, title: "x" }));
    const label = ok(await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "d73a4a" }));
    ok(await attachLabel(pg.db, { accountId: a.accountId, taskId: task.task.id, labelId: label.label.id }));

    expect(await deleteLabel(pg.db, { accountId: a.accountId, labelId: label.label.id })).toBe(true);
    expect(await pg.db.taskLabel.count()).toBe(0);
  });

  test("another account cannot delete a label", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const label = ok(await getOrCreateLabel(pg.db, { accountId: a.accountId, name: "bug", color: "d73a4a" }));

    expect(await deleteLabel(pg.db, { accountId: b.accountId, labelId: label.label.id })).toBe(false);
    expect(await pg.db.label.count()).toBe(1);
  });
});
