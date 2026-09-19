import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser, createTestSubscription, createTestDevice } from "../helpers/fixtures.js";
import { bindLocalProject } from "../../src/models/project.js";
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

function ok<T extends { kind: string }>(result: T): Extract<T, { kind: "ok" }> {
  expect(result.kind).toBe("ok");
  return result as Extract<T, { kind: "ok" }>;
}

describe("bindLocalProject: the other half of the repoKey join", () => {
  test("binding a checkout links a GitHub repo discovered earlier with the same repoKey", async () => {
    const a = await makeAccount();
    const device = await createTestDevice(pg.db, { userId: a.userId, deviceId: "dev-1" });
    const integration = ok(
      await upsertIntegration(pg.db, {
        accountId: a.accountId,
        provider: "github",
        externalAccountId: "org-x",
        installationId: "install-1",
        displayName: "acme",
        installedBy: a.userId,
      })
    ).integration;
    const repo = ok(
      await upsertIntegrationRepo(pg.db, {
        accountId: a.accountId,
        integrationId: integration.id,
        repoKey: "github.com/acme/relay",
        externalRepoId: "gh-100",
        visibility: "private",
        syncEnabled: true,
      })
    ).repo;
    expect(repo.projectId).toBeNull();

    const bound = ok(
      await bindLocalProject(pg.db, {
        accountId: a.accountId,
        repoKey: "github.com/acme/relay",
        displayName: "relay",
        deviceId: device.deviceId,
        localProjectId: "local-1",
        localPath: "/home/dev/relay",
      })
    );

    const linked = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repo.id } });
    expect(linked.projectId).toBe(bound.projectId);
  });

  test("never links a repo belonging to another account", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const device = await createTestDevice(pg.db, { userId: b.userId, deviceId: "dev-2" });
    const integration = ok(
      await upsertIntegration(pg.db, {
        accountId: a.accountId,
        provider: "github",
        externalAccountId: "org-x",
        installationId: "install-2",
        displayName: "acme",
        installedBy: a.userId,
      })
    ).integration;
    const repo = ok(
      await upsertIntegrationRepo(pg.db, {
        accountId: a.accountId,
        integrationId: integration.id,
        repoKey: "github.com/acme/relay",
        externalRepoId: "gh-100",
        visibility: "private",
        syncEnabled: true,
      })
    ).repo;

    await bindLocalProject(pg.db, {
      accountId: b.accountId,
      repoKey: "github.com/acme/relay",
      displayName: "relay",
      deviceId: device.deviceId,
      localProjectId: "local-1",
      localPath: "/home/dev/relay",
    });

    const untouched = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repo.id } });
    expect(untouched.projectId).toBeNull();
  });

  test("does not clobber a repo already linked to a project", async () => {
    const a = await makeAccount();
    const device = await createTestDevice(pg.db, { userId: a.userId, deviceId: "dev-3" });
    const otherProject = await pg.db.project.create({
      data: { accountId: a.accountId, repoKey: "github.com/acme/other", displayName: "other" },
      select: { id: true },
    });
    const integration = ok(
      await upsertIntegration(pg.db, {
        accountId: a.accountId,
        provider: "github",
        externalAccountId: "org-x",
        installationId: "install-3",
        displayName: "acme",
        installedBy: a.userId,
      })
    ).integration;
    const repo = ok(
      await upsertIntegrationRepo(pg.db, {
        accountId: a.accountId,
        integrationId: integration.id,
        repoKey: "github.com/acme/relay",
        externalRepoId: "gh-100",
        projectId: otherProject.id,
        visibility: "private",
        syncEnabled: true,
      })
    ).repo;
    expect(repo.projectId).toBe(otherProject.id);

    await bindLocalProject(pg.db, {
      accountId: a.accountId,
      repoKey: "github.com/acme/relay",
      displayName: "relay",
      deviceId: device.deviceId,
      localProjectId: "local-1",
      localPath: "/home/dev/relay",
    });

    const stillLinked = await pg.db.integrationRepo.findUniqueOrThrow({ where: { id: repo.id } });
    expect(stillLinked.projectId).toBe(otherProject.id);
  });
});
