import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { addTestMember, createTestSubscription, createTestUser } from "../helpers/fixtures.js";
import { upsertIntegration, type IntegrationRecord } from "../../src/models/integration.js";
import {
  resolveProviderIdentities,
  type ProviderUser,
} from "../../src/models/integration-identity.js";

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

async function connect(account: Account, installationId: string): Promise<IntegrationRecord> {
  const result = await upsertIntegration(pg.db, {
    accountId: account.accountId,
    provider: "github",
    externalAccountId: `org-${installationId}`,
    installationId,
    displayName: "acme",
    installedBy: account.userId,
  });
  if (result.kind !== "ok") throw new Error(`upsertIntegration: ${result.kind}`);
  return result.integration;
}

/** What Better-Auth writes when a user signs in with GitHub: the provider's
 *  numeric user id in `accountId`, and never the login. That asymmetry is the
 *  whole reason `integration_identities` exists. */
async function linkGithubOauth(userId: string, externalUserId: string): Promise<void> {
  await pg.db.account.create({
    data: { id: randomUUID(), accountId: externalUserId, providerId: "github", userId },
  });
}

const octocat: ProviderUser = {
  externalUserId: "5",
  login: "octocat",
  avatarUrl: "https://avatars/1",
};

async function resolve(
  integration: IntegrationRecord,
  accountId: string,
  users: ProviderUser[] = [octocat]
) {
  return resolveProviderIdentities(pg.db, {
    integrationId: integration.id,
    accountId,
    provider: "github",
    users,
  });
}

async function identityRow(integrationId: string, externalUserId: string) {
  return pg.db.integrationIdentity.findUnique({
    where: { integrationId_externalUserId: { integrationId, externalUserId } },
  });
}

describe("resolveProviderIdentities", () => {
  test("a member who signed in with GitHub resolves to their user id", async () => {
    const account = await makeAccount();
    const integration = await connect(account, "1");
    await linkGithubOauth(account.userId, "5");

    expect(await resolve(integration, account.accountId)).toEqual(new Map([["5", account.userId]]));

    const row = await identityRow(integration.id, "5");
    expect(row).toMatchObject({ userId: account.userId, externalLogin: "octocat" });
    expect(row?.linkedAt).not.toBeNull();
  });

  // The security property of this file. The `account` row proves the GitHub
  // user signed into Antgrid, and nothing more — resolving through it without
  // the membership filter assigns one tenant's issue to a stranger who happens
  // to hold the same provider identity somewhere else.
  test("a GitHub user outside this account does not resolve to a member", async () => {
    const owner = await makeAccount();
    const stranger = await makeAccount();
    const integration = await connect(owner, "1");
    await linkGithubOauth(stranger.userId, "5");

    expect(await resolve(integration, owner.accountId)).toEqual(new Map());

    // Still recorded, because the login and avatar are what the UI renders for
    // an assignee that is nobody on this account.
    const row = await identityRow(integration.id, "5");
    expect(row).toMatchObject({ userId: null, linkedAt: null, externalLogin: "octocat" });
  });

  test("a member whose membership has ended stops resolving", async () => {
    const owner = await makeAccount();
    const leaver = await createTestUser(pg.db);
    await addTestMember(pg.db, owner.accountId, leaver.id);
    await pg.db.accountMember.updateMany({
      where: { userId: leaver.id },
      data: { status: "removed", endedAt: new Date() },
    });
    const integration = await connect(owner, "1");
    await linkGithubOauth(leaver.id, "5");

    expect(await resolve(integration, owner.accountId)).toEqual(new Map());
  });

  // A GitHub login is renameable and a stale one is a wrong name on every
  // assignee chip that reads it, so it refreshes even when nothing else moved.
  test("a renamed login is refreshed on the next sighting", async () => {
    const account = await makeAccount();
    const integration = await connect(account, "1");

    await resolve(integration, account.accountId);
    await resolve(integration, account.accountId, [
      { externalUserId: "5", login: "octocat-renamed", avatarUrl: null },
    ]);

    expect(await identityRow(integration.id, "5")).toMatchObject({
      externalLogin: "octocat-renamed",
      avatarUrl: null,
    });
  });

  // Unlinking is not something an inbound payload gets to do: a member who
  // signed out of GitHub OAuth has not stopped being the assignee of the issues
  // already imported under their name.
  test("an existing link survives the provider identity disappearing", async () => {
    const account = await makeAccount();
    const integration = await connect(account, "1");
    await linkGithubOauth(account.userId, "5");
    await resolve(integration, account.accountId);

    await pg.db.account.deleteMany({ where: { providerId: "github" } });
    expect(await resolve(integration, account.accountId)).toEqual(new Map([["5", account.userId]]));

    expect(await identityRow(integration.id, "5")).toMatchObject({ userId: account.userId });
  });

  test("no assignees means no rows and no queries", async () => {
    const account = await makeAccount();
    const integration = await connect(account, "1");

    expect(await resolve(integration, account.accountId, [])).toEqual(new Map());
    expect(await pg.db.integrationIdentity.count()).toBe(0);
  });

  // The unique is on `[integrationId, externalUserId]` and deliberately not on
  // `[provider, externalUserId]`: one GitHub user assigned issues in two
  // accounts gets a row in each, and the row carrying a `userId` is the one
  // whose account they actually belong to.
  test("one GitHub user resolves per integration, not globally", async () => {
    const a = await makeAccount();
    const b = await makeAccount();
    const integrationA = await connect(a, "1");
    const integrationB = await connect(b, "2");
    await linkGithubOauth(a.userId, "5");

    expect(await resolve(integrationA, a.accountId)).toEqual(new Map([["5", a.userId]]));
    expect(await resolve(integrationB, b.accountId)).toEqual(new Map());
  });

  // Two members claiming one provider identity is unresolvable, and picking
  // either assigns somebody else's work to a colleague.
  test("an identity two members both claim stays unresolved", async () => {
    const owner = await makeAccount();
    const other = await createTestUser(pg.db);
    await addTestMember(pg.db, owner.accountId, other.id);
    const integration = await connect(owner, "1");
    await linkGithubOauth(owner.userId, "5");
    await linkGithubOauth(other.id, "5");

    expect(await resolve(integration, owner.accountId)).toEqual(new Map());
  });
});
