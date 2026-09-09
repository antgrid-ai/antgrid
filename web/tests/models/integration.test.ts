import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser, createTestSubscription } from "../helpers/fixtures.js";
import {
  getIntegration,
  listIntegrationRepos,
  listIntegrations,
  parseImportFilter,
  resolveInstallation,
  resolveIntegrationRepo,
  revokeIntegration,
  setRepoSyncSettings,
  upsertIntegration,
  upsertIntegrationRepo,
  type IntegrationRecord,
  type IntegrationRepoRecord,
} from "../../src/models/integration.js";

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

async function connect(
  account: Account,
  overrides: Partial<Parameters<typeof upsertIntegration>[1]> = {}
): Promise<IntegrationRecord> {
  return ok(
    await upsertIntegration(pg.db, {
      accountId: account.accountId,
      provider: "github",
      externalAccountId: "org-x",
      installationId: "install-1",
      displayName: "acme",
      installedBy: account.userId,
      ...overrides,
    })
  ).integration;
}

async function addRepo(
  account: Account,
  integrationId: string,
  overrides: Partial<Parameters<typeof upsertIntegrationRepo>[1]> = {}
): Promise<IntegrationRepoRecord> {
  return ok(
    await upsertIntegrationRepo(pg.db, {
      accountId: account.accountId,
      integrationId,
      repoKey: "github.com/acme/relay",
      externalRepoId: "gh-100",
      visibility: "private",
      syncEnabled: true,
      ...overrides,
    })
  ).repo;
}

/** The error string of a write the database is expected to refuse. Empty when
 *  it was not refused, which reads better in an expectation than a thrown
 *  assertion inside the try. */
async function refusal(write: () => Promise<unknown>): Promise<string> {
  try {
    await write();
  } catch (err) {
    return String(err);
  }
  return "";
}

describe("resolveInstallation: the cross-tenant boundary", () => {
  test("a reinstall on the same org routes to the new account, and the revoked row is dropped rather than routed", async () => {
    const a = await makeAccount();
    const b = await makeAccount();

    const aIntegration = await connect(a, { installationId: "install-a" });
    expect(await revokeIntegration(pg.db, a.accountId, aIntegration.id)).toBe(true);

    // Same provider account, a different Antgrid account, a fresh installation
    // id — exactly what an uninstall-then-reinstall on org X produces.
    const bIntegration = await connect(b, { installationId: "install-b" });

    const routed = await resolveInstallation(pg.db, "github", "install-b");
    expect(routed?.id).toBe(bIntegration.id);
    expect(routed?.accountId).toBe(b.accountId);

    // A late delivery for A's dead installation must land nowhere. Routing it
    // through the account-scoped key would put B's issue bodies in A's tenant.
    expect(await resolveInstallation(pg.db, "github", "install-a")).toBeNull();
  });

  test("a suspended-but-live installation still routes", async () => {
    const a = await makeAccount();
    const integration = await connect(a, { installationId: "install-s", status: "suspended" });
    expect((await resolveInstallation(pg.db, "github", "install-s"))?.id).toBe(integration.id);
  });

  test("an unknown provider or installation id resolves to nothing", async () => {
    const a = await makeAccount();
    await connect(a);
    expect(await resolveInstallation(pg.db, "gitlab", "install-1")).toBeNull();
    expect(await resolveInstallation(pg.db, "github", "install-nope")).toBeNull();
    expect(await resolveInstallation(pg.db, "github", "")).toBeNull();
  });
});

describe("Integration uniques", () => {
  test("two accounts hold the same externalAccountId at once", async () => {
    const a = await makeAccount();
    const b = await makeAccount();

    const first = await connect(a, { installationId: "install-a" });
    const second = await connect(b, { installationId: "install-b" });

    expect(first.externalAccountId).toBe(second.externalAccountId);
    expect(first.id).not.toBe(second.id);
  });

  test("an installation id another account holds is refused, never taken over", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    await connect(a, { installationId: "install-shared" });

    const result = await upsertIntegration(pg.db, {
      accountId: b.accountId,
      provider: "github",
      externalAccountId: "org-y",
      installationId: "install-shared",
      displayName: "acme",
      installedBy: b.userId,
    });

    expect(result.kind).toBe("installation_taken");
    // The row inbound deliveries route through is still A's.
    expect((await resolveInstallation(pg.db, "github", "install-shared"))?.accountId).toBe(
      a.accountId
    );
  });

  test("integrations with no installation id coexist, because NULLs are distinct", async () => {
    const a = await makeAccount();
    const b = await makeAccount();

    const first = await connect(a, { installationId: null, externalAccountId: "linear-a" });
    const second = await connect(b, { installationId: null, externalAccountId: "linear-b" });

    expect(first.installationId).toBeNull();
    expect(second.installationId).toBeNull();
    expect(first.id).not.toBe(second.id);
  });

  test("reconnecting a revoked integration revives the row rather than leaving two", async () => {
    const a = await makeAccount();
    const first = await connect(a, { installationId: "install-1" });
    await revokeIntegration(pg.db, a.accountId, first.id);

    const again = await connect(a, { installationId: "install-2" });

    expect(again.id).toBe(first.id);
    expect(again.revokedAt).toBeNull();
    expect(await listIntegrations(pg.db, a.accountId)).toHaveLength(1);
    expect((await resolveInstallation(pg.db, "github", "install-2"))?.id).toBe(first.id);
  });

  test("an unknown provider is refused before it reaches a column", async () => {
    const a = await makeAccount();
    const result = await upsertIntegration(pg.db, {
      accountId: a.accountId,
      provider: "gitlab",
      externalAccountId: "org-x",
      displayName: "acme",
      installedBy: a.userId,
    });
    expect(result.kind).toBe("invalid_provider");
  });
});

describe("account scoping", () => {
  test("getIntegration refuses another account's id", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const integration = await connect(a);

    expect(await getIntegration(pg.db, b.accountId, integration.id)).toBeNull();
    expect((await getIntegration(pg.db, a.accountId, integration.id))?.id).toBe(integration.id);
  });

  test("listIntegrations returns only the caller's", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    await connect(a, { installationId: "install-a" });
    await connect(b, { installationId: "install-b" });

    const listed = await listIntegrations(pg.db, a.accountId);
    expect(listed).toHaveLength(1);
    expect(listed[0]!.accountId).toBe(a.accountId);
  });

  test("revokeIntegration refuses another account's id", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const integration = await connect(a);

    expect(await revokeIntegration(pg.db, b.accountId, integration.id)).toBe(false);
    expect((await getIntegration(pg.db, a.accountId, integration.id))?.revokedAt).toBeNull();
  });

  test("listIntegrationRepos returns nothing for another account's integration", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const integration = await connect(a);
    await addRepo(a, integration.id);

    expect(await listIntegrationRepos(pg.db, b.accountId, integration.id)).toHaveLength(0);
    expect(await listIntegrationRepos(pg.db, a.accountId, integration.id)).toHaveLength(1);
  });

  test("upsertIntegrationRepo refuses another account's integrationId", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const integration = await connect(a);

    const result = await upsertIntegrationRepo(pg.db, {
      accountId: b.accountId,
      integrationId: integration.id,
      repoKey: "github.com/acme/relay",
      externalRepoId: "gh-100",
      visibility: "private",
      syncEnabled: true,
    });

    expect(result.kind).toBe("integration_not_found");
    expect(await pg.db.integrationRepo.count()).toBe(0);
  });

  test("upsertIntegrationRepo refuses another account's projectId", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const integration = await connect(a);
    const project = await pg.db.project.create({
      data: { accountId: b.accountId, repoKey: "github.com/acme/relay", displayName: "relay" },
      select: { id: true },
    });

    const result = await upsertIntegrationRepo(pg.db, {
      accountId: a.accountId,
      integrationId: integration.id,
      repoKey: "github.com/acme/relay",
      externalRepoId: "gh-100",
      projectId: project.id,
      visibility: "private",
      syncEnabled: true,
    });

    expect(result.kind).toBe("project_not_found");
  });

  test("resolveIntegrationRepo and setRepoSyncSettings refuse another account's repo id", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const integration = await connect(a);
    const repo = await addRepo(a, integration.id);

    expect(await resolveIntegrationRepo(pg.db, b.accountId, repo.id)).toBeNull();
    expect((await resolveIntegrationRepo(pg.db, a.accountId, repo.id))?.id).toBe(repo.id);

    const result = await setRepoSyncSettings(pg.db, {
      accountId: b.accountId,
      repoId: repo.id,
      pushEnabled: true,
    });
    expect(result.kind).toBe("not_found");
    // The consent that governs whether we write to a third party's repository
    // is exactly the one a foreign id must not be able to flip.
    expect((await resolveIntegrationRepo(pg.db, a.accountId, repo.id))?.pushEnabled).toBe(false);
  });

  test("a malformed id is a refusal, not a driver error", async () => {
    const a = await makeAccount();
    expect(await getIntegration(pg.db, a.accountId, "not-a-uuid")).toBeNull();
    expect(await revokeIntegration(pg.db, a.accountId, "not-a-uuid")).toBe(false);
    expect(await listIntegrationRepos(pg.db, a.accountId, "not-a-uuid")).toHaveLength(0);
    expect(await resolveIntegrationRepo(pg.db, a.accountId, "not-a-uuid")).toBeNull();
  });
});

describe("IntegrationRepo uniques", () => {
  test("one repoKey per integration", async () => {
    const a = await makeAccount();
    const integration = await connect(a);
    await addRepo(a, integration.id, { repoKey: "github.com/acme/relay", externalRepoId: "gh-1" });

    const result = await upsertIntegrationRepo(pg.db, {
      accountId: a.accountId,
      integrationId: integration.id,
      repoKey: "github.com/acme/relay",
      externalRepoId: "gh-2",
      visibility: "private",
      syncEnabled: true,
    });

    expect(result.kind).toBe("repo_key_conflict");
  });

  test("one externalRepoId per integration: a rename updates the row rather than adding one", async () => {
    const a = await makeAccount();
    const integration = await connect(a);
    const first = await addRepo(a, integration.id, {
      repoKey: "github.com/acme/relay",
      externalRepoId: "gh-1",
    });

    const renamed = await addRepo(a, integration.id, {
      repoKey: "github.com/acme/router",
      externalRepoId: "gh-1",
    });

    expect(renamed.id).toBe(first.id);
    expect(renamed.repoKey).toBe("github.com/acme/router");
    expect(await pg.db.integrationRepo.count()).toBe(1);
  });

  test("two integrations may hold the same repository", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const aIntegration = await connect(a, { installationId: "install-a" });
    const bIntegration = await connect(b, { installationId: "install-b" });

    await addRepo(a, aIntegration.id);
    await addRepo(b, bIntegration.id);

    expect(await pg.db.integrationRepo.count()).toBe(2);
  });

  test("an invalid repoKey never reaches the column", async () => {
    const a = await makeAccount();
    const integration = await connect(a);
    const result = await upsertIntegrationRepo(pg.db, {
      accountId: a.accountId,
      integrationId: integration.id,
      repoKey: "acme/relay",
      externalRepoId: "gh-1",
      visibility: "private",
      syncEnabled: true,
    });
    expect(result.kind).toBe("invalid_repo_key");
  });
});

describe("import filter", () => {
  test("the CHECK rejects a kind outside the vocabulary", async () => {
    const a = await makeAccount();
    const integration = await connect(a);
    const repo = await addRepo(a, integration.id);

    const err = await refusal(() =>
      pg.db.$executeRaw`UPDATE integration_repos SET import_filter_kind = 'everything' WHERE id = ${repo.id}::uuid`
    );
    expect(err).toContain("integration_repos_import_filter_check");
  });

  test("the CHECK rejects `all` carrying a filter value", async () => {
    const a = await makeAccount();
    const integration = await connect(a);
    const repo = await addRepo(a, integration.id);

    const err = await refusal(() =>
      pg.db.$executeRaw`UPDATE integration_repos SET import_filter_kind = 'all', import_filter_value = 'bug' WHERE id = ${repo.id}::uuid`
    );
    expect(err).toContain("integration_repos_import_filter_check");
  });

  test("the CHECK rejects `label` with no value", async () => {
    const a = await makeAccount();
    const integration = await connect(a);
    const repo = await addRepo(a, integration.id);

    const err = await refusal(() =>
      pg.db.$executeRaw`UPDATE integration_repos SET import_filter_kind = 'label' WHERE id = ${repo.id}::uuid`
    );
    expect(err).toContain("integration_repos_import_filter_check");
  });

  test("parseImportFilter refuses the pairs the CHECK would", () => {
    expect(parseImportFilter("all", null)).toEqual({ kind: "all", value: null });
    expect(parseImportFilter("assigned_to_member", null)).toEqual({
      kind: "assigned_to_member",
      value: null,
    });
    expect(parseImportFilter("label", "bug")).toEqual({ kind: "label", value: "bug" });
    expect(parseImportFilter("all", "bug")).toBeNull();
    expect(parseImportFilter("label", null)).toBeNull();
    expect(parseImportFilter("label", "   ")).toBeNull();
    expect(parseImportFilter("everything", null)).toBeNull();
  });

  test("setRepoSyncSettings writes a filter pair the CHECK accepts", async () => {
    const a = await makeAccount();
    const integration = await connect(a);
    const repo = await addRepo(a, integration.id);

    const updated = ok(
      await setRepoSyncSettings(pg.db, {
        accountId: a.accountId,
        repoId: repo.id,
        importFilter: { kind: "milestone", value: "v1" },
      })
    ).repo;

    expect(updated.importFilterKind).toBe("milestone");
    expect(updated.importFilterValue).toBe("v1");
  });
});

describe("per-repo consents", () => {
  test("outbound writes and auto-publish are off until asked for", async () => {
    const a = await makeAccount();
    const integration = await connect(a);
    const repo = await addRepo(a, integration.id);

    expect(repo.pushEnabled).toBe(false);
    expect(repo.publishNewByDefault).toBe(false);
    expect(repo.importFilterKind).toBe("all");
    expect(repo.commentImportCap).toBe(100);
  });

  test("a re-discovery refreshes provider facts and leaves the consents alone", async () => {
    const a = await makeAccount();
    const integration = await connect(a);
    const repo = await addRepo(a, integration.id, { externalRepoId: "gh-1" });
    ok(await setRepoSyncSettings(pg.db, { accountId: a.accountId, repoId: repo.id, pushEnabled: true }));

    const refreshed = await addRepo(a, integration.id, {
      externalRepoId: "gh-1",
      visibility: "public",
      syncEnabled: false,
      pushEnabled: false,
    });

    expect(refreshed.visibility).toBe("public");
    expect(refreshed.pushEnabled).toBe(true);
    expect(refreshed.syncEnabled).toBe(true);
  });

  test("a comment cap outside the bound is refused", async () => {
    const a = await makeAccount();
    const integration = await connect(a);
    const repo = await addRepo(a, integration.id);

    expect(
      (await setRepoSyncSettings(pg.db, { accountId: a.accountId, repoId: repo.id, commentImportCap: -1 }))
        .kind
    ).toBe("invalid_comment_cap");
    expect(
      (await setRepoSyncSettings(pg.db, {
        accountId: a.accountId,
        repoId: repo.id,
        commentImportCap: 1_000_000,
      })).kind
    ).toBe("invalid_comment_cap");
  });
});

describe("tasks.integration_repo_id", () => {
  test("unlinking a repository nulls the column instead of deleting the tasks", async () => {
    const a = await makeAccount();
    const integration = await connect(a);
    const repo = await addRepo(a, integration.id);

    const task = await pg.db.task.create({
      data: {
        accountId: a.accountId,
        number: 1,
        title: "imported",
        status: "open",
        sortKey: "a0",
        createdBy: a.userId,
        integrationRepoId: repo.id,
      },
      select: { id: true },
    });

    await pg.db.integrationRepo.delete({ where: { id: repo.id } });

    const after = await pg.db.task.findUniqueOrThrow({
      where: { id: task.id },
      select: { integrationRepoId: true },
    });
    expect(after.integrationRepoId).toBeNull();
  });

  test("the foreign key refuses a repo id that does not exist", async () => {
    const a = await makeAccount();
    const err = await refusal(() =>
      pg.db.task.create({
        data: {
          accountId: a.accountId,
          number: 1,
          title: "imported",
          status: "open",
          sortKey: "a0",
          createdBy: a.userId,
          integrationRepoId: crypto.randomUUID(),
        },
      })
    );
    expect(err).not.toBe("");
  });
});

/** The composite unique on `webhook_events` is what stops one provider's
 *  delivery id from swallowing another's as a duplicate. Billing's dedup guard
 *  relies on the violation still being P2002, so that is asserted rather than
 *  assumed. */
describe("webhook_events provider namespace", () => {
  const row = (provider: string) => ({
    provider,
    providerEventId: "evt_1",
    type: "subscription.activated",
    payload: {},
  });

  test("two providers may mint the same delivery id", async () => {
    await pg.db.webhookEvent.create({ data: row("paddle") });
    await pg.db.webhookEvent.create({ data: row("razorpay") });
    expect(await pg.db.webhookEvent.count()).toBe(2);
  });

  test("a repeat within one provider is still a P2002", async () => {
    await pg.db.webhookEvent.create({ data: row("paddle") });
    let code: unknown;
    try {
      await pg.db.webhookEvent.create({ data: row("paddle") });
    } catch (err) {
      code = (err as { code?: string }).code;
    }
    expect(code).toBe("P2002");
  });

  test("the compound where-clause finds the row the reducer dedups on", async () => {
    await pg.db.webhookEvent.create({ data: row("paddle") });
    const found = await pg.db.webhookEvent.findUnique({
      where: { provider_providerEventId: { provider: "paddle", providerEventId: "evt_1" } },
    });
    expect(found).not.toBeNull();
    expect(
      await pg.db.webhookEvent.findUnique({
        where: { provider_providerEventId: { provider: "razorpay", providerEventId: "evt_1" } },
      })
    ).toBeNull();
  });
});
