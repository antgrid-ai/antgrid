import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestSession, createTestSubscription, createTestUser } from "../helpers/fixtures.js";

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

type App = ReturnType<typeof buildTestApp>["app"];

async function setupCaller(app: App, email: string) {
  const user = await createTestUser(pg.db, email);
  await createTestSubscription(pg.db, user.id, { tier: "pro" });
  const { cookie } = await createTestSession(pg.db, user.id);
  const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
  return {
    user,
    accountId: account.id,
    headers: { cookie, "content-type": "application/json" } as Record<string, string>,
  };
}

function post(app: App, path: string, headers: Record<string, string>, body: unknown) {
  return app.request(path, { method: "POST", headers, body: JSON.stringify(body) });
}
function put(app: App, path: string, headers: Record<string, string>, body: unknown) {
  return app.request(path, { method: "PUT", headers, body: JSON.stringify(body) });
}

async function makeProject(accountId: string) {
  return pg.db.project.create({
    data: { accountId, repoKey: `github.com/acme/${crypto.randomUUID()}`, displayName: "acme" },
    select: { id: true },
  });
}

async function createTask(
  app: App,
  headers: Record<string, string>,
  body: Record<string, unknown>
): Promise<number> {
  const res = await post(app, "/tasks", headers, { publish: false, ...body });
  if (res.status !== 201) throw new Error(`create failed: ${res.status} ${await res.text()}`);
  return ((await res.json()) as { task: { number: number } }).task.number;
}

async function createLabel(
  app: App,
  headers: Record<string, string>,
  body: Record<string, unknown>
): Promise<{ id: string; name: string }> {
  const res = await post(app, "/labels", headers, body);
  if (res.status !== 201) throw new Error(`label failed: ${res.status} ${await res.text()}`);
  return ((await res.json()) as { label: { id: string; name: string } }).label;
}

async function errorOf(res: Response): Promise<string> {
  return ((await res.json()) as { error: string }).error;
}

async function labelNamesOn(app: App, headers: Record<string, string>, number: number) {
  const res = await app.request(`/tasks/${number}`, { headers });
  expect(res.status).toBe(200);
  const { task } = (await res.json()) as { task: { labels: { name: string }[] } };
  return task.labels.map((label) => label.name).sort();
}

describe("label routes", () => {
  test("create is get-or-create, and case folds", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { headers } = await setupCaller(app, "labels@example.com");

    const first = await post(app, "/labels", headers, { name: "bug", color: "d73a4a" });
    expect(first.status).toBe(201);
    const created = ((await first.json()) as { label: { id: string } }).label;

    // Same label, different capitalisation: CITEXT means one row, and the
    // caller that already holds it gets a 200 rather than a conflict.
    const again = await post(app, "/labels", headers, { name: "BUG", color: "ffffff" });
    expect(again.status).toBe(200);
    expect(((await again.json()) as { label: { id: string } }).label.id).toBe(created.id);
    expect(await pg.db.label.count()).toBe(1);
  });

  test("list returns the account-wide vocabulary plus the named project's", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "list-labels@example.com");
    const project = await makeProject(caller.accountId);
    const other = await makeProject(caller.accountId);
    await createLabel(app, caller.headers, { name: "needs-triage", color: "ededed" });
    await createLabel(app, caller.headers, {
      name: "area/relay",
      color: "0e8a16",
      projectId: project.id,
    });
    await createLabel(app, caller.headers, {
      name: "area/app",
      color: "0e8a16",
      projectId: other.id,
    });

    const names = async (query: string) => {
      const res = await app.request(`/labels${query}`, { headers: caller.headers });
      expect(res.status).toBe(200);
      const { labels } = (await res.json()) as { labels: { name: string }[] };
      return labels.map((label) => label.name).sort();
    };

    expect(await names("")).toEqual(["needs-triage"]);
    expect(await names(`?projectId=${project.id}`)).toEqual(["area/relay", "needs-triage"]);
  });

  test("another account's label is invisible and undeletable", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const owner = await setupCaller(app, "owner-labels@example.com");
    const stranger = await setupCaller(app, "stranger-labels@example.com");
    const label = await createLabel(app, owner.headers, { name: "secret", color: "000000" });

    const list = await app.request("/labels", { headers: stranger.headers });
    expect(((await list.json()) as { labels: unknown[] }).labels).toEqual([]);

    const res = await app.request(`/labels/${label.id}`, {
      method: "DELETE",
      headers: stranger.headers,
    });
    expect(res.status).toBe(404);
    expect(await pg.db.label.count()).toBe(1);
  });

  test("delete removes the label from every task carrying it", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "delete-label@example.com");
    const label = await createLabel(app, caller.headers, { name: "wip", color: "cccccc" });
    const number = await createTask(app, caller.headers, { title: "t", labelIds: [label.id] });
    expect(await labelNamesOn(app, caller.headers, number)).toEqual(["wip"]);

    const res = await app.request(`/labels/${label.id}`, {
      method: "DELETE",
      headers: caller.headers,
    });
    expect(res.status).toBe(200);
    expect(await labelNamesOn(app, caller.headers, number)).toEqual([]);
  });

  test("each label refusal maps to its own code", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "label-refusals@example.com");
    const stranger = await setupCaller(app, "label-stranger@example.com");
    const foreign = await makeProject(stranger.accountId);

    const badName = await post(app, "/labels", caller.headers, { name: "  ", color: "ffffff" });
    expect(badName.status).toBe(400);
    expect(await errorOf(badName)).toBe("INVALID_LABEL_NAME");

    const badColor = await post(app, "/labels", caller.headers, { name: "bug", color: "#fff" });
    expect(badColor.status).toBe(400);
    expect(await errorOf(badColor)).toBe("INVALID_LABEL_COLOR");

    const badProject = await post(app, "/labels", caller.headers, {
      name: "bug",
      color: "ffffff",
      projectId: foreign.id,
    });
    expect(badProject.status).toBe(400);
    expect(await errorOf(badProject)).toBe("PROJECT_NOT_FOUND");

    const malformed = await post(app, "/labels", caller.headers, { color: "ffffff" });
    expect(malformed.status).toBe(400);
    expect(await errorOf(malformed)).toBe("BAD_REQUEST");

    const badQuery = await app.request("/labels?projectId=nope", { headers: caller.headers });
    expect(badQuery.status).toBe(400);
  });
});

describe("task label verbs", () => {
  test("attach, detach and set all answer with the task", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "attach@example.com");
    const bug = await createLabel(app, caller.headers, { name: "bug", color: "d73a4a" });
    const chore = await createLabel(app, caller.headers, { name: "chore", color: "cfd3d7" });
    const number = await createTask(app, caller.headers, { title: "t" });

    const attached = await post(app, `/tasks/${number}/labels`, caller.headers, {
      labelId: bug.id,
    });
    expect(attached.status).toBe(200);
    const { task } = (await attached.json()) as { task: { labels: { name: string }[] } };
    expect(task.labels.map((label) => label.name)).toEqual(["bug"]);

    // Re-attaching is a no-op, because the UI toggles and a double-tap is not a
    // failure.
    expect(
      (await post(app, `/tasks/${number}/labels`, caller.headers, { labelId: bug.id })).status
    ).toBe(200);
    expect(await labelNamesOn(app, caller.headers, number)).toEqual(["bug"]);

    const set = await put(app, `/tasks/${number}/labels`, caller.headers, {
      labelIds: [chore.id],
    });
    expect(set.status).toBe(200);
    expect(await labelNamesOn(app, caller.headers, number)).toEqual(["chore"]);

    const detached = await app.request(`/tasks/${number}/labels/${chore.id}`, {
      method: "DELETE",
      headers: caller.headers,
    });
    expect(detached.status).toBe(200);
    expect(await labelNamesOn(app, caller.headers, number)).toEqual([]);
  });

  test("label_not_found is LABEL_NOT_FOUND, including for another account's label", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "notfound@example.com");
    const stranger = await setupCaller(app, "notfound-stranger@example.com");
    const foreign = await createLabel(app, stranger.headers, { name: "theirs", color: "ffffff" });
    const number = await createTask(app, caller.headers, { title: "t" });

    const unknown = crypto.randomUUID();
    for (const labelId of [unknown, foreign.id]) {
      const res = await post(app, `/tasks/${number}/labels`, caller.headers, { labelId });
      expect(res.status).toBe(400);
      const body = (await res.json()) as { error: string; labelId: string };
      expect(body.error).toBe("LABEL_NOT_FOUND");
      expect(body.labelId).toBe(labelId);

      const setRes = await put(app, `/tasks/${number}/labels`, caller.headers, {
        labelIds: [labelId],
      });
      expect(setRes.status).toBe(400);
      expect(await errorOf(setRes)).toBe("LABEL_NOT_FOUND");
    }
    expect(await pg.db.taskLabel.count()).toBe(0);
  });

  test("label_out_of_scope refuses another project's label on this task", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "scope@example.com");
    const relay = await makeProject(caller.accountId);
    const web = await makeProject(caller.accountId);
    const areaRelay = await createLabel(app, caller.headers, {
      name: "area/relay",
      color: "0e8a16",
      projectId: relay.id,
    });
    const number = await createTask(app, caller.headers, { title: "t", projectId: web.id });

    const res = await post(app, `/tasks/${number}/labels`, caller.headers, {
      labelId: areaRelay.id,
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string; labelId: string };
    expect(body.error).toBe("LABEL_OUT_OF_SCOPE");
    expect(body.labelId).toBe(areaRelay.id);

    const onCreate = await post(app, "/tasks", caller.headers, {
      title: "another",
      projectId: web.id,
      labelIds: [areaRelay.id],
      publish: false,
    });
    expect(onCreate.status).toBe(400);
    expect(await errorOf(onCreate)).toBe("LABEL_OUT_OF_SCOPE");
  });

  test("the label verbs refuse a task number belonging to another account", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const victim = await setupCaller(app, "victim-labels@example.com");
    const attacker = await setupCaller(app, "attacker-labels@example.com");
    await createTask(app, victim.headers, { title: "theirs" });
    const label = await createLabel(app, attacker.headers, { name: "mine", color: "ffffff" });

    const attach = await post(app, "/tasks/1/labels", attacker.headers, { labelId: label.id });
    expect(attach.status).toBe(404);

    const set = await put(app, "/tasks/1/labels", attacker.headers, { labelIds: [label.id] });
    expect(set.status).toBe(404);

    const detach = await app.request(`/tasks/1/labels/${label.id}`, {
      method: "DELETE",
      headers: attacker.headers,
    });
    expect(detach.status).toBe(404);
    expect(await pg.db.taskLabel.count()).toBe(0);
  });

  test("a malformed label body is a 400", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller(app, "malformed-labels@example.com");
    const number = await createTask(app, caller.headers, { title: "t" });

    const attach = await post(app, `/tasks/${number}/labels`, caller.headers, { labelId: "nope" });
    expect(attach.status).toBe(400);
    expect(await errorOf(attach)).toBe("BAD_REQUEST");

    const set = await put(app, `/tasks/${number}/labels`, caller.headers, { labelIds: "bug" });
    expect(set.status).toBe(400);
    expect(await errorOf(set)).toBe("BAD_REQUEST");

    // Detach takes its label id from the path, so a malformed one is refused by
    // the model rather than by the body schema.
    const detach = await app.request(`/tasks/${number}/labels/nope`, {
      method: "DELETE",
      headers: caller.headers,
    });
    expect(detach.status).toBe(400);
    expect(await errorOf(detach)).toBe("LABEL_NOT_FOUND");
  });
});
