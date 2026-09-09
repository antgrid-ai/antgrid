import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import postgres from "postgres";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestSubscription, createTestUser } from "../helpers/fixtures.js";
import {
  upsertIntegration,
  upsertIntegrationRepo,
  type IntegrationRecord,
} from "../../src/models/integration.js";
import { GITHUB_PER_PAGE, GithubApiError } from "../../src/integrations/github-app.js";
import type { GithubIssue } from "../../src/integrations/github-events.js";
import type { GithubIssueLister } from "../../src/integrations/github-issues.js";
import { createPointsBudget } from "../../src/integrations/github-push-policy.js";
import {
  POLL_OVERLAP_SECONDS,
  pollDueRepos,
  type GithubPollDeps,
} from "../../src/integrations/github-poll.js";
import { githubPollNeedsAttention } from "../../src/integrations/github-poll-loop.js";

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

/** One connected, import-enabled repository — the precondition of every walk
 *  below and the thing none of them asserts. */
async function connectedRepo(overrides: Partial<Parameters<typeof upsertIntegrationRepo>[1]> = {}) {
  const account = await makeAccount();
  const integration = await connect(account);
  const repo = await addRepo(account, integration, overrides);
  return { account, integration, repo };
}

const BASE = Date.parse("2026-08-01T00:00:00.000Z");

/** Minute `n` of the fixture clock. Spaced a minute apart so the overlap window
 *  covers exactly one neighbour, which is what makes the resume assertions
 *  countable rather than approximate. */
const minute = (n: number) => new Date(BASE + n * 60_000).toISOString();

function anIssue(n: number, updatedAt: string, over: Record<string, unknown> = {}): GithubIssue {
  return {
    id: String(1000 + n),
    number: n,
    title: `issue ${n}`,
    body: "body",
    state: "open",
    html_url: `https://github.com/acme/relay/issues/${n}`,
    updated_at: updatedAt,
    ...over,
  } as GithubIssue;
}

/** A pull request as the LISTING carries it: the issue object itself holds the
 *  `pull_request` key, with no webhook envelope around it. */
const aPullRequest = (n: number, updatedAt: string) =>
  anIssue(n, updatedAt, { pull_request: { url: "https://api.github.com/pulls/1" } });

type ListCall = { owner: string; repo: string; since: string | null; page: number };

/**
 * The repository as GitHub would page it: filtered by `since`, sliced by
 * `GITHUB_PER_PAGE`, in the ascending order the real query asks for. `items`
 * must already be in that order — the fake does not sort, so a test that hands
 * it unordered fixtures is testing something GitHub never sends.
 */
function fakeGithub(items: GithubIssue[], fail?: () => never) {
  const calls: ListCall[] = [];
  const lister: GithubIssueLister = {
    async listRepoIssuesSince(ref, args) {
      calls.push({ ...ref, since: args.since?.toISOString() ?? null, page: args.page });
      if (fail) fail();
      const visible =
        args.since === null
          ? items
          : items.filter((item) => Date.parse(item.updated_at ?? "") >= args.since!.getTime());
      const start = (args.page - 1) * GITHUB_PER_PAGE;
      return visible.slice(start, start + GITHUB_PER_PAGE);
    },
  };
  return { lister, calls };
}

function deps(lister: GithubIssueLister, over: Partial<GithubPollDeps> = {}): GithubPollDeps {
  return {
    resolveLister: async () => lister,
    budget: createPointsBudget(),
    now: () => new Date(),
    ...over,
  };
}

async function reloadRepo(id: string) {
  return pg.db.integrationRepo.findUniqueOrThrow({ where: { id } });
}

describe("pollDueRepos — the first import", () => {
  test("a repository nobody has synced imports every issue and records that it is caught up", async () => {
    const { repo } = await connectedRepo();
    const { lister, calls } = fakeGithub([
      anIssue(1, minute(1)),
      anIssue(2, minute(2)),
      anIssue(3, minute(3)),
    ]);

    const report = await pollDueRepos(pg.db, deps(lister));

    expect(report).toMatchObject({ scanned: 1, walked: 1, imported: 3, merged: 0, completed: 1 });
    expect(report.repos[0]).toMatchObject({ stoppedBecause: "caught_up", pages: 1, seen: 3 });
    expect(report.backlogRemains).toBe(false);
    expect(await pg.db.task.count()).toBe(3);

    // A first import has no cursor to resume from, and inventing one would
    // silently exclude everything older than it — which is the entire backlog.
    expect(calls).toEqual([{ owner: "acme", repo: "relay", since: null, page: 1 }]);

    const after = await reloadRepo(repo.id);
    expect(after.lastCursor).toBe(minute(3));
    expect(after.lastFullSyncAt).not.toBeNull();
  });

  test("the imported task carries the provenance the launch sheet reads", async () => {
    await connectedRepo();
    const { lister } = fakeGithub([anIssue(7, minute(1))]);

    await pollDueRepos(pg.db, deps(lister));

    const task = await pg.db.task.findFirstOrThrow();
    expect(task).toMatchObject({
      source: "github",
      externalProvider: "github",
      externalId: "1007",
      externalKey: "acme/relay#7",
      syncState: "synced",
    });
  });
});

describe("pollDueRepos — resuming", () => {
  test("a second run sends the stored cursor MINUS the overlap, never the bare cursor", async () => {
    const { repo } = await connectedRepo();
    const items = [anIssue(1, minute(1)), anIssue(2, minute(2))];

    await pollDueRepos(pg.db, deps(fakeGithub(items).lister));
    const cursor = (await reloadRepo(repo.id)).lastCursor;
    expect(cursor).toBe(minute(2));

    const second = fakeGithub(items);
    await pollDueRepos(pg.db, deps(second.lister));

    expect(second.calls[0]!.since).toBe(
      new Date(Date.parse(cursor!) - POLL_OVERLAP_SECONDS * 1000).toISOString()
    );
  });

  test("an issue that has not moved merges to nothing and queues no push", async () => {
    await connectedRepo();
    const items = [anIssue(1, minute(1))];

    await pollDueRepos(pg.db, deps(fakeGithub(items).lister));
    const before = await pg.db.task.findFirstOrThrow();

    const report = await pollDueRepos(pg.db, deps(fakeGithub(items).lister));

    expect(report).toMatchObject({ imported: 0, merged: 1 });
    const after = await pg.db.task.findFirstOrThrow();
    expect(after).toMatchObject({
      id: before.id,
      title: before.title,
      body: before.body,
      status: before.status,
      syncState: before.syncState,
    });
    expect(after.remoteUpdatedAt?.toISOString()).toBe(before.remoteUpdatedAt?.toISOString());
    // The import is one-way; a reconcile that queued an outbound op would push
    // the provider's own state straight back at it.
    expect(await pg.db.taskSyncOp.count()).toBe(0);
  });

  test("an issue edited on GitHub since the last import merges the change in", async () => {
    await connectedRepo();
    await pollDueRepos(pg.db, deps(fakeGithub([anIssue(1, minute(1))]).lister));

    const edited = anIssue(1, minute(4), { title: "renamed upstream", state: "closed" });
    const report = await pollDueRepos(pg.db, deps(fakeGithub([edited]).lister));

    expect(report).toMatchObject({ imported: 0, merged: 1 });
    const task = await pg.db.task.findFirstOrThrow();
    expect(task.title).toBe("renamed upstream");
    expect(task.status).toBe("done");
  });

  test("a listing item with no readable timestamp stops the cursor where it is", async () => {
    const { repo } = await connectedRepo();
    const { lister } = fakeGithub([
      anIssue(1, minute(1)),
      anIssue(2, minute(2), { updated_at: null }),
      anIssue(3, minute(3)),
    ]);

    const report = await pollDueRepos(pg.db, deps(lister));

    // All three import; only the cursor is held back. Advancing past the
    // unreadable one would skip it for ever, and the overlap makes re-reading
    // the two behind it free.
    expect(report).toMatchObject({ imported: 3, completed: 1 });
    expect((await reloadRepo(repo.id)).lastCursor).toBe(minute(1));
  });
});

describe("pollDueRepos — what the walk refuses", () => {
  test("a pull request in the LISTING is skipped and never becomes a task", async () => {
    await connectedRepo();
    const { lister } = fakeGithub([aPullRequest(1, minute(1)), anIssue(2, minute(2))]);

    const report = await pollDueRepos(pg.db, deps(lister));

    expect(report).toMatchObject({ seen: 2, imported: 1, dropped: 1 });
    expect(report.reasons).toMatchObject({ pull_request: 1 });
    const tasks = await pg.db.task.findMany();
    expect(tasks).toHaveLength(1);
    expect(tasks[0]!.externalId).toBe("1002");
  });

  test("the import filter still bounds what the poll pulls in", async () => {
    await connectedRepo({ importFilter: { kind: "label", value: "bug" } });
    const { lister } = fakeGithub([
      anIssue(1, minute(1)),
      anIssue(2, minute(2), { labels: [{ name: "bug" }] }),
    ]);

    const report = await pollDueRepos(pg.db, deps(lister));

    expect(report).toMatchObject({ imported: 1, dropped: 1 });
    expect(report.reasons).toMatchObject({ filtered_out: 1 });
    expect(await pg.db.task.count()).toBe(1);
  });

  test("a repository with import switched off is never walked", async () => {
    await connectedRepo({ syncEnabled: false });
    const { lister, calls } = fakeGithub([anIssue(1, minute(1))]);

    const report = await pollDueRepos(pg.db, deps(lister));

    expect(report).toMatchObject({ scanned: 0, walked: 0, imported: 0 });
    expect(calls).toHaveLength(0);
    expect(await pg.db.task.count()).toBe(0);
  });

  test("a repository under a REVOKED installation is never walked", async () => {
    const { integration } = await connectedRepo();
    await pg.db.integration.update({
      where: { id: integration.id },
      data: { revokedAt: new Date(), status: "revoked" },
    });
    const { lister, calls } = fakeGithub([anIssue(1, minute(1))]);

    const report = await pollDueRepos(pg.db, deps(lister));

    expect(report.scanned).toBe(0);
    expect(calls).toHaveLength(0);
    expect(await pg.db.task.count()).toBe(0);
  });

  test("a repository removed from the installation is never walked", async () => {
    const { repo } = await connectedRepo();
    await pg.db.integrationRepo.update({
      where: { id: repo.id },
      data: { removedAt: new Date() },
    });
    const { lister, calls } = fakeGithub([anIssue(1, minute(1))]);

    expect(await pollDueRepos(pg.db, deps(lister))).toMatchObject({ scanned: 0 });
    expect(calls).toHaveLength(0);
  });

  test("a repoKey that names no addressable GitHub repository is counted, not thrown", async () => {
    await connectedRepo({ repoKey: "gitlab.com/acme/relay" });
    const { lister, calls } = fakeGithub([anIssue(1, minute(1))]);

    const report = await pollDueRepos(pg.db, deps(lister));

    expect(report.repos[0]).toMatchObject({ stoppedBecause: "unroutable", pages: 0 });
    expect(calls).toHaveLength(0);
    expect(githubPollNeedsAttention(report)).toBe(true);
  });
});

describe("pollDueRepos — bounds", () => {
  // 100 items is a FULL page, which is the only thing that tells the walk there
  // may be more; a short page would end it as caught up instead.
  const fullPage = Array.from({ length: GITHUB_PER_PAGE }, (_, i) =>
    aPullRequest(i + 1, minute(i + 1))
  );
  const tail = [
    anIssue(GITHUB_PER_PAGE + 1, minute(GITHUB_PER_PAGE + 1)),
    anIssue(GITHUB_PER_PAGE + 2, minute(GITHUB_PER_PAGE + 2)),
  ];

  test("the page ceiling advances the cursor but never claims the repository is caught up", async () => {
    const { repo } = await connectedRepo();
    const { lister } = fakeGithub([...fullPage, ...tail]);

    const report = await pollDueRepos(pg.db, deps(lister, { maxPages: 1 }));

    expect(report.repos[0]).toMatchObject({ stoppedBecause: "page_limit", pages: 1, seen: 100 });
    expect(report.backlogRemains).toBe(true);
    const after = await reloadRepo(repo.id);
    expect(after.lastCursor).toBe(minute(GITHUB_PER_PAGE));
    expect(after.lastFullSyncAt).toBeNull();
  });

  test("the run after a page ceiling resumes from the cursor rather than starting over", async () => {
    const { repo } = await connectedRepo();
    await pollDueRepos(pg.db, deps(fakeGithub([...fullPage, ...tail]).lister, { maxPages: 1 }));

    const second = fakeGithub([...fullPage, ...tail]);
    const report = await pollDueRepos(pg.db, deps(second.lister));

    // The overlap re-lists exactly the one neighbour inside its window; a run
    // that had restarted would have seen all 102 again.
    expect(report.repos[0]).toMatchObject({ stoppedBecause: "caught_up", seen: 4 });
    expect(report).toMatchObject({ imported: 2 });
    expect(second.calls[0]!.since).toBe(
      new Date(Date.parse(minute(GITHUB_PER_PAGE)) - POLL_OVERLAP_SECONDS * 1000).toISOString()
    );
    const after = await reloadRepo(repo.id);
    expect(after.lastCursor).toBe(minute(GITHUB_PER_PAGE + 2));
    expect(after.lastFullSyncAt).not.toBeNull();
  });

  test("a rate refusal ends the invocation instead of being retried inside it", async () => {
    const { repo } = await connectedRepo();
    const { lister } = fakeGithub([anIssue(1, minute(1))], () => {
      // 429 with no rate headers is the documented secondary-limit shape.
      throw new GithubApiError("retryable", "/repos/acme/relay/issues", 429, "failed");
    });

    const report = await pollDueRepos(pg.db, deps(lister));

    expect(report.stoppedBecause).toBe("rate_limited");
    expect(report.repos[0]!.stoppedBecause).toBe("rate_limited");
    expect((await reloadRepo(repo.id)).lastFullSyncAt).toBeNull();
    // A wait is not a defect: the next tick resumes from the same cursor.
    expect(githubPollNeedsAttention(report)).toBe(false);
  });

  test("a permission 403 retires the repository and asks for a person", async () => {
    await connectedRepo();
    const { lister } = fakeGithub([anIssue(1, minute(1))], () => {
      // Rate headers present with budget left is the only thing separating this
      // from the throttle above — GitHub gives both the same status.
      throw new GithubApiError(
        "refused",
        "/repos/acme/relay/issues",
        403,
        "failed",
        new Headers({ "x-ratelimit-remaining": "4999" })
      );
    });

    const report = await pollDueRepos(pg.db, deps(lister));

    expect(report).toMatchObject({ failed: 1, stoppedBecause: "complete" });
    expect(report.repos[0]!.stoppedBecause).toBe("refused");
    expect(githubPollNeedsAttention(report)).toBe(true);
  });
});

describe("pollDueRepos — the claim lock", () => {
  test("a repository another runner holds ghpoll: for is left alone, not queued behind", async () => {
    const { repo } = await connectedRepo();
    const { lister, calls } = fakeGithub([anIssue(1, minute(1))]);

    // A second connection standing in for the second runner. Session-scoped
    // rather than transaction-scoped only so the test can hold it across the
    // poll; the key and the namespace are the ones the claim uses.
    const other = postgres(pg.url, { max: 1, prepare: false, onnotice: () => {} });
    try {
      await other`SELECT pg_advisory_lock(hashtext(${`ghpoll:${repo.id}`}))`;

      const report = await pollDueRepos(pg.db, deps(lister));

      expect(report).toMatchObject({ scanned: 1, walked: 0, skipped: 1, imported: 0 });
      expect(report.repos[0]).toMatchObject({ stoppedBecause: "locked", pages: 0 });
      expect(report.backlogRemains).toBe(true);
      expect(calls).toHaveLength(0);
      expect(await pg.db.task.count()).toBe(0);

      await other`SELECT pg_advisory_unlock(hashtext(${`ghpoll:${repo.id}`}))`;
    } finally {
      await other.end();
    }

    // Released, so the next tick picks up exactly what this one declined.
    expect(await pollDueRepos(pg.db, deps(fakeGithub([anIssue(1, minute(1))]).lister))).toMatchObject(
      { walked: 1, imported: 1 }
    );
  });
});
