// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { DB, Tx } from "../db/index.js";
import type { Prisma } from "../generated/prisma/client.js";
import {
  cancelOp,
  enqueueForTask,
  lockTaskSync,
  rotateOpKey,
  TaskSyncOpKindSchema,
  TaskSyncOpStatusSchema,
} from "../tasks/sync-op.js";

/**
 * Comments on a task: the thread under its description.
 *
 * Two kinds share `task_comments`. A comment written here has an
 * `authorUserId`; one imported from the provider has an `externalId` and,
 * usually, only an `authorExternalLogin`. The imported kind is the import's to
 * write — it re-applies provider edits and deletes by `externalId` — so nothing
 * here edits or deletes one: a local edit would be overwritten by the next
 * provider edit, and a local delete would hide a comment that still exists
 * upstream.
 *
 * A comment written here on a task whose issue takes pushes is mirrored onto
 * it through the outbox, and then carries the mirror's `externalId` too. Its
 * author still owns it: their edits and deletes here are sent on, and an edit
 * to the mirror on the provider is not imported back.
 *
 * A comment is addressed by its uuid, but always under the task's
 * `(accountId, number)`: the uuid alone is never trusted to name a tenant.
 */

/** GitHub's ceiling on a comment body, matching the task body's cap. Nothing
 *  pushes comments today, but a thread that could never be published is a
 *  limit worth not having to migrate past. */
export const COMMENT_BODY_MAX = 65536;

/** No cursor yet; the cap keeps a runaway thread from being one response. */
const COMMENT_LIST_LIMIT = 500;

const COMMENT_SELECT = {
  id: true,
  authorUserId: true,
  authorExternalLogin: true,
  body: true,
  externalId: true,
  createdAt: true,
  updatedAt: true,
  author: { select: { name: true, image: true } },
} satisfies Prisma.TaskCommentSelect;

type CommentRow = Prisma.TaskCommentGetPayload<{ select: typeof COMMENT_SELECT }>;

export type CommentAuthor =
  | { kind: "member"; userId: string; name: string; avatarUrl: string | null }
  | { kind: "external"; login: string }
  /** A member who has since deleted their user, or an import with no login. */
  | null;

export type TaskCommentRecord = {
  id: string;
  author: CommentAuthor;
  body: string;
  imported: boolean;
  /** Written here and mirrored onto the linked issue. */
  mirrored: boolean;
  createdAt: Date;
  updatedAt: Date;
};

export type TaskCommentRefusal =
  | { kind: "not_found" }
  | { kind: "comment_not_found" }
  | { kind: "empty_body" }
  | { kind: "not_author" }
  | { kind: "imported" };

export type TaskCommentResult = { kind: "ok"; comment: TaskCommentRecord } | TaskCommentRefusal;

type TaskAddress = { accountId: string; number: number };

export async function listTaskComments(
  db: Tx,
  args: TaskAddress
): Promise<TaskCommentRecord[] | null> {
  const task = await findTaskId(db, args);
  if (task === null) return null;
  // The newest page, flipped back to reading order: capping an ascending read
  // would drop the comment just posted from every reload of a long thread.
  const rows = await db.taskComment.findMany({
    where: { taskId: task, deletedAt: null },
    orderBy: [{ createdAt: "desc" }, { id: "desc" }],
    take: COMMENT_LIST_LIMIT,
    select: COMMENT_SELECT,
  });
  return rows.reverse().map(toRecord);
}

export async function createTaskComment(
  db: DB,
  args: TaskAddress & { authorUserId: string; body: string }
): Promise<TaskCommentResult> {
  const body = args.body.trim();
  if (body.length === 0) return { kind: "empty_body" };
  return db.$transaction(async (tx): Promise<TaskCommentResult> => {
    const task = await findTaskId(tx, args);
    if (task === null) return { kind: "not_found" };
    await lockTaskSync(tx, task);
    const row = await tx.taskComment.create({
      data: { taskId: task, authorUserId: args.authorUserId, body },
      select: COMMENT_SELECT,
    });
    // A no-op unless the task's issue takes pushes — `enqueueForTask` is the
    // one place that consent is asked.
    await enqueueForTask(tx, {
      accountId: args.accountId,
      taskId: task,
      payloads: [{ kind: TaskSyncOpKindSchema.enum["comment.create"], commentId: row.id }],
    });
    return { kind: "ok", comment: toRecord(row) };
  });
}

export async function updateTaskComment(
  db: DB,
  args: TaskAddress & { commentId: string; actorUserId: string; body: string }
): Promise<TaskCommentResult> {
  const body = args.body.trim();
  if (body.length === 0) return { kind: "empty_body" };
  return db.$transaction(async (tx): Promise<TaskCommentResult> => {
    const target = await writableComment(tx, args);
    if ("kind" in target) return target;
    const row = await tx.taskComment.update({
      where: { id: args.commentId },
      data: { body },
      select: COMMENT_SELECT,
    });
    await mirrorChange(tx, args.accountId, target, "update");
    return { kind: "ok", comment: toRecord(row) };
  });
}

/** Soft, like the import's delete: one shape of "gone" for every reader. */
export async function deleteTaskComment(
  db: DB,
  args: TaskAddress & { commentId: string; actorUserId: string }
): Promise<{ kind: "ok" } | TaskCommentRefusal> {
  return db.$transaction(async (tx) => {
    const target = await writableComment(tx, args);
    if ("kind" in target) return target;
    await tx.taskComment.update({
      where: { id: args.commentId },
      data: { deletedAt: new Date() },
    });
    await mirrorChange(tx, args.accountId, target, "delete");
    return { kind: "ok" as const };
  });
}

type WritableComment = { taskId: string; commentId: string; externalId: string | null };

/** Resolves the comment and takes the task's `tasksync:` lock, which every
 *  enqueue requires of its caller and which orders this edit against the drain. */
async function writableComment(
  tx: Tx,
  args: TaskAddress & { commentId: string; actorUserId: string }
): Promise<WritableComment | TaskCommentRefusal> {
  const task = await findTaskId(tx, args);
  if (task === null) return { kind: "not_found" };
  await lockTaskSync(tx, task);
  // Scoped to the task as well as the id, so a uuid from another task — or
  // another account — misses exactly like one that never existed.
  const comment = await tx.taskComment.findFirst({
    where: { id: args.commentId, taskId: task, deletedAt: null },
    select: { authorUserId: true, externalId: true },
  });
  if (!comment) return { kind: "comment_not_found" };
  if (isImported(comment)) return { kind: "imported" };
  if (comment.authorUserId !== args.actorUserId) return { kind: "not_author" };
  return { taskId: task, commentId: args.commentId, externalId: comment.externalId };
}

/**
 * Send an edit or a delete on to the mirror, when there is one or one is on
 * its way.
 *
 * A create not yet handed to the provider absorbs both: it reads the body when
 * it is sent, so an edit needs no op of its own, and a delete simply cancels
 * it. "Not yet handed" still allows the drain to have read the old body in its
 * first critical section, so an edit rotates the create's key — its commit then
 * sees the intent moved and queues the edit behind the post. A comment with no
 * mirror and no create queued was written while nothing was being pushed, and
 * an edit is not consent to publish it now.
 */
async function mirrorChange(
  tx: Tx,
  accountId: string,
  comment: WritableComment,
  verb: "update" | "delete"
): Promise<void> {
  const create = await tx.taskSyncOp.findFirst({
    where: {
      taskId: comment.taskId,
      kind: TaskSyncOpKindSchema.enum["comment.create"],
      status: TaskSyncOpStatusSchema.enum.pending,
      payload: { path: ["commentId"], equals: comment.commentId },
    },
    select: { id: true, attemptedAt: true },
  });
  if (create && create.attemptedAt === null) {
    if (verb === "delete") await cancelOp(tx, create.id, "the comment was deleted before it was sent");
    else await rotateOpKey(tx, create.id);
    return;
  }
  if (comment.externalId === null && !create) return;
  await enqueueForTask(tx, {
    accountId,
    taskId: comment.taskId,
    payloads: [{ kind: TaskSyncOpKindSchema.enum[`comment.${verb}`], commentId: comment.commentId }],
  });
}

/** From the provider, as opposed to written here and mirrored there. */
function isImported(row: { authorUserId: string | null; externalId: string | null }): boolean {
  return row.externalId !== null && row.authorUserId === null;
}

async function findTaskId(db: Tx, args: TaskAddress): Promise<string | null> {
  const task = await db.task.findFirst({
    where: { accountId: args.accountId, number: args.number, deletedAt: null },
    select: { id: true },
  });
  return task?.id ?? null;
}

function toRecord(row: CommentRow): TaskCommentRecord {
  return {
    id: row.id,
    author: authorOf(row),
    body: row.body,
    imported: isImported(row),
    mirrored: row.externalId !== null && row.authorUserId !== null,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

function authorOf(row: CommentRow): CommentAuthor {
  if (row.authorUserId !== null && row.author !== null) {
    return {
      kind: "member",
      userId: row.authorUserId,
      name: row.author.name,
      avatarUrl: row.author.image,
    };
  }
  if (row.authorExternalLogin !== null) {
    return { kind: "external", login: row.authorExternalLogin };
  }
  return null;
}
