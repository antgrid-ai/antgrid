import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser, createTestSubscription } from "../helpers/fixtures.js";
import {
  listIntegrationRepos,
  listIntegrations,
  upsertIntegration,
} from "../../src/models/integration.js";
import {
  completeGithubInstall,
  startGithubInstall,
  verifyInstallState,
  type DiscoveredRepo,
  type GithubInstallDirectory,
  type InstallationIdentity,
} from "../../src/integrations/github-install.js";

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

const MINE: InstallationIdentity = {
  installationId: "4242",
  externalAccountId: "9001",
  displayName: "acme",
};

function repo(overrides: Partial<DiscoveredRepo> = {}): DiscoveredRepo {
  return {
    externalRepoId: "r1",
    fullName: "acme/relay",
    visibility: "private",
    ...overrides,
  };
}

type DirectoryOverrides = Partial<GithubInstallDirectory>;

/** Records what the flow asked GitHub, so a test can assert on the order as
 *  well as the answer — the identity check is only worth anything if it happens
 *  before the write. */
function directory(overrides: DirectoryOverrides = {}): GithubInstallDirectory & {
  calls: string[];
} {
  const calls: string[] = [];
  return {
    calls,
    async exchangeUserCode(code) {
      calls.push(`exchange:${code}`);
      return overrides.exchangeUserCode ? overrides.exchangeUserCode(code) : "user-token";
    },
    async listUserInstallations(token) {
      calls.push(`installations:${token}`);
      return overrides.listUserInstallations ? overrides.listUserInstallations(token) : [MINE];
    },
    async listInstallationRepos(id) {
      calls.push(`repos:${id}`);
      return overrides.listInstallationRepos ? overrides.listInstallationRepos(id) : [repo()];
    },
  };
}

describe("install state", () => {
  test("the callback is accepted only for the browser and user that started it", () => {
    const started = startGithubInstall({ userId: "u1", appSlug: "antgrid" });
    const state = new URL(started.url).searchParams.get("state")!;

    expect(verifyInstallState({ cookie: started.cookie, state, userId: "u1" })).toBe(true);
    expect(verifyInstallState({ cookie: started.cookie, state, userId: "u2" })).toBe(false);
    expect(verifyInstallState({ cookie: started.cookie, state: "other", userId: "u1" })).toBe(false);
    expect(verifyInstallState({ cookie: undefined, state, userId: "u1" })).toBe(false);
    expect(verifyInstallState({ cookie: started.cookie, state: undefined, userId: "u1" })).toBe(
      false
    );
  });

  test("a user id containing the separator cannot borrow another user's nonce", () => {
    const started = startGithubInstall({ userId: "u1.u2", appSlug: "antgrid" });
    const state = new URL(started.url).searchParams.get("state")!;

    expect(verifyInstallState({ cookie: started.cookie, state, userId: "u1.u2" })).toBe(true);
    expect(verifyInstallState({ cookie: started.cookie, state, userId: "u1" })).toBe(false);
  });

  test("two starts do not share a nonce", () => {
    const a = startGithubInstall({ userId: "u1", appSlug: "antgrid" });
    const b = startGithubInstall({ userId: "u1", appSlug: "antgrid" });
    expect(a.cookie).not.toBe(b.cookie);
  });

  test("the slug is escaped into the URL rather than concatenated", () => {
    const started = startGithubInstall({ userId: "u1", appSlug: "a b/../evil" });
    expect(started.url.startsWith("https://github.com/apps/")).toBe(true);
    expect(started.url).not.toContain("/../");
  });
});

describe("completeGithubInstall", () => {
  test("binds the installation and records its repositories, none of them enabled", async () => {
    const account = await makeAccount();
    const gh = directory({
      async listInstallationRepos() {
        return [
          repo({ externalRepoId: "r1", fullName: "acme/relay", visibility: "private" }),
          repo({ externalRepoId: "r2", fullName: "acme/site", visibility: "public" }),
        ];
      },
    });

    const result = await completeGithubInstall(pg.db, gh, {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "code-1",
    });

    expect(result).toMatchObject({ kind: "ok", reposRecorded: 2, reposSkipped: 0 });

    const integrations = await listIntegrations(pg.db, account.accountId);
    expect(integrations).toHaveLength(1);
    expect(integrations[0]).toMatchObject({
      installationId: "4242",
      externalAccountId: "9001",
      displayName: "acme",
      installedBy: account.userId,
      status: "active",
      revokedAt: null,
    });

    const repos = await listIntegrationRepos(pg.db, account.accountId, integrations[0]!.id);
    expect(repos.map((r) => [r.repoKey, r.visibility, r.syncEnabled])).toEqual([
      ["github.com/acme/relay", "private", false],
      ["github.com/acme/site", "public", false],
    ]);
  });

  test("the identity check runs before anything is written", async () => {
    const account = await makeAccount();
    const gh = directory({
      async listUserInstallations() {
        return [{ ...MINE, installationId: "1" }];
      },
    });

    const result = await completeGithubInstall(pg.db, gh, {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "code-1",
    });

    expect(result).toEqual({ kind: "not_your_installation" });
    expect(await listIntegrations(pg.db, account.accountId)).toHaveLength(0);
    // No repository listing either: a refused installation must not become a
    // reason to spend an installation token on it.
    expect(gh.calls).toEqual(["exchange:code-1", "installations:user-token"]);
  });

  test("an installation another account holds is refused, not taken over", async () => {
    const victim = await makeAccount();
    const attacker = await makeAccount();
    await upsertIntegration(pg.db, {
      accountId: victim.accountId,
      provider: "github",
      externalAccountId: "9001",
      installationId: "4242",
      displayName: "acme",
      installedBy: victim.userId,
    });

    // The attacker's GitHub user genuinely administers it — the identity check
    // passes and the global unique is the thing that has to refuse.
    const result = await completeGithubInstall(pg.db, directory(), {
      accountId: attacker.accountId,
      userId: attacker.userId,
      installationId: "4242",
      code: "code-1",
    });

    expect(result).toEqual({ kind: "installation_taken" });
    expect(await listIntegrations(pg.db, attacker.accountId)).toHaveLength(0);
    expect(await listIntegrations(pg.db, victim.accountId)).toHaveLength(1);
  });

  test("a rejected code never reaches the installation list", async () => {
    const account = await makeAccount();
    const gh = directory({
      async exchangeUserCode() {
        return null;
      },
    });

    const result = await completeGithubInstall(pg.db, gh, {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "stale",
    });

    expect(result).toEqual({ kind: "code_rejected" });
    expect(gh.calls).toEqual(["exchange:stale"]);
  });

  test("a provider failure is reported without the token that caused it", async () => {
    const account = await makeAccount();
    const gh = directory({
      async listUserInstallations() {
        throw new Error("GET /user/installations failed: 503");
      },
    });

    const result = await completeGithubInstall(pg.db, gh, {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "code-1",
    });

    expect(result.kind).toBe("provider_error");
    expect(JSON.stringify(result)).not.toContain("user-token");
  });

  test("a repository name that cannot be folded into a repo key is skipped, not invented", async () => {
    const account = await makeAccount();
    const gh = directory({
      async listInstallationRepos() {
        return [repo({ externalRepoId: "r1", fullName: "not-a-full-name" }), repo()];
      },
    });

    const result = await completeGithubInstall(pg.db, gh, {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "code-1",
    });

    expect(result).toMatchObject({ kind: "ok", reposRecorded: 1, reposSkipped: 1 });
  });

  test("re-running the flow leaves a consent the user already gave alone", async () => {
    const account = await makeAccount();
    const first = await completeGithubInstall(pg.db, directory(), {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "code-1",
    });
    const integrationId = (first as { integrationId: string }).integrationId;

    const [only] = await listIntegrationRepos(pg.db, account.accountId, integrationId);
    await pg.db.integrationRepo.update({
      where: { id: only!.id },
      data: { syncEnabled: true },
    });

    await completeGithubInstall(pg.db, directory(), {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "code-2",
    });

    const after = await listIntegrationRepos(pg.db, account.accountId, integrationId);
    expect(after[0]!.syncEnabled).toBe(true);
  });

  test("a repository dropped from the installation is marked removed and stops syncing", async () => {
    const account = await makeAccount();
    const both = directory({
      async listInstallationRepos() {
        return [repo({ externalRepoId: "r1", fullName: "acme/relay" }), repo({ externalRepoId: "r2", fullName: "acme/site" })];
      },
    });
    const first = await completeGithubInstall(pg.db, both, {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "code-1",
    });
    const integrationId = (first as { integrationId: string }).integrationId;
    await pg.db.integrationRepo.updateMany({ data: { syncEnabled: true } });

    const dropped = directory({
      async listInstallationRepos() {
        return [repo({ externalRepoId: "r1", fullName: "acme/relay" })];
      },
    });
    await completeGithubInstall(pg.db, dropped, {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "code-2",
    });

    const after = await listIntegrationRepos(pg.db, account.accountId, integrationId);
    const kept = after.find((r) => r.externalRepoId === "r1")!;
    const gone = after.find((r) => r.externalRepoId === "r2")!;
    expect(kept.removedAt).toBeNull();
    expect(kept.syncEnabled).toBe(true);
    expect(gone.removedAt).not.toBeNull();
    expect(gone.syncEnabled).toBe(false);
  });

  test("a repository that comes back is reachable again, but not re-enabled", async () => {
    const account = await makeAccount();
    const first = await completeGithubInstall(pg.db, directory(), {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "code-1",
    });
    const integrationId = (first as { integrationId: string }).integrationId;
    await pg.db.integrationRepo.updateMany({
      data: { syncEnabled: false, removedAt: new Date() },
    });

    await completeGithubInstall(pg.db, directory(), {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "code-2",
    });

    const [back] = await listIntegrationRepos(pg.db, account.accountId, integrationId);
    expect(back!.removedAt).toBeNull();
    expect(back!.syncEnabled).toBe(false);
  });

  test("an empty repository list is treated as an error, not as every repository leaving", async () => {
    const account = await makeAccount();
    const first = await completeGithubInstall(pg.db, directory(), {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "code-1",
    });
    const integrationId = (first as { integrationId: string }).integrationId;
    await pg.db.integrationRepo.updateMany({ data: { syncEnabled: true } });

    const empty = directory({
      async listInstallationRepos() {
        return [];
      },
    });
    await completeGithubInstall(pg.db, empty, {
      accountId: account.accountId,
      userId: account.userId,
      installationId: "4242",
      code: "code-2",
    });

    const [survivor] = await listIntegrationRepos(pg.db, account.accountId, integrationId);
    expect(survivor!.removedAt).toBeNull();
    expect(survivor!.syncEnabled).toBe(true);
  });
});
