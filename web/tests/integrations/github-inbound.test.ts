import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestSubscription, createTestUser } from "../helpers/fixtures.js";
import {
  upsertIntegration,
  upsertIntegrationRepo,
  type IntegrationRecord,
} from "../../src/models/integration.js";
import { drainGithubWebhooks } from "../../src/integrations/github-inbound.js";
import {
  drainGithubBacklog,
  githubDrainLoopDeps,
} from "../../src/integrations/github-drain-loop.js";
import {
  MAX_WEBHOOK_ATTEMPTS,
  listGivenUpDeliveries,
  purgeProcessedWebhookEvents,
  recordDeliveryFailure,
  retentionCutoff,
} from "../../src/integrations/webhook-events.js";

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

async function connect(
  account: Account,
  overrides: Partial<Parameters<typeof upsertIntegration>[1]> = {}
): Promise<IntegrationRecord> {
  const result = await upsertIntegration(pg.db, {
    accountId: account.accountId,
    provider: "github",
    externalAccountId: "org-x",
    installationId: "42",
    displayName: "acme",
    installedBy: account.userId,
    ...overrides,
  });
  if (result.kind !== "ok") throw new Error(`upsertIntegration: ${result.kind}`);
  return result.integration;
}

async function addRepo(
  account: Account,
  integration: IntegrationRecord,
  overrides: Partial<Parameters<typeof upsertIntegrationRepo>[1]> = {}
) {
  const result = await upsertIntegrationRepo(pg.db, {
    accountId: account.accountId,
    integrationId: integration.id,
    repoKey: "github.com/acme/relay",
    externalRepoId: "gh-100",
    visibility: "private",
    syncEnabled: true,
    ...overrides,
  });
  if (result.kind !== "ok") throw new Error(`upsertIntegrationRepo: ${result.kind}`);
  return result.repo;
}

/** What Better-Auth writes when a user signs in with GitHub: the provider's
 *  numeric user id in `accountId`, never the login. Resolving an assignee to a
 *  member starts here. */
async function linkGithubOauth(userId: string, externalUserId: string) {
  await pg.db.account.create({
    data: { id: randomUUID(), accountId: externalUserId, providerId: "github", userId },
  });
}

async function record(type: string, body: unknown, provider = "github") {
  return pg.db.webhookEvent.create({
    data: {
      provider,
      providerEventId: randomUUID(),
      type,
      payload: { deliveryId: `d-${randomUUID()}`, body } as never,
    },
    select: { id: true },
  });
}

async function reload(id: string) {
  return pg.db.webhookEvent.findUniqueOrThrow({ where: { id } });
}

const repoRef = (id: string, fullName: string, isPrivate = true) => ({
  id,
  node_id: "n",
  name: fullName.split("/")[1],
  full_name: fullName,
  private: isPrivate,
});

describe("drainGithubWebhooks — routing", () => {
  test("a delivery for an installation nobody connected is dropped, not retried", async () => {
    const row = await record("installation", {
      action: "suspend",
      installation: { id: 999 },
    });

    const report = await drainGithubWebhooks(pg.db);
    expect(report).toMatchObject({ scanned: 1, dropped: 1, applied: 0, failed: 0 });

    const after = await reload(row.id);
    expect(after.processedAt).not.toBeNull();
    expect(after.attempts).toBe(0);
  });

  // Silent and cross-tenant if it ever regresses: the revoked row is retained by
  // design, and routing to it writes another org's payload into an account that
  // has disconnected.
  test("a delivery for a REVOKED installation is dropped rather than routed", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    const repo = await addRepo(account, integration);
    await pg.db.integration.update({
      where: { id: integration.id },
      data: { revokedAt: new Date(), status: "revoked" },
    });

    const row = await record("repository", {
      action: "publicized",
      installation: { id: 42 },
      repository: repoRef("gh-100", "acme/relay", false),
    });

    const report = await drainGithubWebhooks(pg.db);
    expect(report).toMatchObject({ dropped: 1, applied: 0 });

    const after = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repo.id } });
    expect(after.visibility).toBe("private");
    expect((await reload(row.id)).processedAt).not.toBeNull();
  });

  test("a repository we do not hold is dropped", async () => {
    const account = await makeAccount();
    await connect(account);
    await record("repository", {
      action: "renamed",
      installation: { id: 42 },
      repository: repoRef("gh-999", "acme/other"),
    });

    const report = await drainGithubWebhooks(pg.db);
    expect(report).toMatchObject({ dropped: 1 });
  });

  test("an unrecognized action is a no-op rather than a failure", async () => {
    const account = await makeAccount();
    await connect(account);
    const row = await record("installation", {
      action: "new_permissions_accepted",
      installation: { id: 42 },
    });

    const report = await drainGithubWebhooks(pg.db);
    expect(report).toMatchObject({ dropped: 1, failed: 0 });
    expect((await reload(row.id)).processedAt).not.toBeNull();
  });

  test("a payload no schema accepts is closed with the reason on the row", async () => {
    const account = await makeAccount();
    await connect(account);
    const row = await record("installation", { action: "created" });

    const report = await drainGithubWebhooks(pg.db);
    expect(report).toMatchObject({ invalid: 1, failed: 0 });

    const after = await reload(row.id);
    expect(after.processedAt).not.toBeNull();
    expect(after.lastError).toContain("installation");
  });
});

describe("drainGithubWebhooks — installation lifecycle", () => {
  test("created records the repositories the install carries, sync off", async () => {
    const account = await makeAccount();
    const integration = await connect(account, { status: "suspended" });

    await record("installation", {
      action: "created",
      installation: { id: 42, account: { login: "acme-renamed" } },
      repositories: [repoRef("gh-1", "Acme/Relay"), repoRef("gh-2", "acme/app", false)],
    });

    const report = await drainGithubWebhooks(pg.db);
    expect(report).toMatchObject({ applied: 1 });

    const after = await pg.db.integration.findUniqueOrThrow({ where: { id: integration.id } });
    expect(after.status).toBe("active");
    expect(after.displayName).toBe("acme-renamed");

    const repos = await pg.db.integrationRepo.findMany({ orderBy: { repoKey: "asc" } });
    expect(repos.map((r) => [r.repoKey, r.visibility, r.syncEnabled])).toEqual([
      ["github.com/acme/app", "public", false],
      ["github.com/acme/relay", "private", false],
    ]);
  });

  test("deleted revokes the integration and later deliveries stop routing", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    const repo = await addRepo(account, integration);

    await record("installation", { action: "deleted", installation: { id: 42 } });
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const after = await pg.db.integration.findUniqueOrThrow({ where: { id: integration.id } });
    expect(after.revokedAt).not.toBeNull();
    expect(after.status).toBe("revoked");

    await record("repository", {
      action: "privatized",
      installation: { id: 42 },
      repository: repoRef("gh-100", "acme/relay"),
    });
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    const repoAfter = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repo.id } });
    expect(repoAfter.visibility).toBe("private");
  });

  // 4a routes a suspended installation on purpose: an `unsuspend` has to be able
  // to arrive and lift it, which a status filter on the inbound path would block.
  test("suspend and unsuspend move status, and routing survives the suspension", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    const repo = await addRepo(account, integration);

    await record("installation", { action: "suspend", installation: { id: 42 } });
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });
    expect(
      (await pg.db.integration.findUniqueOrThrow({ where: { id: integration.id } })).status
    ).toBe("suspended");

    await record("repository", {
      action: "publicized",
      installation: { id: 42 },
      repository: repoRef("gh-100", "acme/relay", false),
    });
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });
    expect(
      (await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repo.id } })).visibility
    ).toBe("public");

    await record("installation", { action: "unsuspend", installation: { id: 42 } });
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });
    const after = await pg.db.integration.findUniqueOrThrow({ where: { id: integration.id } });
    expect(after.status).toBe("active");
    expect(after.revokedAt).toBeNull();
  });
});

describe("drainGithubWebhooks — repositories", () => {
  test("repositories added and removed from the installation", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    const existing = await addRepo(account, integration);

    await record("installation_repositories", {
      action: "added",
      installation: { id: 42 },
      repositories_added: [repoRef("gh-200", "acme/site", false)],
      repositories_removed: [repoRef("gh-100", "acme/relay")],
    });

    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const added = await pg.db.integrationRepo.findFirstOrThrow({
      where: { externalRepoId: "gh-200" },
    });
    expect(added.repoKey).toBe("github.com/acme/site");
    expect(added.visibility).toBe("public");
    expect(added.syncEnabled).toBe(false);

    // Never deleted: tasks imported through it point at this row.
    const removed = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: existing.id } });
    expect(removed.syncEnabled).toBe(false);
    // And distinguishable from the user having turned it off, which is the only
    // way the settings page can explain an off state nobody chose.
    expect(removed.removedAt).not.toBeNull();
    expect(added.removedAt).toBeNull();
  });

  test("a rename rewrites the repoKey", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    const repo = await addRepo(account, integration);

    await record("repository", {
      action: "renamed",
      installation: { id: 42 },
      repository: repoRef("gh-100", "acme/relay-core"),
    });
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const after = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repo.id } });
    expect(after.repoKey).toBe("github.com/acme/relay-core");
  });

  test("the private to public flip updates visibility", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    const repo = await addRepo(account, integration, { visibility: "private" });

    await record("repository", {
      action: "publicized",
      installation: { id: 42 },
      repository: repoRef("gh-100", "acme/relay", false),
    });
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });
    expect(
      (await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repo.id } })).visibility
    ).toBe("public");

    await record("repository", {
      action: "privatized",
      installation: { id: 42 },
      repository: repoRef("gh-100", "acme/relay", true),
    });
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });
    expect(
      (await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repo.id } })).visibility
    ).toBe("private");
  });

  test("a transfer that collides with a repository we already hold fails and retries", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    await addRepo(account, integration, { externalRepoId: "gh-100", repoKey: "github.com/acme/a" });
    await addRepo(account, integration, { externalRepoId: "gh-200", repoKey: "github.com/acme/b" });

    const row = await record("repository", {
      action: "transferred",
      installation: { id: 42 },
      repository: repoRef("gh-200", "acme/a"),
    });

    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ failed: 1, applied: 0 });
    const after = await reload(row.id);
    expect(after.processedAt).toBeNull();
    expect(after.attempts).toBe(1);
    expect(after.lastError).not.toBeNull();
  });
});

describe("drainGithubWebhooks — claim discipline", () => {
  test("deferred event types are never claimed", async () => {
    const account = await makeAccount();
    await connect(account);
    const row = await record("label", { action: "created", installation: { id: 42 } });

    const report = await drainGithubWebhooks(pg.db);
    expect(report.scanned).toBe(0);
    expect((await reload(row.id)).processedAt).toBeNull();
  });

  test("two drains running at once apply each delivery exactly once", async () => {
    const account = await makeAccount();
    await connect(account);
    for (let i = 0; i < 6; i++) {
      await record("installation", { action: "suspend", installation: { id: 42 }, seq: i });
    }

    const [a, b] = await Promise.all([drainGithubWebhooks(pg.db), drainGithubWebhooks(pg.db)]);
    expect(a.applied + b.applied).toBe(6);
    expect(a.failed + b.failed).toBe(0);
    expect(await pg.db.webhookEvent.count({ where: { processedAt: null } })).toBe(0);
  });

  test("a row at the attempt ceiling is left alone and stays findable", async () => {
    const account = await makeAccount();
    await connect(account);
    const row = await record("installation", { action: "suspend", installation: { id: 42 } });
    await pg.db.webhookEvent.update({
      where: { id: row.id },
      data: { attempts: MAX_WEBHOOK_ATTEMPTS, lastError: "poison" },
    });

    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ scanned: 0 });

    const givenUp = await listGivenUpDeliveries(pg.db, "github");
    expect(givenUp.map((r) => r.id)).toEqual([row.id]);
    expect(givenUp[0]!.lastError).toBe("poison");
  });

  test("recording a failure counts the attempt and leaves the row claimable", async () => {
    const row = await record("installation", { action: "suspend", installation: { id: 1 } });
    expect(await recordDeliveryFailure(pg.db, row.id, "transient")).toBe(1);
    const after = await reload(row.id);
    expect(after.processedAt).toBeNull();
    expect(after.lastError).toBe("transient");
  });

  test("the batch size bounds one pass", async () => {
    const account = await makeAccount();
    await connect(account);
    for (let i = 0; i < 5; i++) {
      await record("installation", { action: "suspend", installation: { id: 42 }, seq: i });
    }
    expect(await drainGithubWebhooks(pg.db, { batchSize: 2 })).toMatchObject({ scanned: 2 });
    expect(await pg.db.webhookEvent.count({ where: { processedAt: null } })).toBe(3);
  });
});

describe("purgeProcessedWebhookEvents", () => {
  test("deletes processed rows past the cutoff and leaves the rest", async () => {
    const old = new Date("2026-01-01T00:00:00.000Z");
    const recent = new Date();

    const staleProcessed = await record("installation", { action: "suspend" });
    const freshProcessed = await record("installation", { action: "suspend" });
    const staleUnprocessed = await record("issues", { action: "opened" });
    const otherProvider = await record("subscription.activated", { id: 1 }, "razorpay");

    await pg.db.webhookEvent.update({
      where: { id: staleProcessed.id },
      data: { processedAt: old, receivedAt: old },
    });
    await pg.db.webhookEvent.update({
      where: { id: freshProcessed.id },
      data: { processedAt: recent },
    });
    await pg.db.webhookEvent.update({
      where: { id: staleUnprocessed.id },
      data: { receivedAt: old },
    });
    await pg.db.webhookEvent.update({
      where: { id: otherProvider.id },
      data: { processedAt: old, receivedAt: old },
    });

    const deleted = await purgeProcessedWebhookEvents(pg.db, {
      provider: "github",
      before: retentionCutoff(new Date()),
    });
    expect(deleted).toBe(1);

    const left = await pg.db.webhookEvent.findMany({ select: { id: true } });
    expect(left.map((r) => r.id).sort()).toEqual(
      [freshProcessed.id, staleUnprocessed.id, otherProvider.id].sort()
    );
  });

  test("the cutoff is the retention window back from now", async () => {
    const now = new Date("2026-08-18T00:00:00.000Z");
    const cutoff = retentionCutoff(now);
    expect(now.getTime() - cutoff.getTime()).toBe(30 * 24 * 60 * 60 * 1000);
  });
});

const issuePayload = (overrides: Record<string, unknown> = {}) => ({
  id: 1001,
  number: 7,
  title: "Relay drops a frame",
  body: "steps to reproduce",
  state: "open",
  html_url: "https://github.com/acme/relay/issues/7",
  updated_at: "2026-08-18T10:00:00Z",
  ...overrides,
});

const issuesEvent = (action: string, issue: Record<string, unknown> = {}) => ({
  action,
  installation: { id: 42 },
  repository: repoRef("gh-100", "acme/relay"),
  issue: issuePayload(issue),
});

const commentEvent = (
  action: string,
  comment: Record<string, unknown> = {},
  issue: Record<string, unknown> = {}
) => ({
  action,
  installation: { id: 42 },
  repository: repoRef("gh-100", "acme/relay"),
  issue: issuePayload(issue),
  comment: {
    id: 5001,
    body: "a comment",
    user: { id: 9, login: "octocat" },
    ...comment,
  },
});

async function onlyTask() {
  return pg.db.task.findFirstOrThrow({ include: { labels: { include: { label: true } } } });
}

/** Import one issue and hand back the task it produced — the precondition of
 *  every merge test below, and not the thing any of them asserts. */
async function importedTask(account: Account, issue: Record<string, unknown> = {}) {
  const integration = await connect(account);
  await addRepo(account, integration);
  await record("issues", issuesEvent("opened", issue));
  expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });
  return onlyTask();
}

describe("drainGithubWebhooks — issue import", () => {
  test("a new issue lands as a task carrying its provenance", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    const repo = await addRepo(account, integration);

    await record("issues", issuesEvent("opened", { labels: [{ name: "bug", color: "d73a4a" }] }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1, dropped: 0, failed: 0 });

    const task = await onlyTask();
    // `source` plus the external columns are what the app's launch sheet reads
    // to treat the body as untrusted. Left at `local`, that mitigation is off.
    expect(task.source).toBe("github");
    expect(task.externalProvider).toBe("github");
    expect(task.externalId).toBe("1001");
    expect(task.externalKey).toBe("acme/relay#7");
    expect(task.externalUrl).toBe("https://github.com/acme/relay/issues/7");
    expect(task.integrationRepoId).toBe(repo.id);
    expect(task.createdBy).toBe(account.userId);
    expect(task.title).toBe("Relay drops a frame");
    expect(task.body).toBe("steps to reproduce");
    expect(task.status).toBe("open");
    expect(task.syncState).toBe("synced");
    expect(task.localConflict).toBeNull();
    expect(task.remoteUpdatedAt?.toISOString()).toBe("2026-08-18T10:00:00.000Z");
    expect(task.syncedAt).not.toBeNull();
    expect(task.remoteSnapshot).toEqual({
      title: "Relay drops a frame",
      body: "steps to reproduce",
      status: { state: "open", stateReason: null },
      labels: ["bug"],
      assignee: null,
      assignees: [],
    });
  });

  // The whole point of the identity table: the assignee lands on the member
  // column pair, which is what makes the task filterable as theirs rather than
  // as a login nothing in the product can act on.
  test("an issue assigned to a linked member imports as that member", async () => {
    const account = await makeAccount();
    await linkGithubOauth(account.userId, "9");
    const task = await importedTask(account, {
      assignees: [{ id: 9, login: "octocat", avatar_url: "https://avatars/1" }],
    });

    expect(task.assigneeUserId).toBe(account.userId);
    expect(task.assigneeExternalId).toBeNull();
    expect(task.assigneeLogin).toBeNull();
  });

  // The column pair holds one assignee; the snapshot is the only record that
  // the others existed, and the "+n others on GitHub" marker reads it.
  test("a multi-assignee issue keeps the member and snapshots the rest", async () => {
    const account = await makeAccount();
    await linkGithubOauth(account.userId, "9");
    const task = await importedTask(account, {
      assignees: [
        { id: 8, login: "outsider" },
        { id: 9, login: "octocat" },
      ],
    });

    expect(task.assigneeUserId).toBe(account.userId);
    expect(task.remoteSnapshot).toMatchObject({
      assignee: { kind: "member", userId: account.userId },
      assignees: [
        { kind: "external", externalId: "8", login: "outsider", avatarUrl: null },
        { kind: "member", userId: account.userId },
      ],
    });
  });

  // A GitHub user nobody on the account has linked is a stranger, and inventing
  // a member for them assigns a colleague work they never took.
  test("an assignee outside the account stays external", async () => {
    const account = await makeAccount();
    const task = await importedTask(account, {
      assignees: [{ id: 9, login: "octocat", avatar_url: "https://avatars/1" }],
    });

    expect(task.assigneeUserId).toBeNull();
    expect(task.assigneeExternalId).toBe("9");
    expect(task.assigneeLogin).toBe("octocat");
  });

  test("a closed issue imports closed", async () => {
    const account = await makeAccount();
    const task = await importedTask(account, { state: "closed", state_reason: "not_planned" });
    expect(task.status).toBe("cancelled");
    expect(task.closedAt).not.toBeNull();
  });

  // The `[accountId, externalProvider, externalId]` unique is the whole inbound
  // idempotency mechanism; a second lookup keyed on anything else is how one
  // issue becomes two tasks.
  test("re-delivering the same issue produces one task, not two", async () => {
    const account = await makeAccount();
    await importedTask(account);

    await record("issues", issuesEvent("edited"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1, failed: 0 });
    expect(await pg.db.task.count()).toBe(1);
  });

  test("a pull request is dropped rather than imported", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    await addRepo(account, integration);

    const row = await record(
      "issues",
      issuesEvent("opened", { pull_request: { url: "https://api.github.com/pulls/7" } })
    );
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    expect(await pg.db.task.count()).toBe(0);
    expect((await reload(row.id)).processedAt).not.toBeNull();
  });

  // Discovery is not consent: every repository of an installation is recorded,
  // and only the user turning sync on makes one importable.
  test("a repository with sync off drops the delivery", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    await addRepo(account, integration, { syncEnabled: false });

    await record("issues", issuesEvent("opened"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    expect(await pg.db.task.count()).toBe(0);
  });

  test("an issue for an installation nobody connected is dropped", async () => {
    await record("issues", issuesEvent("opened"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    expect(await pg.db.task.count()).toBe(0);
  });

  test("an issue for a REVOKED installation is dropped rather than routed", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    await addRepo(account, integration);
    await pg.db.integration.update({
      where: { id: integration.id },
      data: { revokedAt: new Date(), status: "revoked" },
    });

    await record("issues", issuesEvent("opened"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    expect(await pg.db.task.count()).toBe(0);
  });

  test("a repository of the installation we never recorded is dropped", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    await addRepo(account, integration);

    await record("issues", {
      action: "opened",
      installation: { id: 42 },
      repository: repoRef("gh-999", "acme/other"),
      issue: issuePayload(),
    });
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    expect(await pg.db.task.count()).toBe(0);
  });

  // Removing a local task because its issue vanished discards whatever local
  // edits, runs and comments it accumulated; a one-way import does not earn that.
  test("issues.deleted leaves the task alone", async () => {
    const account = await makeAccount();
    await importedTask(account);

    await record("issues", issuesEvent("deleted"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    expect((await onlyTask()).deletedAt).toBeNull();
  });

  // The tombstone keeps the external identity so this lookup still resolves;
  // refusing here is what stops the next remote edit re-animating it.
  test("a soft-deleted task is not re-animated by a later delivery", async () => {
    const account = await makeAccount();
    const task = await importedTask(account);
    await pg.db.task.update({
      where: { id: task.id },
      data: { deletedAt: new Date(), syncState: "unlinked" },
    });

    await record("issues", issuesEvent("edited", { title: "renamed remotely" }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    expect((await onlyTask()).title).toBe("Relay drops a frame");
  });
});

describe("drainGithubWebhooks — the three-way merge", () => {
  test("a remote-only edit applies", async () => {
    const account = await makeAccount();
    await importedTask(account);

    await record("issues", issuesEvent("edited", { title: "Relay drops two frames" }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const task = await onlyTask();
    expect(task.title).toBe("Relay drops two frames");
    expect(task.syncState).toBe("synced");
    expect(task.localConflict).toBeNull();
  });

  test("a local-only edit is left alone by an unchanged remote", async () => {
    const account = await makeAccount();
    const task = await importedTask(account);
    await pg.db.task.update({ where: { id: task.id }, data: { title: "my own words" } });

    await record("issues", issuesEvent("labeled"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const after = await onlyTask();
    expect(after.title).toBe("my own words");
    expect(after.syncState).toBe("synced");
  });

  // Remote wins for a provider-owned field, and the losing local value is kept:
  // silent data loss is the one outcome that is never acceptable.
  test("a two-sided edit conflicts and keeps the local value", async () => {
    const account = await makeAccount();
    const task = await importedTask(account);
    await pg.db.task.update({ where: { id: task.id }, data: { title: "my own words" } });

    await record("issues", issuesEvent("edited", { title: "their words" }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const after = await onlyTask();
    expect(after.title).toBe("their words");
    expect(after.syncState).toBe("conflict");
    expect(after.localConflict).toMatchObject({
      conflicts: { title: { localValue: "my own words", remoteValue: "their words" } },
    });
  });

  // The sub-status rule: `open` coming back is ambiguous between "unchanged" and
  // "reopened", so the hint comes from the local row. Without it every inbound
  // event on an untouched issue clobbers a live run back to `open`.
  test("in_progress survives an inbound open issue", async () => {
    const account = await makeAccount();
    const task = await importedTask(account);
    await pg.db.task.update({ where: { id: task.id }, data: { status: "in_progress" } });

    await record("issues", issuesEvent("labeled"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const after = await onlyTask();
    expect(after.status).toBe("in_progress");
    expect(after.syncState).toBe("synced");
  });

  test("a remote close applies over a local in_progress without conflicting", async () => {
    const account = await makeAccount();
    const task = await importedTask(account);
    await pg.db.task.update({ where: { id: task.id }, data: { status: "in_progress" } });

    await record("issues", issuesEvent("closed", { state: "closed", state_reason: "completed" }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const after = await onlyTask();
    expect(after.status).toBe("done");
    expect(after.closedAt).not.toBeNull();
    expect(after.syncState).toBe("synced");
  });

  test("an unreadable snapshot is treated as absent and the remote is taken whole", async () => {
    const account = await makeAccount();
    const task = await importedTask(account);
    await pg.db.task.update({
      where: { id: task.id },
      data: { title: "my own words", remoteSnapshot: { nonsense: true } },
    });

    await record("issues", issuesEvent("edited", { title: "their words" }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const after = await onlyTask();
    expect(after.title).toBe("their words");
    // With no base nothing can read as locally moved, so there is nothing to
    // conflict with — a first sync, not an adjudication.
    expect(after.syncState).toBe("synced");
  });
});

describe("drainGithubWebhooks — import filter", () => {
  async function withFilter(overrides: Record<string, unknown>) {
    const account = await makeAccount();
    const integration = await connect(account);
    await addRepo(account, integration, overrides);
    return account;
  }

  test("label includes a matching issue and excludes the rest", async () => {
    await withFilter({ importFilter: { kind: "label", value: "bug" } });

    await record("issues", issuesEvent("opened", { labels: [{ name: "Bug", color: "d73a4a" }] }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });
    expect(await pg.db.task.count()).toBe(1);

    await record("issues", {
      action: "opened",
      installation: { id: 42 },
      repository: repoRef("gh-100", "acme/relay"),
      issue: issuePayload({ id: 2002, number: 8, labels: [] }),
    });
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    expect(await pg.db.task.count()).toBe(1);
  });

  test("milestone includes and excludes on the title", async () => {
    await withFilter({ importFilter: { kind: "milestone", value: "v1" } });

    await record("issues", issuesEvent("opened", { milestone: { title: "v2" } }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1 });

    await record("issues", issuesEvent("opened", { milestone: { title: "v1" } }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });
    expect(await pg.db.task.count()).toBe(1);
  });

  // The strict reading. A user picking this filter is asking for the issues
  // their team owns, so an issue assigned only to somebody outside the account
  // is exactly what it has to keep out.
  test("assigned_to_member wants a resolved member, not just an assignee", async () => {
    const account = await withFilter({ importFilter: { kind: "assigned_to_member", value: null } });
    const assigned = { assignees: [{ id: 9, login: "octocat" }] };

    await record("issues", issuesEvent("opened"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1 });

    await record("issues", issuesEvent("opened", assigned));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1 });
    expect(await pg.db.task.count()).toBe(0);

    await linkGithubOauth(account.userId, "9");
    await record("issues", issuesEvent("opened", assigned));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });
    expect(await pg.db.task.count()).toBe(1);
  });

  // A task that silently stops tracking its issue is worse than one that
  // arguably should not have been imported, and only the second is visible.
  test("a task already imported keeps updating after it falls out of scope", async () => {
    await withFilter({ importFilter: { kind: "label", value: "bug" } });

    await record("issues", issuesEvent("opened", { labels: [{ name: "bug", color: "d73a4a" }] }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    await record("issues", issuesEvent("unlabeled", { labels: [], title: "still ours" }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1, dropped: 0 });

    const task = await onlyTask();
    expect(task.title).toBe("still ours");
    expect(task.labels).toHaveLength(0);
  });
});

describe("drainGithubWebhooks — labels", () => {
  test("remote labels are created and attached with their provider colour", async () => {
    const account = await makeAccount();
    const task = await importedTask(account, {
      labels: [
        { name: "bug", color: "d73a4a" },
        { name: "chore", color: "0e8a16" },
      ],
    });

    expect(task.labels.map((entry) => `${entry.label.name}:${entry.label.color}`).sort()).toEqual([
      "bug:d73a4a",
      "chore:0e8a16",
    ]);
    // Account-wide, because the repository is bound to no project.
    expect((await pg.db.label.findMany()).every((label) => label.projectId === null)).toBe(true);
  });

  test("a label removed on GitHub is removed locally", async () => {
    const account = await makeAccount();
    await importedTask(account, {
      labels: [
        { name: "bug", color: "d73a4a" },
        { name: "chore", color: "0e8a16" },
      ],
    });

    await record("issues", issuesEvent("unlabeled", { labels: [{ name: "bug", color: "d73a4a" }] }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const after = await onlyTask();
    expect(after.labels.map((entry) => entry.label.name)).toEqual(["bug"]);
    // The Label row survives: it is account vocabulary, not a property of one task.
    expect(await pg.db.label.count()).toBe(2);
  });

  test("a label added on GitHub is attached without recreating the existing ones", async () => {
    const account = await makeAccount();
    await importedTask(account, { labels: [{ name: "bug", color: "d73a4a" }] });

    await record(
      "issues",
      issuesEvent("labeled", {
        labels: [
          { name: "bug", color: "d73a4a" },
          { name: "P1", color: "ffffff" },
        ],
      })
    );
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const after = await onlyTask();
    expect(after.labels.map((entry) => entry.label.name).sort()).toEqual(["P1", "bug"]);
    expect(await pg.db.label.count()).toBe(2);
  });
});

describe("drainGithubWebhooks — issue comments", () => {
  test("a comment imports against its task with the author as a snapshot", async () => {
    const account = await makeAccount();
    await importedTask(account);

    await record("issue_comment", commentEvent("created"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const comments = await pg.db.taskComment.findMany();
    expect(comments).toHaveLength(1);
    expect(comments[0]!.body).toBe("a comment");
    expect(comments[0]!.externalId).toBe("5001");
    expect(comments[0]!.authorExternalLogin).toBe("octocat");
    // No provider-identity to member mapping exists, so the author never
    // resolves to a `user` row.
    expect(comments[0]!.authorUserId).toBeNull();
  });

  test("re-delivering a comment updates it rather than duplicating it", async () => {
    const account = await makeAccount();
    await importedTask(account);
    await record("issue_comment", commentEvent("created"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    await record("issue_comment", commentEvent("edited", { body: "an edited comment" }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const comments = await pg.db.taskComment.findMany();
    expect(comments).toHaveLength(1);
    expect(comments[0]!.body).toBe("an edited comment");
  });

  test("deleted soft-deletes, so the same comment cannot import again as a new one", async () => {
    const account = await makeAccount();
    await importedTask(account);
    await record("issue_comment", commentEvent("created"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    await record("issue_comment", commentEvent("deleted"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const comments = await pg.db.taskComment.findMany();
    expect(comments).toHaveLength(1);
    expect(comments[0]!.deletedAt).not.toBeNull();
  });

  // The cap bounds a THREAD, not a repository: it is asked per task, and an
  // edit to a comment already imported is never refused by it.
  test("the comment cap bounds new comments per task and never blocks an edit", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    await addRepo(account, integration, { commentImportCap: 1 });
    await record("issues", issuesEvent("opened"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    await record("issue_comment", commentEvent("created"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const second = await record(
      "issue_comment",
      commentEvent("created", { id: 5002, body: "over the cap" })
    );
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    expect((await reload(second.id)).processedAt).not.toBeNull();
    expect(await pg.db.taskComment.count()).toBe(1);

    await record("issue_comment", commentEvent("edited", { body: "still editable" }));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });
    expect((await pg.db.taskComment.findFirstOrThrow()).body).toBe("still editable");
  });

  test("a cap of zero imports the issue and none of its comments", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    await addRepo(account, integration, { commentImportCap: 0 });

    await record("issue_comment", commentEvent("created"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    expect(await pg.db.task.count()).toBe(1);
    expect(await pg.db.taskComment.count()).toBe(0);
  });

  // The `issues` event that opened it may have arrived while the repository was
  // disabled, or given up at the ceiling; nothing will redeliver it.
  test("a comment for a task nobody imported yet imports the issue too", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    await addRepo(account, integration);

    await record("issue_comment", commentEvent("created"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ applied: 1 });

    const task = await onlyTask();
    expect(task.source).toBe("github");
    expect(task.externalId).toBe("1001");
    expect(await pg.db.taskComment.count()).toBe(1);
  });

  test("a comment on a pull request is dropped with the pull request", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    await addRepo(account, integration);

    await record(
      "issue_comment",
      commentEvent("created", {}, { pull_request: { url: "https://api.github.com/pulls/7" } })
    );
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    expect(await pg.db.task.count()).toBe(0);
    expect(await pg.db.taskComment.count()).toBe(0);
  });

  test("a comment for an out-of-scope issue is dropped with the issue", async () => {
    const account = await makeAccount();
    const integration = await connect(account);
    await addRepo(account, integration, { importFilter: { kind: "label", value: "bug" } });

    await record("issue_comment", commentEvent("created"));
    expect(await drainGithubWebhooks(pg.db)).toMatchObject({ dropped: 1, applied: 0 });
    expect(await pg.db.task.count()).toBe(0);
  });
});

describe("the scheduled runner", () => {
  test("drains what the route recorded and reports the queue empty", async () => {
    // No integration seeded, so both deliveries resolve to nothing we own and are
    // dropped - closed rather than retried, which is what the loop needs to see
    // to reach an empty pass.
    await record("issue_comment", commentEvent("created"));
    await record("issue_comment", commentEvent("created"));

    const report = await drainGithubBacklog(githubDrainLoopDeps(pg.db));

    expect(report.stoppedBecause).toBe("queue_empty");
    expect(report.backlogRemains).toBe(false);
    expect(report.scanned).toBe(2);
    expect(report.processed).toBe(2);
    expect(report.dropped).toBe(2);
    // Two passes for two rows: the second is the one that proves the queue empty,
    // and a runner that skipped it would stop one pass short of knowing.
    expect(report.passes).toBe(2);
    expect(report.purgeError).toBeNull();
    expect(await pg.db.webhookEvent.count({ where: { processedAt: null } })).toBe(0);
  });
});
