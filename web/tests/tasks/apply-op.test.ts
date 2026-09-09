import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestSubscription, createTestUser } from "../helpers/fixtures.js";
import {
  upsertIntegration,
  upsertIntegrationRepo,
  type IntegrationRecord,
} from "../../src/models/integration.js";
import { createTask } from "../../src/models/task.js";
import { getOrCreateLabel, setTaskLabelsInTx } from "../../src/models/label.js";
import { drainGithubWebhooks } from "../../src/integrations/github-inbound.js";
import { GithubApiError } from "../../src/integrations/github-app.js";
import { GithubIssueSchema, type GithubIssue } from "../../src/integrations/github-events.js";
import { githubIssueEchoHash } from "../../src/integrations/github-echo.js";
import {
  opMarker,
  type GithubIssueCreate,
  type GithubIssuePatch,
  type GithubIssueTarget,
  type GithubIssueWriter,
  type GithubRepoTarget,
} from "../../src/integrations/github-issues.js";
import { createWriteBudget } from "../../src/integrations/github-push-policy.js";
import { applyOp, type ApplyOpOutcome } from "../../src/tasks/apply-op.js";
import {
  claimNextOps,
  enqueueSyncOp,
  type TaskSyncOpPayload,
  type TaskSyncOpRecord,
} from "../../src/tasks/sync-op.js";
import { clearTaskPushBlock, PUSH_BLOCK_THRESHOLD } from "../../src/tasks/push-blocked.js";
import type { Tx } from "../../src/db/index.js";

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

const APP_SLUG = "antgrid";

type Account = { userId: string; accountId: string };

async function makeAccount(): Promise<Account> {
  const user = await createTestUser(pg.db);
  await createTestSubscription(pg.db, user.id);
  const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
  return { userId: user.id, accountId: account.id };
}

async function connect(account: Account): Promise<IntegrationRecord> {
  const result = await upsertIntegration(pg.db, {
    accountId: account.accountId,
    provider: "github",
    externalAccountId: "org-x",
    installationId: "42",
    displayName: "acme",
    installedBy: account.userId,
  });
  if (result.kind !== "ok") throw new Error(`upsertIntegration: ${result.kind}`);
  return result.integration;
}

/** `pushEnabled` is a create-only consent column on the model, so the test sets
 *  it the way the settings route will rather than through the upsert. */
async function addRepo(account: Account, integration: IntegrationRecord, push = true) {
  const result = await upsertIntegrationRepo(pg.db, {
    accountId: account.accountId,
    integrationId: integration.id,
    repoKey: "github.com/acme/relay",
    externalRepoId: "gh-100",
    visibility: "private",
    syncEnabled: true,
  });
  if (result.kind !== "ok") throw new Error(`upsertIntegrationRepo: ${result.kind}`);
  await pg.db.integrationRepo.update({
    where: { id: result.repo.id },
    data: { pushEnabled: push },
  });
  return result.repo;
}

const repoRef = (id: string, fullName: string) => ({
  id,
  node_id: "n",
  name: fullName.split("/")[1],
  full_name: fullName,
  private: true,
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

function issue(overrides: Record<string, unknown> = {}): GithubIssue {
  return GithubIssueSchema.parse(issuePayload(overrides));
}

async function record(type: string, body: unknown) {
  return pg.db.webhookEvent.create({
    data: {
      provider: "github",
      providerEventId: randomUUID(),
      type,
      payload: { deliveryId: `d-${randomUUID()}`, body } as never,
    },
    select: { id: true },
  });
}

async function deliverIssue(overrides: Record<string, unknown> = {}) {
  await record("issues", {
    action: "edited",
    installation: { id: 42 },
    repository: repoRef("gh-100", "acme/relay"),
    issue: issuePayload(overrides),
  });
  return drainGithubWebhooks(pg.db);
}

/** A task linked to `acme/relay#7`, established the way production does: by
 *  importing the issue, so the base snapshot is the provider's own projection. */
async function linkedTask(account: Account, overrides: Record<string, unknown> = {}) {
  const integration = await connect(account);
  await addRepo(account, integration);
  const report = await deliverIssue(overrides);
  expect(report).toMatchObject({ applied: 1 });
  return pg.db.task.findFirstOrThrow({ include: { labels: { include: { label: true } } } });
}

async function underTaskLock<T>(taskId: string, fn: (tx: Tx) => Promise<T>): Promise<T> {
  return pg.db.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${taskId}`}))`;
    return fn(tx);
  });
}

async function enqueue(
  integrationId: string,
  taskId: string,
  payload: TaskSyncOpPayload
): Promise<void> {
  const result = await underTaskLock(taskId, (tx) =>
    enqueueSyncOp(tx, { taskId, integrationId, provider: "github", payload })
  );
  if (result.kind !== "ok") throw new Error(`enqueueSyncOp: ${result.kind}`);
}

async function claimOne(): Promise<TaskSyncOpRecord> {
  const claimed = await claimNextOps(pg.db, { now: new Date(), limit: 5 });
  const op = claimed[0];
  if (!op) throw new Error("nothing claimable");
  return op;
}

async function integrationId(): Promise<string> {
  return (await pg.db.integration.findFirstOrThrow()).id;
}

async function opRow(id: string) {
  return pg.db.taskSyncOp.findUniqueOrThrow({ where: { id } });
}

async function taskRow(id: string) {
  return pg.db.task.findUniqueOrThrow({ where: { id } });
}

type WriterCalls = {
  get: GithubIssueTarget[];
  patch: { ref: GithubIssueTarget; patch: GithubIssuePatch }[];
  create: { ref: GithubRepoTarget; input: GithubIssueCreate }[];
  list: { ref: GithubRepoTarget; since: Date }[];
};

type FakeWriterOpts = {
  /** What the pre-push re-fetch returns. Defaults to the unchanged issue. */
  current?: () => GithubIssue;
  /** What the PATCH answers with, given what was asked. */
  patched?: (patch: GithubIssuePatch) => GithubIssue | never;
  created?: (input: GithubIssueCreate) => GithubIssue;
  listed?: () => GithubIssue[];
  /** Runs between the re-fetch and the PATCH — the HTTP gap, where a webhook or
   *  a supersede can land. */
  duringGap?: () => Promise<void>;
};

function fakeWriter(opts: FakeWriterOpts = {}): {
  writer: GithubIssueWriter;
  calls: WriterCalls;
} {
  const calls: WriterCalls = { get: [], patch: [], create: [], list: [] };
  const writer: GithubIssueWriter = {
    async getIssue(ref) {
      calls.get.push(ref);
      return opts.current?.() ?? issue();
    },
    async patchIssue(ref, patch) {
      if (opts.duringGap) await opts.duringGap();
      calls.patch.push({ ref, patch });
      return opts.patched ? opts.patched(patch) : issue({ ...patch });
    },
    async createIssue(ref, input) {
      if (opts.duringGap) await opts.duringGap();
      calls.create.push({ ref, input });
      return opts.created
        ? opts.created(input)
        : issue({ id: 2002, number: 11, title: input.title, body: input.body });
    },
    async listAppIssuesSince(ref, args) {
      calls.list.push({ ref, since: args.since });
      return opts.listed?.() ?? [];
    },
  };
  return { writer, calls };
}

function run(writer: GithubIssueWriter, op: TaskSyncOpRecord, extra: { budget?: ReturnType<typeof createWriteBudget> } = {}) {
  return applyOp({ db: pg.db, writer, appSlug: APP_SLUG, ...extra }, op);
}

function expectKind<K extends ApplyOpOutcome["kind"]>(
  outcome: ApplyOpOutcome,
  kind: K
): Extract<ApplyOpOutcome, { kind: K }> {
  expect(outcome.kind).toBe(kind);
  return outcome as Extract<ApplyOpOutcome, { kind: K }>;
}

describe("the echo hash", () => {
  test("label order and CRLF do not change it, but a label does", () => {
    const a = issue({ body: "one\r\ntwo", labels: [{ name: "bug" }, { name: "p1" }] });
    const b = issue({ body: "one\ntwo", labels: [{ name: "p1" }, { name: "bug" }] });
    expect(githubIssueEchoHash(a)).toBe(githubIssueEchoHash(b));

    const c = issue({ body: "one\ntwo", labels: [{ name: "p1" }] });
    expect(githubIssueEchoHash(c)).not.toBe(githubIssueEchoHash(b));
  });

  // GitHub stamps `reopened` on an issue we never sent a reason for, so a hash
  // that read it would never match its own response.
  test("state_reason is ignored while the issue is open and counted while closed", () => {
    expect(githubIssueEchoHash(issue({ state_reason: "reopened" }))).toBe(
      githubIssueEchoHash(issue({ state_reason: null }))
    );
    expect(
      githubIssueEchoHash(issue({ state: "closed", state_reason: "not_planned" }))
    ).not.toBe(githubIssueEchoHash(issue({ state: "closed", state_reason: "completed" })));
  });

  test("an assignee change is not our echo", () => {
    const bare = issue();
    const assigned = issue({ assignees: [{ id: 9, login: "octocat" }] });
    expect(githubIssueEchoHash(bare)).not.toBe(githubIssueEchoHash(assigned));
  });
});

describe("applyOp — the pre-push re-fetch", () => {
  // GitHub has no If-Match, so this is the whole compare-and-swap. Without it a
  // queued PATCH lands blind over an edit made while it sat in the queue.
  test("a remote that moved since the base aborts to a merge and does not push", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account);
    await pg.db.task.update({ where: { id: task.id }, data: { title: "Local edit" } });
    await enqueue(await integrationId(), task.id, {
      kind: "issue.patch.title",
      title: "Local edit",
    });

    const { writer, calls } = fakeWriter({ current: () => issue({ title: "Human edit" }) });
    const outcome = expectKind(await run(writer, await claimOne()), "aborted_to_merge");
    expect(outcome.field).toBe("title");
    expect(calls.patch).toHaveLength(0);

    const after = await taskRow(task.id);
    expect(after.syncState).toBe("conflict");
    expect(after.title).toBe("Human edit");
    expect((after.localConflict as { conflicts: Record<string, unknown> }).conflicts.title)
      .toBeDefined();

    const op = await pg.db.taskSyncOp.findFirstOrThrow({ where: { taskId: task.id } });
    expect(op.status).toBe("pending");
    expect(op.attempts).toBe(0);
  });

  test("an unchanged remote is pushed", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account);
    await enqueue(await integrationId(), task.id, {
      kind: "issue.patch.title",
      title: "Relay drops two frames",
    });

    const { writer, calls } = fakeWriter();
    const outcome = expectKind(await run(writer, await claimOne()), "applied");
    expect(calls.patch[0]?.patch).toEqual({ title: "Relay drops two frames" });

    const after = await taskRow(task.id);
    expect(after.pushedHash).toBe(outcome.pushedHash);
    expect(after.syncState).toBe("synced");
    expect((await pg.db.taskSyncOp.findFirstOrThrow()).status).toBe("processed");
  });
});

describe("applyOp — the gap between the two critical sections", () => {
  // A supersede rewrites the op in place with a FRESH opKey precisely so this
  // comparison can see it; completing the op would mark the user's newer edit
  // delivered and drop it.
  test("an op superseded during the HTTP gap does not have its result written", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account);
    await enqueue(await integrationId(), task.id, { kind: "issue.patch.title", title: "T2" });
    const claimed = await claimOne();

    const { writer } = fakeWriter({
      duringGap: async () => {
        await pg.db.taskSyncOp.update({
          where: { id: claimed.id },
          data: { opKey: "b".repeat(32), payload: { kind: "issue.patch.title", title: "T3" } },
        });
      },
    });
    const outcome = expectKind(await run(writer, claimed), "superseded");
    expect(outcome.reason).toBe("op_key");

    const op = await opRow(claimed.id);
    expect(op.status).toBe("pending");
    expect(op.payload).toEqual({ kind: "issue.patch.title", title: "T3" });

    // The observation IS kept: our write landed, and a base left behind our own
    // push turns the echo of it into a conflict against ourselves.
    const after = await taskRow(task.id);
    expect(after.pushedHash).not.toBeNull();
    expect((after.remoteSnapshot as { title: string }).title).toBe("T2");
  });

  test("an inbound merge landing in the gap keeps its newer base", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account);
    await enqueue(await integrationId(), task.id, { kind: "issue.patch.title", title: "T2" });
    const claimed = await claimOne();

    const { writer } = fakeWriter({
      duringGap: async () => {
        expect(await deliverIssue({ title: "Human edit", updated_at: "2026-08-18T11:00:00Z" }))
          .toMatchObject({ applied: 1 });
      },
    });
    const outcome = expectKind(await run(writer, claimed), "superseded");
    expect(outcome.reason).toBe("remote_base");

    const after = await taskRow(task.id);
    expect((after.remoteSnapshot as { title: string }).title).toBe("Human edit");
    expect((await opRow(claimed.id)).status).toBe("pending");
  });
});

describe("applyOp — array-valued payloads", () => {
  // `PATCH /issues/{n}` replaces the whole labels array, so a replay of the set
  // as stored is a rollback rather than a repeat.
  test("a labels op sends a set recomputed at send time, not the stored one", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account, { labels: [{ name: "bug", color: "d73a4a" }] });
    await enqueue(await integrationId(), task.id, { kind: "issue.labels", labels: ["bug"] });

    const urgent = await getOrCreateLabel(pg.db, {
      accountId: account.accountId,
      projectId: null,
      name: "urgent",
      color: "ededed",
    });
    if (urgent.kind !== "ok") throw new Error(urgent.kind);
    const bug = await pg.db.label.findFirstOrThrow({ where: { name: "bug" } });
    const set = await pg.db.$transaction((tx) =>
      setTaskLabelsInTx(tx, {
        accountId: account.accountId,
        taskId: task.id,
        labelIds: [bug.id, urgent.label.id],
      })
    );
    expect(set.kind).toBe("ok");

    const { writer, calls } = fakeWriter({
      // The re-fetch has to agree with the base, or the abort fires first and
      // this test would pass for the wrong reason.
      current: () => issue({ labels: [{ name: "bug" }] }),
      patched: (patch) =>
        issue({ labels: (patch.labels ?? []).map((name) => ({ name })) }),
    });
    expectKind(await run(writer, await claimOne()), "applied");
    expect(calls.patch[0]?.patch.labels?.slice().sort()).toEqual(["bug", "urgent"]);
  });
});

describe("applyOp — a create whose outcome is unknown", () => {
  async function localTaskWithRepo(account: Account) {
    const integration = await connect(account);
    const repo = await addRepo(account, integration);
    const created = await createTask(pg.db, {
      accountId: account.accountId,
      createdBy: account.userId,
      title: "publish me",
    });
    if (created.kind !== "ok") throw new Error(created.kind);
    await pg.db.task.update({
      where: { id: created.task.id },
      data: { integrationRepoId: repo.id, syncState: "pending" },
    });
    return { taskId: created.task.id, integrationId: integration.id };
  }

  const createPayload: TaskSyncOpPayload = {
    kind: "issue.create",
    title: "publish me",
    body: "the body",
    state: "open",
    stateReason: null,
    labels: [],
  };

  test("a create with an unknown outcome finds its own issue by marker and does not post again", async () => {
    const account = await makeAccount();
    const { taskId, integrationId: iid } = await localTaskWithRepo(account);
    await enqueue(iid, taskId, createPayload);

    // The lost-response state: handed to GitHub, nothing recorded locally.
    const pending = await pg.db.taskSyncOp.findFirstOrThrow({ where: { taskId } });
    await pg.db.taskSyncOp.update({
      where: { id: pending.id },
      data: { attemptedAt: new Date(Date.now() - 120_000) },
    });

    const orphan = issue({
      id: 3003,
      number: 21,
      title: "publish me",
      body: `the body\n\n${opMarker(pending.opKey)}`,
    });
    const { writer, calls } = fakeWriter({ listed: () => [orphan] });
    const outcome = expectKind(await run(writer, await claimOne()), "applied");
    expect(outcome.recovered).toBe(true);
    expect(calls.create).toHaveLength(0);
    expect(calls.list).toHaveLength(1);
    // The `since` anchor is the FIRST hand-off, backdated for clock skew — a
    // stamp re-taken on every retry walks past the issue being looked for.
    expect(calls.list[0]!.since.getTime()).toBeLessThan(Date.now() - 120_000);

    const after = await taskRow(taskId);
    expect(after.externalId).toBe("3003");
    expect(after.externalKey).toBe("acme/relay#21");
    expect(after.syncState).toBe("synced");
  });

  test("a first create posts, and a create for an already-linked task never does", async () => {
    const account = await makeAccount();
    const { taskId, integrationId: iid } = await localTaskWithRepo(account);
    await enqueue(iid, taskId, createPayload);

    const { writer, calls } = fakeWriter();
    expectKind(await run(writer, await claimOne()), "applied");
    expect(calls.create).toHaveLength(1);
    expect(calls.list).toHaveLength(0);
    // The marker is embedded so a lost response is resolvable at all.
    const op = await pg.db.taskSyncOp.findFirstOrThrow({ where: { taskId } });
    expect(calls.create[0]!.input.body).toContain(opMarker(op.opKey));

    const second = await underTaskLock(taskId, (tx) =>
      enqueueSyncOp(tx, {
        taskId,
        integrationId: iid,
        provider: "github",
        payload: createPayload,
      })
    );
    expect(second.kind).toBe("already_created");
  });

  test("a task published closed queues the state the create could not carry", async () => {
    const account = await makeAccount();
    const { taskId, integrationId: iid } = await localTaskWithRepo(account);
    await enqueue(iid, taskId, {
      ...createPayload,
      state: "closed",
      stateReason: "completed",
    });

    // `POST /issues` has no `state` field, so GitHub answers `open` however the
    // task was published.
    const { writer, calls } = fakeWriter();
    const outcome = expectKind(await run(writer, await claimOne()), "applied");
    // Not a provider refusal: nothing asked for the state, so nothing declined it.
    expect(outcome.cleared).toEqual([]);
    expect(await taskRow(taskId).then((row) => row.pushBlocked)).toBeNull();
    expect(calls.create).toHaveLength(1);

    const followUp = await pg.db.taskSyncOp.findFirstOrThrow({
      where: { taskId, kind: "issue.state", status: "pending" },
    });
    expect(followUp.payload).toMatchObject({ state: "closed", stateReason: "completed" });
  });

  test("a task published open queues nothing further", async () => {
    const account = await makeAccount();
    const { taskId, integrationId: iid } = await localTaskWithRepo(account);
    await enqueue(iid, taskId, createPayload);
    const { writer } = fakeWriter();
    expectKind(await run(writer, await claimOne()), "applied");
    expect(await pg.db.taskSyncOp.count({ where: { taskId, status: "pending" } })).toBe(0);
  });
});

describe("applyOp — echo suppression end to end", () => {
  test("the delivery echoing our own push is dropped, a different one is merged", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account);
    await pg.db.task.update({ where: { id: task.id }, data: { title: "T2" } });
    await enqueue(await integrationId(), task.id, { kind: "issue.patch.title", title: "T2" });

    const pushed = issue({ title: "T2", updated_at: "2026-08-18T12:00:00Z" });
    const { writer } = fakeWriter({ patched: () => pushed });
    expectKind(await run(writer, await claimOne()), "applied");
    const afterPush = await taskRow(task.id);
    expect(afterPush.pushedHash).toBe(githubIssueEchoHash(pushed));

    // GitHub redelivers our own write. Same field set, so the timestamp it
    // carries is irrelevant — it is our echo and must not re-merge.
    expect(await deliverIssue({ title: "T2", updated_at: "2026-08-18T13:00:00Z" }))
      .toMatchObject({ applied: 0, dropped: 1, failed: 0 });
    const afterEcho = await taskRow(task.id);
    expect(afterEcho.remoteUpdatedAt).toEqual(afterPush.remoteUpdatedAt);
    // Not cleared on a match, so a second redelivery is suppressed too.
    expect(afterEcho.pushedHash).toBe(afterPush.pushedHash);

    // A third party's edit, timestamped BEFORE our push. The whole reason the
    // hash keys on content: an `updated_at` scheme drops this silently.
    expect(await deliverIssue({ title: "Human edit", updated_at: "2026-08-18T09:00:00Z" }))
      .toMatchObject({ applied: 1, dropped: 0, failed: 0 });
    const afterHuman = await taskRow(task.id);
    expect(afterHuman.title).toBe("Human edit");
    expect(afterHuman.pushedHash).toBeNull();
  });
});

describe("applyOp — the no-effect detector", () => {
  /** The base already carries the value GitHub insists on, so the re-fetch
   *  agrees and the push is genuinely a declined write rather than a remote that
   *  moved. That ordering is the point: the abort fires first when it applies. */
  const DECLINED = "GitHub keeps this";

  async function pushTitleOnce(account: Account, taskId: string, title: string, answer: string) {
    await enqueue(await integrationId(), taskId, { kind: "issue.patch.title", title });
    const { writer, calls } = fakeWriter({
      current: () => issue({ title: answer }),
      patched: () => issue({ title: answer }),
    });
    const outcome = await run(writer, await claimOne());
    return { outcome, calls };
  }

  test("three no-effect pushes block the field and a fourth is not sent", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account, { title: DECLINED });

    for (let attempt = 1; attempt <= PUSH_BLOCK_THRESHOLD; attempt++) {
      // The base is re-derived from each response, so the re-fetch keeps agreeing
      // with it — the loop this counter exists to stop.
      const { outcome, calls } = await pushTitleOnce(
        account,
        task.id,
        `Local ${attempt}`,
        DECLINED
      );
      const noEffect = expectKind(outcome, "no_effect");
      expect(noEffect.fields).toEqual(["title"]);
      expect(calls.patch).toHaveLength(1);
      const blob = (await taskRow(task.id)).pushBlocked as Record<string, { count: number }>;
      expect(blob.title!.count).toBe(attempt);
    }

    const fourth = await pushTitleOnce(account, task.id, "Local 4", DECLINED);
    expect(expectKind(fourth.outcome, "skipped").reason).toBe("fields_blocked");
    expect(fourth.calls.patch).toHaveLength(0);
    expect(fourth.calls.get).toHaveLength(0);
    // Closed rather than left pending: the claim only offers a task's lowest
    // pending seq, so an op nothing will send is a head-of-line block.
    expect((await pg.db.taskSyncOp.findFirstOrThrow({ orderBy: { seq: "desc" } })).status)
      .toBe("cancelled");
  });

  test("a push that takes effect clears the block", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account, { title: DECLINED });

    await pushTitleOnce(account, task.id, "Local 1", DECLINED);
    expect((await taskRow(task.id)).pushBlocked).not.toBeNull();

    await enqueue(await integrationId(), task.id, { kind: "issue.patch.title", title: "Local 2" });
    const { writer } = fakeWriter({
      current: () => issue({ title: DECLINED }),
      patched: (patch) => issue({ title: patch.title }),
    });
    const outcome = expectKind(await run(writer, await claimOne()), "applied");
    expect(outcome.cleared).toEqual(["title"]);
    expect((await taskRow(task.id)).pushBlocked).toBeNull();
  });

  test("a blocked field is releasable by hand, and the release is what lets it push again", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account, { title: DECLINED });
    for (let attempt = 1; attempt <= PUSH_BLOCK_THRESHOLD; attempt++) {
      await pushTitleOnce(account, task.id, `Local ${attempt}`, DECLINED);
    }

    expect(await pg.db.$transaction((tx) =>
      clearTaskPushBlock(tx, { taskId: task.id, field: "title" })
    )).toBe(true);
    expect((await taskRow(task.id)).pushBlocked).toBeNull();

    const again = await pushTitleOnce(account, task.id, "Local 5", DECLINED);
    expect(again.calls.patch).toHaveLength(1);
  });

  // The transition the counter is genuinely for: both map to `closed`, and
  // `state_reason` is documented as ignored unless `state` changes.
  test("done → cancelled on an already-closed issue reads as no effect on status", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account, { state: "closed", state_reason: "completed" });
    await enqueue(await integrationId(), task.id, {
      kind: "issue.state",
      state: "closed",
      stateReason: "not_planned",
    });

    const answer = () => issue({ state: "closed", state_reason: "completed" });
    const { writer } = fakeWriter({ current: answer, patched: answer });
    const outcome = expectKind(await run(writer, await claimOne()), "no_effect");
    expect(outcome.fields).toEqual(["status"]);
    const blob = (await taskRow(task.id)).pushBlocked as Record<string, { reason: string }>;
    expect(blob.status!.reason).toContain("state_reason");
  });
});

describe("applyOp — throttling and refusal", () => {
  function throwing(status: number, headers: Record<string, string> = {}) {
    return fakeWriter({
      patched: () => {
        throw new GithubApiError("refused", "/repos/acme/relay/issues/7", status, "failed", new Headers(headers));
      },
    });
  }

  // A queue that is merely waiting must not drive itself into exponential
  // backoff and then into the abandonment ceiling.
  test("a secondary-limit throttle does not increment attempts", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account);
    await enqueue(await integrationId(), task.id, { kind: "issue.patch.title", title: "T2" });
    const claimed = await claimOne();

    const { writer } = throwing(403);
    const outcome = expectKind(await run(writer, claimed), "throttled");
    expect(outcome.limit).toBe("secondary");

    const op = await opRow(claimed.id);
    expect(op.attempts).toBe(0);
    expect(op.status).toBe("pending");
    expect(op.nextAttemptAt.getTime()).toBeGreaterThan(Date.now() + 30_000);
  });

  test("a local budget refusal is a throttle, not an attempt, and nothing is sent", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account);
    await enqueue(await integrationId(), task.id, { kind: "issue.patch.title", title: "T2" });
    const claimed = await claimOne();

    const budget = createWriteBudget({ perHour: 1, perMinute: 1 });
    budget.take(new Date());
    const { writer, calls } = fakeWriter();
    const outcome = expectKind(await run(writer, claimed, { budget }), "throttled");
    expect(outcome.limit).toBe("local");
    expect(calls.get).toHaveLength(0);
    expect((await opRow(claimed.id)).attempts).toBe(0);
    // Never handed over, so nothing has to be treated as an unknown outcome.
    expect((await opRow(claimed.id)).attemptedAt).toBeNull();
  });

  // A permission 403 carries the ordinary primary counters with budget left; a
  // rate 403 does not. Reading one as the other either retries a permanent
  // refusal for ever or drops a user's edit.
  test("a permission 403 is a refusal and retires the op", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account);
    await enqueue(await integrationId(), task.id, { kind: "issue.patch.title", title: "T2" });
    const claimed = await claimOne();

    const { writer } = throwing(403, { "x-ratelimit-remaining": "4900" });
    expectKind(await run(writer, claimed), "refused");
    expect((await opRow(claimed.id)).status).toBe("given_up");
  });

  test("a 500 is a failure that counts an attempt", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account);
    await enqueue(await integrationId(), task.id, { kind: "issue.patch.title", title: "T2" });
    const claimed = await claimOne();

    const { writer } = throwing(500);
    const outcome = expectKind(await run(writer, claimed), "failed");
    expect(outcome.attempts).toBe(1);
    expect((await opRow(claimed.id)).status).toBe("pending");
  });
});

describe("applyOp — local refusals", () => {
  test("a repository whose push consent was withdrawn cancels the op without sending", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account);
    await enqueue(await integrationId(), task.id, { kind: "issue.patch.title", title: "T2" });
    const claimed = await claimOne();
    await pg.db.integrationRepo.updateMany({ data: { pushEnabled: false } });

    const { writer, calls } = fakeWriter();
    expect(expectKind(await run(writer, claimed), "skipped").reason).toBe("push_disabled");
    expect(calls.get).toHaveLength(0);
    expect((await opRow(claimed.id)).status).toBe("cancelled");
  });

  test("an unadjudicated conflict defers the op rather than pushing over it", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account);
    await enqueue(await integrationId(), task.id, { kind: "issue.patch.title", title: "T2" });
    const claimed = await claimOne();
    await pg.db.task.update({ where: { id: task.id }, data: { syncState: "conflict" } });

    const { writer, calls } = fakeWriter();
    expect(expectKind(await run(writer, claimed), "skipped").reason).toBe("task_in_conflict");
    expect(calls.get).toHaveLength(0);
    const op = await opRow(claimed.id);
    expect(op.status).toBe("pending");
    expect(op.attempts).toBe(0);
  });

  test("a deleted task cancels its queued writes rather than writing to the repository", async () => {
    const account = await makeAccount();
    const task = await linkedTask(account);
    await enqueue(await integrationId(), task.id, { kind: "issue.patch.title", title: "T2" });
    const claimed = await claimOne();
    await pg.db.task.update({
      where: { id: task.id },
      data: { deletedAt: new Date(), syncState: "unlinked" },
    });

    const { writer, calls } = fakeWriter();
    expect(expectKind(await run(writer, claimed), "skipped").reason).toBe("task_unlinked");
    expect(calls.get).toHaveLength(0);
    expect((await opRow(claimed.id)).status).toBe("cancelled");
  });
});
