// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { DB, Tx } from "../db/index.js";
import type { Prisma } from "../generated/prisma/client.js";

/**
 * Comments on a task: the thread under its description.
 *
 * Two kinds share `task_comments`. A comment written here has an
 * `authorUserId` and no `externalId`; one imported from the provider has an
 * `externalId` and, usually, only an `authorExternalLogin`. The imported kind
 * is the import's to write — it re-applies provider edits and deletes by
 * `externalId` — so nothing here edits or deletes one: a local edit would be
 * overwritten by the next provider edit, and a local delete would be undone by
 * nothing but would hide a comment that still exists upstream. Comments never
 * push (see `TaskSyncOpKindSchema`), so a local comment stays in Antgrid.
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
  const rows = await db.taskComment.findMany({
    where: { taskId: task, deletedAt: null },
    orderBy: [{ createdAt: "asc" }, { id: "asc" }],
    take: COMMENT_LIST_LIMIT,
    select: COMMENT_SELECT,
  });
  return rows.map(toRecord);
}

export async function createTaskComment(
  db: DB,
  args: TaskAddress & { authorUserId: string; body: string }
): Promise<TaskCommentResult> {
  const body = args.body.trim();
  if (body.length === 0) return { kind: "empty_body" };
  const task = await findTaskId(db, args);
  if (task === null) return { kind: "not_found" };
  const row = await db.taskComment.create({
    data: { taskId: task, authorUserId: args.authorUserId, body },
    select: COMMENT_SELECT,
  });
  return { kind: "ok", comment: toRecord(row) };
}

export async function updateTaskComment(
  db: DB,
  args: TaskAddress & { commentId: string; actorUserId: string; body: string }
): Promise<TaskCommentResult> {
  const body = args.body.trim();
  if (body.length === 0) return { kind: "empty_body" };
  return db.$transaction(async (tx): Promise<TaskCommentResult> => {
    const refusal = await refuseWrite(tx, args);
    if (refusal) return refusal;
    const row = await tx.taskComment.update({
      where: { id: args.commentId },
      data: { body },
      select: COMMENT_SELECT,
    });
    return { kind: "ok", comment: toRecord(row) };
  });
}

/** Soft, like the import's delete: one shape of "gone" for every reader. */
export async function deleteTaskComment(
  db: DB,
  args: TaskAddress & { commentId: string; actorUserId: string }
): Promise<{ kind: "ok" } | TaskCommentRefusal> {
  return db.$transaction(async (tx) => {
    const refusal = await refuseWrite(tx, args);
    if (refusal) return refusal;
    await tx.taskComment.update({
      where: { id: args.commentId },
      data: { deletedAt: new Date() },
    });
    return { kind: "ok" as const };
  });
}

async function refuseWrite(
  tx: Tx,
  args: TaskAddress & { commentId: string; actorUserId: string }
): Promise<TaskCommentRefusal | null> {
  const task = await findTaskId(tx, args);
  if (task === null) return { kind: "not_found" };
  // Scoped to the task as well as the id, so a uuid from another task — or
  // another account — misses exactly like one that never existed.
  const comment = await tx.taskComment.findFirst({
    where: { id: args.commentId, taskId: task, deletedAt: null },
    select: { authorUserId: true, externalId: true },
  });
  if (!comment) return { kind: "comment_not_found" };
  if (comment.externalId !== null) return { kind: "imported" };
  if (comment.authorUserId !== args.actorUserId) return { kind: "not_author" };
  return null;
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
    imported: row.externalId !== null,
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
