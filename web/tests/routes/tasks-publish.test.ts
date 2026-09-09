import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestSession, createTestSubscription, createTestUser } from "../helpers/fixtures.js";
import { upsertIntegration, upsertIntegrationRepo } from "../../src/models/integration.js";

/**
 * Publishing a local task to GitHub, over HTTP.
 *
 * The property the whole suite is built around: **nothing publishes that the
 * caller did not ask to publish, in a repository the caller was shown.** So the
 * refusals matter more than the happy path — a create that falls back to a
 * default, or that picks one of several repositories on the caller's behalf,
 * posts a private note into a public repository and cannot be undone.
 */

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

type Caller = {
  userId: string;
  accountId: string;
  headers: Record<string, string>;
};

let installations = 0;

async function setupCaller(email?: string): Promise<Caller> {
  const user = await createTestUser(pg.db, email);
  await createTestSubscription(pg.db, user.id, { tier: "pro" });
  const { cookie } = await createTestSession(pg.db, user.id);
  const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
  return {
    userId: user.id,
    accountId: account.id,
    headers: { cookie, "content-type": "application/json" },
  };
}

async function makeProject(accountId: string) {
  return pg.db.project.create({
    data: { accountId, repoKey: `github.com/acme/${crypto.randomUUID()}`, displayName: "acme" },
    select: { id: true },
  });
}

async function makeIntegration(caller: Caller): Promise<string> {
  const result = await upsertIntegration(pg.db, {
    accountId: caller.accountId,
    provider: "github",
    externalAccountId: `org-${++installations}`,
    installationId: `${installations}`,
    displayName: "acme",
    installedBy: caller.userId,
  });
  if (result.kind !== "ok") throw new Error(`upsertIntegration: ${result.kind}`);
  return result.integration.id;
}

/** A repository qualifying as a publish target unless a test says otherwise —
 *  `pushEnabled` on, a live installation, still present, bound to a project. */
async function makeRepo(
  caller: Caller,
  args: {
    integrationId: string;
    projectId: string | null;
    name: string;
    pushEnabled?: boolean;
    visibility?: "public" | "private";
    publishNewByDefault?: boolean;
  }
): Promise<string> {
  const result = await upsertIntegrationRepo(pg.db, {
    accountId: caller.accountId,
    integrationId: args.integrationId,
    repoKey: `github.com/acme/${args.name}`,
    externalRepoId: `ext-${args.name}-${crypto.randomUUID()}`,
    projectId: args.projectId,
    visibility: args.visibility ?? "private",
    syncEnabled: true,
    pushEnabled: args.pushEnabled ?? true,
    publishNewByDefault: args.publishNewByDefault ?? false,
  });
  if (result.kind !== "ok") throw new Error(`upsertIntegrationRepo: ${result.kind}`);
  return result.repo.id;
}

function post(app: App, path: string, caller: Caller, body: unknown) {
  return app.request(path, {
    method: "POST",
    headers: caller.headers,
    body: JSON.stringify(body),
  });
}

async function errorOf(res: Response): Promise<string> {
  return ((await res.json()) as { error: string }).error;
}

async function taskRow(number = 1) {
  return pg.db.task.findFirstOrThrow({ where: { number } });
}

async function opsOf(taskId: string) {
  return pg.db.taskSyncOp.findMany({ where: { taskId }, orderBy: { seq: "asc" } });
}

/** What the drain writes back when a create lands, applied by hand: the suite
 *  needs a genuinely linked row and nothing here talks to GitHub. */
async function markSynced(taskId: string, issue: number) {
  await pg.db.task.update({
    where: { id: taskId },
    data: {
      externalProvider: "github",
      externalId: `${issue}`,
      externalKey: `acme/web#${issue}`,
      externalUrl: `https://github.com/acme/web/issues/${issue}`,
      remoteSnapshot: { title: "t", body: "", status: { state: "open" }, labels: [] },
      pushedHash: "deadbeef",
      syncState: "synced",
      syncedAt: new Date(),
    },
  });
}

describe("POST /tasks: publish is required", () => {
  test("a body without `publish` is refused and creates nothing", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const project = await makeProject(caller.accountId);
    const integrationId = await makeIntegration(caller);
    // Configured exactly as an older client would meet it: a target exists and
    // the per-project default is ON, which is precisely when a server-side
    // fallback would publish something nobody was shown.
    await makeRepo(caller, {
      integrationId,
      projectId: project.id,
      name: "web",
      publishNewByDefault: true,
    });

    const res = await post(app, "/tasks", caller, { title: "a private note", projectId: project.id });
    expect(res.status).toBe(400);
    expect(await errorOf(res)).toBe("BAD_REQUEST");
    expect(await pg.db.task.count()).toBe(0);
  });

  test("publish: false leaves the task local even where a target exists", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const project = await makeProject(caller.accountId);
    const integrationId = await makeIntegration(caller);
    await makeRepo(caller, {
      integrationId,
      projectId: project.id,
      name: "web",
      publishNewByDefault: true,
    });

    const res = await post(app, "/tasks", caller, {
      title: "a private note",
      projectId: project.id,
      publish: false,
    });
    expect(res.status).toBe(201);

    const task = await taskRow();
    expect(task.integrationRepoId).toBeNull();
    expect(task.syncState).toBeNull();
    expect(await opsOf(task.id)).toEqual([]);
  });
});

describe("POST /tasks: publishing at creation", () => {
  test("the one qualifying target is used, and the create op carries the task", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const project = await makeProject(caller.accountId);
    const integrationId = await makeIntegration(caller);
    const repoId = await makeRepo(caller, { integrationId, projectId: project.id, name: "web" });

    const label = await post(app, "/labels", caller, { name: "bug", color: "ff0000" });
    expect(label.status).toBe(201);
    const labelId = ((await label.json()) as { label: { id: string } }).label.id;

    const res = await post(app, "/tasks", caller, {
      title: "wire the drain",
      body: "with backoff",
      status: "done",
      projectId: project.id,
      labelIds: [labelId],
      publish: true,
    });
    expect(res.status).toBe(201);
    const { task } = (await res.json()) as { task: { syncState: string; source: string } };
    expect(task.syncState).toBe("pending");
    // Where the task was born, not where it now lives.
    expect(task.source).toBe("local");

    const row = await taskRow();
    expect(row.integrationRepoId).toBe(repoId);

    const ops = await opsOf(row.id);
    expect(ops.length).toBe(1);
    expect(ops[0]!.kind).toBe("issue.create");
    expect(ops[0]!.integrationId).toBe(integrationId);
    expect(ops[0]!.payload).toEqual({
      kind: "issue.create",
      title: "wire the drain",
      body: "with backoff",
      // Provider space, from `toRemote` — Antgrid vocabulary would be a value
      // GitHub cannot store.
      state: "closed",
      stateReason: "completed",
      // Names, not ids: ids mean nothing to the provider.
      labels: ["bug"],
    });
  });

  test("several targets and no choice is a refusal, and creates nothing", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const project = await makeProject(caller.accountId);
    const integrationId = await makeIntegration(caller);
    await makeRepo(caller, { integrationId, projectId: project.id, name: "web" });
    const apiId = await makeRepo(caller, { integrationId, projectId: project.id, name: "api" });

    const ambiguous = await post(app, "/tasks", caller, {
      title: "which repo",
      projectId: project.id,
      publish: true,
    });
    expect(ambiguous.status).toBe(409);
    expect(await errorOf(ambiguous)).toBe("PUBLISH_REPO_AMBIGUOUS");
    expect(await pg.db.task.count()).toBe(0);

    const chosen = await post(app, "/tasks", caller, {
      title: "this one",
      projectId: project.id,
      publish: true,
      publishRepoId: apiId,
    });
    expect(chosen.status).toBe(201);
    expect((await taskRow()).integrationRepoId).toBe(apiId);
  });

  test("a task with no project has nowhere to publish", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const integrationId = await makeIntegration(caller);
    await makeRepo(caller, { integrationId, projectId: null, name: "web" });

    const res = await post(app, "/tasks", caller, { title: "unfiled", publish: true });
    expect(res.status).toBe(409);
    expect(await errorOf(res)).toBe("PUBLISH_NOT_AVAILABLE");
    expect(await pg.db.task.count()).toBe(0);
  });

  test("a repository without outbound consent is not offered", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const project = await makeProject(caller.accountId);
    const integrationId = await makeIntegration(caller);
    // Offering it would show a choice whose outcome is `applyOp` cancelling the
    // create — a publish the user watched fail silently.
    await makeRepo(caller, {
      integrationId,
      projectId: project.id,
      name: "web",
      pushEnabled: false,
    });

    const res = await post(app, "/tasks", caller, {
      title: "t",
      projectId: project.id,
      publish: true,
    });
    expect(res.status).toBe(409);
    expect(await errorOf(res)).toBe("PUBLISH_NOT_AVAILABLE");
    expect(await pg.db.task.count()).toBe(0);
  });

  test("naming a repository that is not a target is a miss, not a bypass", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const project = await makeProject(caller.accountId);
    const other = await makeProject(caller.accountId);
    const integrationId = await makeIntegration(caller);
    // The project has a real target, so what refuses each request below is the
    // repository named rather than the project having nothing at all.
    await makeRepo(caller, { integrationId, projectId: project.id, name: "web" });
    const noPush = await makeRepo(caller, {
      integrationId,
      projectId: project.id,
      name: "no-push",
      pushEnabled: false,
    });
    const elsewhere = await makeRepo(caller, {
      integrationId,
      projectId: other.id,
      name: "relay",
    });

    for (const publishRepoId of [noPush, elsewhere]) {
      const res = await post(app, "/tasks", caller, {
        title: "t",
        projectId: project.id,
        publish: true,
        publishRepoId,
      });
      expect(res.status).toBe(404);
      expect(await errorOf(res)).toBe("PUBLISH_REPO_NOT_FOUND");
    }
    expect(await pg.db.task.count()).toBe(0);
  });

  test("another account's repository is never a target, named or not", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller("owner@example.com");
    const stranger = await setupCaller("stranger@example.com");
    const project = await makeProject(caller.accountId);
    const strangerProject = await makeProject(stranger.accountId);

    const mine = await makeIntegration(caller);
    const mineRepo = await makeRepo(caller, {
      integrationId: mine,
      projectId: project.id,
      name: "web",
    });
    const theirs = await makeIntegration(stranger);
    const theirRepo = await makeRepo(stranger, {
      integrationId: theirs,
      projectId: strangerProject.id,
      name: "secret",
    });

    const res = await post(app, "/tasks", caller, {
      title: "t",
      projectId: project.id,
      publish: true,
      publishRepoId: theirRepo,
    });
    expect(res.status).toBe(404);
    expect(await errorOf(res)).toBe("PUBLISH_REPO_NOT_FOUND");
    expect(await pg.db.task.count()).toBe(0);

    // The caller's own repository still resolves, so the refusal above is
    // tenancy and not a broken fixture.
    const ok = await post(app, "/tasks", caller, {
      title: "t",
      projectId: project.id,
      publish: true,
      publishRepoId: mineRepo,
    });
    expect(ok.status).toBe(201);
  });

  test("a revoked installation and a removed repository both stop being targets", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const project = await makeProject(caller.accountId);
    const integrationId = await makeIntegration(caller);
    const repoId = await makeRepo(caller, { integrationId, projectId: project.id, name: "web" });

    await pg.db.integrationRepo.update({
      where: { id: repoId },
      data: { removedAt: new Date() },
    });
    const removed = await post(app, "/tasks", caller, {
      title: "t",
      projectId: project.id,
      publish: true,
    });
    expect(await errorOf(removed)).toBe("PUBLISH_NOT_AVAILABLE");

    await pg.db.integrationRepo.update({ where: { id: repoId }, data: { removedAt: null } });
    await pg.db.integration.update({
      where: { id: integrationId },
      data: { revokedAt: new Date(), status: "revoked" },
    });
    const revoked = await post(app, "/tasks", caller, {
      title: "t",
      projectId: project.id,
      publish: true,
    });
    expect(await errorOf(revoked)).toBe("PUBLISH_NOT_AVAILABLE");
    expect(await pg.db.task.count()).toBe(0);
  });
});

describe("GET /tasks/publish-targets", () => {
  test("only qualifying rows, with the address the consent UI must render", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller("targets@example.com");
    const stranger = await setupCaller("targets-stranger@example.com");
    const project = await makeProject(caller.accountId);
    const integrationId = await makeIntegration(caller);

    const webId = await makeRepo(caller, {
      integrationId,
      projectId: project.id,
      name: "web",
      visibility: "public",
      publishNewByDefault: true,
    });
    await makeRepo(caller, {
      integrationId,
      projectId: project.id,
      name: "no-push",
      pushEnabled: false,
    });
    const removedId = await makeRepo(caller, {
      integrationId,
      projectId: project.id,
      name: "gone",
    });
    await pg.db.integrationRepo.update({
      where: { id: removedId },
      data: { removedAt: new Date() },
    });
    // Same project id asserted from another account's integration: the join is
    // by project, so the account filter is the only thing keeping it out.
    const theirs = await makeIntegration(stranger);
    await pg.db.integrationRepo.create({
      data: {
        integrationId: theirs,
        repoKey: "github.com/acme/theirs",
        externalRepoId: `ext-${crypto.randomUUID()}`,
        projectId: project.id,
        visibility: "public",
        syncEnabled: true,
        pushEnabled: true,
      },
    });

    const res = await app.request(`/tasks/publish-targets?projectId=${project.id}`, {
      headers: caller.headers,
    });
    expect(res.status).toBe(200);
    const { targets } = (await res.json()) as { targets: Record<string, unknown>[] };
    expect(targets).toEqual([
      {
        id: webId,
        owner: "acme",
        name: "web",
        visibility: "public",
        publishNewByDefault: true,
      },
    ]);
  });

  test("a project with no targets answers an empty list, and a bad projectId is a 400", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const project = await makeProject(caller.accountId);

    const empty = await app.request(`/tasks/publish-targets?projectId=${project.id}`, {
      headers: caller.headers,
    });
    expect(empty.status).toBe(200);
    expect((await empty.json()) as unknown).toEqual({ targets: [] });

    for (const query of ["", "?projectId=", "?projectId=nope"]) {
      const res = await app.request(`/tasks/publish-targets${query}`, { headers: caller.headers });
      expect(res.status).toBe(400);
      expect(await errorOf(res)).toBe("BAD_REQUEST");
    }
  });

  test("the literal path is not read as a task id", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const res = await app.request("/tasks/publish-targets", { headers: caller.headers });
    // The targets route answered (missing projectId), not `/tasks/:number`.
    expect(res.status).toBe(400);
  });
});

describe("POST /tasks/:number/publish", () => {
  test("an existing local task publishes on the same terms as the create form", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const project = await makeProject(caller.accountId);
    const integrationId = await makeIntegration(caller);
    const repoId = await makeRepo(caller, { integrationId, projectId: project.id, name: "web" });

    const created = await post(app, "/tasks", caller, {
      title: "started as a note",
      body: "now ready to share",
      projectId: project.id,
      publish: false,
    });
    expect(created.status).toBe(201);

    const res = await post(app, "/tasks/1/publish", caller, {});
    expect(res.status).toBe(200);
    const { task } = (await res.json()) as { task: { syncState: string } };
    expect(task.syncState).toBe("pending");

    const row = await taskRow();
    expect(row.integrationRepoId).toBe(repoId);
    const ops = await opsOf(row.id);
    expect(ops.map((op) => op.kind)).toEqual(["issue.create"]);
    expect((ops[0]!.payload as { title: string }).title).toBe("started as a note");
  });

  test("a task already on its way to an issue is refused rather than published twice", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const project = await makeProject(caller.accountId);
    const integrationId = await makeIntegration(caller);
    await makeRepo(caller, { integrationId, projectId: project.id, name: "web" });

    await post(app, "/tasks", caller, { title: "t", projectId: project.id, publish: true });

    // Still `pending`, so `externalId` is null and only the sync state says an
    // `issue.create` is already queued. A second one posts a duplicate issue.
    const pending = await post(app, "/tasks/1/publish", caller, {});
    expect(pending.status).toBe(409);
    expect(await errorOf(pending)).toBe("ALREADY_LINKED");

    await markSynced((await taskRow()).id, 12);
    const linked = await post(app, "/tasks/1/publish", caller, {});
    expect(linked.status).toBe(409);
    expect(await errorOf(linked)).toBe("ALREADY_LINKED");

    expect((await opsOf((await taskRow()).id)).length).toBe(1);
  });

  test("another account's task number is a 404 on both verbs", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const victim = await setupCaller("victim@example.com");
    const attacker = await setupCaller("attacker@example.com");
    const project = await makeProject(victim.accountId);
    const integrationId = await makeIntegration(victim);
    await makeRepo(victim, { integrationId, projectId: project.id, name: "web" });

    await post(app, "/tasks", victim, { title: "theirs", projectId: project.id, publish: false });

    expect((await post(app, "/tasks/1/publish", attacker, {})).status).toBe(404);
    expect((await post(app, "/tasks/1/unlink", attacker, {})).status).toBe(404);
    expect((await taskRow()).integrationRepoId).toBeNull();
  });
});

describe("POST /tasks/:number/unlink", () => {
  test("unlink keeps the identity on the row and leaves the queue alone", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const project = await makeProject(caller.accountId);
    const integrationId = await makeIntegration(caller);
    const repoId = await makeRepo(caller, { integrationId, projectId: project.id, name: "web" });

    await post(app, "/tasks", caller, { title: "t", projectId: project.id, publish: true });
    const published = await taskRow();
    await markSynced(published.id, 7);

    const res = await post(app, "/tasks/1/unlink", caller, {});
    expect(res.status).toBe(200);

    const row = await taskRow();
    expect(row.syncState).toBe("unlinked");
    // The tombstone: the confirm sheet for a re-publish names the issue that
    // already exists rather than describing the hazard in the abstract.
    expect(row.externalId).toBe("7");
    expect(row.externalKey).toBe("acme/web#7");
    expect(row.externalUrl).toBe("https://github.com/acme/web/issues/7");
    expect(row.integrationRepoId).toBe(repoId);

    // Not cancelled here: `applyOp` drops an op whose task is unlinked, and one
    // code path for that decision is better than two.
    expect((await opsOf(row.id)).map((op) => op.status)).toEqual(["pending"]);
  });

  test("a task that was never linked has nothing to unlink", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    await post(app, "/tasks", caller, { title: "local only", publish: false });

    const res = await post(app, "/tasks/1/unlink", caller, {});
    expect(res.status).toBe(409);
    expect(await errorOf(res)).toBe("NOT_LINKED");

    await pg.db.task.update({
      where: { id: (await taskRow()).id },
      data: { syncState: "unlinked", externalProvider: "github", externalId: "9" },
    });
    const again = await post(app, "/tasks/1/unlink", caller, {});
    expect(again.status).toBe(409);
    expect(await errorOf(again)).toBe("NOT_LINKED");
  });

  test("re-publishing an unlinked task keeps nothing of the first issue", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const caller = await setupCaller();
    const project = await makeProject(caller.accountId);
    const integrationId = await makeIntegration(caller);
    const webId = await makeRepo(caller, { integrationId, projectId: project.id, name: "web" });
    const apiId = await makeRepo(caller, { integrationId, projectId: project.id, name: "api" });

    await post(app, "/tasks", caller, {
      title: "t",
      projectId: project.id,
      publish: true,
      publishRepoId: webId,
    });
    const first = await taskRow();
    await markSynced(first.id, 3);
    await pg.db.task.update({
      where: { id: first.id },
      data: {
        localConflict: { conflicts: {}, labelRemoveWins: ["bug"] },
        pushBlocked: { title: { count: 3, lastAt: new Date().toISOString(), reason: "no effect" } },
      },
    });
    expect((await post(app, "/tasks/1/unlink", caller, {})).status).toBe(200);

    const res = await post(app, "/tasks/1/publish", caller, { repoId: apiId });
    expect(res.status).toBe(200);

    const row = await taskRow();
    expect(row.integrationRepoId).toBe(apiId);
    expect(row.syncState).toBe("pending");
    // Nothing about the first issue may survive: the row now describes a second
    // issue that does not exist yet, and `enqueueSyncOp` refuses an
    // `issue.create` outright while `externalId` is set.
    expect(row.externalProvider).toBeNull();
    expect(row.externalId).toBeNull();
    expect(row.externalKey).toBeNull();
    expect(row.externalUrl).toBeNull();
    expect(row.remoteSnapshot).toBeNull();
    expect(row.pushedHash).toBeNull();
    expect(row.localConflict).toBeNull();
    expect(row.pushBlocked).toBeNull();

    // Superseded rather than queued: the first create had not been handed to the
    // provider, so there is one create and it addresses the chosen repository.
    const ops = await opsOf(row.id);
    expect(ops.map((op) => op.kind)).toEqual(["issue.create"]);
    expect(ops[0]!.status).toBe("pending");
  });
});
