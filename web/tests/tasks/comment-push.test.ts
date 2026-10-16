// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestSubscription, createTestUser } from "../helpers/fixtures.js";
import { upsertIntegration, upsertIntegrationRepo } from "../../src/models/integration.js";
import { createTask, unlinkTask } from "../../src/models/task.js";
import {
  createTaskComment,
  deleteTaskComment,
  listTaskComments,
  updateTaskComment,
} from "../../src/models/task-comment.js";
import { drainGithubWebhooks } from "../../src/integrations/github-inbound.js";
import { recordDelivery } from "../../src/integrations/webhook-events.js";
import {
  GithubIssueCommentSchema,
  GithubIssueSchema,
  type GithubIssueComment,
} from "../../src/integrations/github-events.js";
import {
  commentMarker,
  findCommentKey,
  type GithubCommentTarget,
  type GithubIssueTarget,
  type GithubIssueWriter,
} from "../../src/integrations/github-issues.js";
import { applyOp } from "../../src/tasks/apply-op.js";
import { renderMirroredComment } from "../../src/tasks/comment-push.js";
import { claimNextOps, enqueueSyncOp } from "../../src/tasks/sync-op.js";

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

type Fixture = { userId: string; accountId: string; taskId: string; number: number };

const repoRef = { id: "gh-100", node_id: "n", name: "relay", full_name: "acme/relay", private: true };
const issuePayload = {
  id: 1001,
  number: 7,
  title: "Relay drops a frame",
  body: "steps",
  state: "open",
  updated_at: "2026-08-18T10:00:00Z",
};

async function account() {
  const user = await createTestUser(pg.db);
  await createTestSubscription(pg.db, user.id);
  const acct = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
  const integration = await upsertIntegration(pg.db, {
    accountId: acct.id,
    provider: "github",
    externalAccountId: "org-x",
    installationId: "42",
    displayName: "acme",
    installedBy: user.id,
  });
  if (integration.kind !== "ok") throw new Error(integration.kind);
  const repo = await upsertIntegrationRepo(pg.db, {
    accountId: acct.id,
    integrationId: integration.integration.id,
    repoKey: "github.com/acme/relay",
    externalRepoId: "gh-100",
    visibility: "private",
    syncEnabled: true,
  });
  if (repo.kind !== "ok") throw new Error(repo.kind);
  await pg.db.integrationRepo.update({ where: { id: repo.repo.id }, data: { pushEnabled: true } });
  return { userId: user.id, accountId: acct.id, repoId: repo.repo.id };
}

async function deliver(type: string, body: unknown) {
  await recordDelivery(pg.db, {
    provider: "github",
    providerEventId: randomUUID(),
    type,
    payload: { deliveryId: `d-${randomUUID()}`, body },
  });
  return drainGithubWebhooks(pg.db, { appSlug: "antgrid" });
}

/** A task linked to `acme/relay#7`, imported the way production links one. */
async function linkedTask(): Promise<Fixture> {
  const { userId, accountId } = await account();
  await deliver("issues", {
    action: "opened",
    installation: { id: 42 },
    repository: repoRef,
    issue: issuePayload,
  });
  const task = await pg.db.task.findFirstOrThrow();
  // The imported author is the account's own member, so writes are theirs.
  await pg.db.user.update({ where: { id: userId }, data: { name: "Amy Pond" } });
  return { userId, accountId, taskId: task.id, number: task.number };
}

function commentEvent(action: string, comment: Record<string, unknown>) {
  return {
    action,
    installation: { id: 42 },
    repository: repoRef,
    issue: issuePayload,
    comment: { user: { id: 9, login: "antgrid[bot]", type: "Bot" }, ...comment },
  };
}

type Calls = {
  create: { ref: GithubIssueTarget; body: string }[];
  update: { ref: GithubCommentTarget; body: string }[];
  remove: GithubCommentTarget[];
  list: number;
};

function fakeWriter(
  opts: {
    listed?: () => GithubIssueComment[];
    onCreate?: () => Promise<void>;
    onCreateIssue?: () => Promise<void>;
  } = {}
) {
  const calls: Calls = { create: [], update: [], remove: [], list: 0 };
  let nextId = 9000;
  const comment = (body: string, id = String(nextId++)) =>
    GithubIssueCommentSchema.parse({ id, body, user: { id: 9, login: "antgrid[bot]", type: "Bot" } });
  const unused = async (): Promise<never> => {
    throw new Error("issue writer called from a comment test");
  };
  const writer: GithubIssueWriter = {
    getIssue: async () => GithubIssueSchema.parse(issuePayload),
    patchIssue: unused,
    async createIssue(_ref, input) {
      await opts.onCreateIssue?.();
      return GithubIssueSchema.parse({ ...issuePayload, title: input.title, body: input.body });
    },
    listAppIssuesSince: async () => [],
    async createComment(ref, body) {
      calls.create.push({ ref, body });
      const created = comment(body);
      await opts.onCreate?.();
      return created;
    },
    async updateComment(ref, body) {
      calls.update.push({ ref, body });
      return comment(body, ref.commentId);
    },
    async deleteComment(ref) {
      calls.remove.push(ref);
    },
    async listIssueCommentsSince() {
      calls.list += 1;
      return opts.listed?.() ?? [];
    },
  };
  return { writer, calls };
}

/** Run every op the outbox will hand out right now. */
async function drain(writer: GithubIssueWriter) {
  const outcomes = [];
  for (let i = 0; i < 20; i++) {
    const [op] = await claimNextOps(pg.db, { now: new Date(), limit: 1 });
    if (!op) break;
    outcomes.push(await applyOp({ db: pg.db, writer, appSlug: "antgrid" }, op));
  }
  return outcomes;
}

async function comment(f: Fixture, body: string): Promise<string> {
  const result = await createTaskComment(pg.db, {
    accountId: f.accountId,
    number: f.number,
    authorUserId: f.userId,
    body,
  });
  if (result.kind !== "ok") throw new Error(result.kind);
  return result.comment.id;
}

const edit = (f: Fixture, commentId: string, body: string) =>
  updateTaskComment(pg.db, { accountId: f.accountId, number: f.number, commentId, actorUserId: f.userId, body });
const remove = (f: Fixture, commentId: string) =>
  deleteTaskComment(pg.db, { accountId: f.accountId, number: f.number, commentId, actorUserId: f.userId });

describe("comments written here reach the issue", () => {
  test("a comment is posted with its author's byline and its marker, and linked", async () => {
    const f = await linkedTask();
    const id = await comment(f, "repro attached");
    const { writer, calls } = fakeWriter();

    const outcomes = await drain(writer);
    expect(outcomes.map((o) => o.kind)).toEqual(["comment"]);
    expect(calls.create).toHaveLength(1);
    expect(calls.create[0]!.ref).toMatchObject({ owner: "acme", repo: "relay", number: 7 });
    expect(calls.create[0]!.body).toBe(
      `_Amy Pond commented in Antgrid_\n\nrepro attached\n\n${commentMarker(id)}`
    );

    const [listed] = (await listTaskComments(pg.db, f))!;
    expect(listed).toMatchObject({ id, body: "repro attached", mirrored: true, imported: false });
  });

  test("two comments on one task are two posts, never one superseding the other", async () => {
    const f = await linkedTask();
    await comment(f, "first");
    await comment(f, "second");
    const { writer, calls } = fakeWriter();
    await drain(writer);
    expect(calls.create.map((c) => c.body.split("\n\n")[1])).toEqual(["first", "second"]);
  });

  test("an edit before the post is sent is the text that gets posted, once", async () => {
    const f = await linkedTask();
    const id = await comment(f, "draft");
    expect((await edit(f, id, "final")).kind).toBe("ok");
    const { writer, calls } = fakeWriter();
    await drain(writer);
    expect(calls.create.map((c) => c.body.split("\n\n")[1])).toEqual(["final"]);
    expect(calls.update).toHaveLength(0);
  });

  test("a delete before the post is sent posts nothing", async () => {
    const f = await linkedTask();
    const id = await comment(f, "oops");
    expect((await remove(f, id)).kind).toBe("ok");
    const { writer, calls } = fakeWriter();
    await drain(writer);
    expect(calls.create).toHaveLength(0);
    expect(calls.remove).toHaveLength(0);
  });

  test("an edit and a delete after the post reach the mirror, and the author can still make them", async () => {
    const f = await linkedTask();
    const id = await comment(f, "v1");
    const { writer, calls } = fakeWriter();
    await drain(writer);
    const externalId = (await pg.db.taskComment.findUniqueOrThrow({ where: { id } })).externalId!;

    expect((await edit(f, id, "v2")).kind).toBe("ok");
    await drain(writer);
    expect(calls.update).toEqual([
      {
        ref: { owner: "acme", repo: "relay", commentId: externalId },
        body: `_Amy Pond commented in Antgrid_\n\nv2\n\n${commentMarker(id)}`,
      },
    ]);

    expect((await remove(f, id)).kind).toBe("ok");
    await drain(writer);
    expect(calls.remove).toEqual([{ owner: "acme", repo: "relay", commentId: externalId }]);
  });

  test("a task with no issue, or with pushes off, queues nothing", async () => {
    const { userId, accountId } = await account();
    const local = await createTask(pg.db, { accountId, createdBy: userId, title: "local only" });
    if (local.kind !== "ok") throw new Error(local.kind);
    await createTaskComment(pg.db, { accountId, number: local.task.number, authorUserId: userId, body: "x" });
    expect(await pg.db.taskSyncOp.count()).toBe(0);

    await pg.db.integrationRepo.updateMany({ data: { pushEnabled: false } });
    await deliver("issues", { action: "opened", installation: { id: 42 }, repository: repoRef, issue: issuePayload });
    const linked = await pg.db.task.findFirstOrThrow({ where: { externalId: { not: null } } });
    await createTaskComment(pg.db, { accountId, number: linked.number, authorUserId: userId, body: "y" });
    expect(await pg.db.taskSyncOp.count()).toBe(0);
  });

  test("publishing a task posts the thread written before the issue existed, oldest first", async () => {
    const { userId, accountId, repoId } = await account();
    const local = await createTask(pg.db, { accountId, createdBy: userId, title: "to publish" });
    if (local.kind !== "ok") throw new Error(local.kind);
    const f = { userId, accountId, taskId: local.task.id, number: local.task.number };
    await comment(f, "older");
    await comment(f, "newer");
    const integrationId = (await pg.db.integration.findFirstOrThrow()).id;
    await pg.db.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${f.taskId}`}))`;
      await tx.task.update({ where: { id: f.taskId }, data: { integrationRepoId: repoId, syncState: "pending" } });
      await enqueueSyncOp(tx, {
        taskId: f.taskId,
        integrationId,
        provider: "github",
        payload: { kind: "issue.create", title: "to publish", body: "", state: "open", stateReason: null, labels: [] },
      });
    });

    const { writer, calls } = fakeWriter();
    const outcomes = await drain(writer);
    expect(outcomes.map((o) => o.kind)).toEqual(["applied", "comment", "comment"]);
    expect(calls.create.map((c) => c.body.split("\n\n")[1])).toEqual(["older", "newer"]);
  });

  test("a create whose response was lost is found by its marker rather than posted twice", async () => {
    const f = await linkedTask();
    const id = await comment(f, "once");
    const [op] = await claimNextOps(pg.db, { now: new Date(), limit: 1 });
    await pg.db.taskSyncOp.update({ where: { id: op!.id }, data: { attemptedAt: new Date() } });
    const posted = GithubIssueCommentSchema.parse({
      id: 777,
      user: { id: 9, login: "antgrid[bot]", type: "Bot" },
      body: `_Amy Pond commented in Antgrid_\n\nonce\n\n${commentMarker(id)}`,
    });
    const { writer, calls } = fakeWriter({ listed: () => [posted] });

    const outcome = await applyOp(
      { db: pg.db, writer, appSlug: "antgrid" },
      { ...op!, attemptedAt: new Date() }
    );
    expect(outcome).toMatchObject({ kind: "comment", verb: "create", recovered: true });
    expect(calls.create).toHaveLength(0);
    expect((await pg.db.taskComment.findUniqueOrThrow({ where: { id } })).externalId).toBe("777");
  });
});

describe("the issue's side of a mirrored comment", () => {
  test("the echo of our post, drained before the push records it, links rather than duplicates", async () => {
    const f = await linkedTask();
    const id = await comment(f, "racing");
    const { writer } = fakeWriter({
      // The webhook for the comment is drained in the HTTP gap.
      onCreate: async () => {
        await deliver(
          "issue_comment",
          commentEvent("created", { id: 9000, body: `byline\n\nracing\n\n${commentMarker(id)}` })
        );
      },
    });
    await drain(writer);

    const rows = await pg.db.taskComment.findMany({ where: { deletedAt: null } });
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ id, externalId: "9000", body: "racing" });
  });

  test("a pasted marker from a person's account imports as their comment, never as ours", async () => {
    const f = await linkedTask();
    const id = await comment(f, "mine");
    await deliver(
      "issue_comment",
      commentEvent("created", {
        id: 4242,
        body: `hijack ${commentMarker(id)}`,
        user: { id: 5, login: "mallory", type: "User" },
      })
    );
    expect((await pg.db.taskComment.findUniqueOrThrow({ where: { id } })).externalId).toBeNull();
    expect(await pg.db.taskComment.count({ where: { externalId: "4242", authorUserId: null } })).toBe(1);
  });

  test("an edit to the mirror on GitHub does not rewrite the comment here", async () => {
    const f = await linkedTask();
    const id = await comment(f, "authored here");
    await drain(fakeWriter().writer);
    const externalId = (await pg.db.taskComment.findUniqueOrThrow({ where: { id } })).externalId!;

    await deliver("issue_comment", commentEvent("edited", { id: externalId, body: "changed on GitHub" }));
    expect((await pg.db.taskComment.findUniqueOrThrow({ where: { id } })).body).toBe("authored here");
  });

  test("a mirror deleted on GitHub is deleted here too", async () => {
    const f = await linkedTask();
    const id = await comment(f, "short-lived");
    await drain(fakeWriter().writer);
    const externalId = (await pg.db.taskComment.findUniqueOrThrow({ where: { id } })).externalId!;

    await deliver("issue_comment", commentEvent("deleted", { id: externalId, body: "" }));
    expect((await pg.db.taskComment.findUniqueOrThrow({ where: { id } })).deletedAt).not.toBeNull();
  });
});

const ownBot = { id: 9, login: "antgrid[bot]", type: "Bot" };
const bodyText = (posted: { body: string }) => posted.body.split("\n\n")[1];

/** Claim the comment's create and stamp it handed-over, as a lost response
 *  leaves it. */
async function inFlightCreate() {
  const [op] = await claimNextOps(pg.db, { now: new Date(), limit: 1 });
  if (!op) throw new Error("nothing claimable");
  await pg.db.taskSyncOp.update({
    where: { id: op.id },
    data: { attemptedAt: new Date(), nextAttemptAt: new Date(0) },
  });
  return op;
}

describe("review regressions", () => {
  test("an edit landing after the post read its text is sent as an update behind it", async () => {
    const f = await linkedTask();
    const id = await comment(f, "v1");
    const { writer, calls } = fakeWriter({
      // The edit lands between the first critical section and the hand-off
      // stamp, where mirrorChange still sees an unsent create.
      onCreate: async () => {
        await pg.db.taskSyncOp.updateMany({ data: { attemptedAt: null } });
        expect((await edit(f, id, "v2")).kind).toBe("ok");
      },
    });
    await drain(writer);
    expect(calls.create.map(bodyText)).toEqual(["v1"]);
    expect(calls.update.map(bodyText)).toEqual(["v2"]);
  });

  test("unlinking a task does not orphan a post whose outcome is unknown", async () => {
    const f = await linkedTask();
    const id = await comment(f, "in flight");
    const op = await inFlightCreate();
    expect((await unlinkTask(pg.db, { accountId: f.accountId, number: f.number })).kind).toBe("ok");
    expect((await pg.db.taskSyncOp.findUniqueOrThrow({ where: { id: op.id } })).status).toBe("pending");

    const posted = GithubIssueCommentSchema.parse({
      id: 31,
      user: ownBot,
      body: `byline\n\nin flight\n\n${commentMarker(id)}`,
    });
    const { writer, calls } = fakeWriter({ listed: () => [posted] });
    await drain(writer);
    expect(calls.create).toHaveLength(0);
    expect((await pg.db.taskComment.findUniqueOrThrow({ where: { id } })).externalId).toBe("31");
  });

  test("an unlinked task's post that never landed is not posted afresh", async () => {
    const f = await linkedTask();
    await comment(f, "lost");
    const op = await inFlightCreate();
    await unlinkTask(pg.db, { accountId: f.accountId, number: f.number });
    const { writer, calls } = fakeWriter();
    await drain(writer);
    expect(calls.list).toBe(1);
    expect(calls.create).toHaveLength(0);
    expect((await pg.db.taskSyncOp.findUniqueOrThrow({ where: { id: op.id } })).status).toBe("cancelled");
  });

  test("a post whose local comment vanished is taken back off the issue", async () => {
    const f = await linkedTask();
    const id = await comment(f, "gone");
    const { writer, calls } = fakeWriter({
      onCreate: async () => {
        await pg.db.taskComment.delete({ where: { id } });
      },
    });
    const outcomes = await drain(writer);
    expect(outcomes.map((o) => o.kind)).toEqual(["comment"]);
    expect(calls.remove).toHaveLength(1);
  });

  test("another App's bot carrying our marker is imported, never linked", async () => {
    const f = await linkedTask();
    const id = await comment(f, "ours");
    await deliver(
      "issue_comment",
      commentEvent("created", {
        id: 6060,
        body: `echo\n\n${commentMarker(id)}`,
        user: { id: 7, login: "other-app[bot]", type: "Bot" },
      })
    );
    expect((await pg.db.taskComment.findUniqueOrThrow({ where: { id } })).externalId).toBeNull();
  });

  test("lost-response recovery ignores a stranger who pasted the marker", async () => {
    const f = await linkedTask();
    const id = await comment(f, "real");
    const op = await inFlightCreate();
    const forged = GithubIssueCommentSchema.parse({
      id: 13,
      user: { id: 5, login: "mallory", type: "User" },
      body: `gotcha ${commentMarker(id)}`,
    });
    const { writer, calls } = fakeWriter({ listed: () => [forged] });
    await applyOp({ db: pg.db, writer, appSlug: "antgrid" }, { ...op, attemptedAt: new Date() });
    expect(calls.create).toHaveLength(1);
    expect((await pg.db.taskComment.findUniqueOrThrow({ where: { id } })).externalId).not.toBe("13");
  });

  test("only the trailing marker names the comment", () => {
    const own = "11111111-1111-4111-8111-111111111111";
    const quoted = "22222222-2222-4222-8222-222222222222";
    const body = renderMirroredComment({
      authorName: "Amy",
      body: `see ${commentMarker(quoted)} above`,
      commentId: own,
    });
    expect(findCommentKey(body)).toBe(own);
    expect(findCommentKey(`${commentMarker(quoted)} trailing text`)).toBeNull();
  });

  test("a display name cannot @mention anyone on GitHub", () => {
    const body = renderMirroredComment({
      authorName: "@org/security-team",
      body: "hi",
      commentId: "11111111-1111-4111-8111-111111111111",
    });
    expect(body.startsWith("_org/security-team commented in Antgrid_")).toBe(true);
  });

  test("a conflict on the issue fields does not hold back the thread", async () => {
    const f = await linkedTask();
    await pg.db.task.update({ where: { id: f.taskId }, data: { syncState: "conflict" } });
    await comment(f, "still goes");
    const { writer, calls } = fakeWriter();
    await drain(writer);
    expect(calls.create).toHaveLength(1);
  });

  test("a publish that resolves as superseded still queues the earlier thread", async () => {
    const { userId, accountId, repoId } = await account();
    const local = await createTask(pg.db, { accountId, createdBy: userId, title: "to publish" });
    if (local.kind !== "ok") throw new Error(local.kind);
    const f = { userId, accountId, taskId: local.task.id, number: local.task.number };
    await comment(f, "written first");
    const integrationId = (await pg.db.integration.findFirstOrThrow()).id;
    await pg.db.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${f.taskId}`}))`;
      await tx.task.update({ where: { id: f.taskId }, data: { integrationRepoId: repoId, syncState: "pending" } });
      await enqueueSyncOp(tx, {
        taskId: f.taskId,
        integrationId,
        provider: "github",
        payload: { kind: "issue.create", title: "to publish", body: "", state: "open", stateReason: null, labels: [] },
      });
    });
    const { writer, calls } = fakeWriter({
      // The intent moves while the create is in flight.
      onCreateIssue: async () => {
        await pg.db.taskSyncOp.updateMany({ where: { kind: "issue.create" }, data: { opKey: "moved" } });
      },
    });
    const outcomes = await drain(writer);
    expect(outcomes[0]!.kind).toBe("superseded");
    // The superseded create keeps its claim lease and heads the task's queue;
    // the thread waits behind it until the lease runs out.
    await pg.db.taskSyncOp.updateMany({ where: { status: "pending" }, data: { nextAttemptAt: new Date(0) } });
    await drain(writer);
    expect(calls.create.map(bodyText)).toEqual(["written first"]);
  });
});
