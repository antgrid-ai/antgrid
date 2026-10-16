// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { Tx } from "../db/index.js";
import { githubIssueNumberFromKey } from "../integrations/github-import.js";
import { GITHUB_PROVIDER, type GithubIssueComment } from "../integrations/github-events.js";
import {
  commentMarker,
  findCommentKey,
  isOwnAppComment,
  type GithubIssueWriter,
  type GithubRepoTarget,
} from "../integrations/github-issues.js";
import {
  cancelOp,
  completeOp,
  enqueueSyncOp,
  refuseOp,
  TaskSyncOpKindSchema,
  type CommentSyncOpPayload,
} from "./sync-op.js";

/**
 * Mirroring a thread written in Antgrid onto the linked issue: the comment arm
 * of `applyOp`, with the same two critical sections around one round trip.
 *
 * Simpler than the issue arm in two ways, both deliberate. There is no
 * compare-and-swap: a mirrored comment is authored by the App, and the person
 * who wrote it here owns its text — an edit made to the mirror on GitHub is not
 * imported (see `applyComment` in `github-inbound.ts`), so there is no remote
 * value for a push to clobber. And there is no echo hash, for the same reason:
 * an inbound event for a comment written here never writes its body.
 *
 * What is NOT simpler is the lost response. A create posts a public comment, so
 * one handed to GitHub with an unknown outcome is resolved by listing the
 * issue's comments for its marker before anything is posted again — the same
 * shape `listAppIssuesSince` gives an issue create.
 */

/** Same tolerance as an issue create's resolution, for the same clock skew. */
const RESOLUTION_SKEW_SECONDS = 60;

/** Why a comment op was closed without reaching the provider. */
export type CommentSkipReason =
  | "comment_missing"
  | "comment_deleted"
  | "comment_not_pushed"
  | "already_created";

export type CommentPlan = {
  opKey: string;
  attemptedAt: Date | null;
  taskId: string;
  integrationId: string;
  repo: GithubRepoTarget;
  issueNumber: number;
  commentId: string;
  request:
    | {
        kind: "create";
        body: string;
        /** The local comment was deleted after an earlier attempt was handed to
         *  GitHub: find what that attempt posted so it can be removed, but never
         *  post it afresh. */
        resolveOnly: boolean;
      }
    | { kind: "update"; externalId: string; body: string }
    | { kind: "delete"; externalId: string };
};

export type CommentDecision =
  | { kind: "push"; plan: CommentPlan }
  | { kind: "skip"; reason: CommentSkipReason }
  | { kind: "refuse"; reason: string };

/**
 * First critical section, entered with `tasksync:` held and the task's own
 * guards (deleted, unlinked, push consent, installation) already passed.
 */
export async function decideComment(
  tx: Tx,
  args: {
    opId: string;
    opKey: string;
    attemptedAt: Date | null;
    taskId: string;
    integrationId: string;
    externalKey: string | null;
    repo: GithubRepoTarget;
    payload: CommentSyncOpPayload;
    /** The task stopped taking pushes after this create was handed over:
     *  resolve what the hand-off posted, never post again. */
    resolveOnly: boolean;
  }
): Promise<CommentDecision> {
  if (args.resolveOnly && !(args.payload.kind === "comment.create" && args.attemptedAt !== null)) {
    await cancelOp(tx, args.opId, "the task no longer sends edits to the issue");
    return { kind: "skip", reason: "comment_not_pushed" };
  }
  const issueNumber = githubIssueNumberFromKey(args.externalKey);
  if (issueNumber === null) {
    const reason = "the task carries no usable issue number";
    await refuseOp(tx, args.opId, reason);
    return { kind: "refuse", reason };
  }

  const comment = await tx.taskComment.findFirst({
    where: { id: args.payload.commentId, taskId: args.taskId },
    select: {
      body: true,
      externalId: true,
      deletedAt: true,
      authorUserId: true,
      author: { select: { name: true } },
    },
  });
  // A comment imported from the provider is the provider's; nothing here writes
  // one back, and a comment without a local author is one of those or a
  // member's whose account is gone.
  if (!comment || comment.authorUserId === null) {
    await cancelOp(tx, args.opId, "no comment written here to mirror");
    return { kind: "skip", reason: "comment_missing" };
  }

  const base = {
    opKey: args.opKey,
    attemptedAt: args.attemptedAt,
    taskId: args.taskId,
    integrationId: args.integrationId,
    repo: args.repo,
    issueNumber,
    commentId: args.payload.commentId,
  };
  const body = renderMirroredComment({
    authorName: comment.author?.name ?? null,
    body: comment.body,
    commentId: args.payload.commentId,
  });

  if (args.payload.kind === TaskSyncOpKindSchema.enum["comment.create"]) {
    if (comment.externalId !== null) {
      await cancelOp(tx, args.opId, "the comment is already on the issue");
      return { kind: "skip", reason: "already_created" };
    }
    const deleted = comment.deletedAt !== null;
    if (deleted && args.attemptedAt === null) {
      await cancelOp(tx, args.opId, "the comment was deleted before it was sent");
      return { kind: "skip", reason: "comment_deleted" };
    }
    return {
      kind: "push",
      plan: { ...base, request: { kind: "create", body, resolveOnly: deleted || args.resolveOnly } },
    };
  }

  // An edit or a delete addresses the mirror, and there is none to address.
  if (comment.externalId === null) {
    await cancelOp(tx, args.opId, "the comment never reached the issue");
    return { kind: "skip", reason: "comment_not_pushed" };
  }
  if (args.payload.kind === TaskSyncOpKindSchema.enum["comment.delete"]) {
    return {
      kind: "push",
      plan: { ...base, request: { kind: "delete", externalId: comment.externalId } },
    };
  }
  // A delete is queued behind this edit; sending the text first would only put
  // a deleted comment back in front of the issue's watchers.
  if (comment.deletedAt !== null) {
    await cancelOp(tx, args.opId, "the comment was deleted");
    return { kind: "skip", reason: "comment_deleted" };
  }
  return {
    kind: "push",
    plan: { ...base, request: { kind: "update", externalId: comment.externalId, body } },
  };
}

export type CommentSendResult =
  | { kind: "created"; comment: GithubIssueComment; recovered: boolean }
  /** A resolve-only create found nothing: the earlier attempt never landed. */
  | { kind: "absent" }
  | { kind: "updated" }
  | { kind: "deleted" };

/** The provider round trip: no database handle reaches this, by construction. */
export async function sendComment(
  writer: GithubIssueWriter,
  plan: CommentPlan,
  appSlug: string
): Promise<CommentSendResult> {
  const issue = { ...plan.repo, number: plan.issueNumber };
  const request = plan.request;
  switch (request.kind) {
    case "create": {
      if (plan.attemptedAt !== null) {
        const since = new Date(plan.attemptedAt.getTime() - RESOLUTION_SKEW_SECONDS * 1000);
        const listed = await writer.listIssueCommentsSince(issue, since);
        const found = listed.find(
          (c) => isOwnAppComment(c, appSlug) && findCommentKey(c.body) === plan.commentId
        );
        if (found) return { kind: "created", comment: found, recovered: true };
      }
      if (request.resolveOnly) return { kind: "absent" };
      const created = await writer.createComment(issue, request.body);
      return { kind: "created", comment: created, recovered: false };
    }
    case "update":
      await writer.updateComment({ ...plan.repo, commentId: request.externalId }, request.body);
      return { kind: "updated" };
    case "delete":
      await writer.deleteComment({ ...plan.repo, commentId: request.externalId });
      return { kind: "deleted" };
  }
}

export type CommentCommitOutcome =
  | { kind: "done"; recovered: boolean }
  /** A newer edit rewrote the op while the request was in flight; it stays
   *  pending and goes out again with the current text. */
  | { kind: "superseded" }
  /** The post landed but its local comment no longer exists, so nothing here
   *  can ever name it again. The caller removes it from the issue. */
  | { kind: "orphaned"; externalId: string };

/**
 * Second critical section, entered with `tasksync:` held.
 *
 * A create's link is written whatever happened to the op meanwhile: the comment
 * now exists on GitHub, and a local row that does not name it is a public
 * comment nothing here can edit or delete again.
 */
export async function commitComment(
  tx: Tx,
  plan: CommentPlan,
  opId: string,
  sent: CommentSendResult
): Promise<CommentCommitOutcome> {
  const op = await tx.taskSyncOp.findUnique({
    where: { id: opId },
    select: { status: true, opKey: true },
  });
  const current = op !== null && op.status === "pending" && op.opKey === plan.opKey;

  if (sent.kind === "absent") {
    if (current) await cancelOp(tx, opId, "the comment was deleted before it reached the issue");
    return { kind: "done", recovered: false };
  }

  if (sent.kind === "created") {
    const externalId = sent.comment.id;
    // The webhook for this very comment can be drained before this commit, and
    // one that arrived without a recognisable marker imported it as a stranger's.
    // That row is this comment's duplicate, and it holds the unique key.
    await tx.taskComment.deleteMany({
      where: { taskId: plan.taskId, externalId, authorUserId: null, id: { not: plan.commentId } },
    });
    // `updateMany`, not `update`: a row that vanished mid-flight must end this
    // op, not throw into a retry that recovers the same comment and throws
    // again until the attempt ceiling.
    const linked = await tx.taskComment.updateMany({
      where: { id: plan.commentId, taskId: plan.taskId },
      data: { externalId },
    });
    if (op?.status === "pending") await completeOp(tx, opId);
    if (linked.count === 0) return { kind: "orphaned", externalId };

    const row = await tx.taskComment.findUniqueOrThrow({
      where: { id: plan.commentId },
      select: { deletedAt: true },
    });
    const follow = (kind: "comment.delete" | "comment.update") =>
      enqueueSyncOp(tx, {
        taskId: plan.taskId,
        integrationId: plan.integrationId,
        provider: GITHUB_PROVIDER,
        payload: { kind: TaskSyncOpKindSchema.enum[kind], commentId: plan.commentId },
      });
    // Deleted here while the post was in flight, after the delete had already
    // decided there was nothing on GitHub to remove.
    if (row.deletedAt !== null) await follow("comment.delete");
    // Edited after this op's text was read: the key moved (`rotateOpKey`), and
    // what was posted is the older text. A resolve-only create carries no
    // consent to write further, so it queues nothing.
    else if (!current && op?.status === "pending" && plan.request.kind === "create" && !plan.request.resolveOnly) {
      await follow("comment.update");
    }
    return { kind: "done", recovered: sent.recovered };
  }

  if (!current) return { kind: "superseded" };
  await completeOp(tx, opId);
  return { kind: "done", recovered: false };
}

/**
 * What a mirrored comment says on GitHub. The App is the author there, so the
 * person who wrote it is named in the body, or every mirrored comment reads as
 * the bot talking to itself.
 */
export function renderMirroredComment(args: {
  authorName: string | null;
  body: string;
  commentId: string;
}): string {
  // A name is free text the member chose: Markdown in it would render as a
  // link or a heading in front of every watcher, and an `@` would notify
  // whichever GitHub user or team it happens to spell.
  const name = (args.authorName ?? "").replace(/[\r\n*_`[\]<>#|\\@]/g, "").trim();
  const byline = name ? `_${name} commented in Antgrid_` : "_Commented in Antgrid_";
  return `${byline}\n\n${args.body}\n\n${commentMarker(args.commentId)}`;
}
