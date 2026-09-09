import { z } from "zod";
import type { DB, Tx } from "../db/index.js";
import { Prisma } from "../generated/prisma/client.js";
import { ACCOUNT_MEMBER_STATUS_ACTIVE } from "./account-member.js";
import { resolveLabelIds, type LabelResolution } from "./label.js";
import { keyBetween } from "../tasks/sort-key.js";
import { isUuid } from "../util/uuid.js";
import { sameRemoteState, toRemote, type Assignee, type TaskStatus } from "../tasks/merge.js";
import {
  cancelPendingOps,
  enqueueForTask,
  issueLabelsPayload,
  sameLabelSet,
  TaskSyncOpKindSchema,
  type CancelPendingOpsResult,
  type TaskSyncOpPayload,
} from "../tasks/sync-op.js";
import {
  clearTaskPushBlock,
  isPushBlocked,
  parsePushBlocked,
  type PushField,
} from "../tasks/push-blocked.js";
import { TaskSyncStateSchema, type TaskSyncState } from "../tasks/sync-state.js";
import {
  choosePublishTarget,
  isLinked,
  publishTaskInTx,
  type PublishRefusal,
} from "../tasks/publish.js";

/**
 * Tasks: account-owned units of work, optionally filed against a project.
 *
 * One rule outranks everything else in this file. **Prisma foreign keys enforce
 * existence, not tenancy** — a `projectId`, `labelId` or `assigneeUserId` from
 * another account is a perfectly valid FK — so every id that arrives from a
 * caller is re-resolved under the caller's `accountId` before it is written,
 * and every read carries `accountId` in its where-clause. `number` is a small
 * sequential key the API addresses (`/tasks/ANT-14`), which makes a where-clause
 * missing `accountId` immediately enumerable rather than theoretically
 * exploitable.
 *
 * `accountId` is always the caller's resolved active membership —
 * `findActiveMembership`, never `resolveBillingAccountId` and never
 * `user.accountId`. The owner fallback would silently write a task to a
 * different account than the team the user is acting in.
 */

/** Antgrid vocabulary, not a provider passthrough. Mirrors `TaskStatus` in
 *  `src/tasks/merge.ts`: a status one side can produce and the other cannot
 *  store would be dropped on write, silently. */
export const TaskStatusSchema = z.enum(["open", "in_progress", "blocked", "done", "cancelled"]);

/** The annotated return type is what keeps the two vocabularies in step — it
 *  stops compiling the moment the schema admits a status the merge does not. */
export function parseTaskStatus(value: string): TaskStatus | null {
  const parsed = TaskStatusSchema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

/** Where the task was born. A provider joins this union when its adapter lands;
 *  the column is text, so that is a code change rather than a migration. */
export const TaskSourceSchema = z.enum(["local", "github"]);
export type TaskSource = z.infer<typeof TaskSourceSchema>;

/** Re-exported so this module stays the one place a task's vocabulary is looked
 *  up, even though the enum itself has to live outside the import cycle this
 *  file sits at the top of — see `tasks/sync-state.ts`. */
export { TaskSyncStateSchema, type TaskSyncState };

/** The statuses that close a task. `closedAt` is derived from `status` in the
 *  same write and never set on its own, so the two cannot disagree. */
const CLOSED_STATUSES = new Set<TaskStatus>([
  TaskStatusSchema.enum.done,
  TaskStatusSchema.enum.cancelled,
]);

export const TaskTitleSchema = z.string().trim().min(1).max(500);

const TASK_SELECT = {
  id: true,
  accountId: true,
  projectId: true,
  number: true,
  title: true,
  body: true,
  status: true,
  priority: true,
  sortKey: true,
  source: true,
  assigneeUserId: true,
  assigneeExternalId: true,
  assigneeLogin: true,
  assigneeAvatarUrl: true,
  externalProvider: true,
  externalId: true,
  externalKey: true,
  externalUrl: true,
  syncState: true,
  remoteSnapshot: true,
  localConflict: true,
  pushBlocked: true,
  createdBy: true,
  createdAt: true,
  updatedAt: true,
  closedAt: true,
  labels: { select: { label: { select: { id: true, name: true, color: true } } } },
} satisfies Prisma.TaskSelect;

type TaskRow = Prisma.TaskGetPayload<{ select: typeof TASK_SELECT }>;

export type TaskLabelSummary = { id: string; name: string; color: string };

export type TaskRecord = {
  id: string;
  accountId: string;
  projectId: string | null;
  number: number;
  title: string;
  body: string;
  status: TaskStatus;
  priority: number | null;
  sortKey: string;
  source: string;
  assignee: Assignee | null;
  externalProvider: string | null;
  /** The provider's opaque handle. Never rendered — `externalKey` is the
   *  readable half of the same identity. */
  externalId: string | null;
  externalKey: string | null;
  externalUrl: string | null;
  syncState: string | null;
  /** The provider blob verbatim. `unknown` on purpose: reading it needs the
   *  provider's own parser, and importing one here would put provider knowledge
   *  in a layer that is supposed to speak only Antgrid vocabulary. */
  remoteSnapshot: unknown;
  /** The losing local values a merge kept, verbatim. `unknown` for the same
   *  reason as `remoteSnapshot`: the blob is provider-shaped and reading it
   *  needs the provider's parser. */
  localConflict: unknown;
  /** The per-field no-effect counters, as the column holds them. `unknown` so
   *  that every reader goes through `parsePushBlocked` — which is also the
   *  filter that drops a field name written before this vocabulary, or after
   *  one was retired. */
  pushBlocked: unknown;
  createdBy: string;
  createdAt: Date;
  updatedAt: Date;
  closedAt: Date | null;
  labels: TaskLabelSummary[];
};

export type TaskRefusal =
  | { kind: "not_found" }
  | { kind: "invalid_title" }
  | { kind: "project_not_found" }
  | { kind: "assignee_not_member"; userId: string }
  | { kind: "neighbours_out_of_order" }
  | PublishRefusal
  | Exclude<LabelResolution, { kind: "ok" }>;

export type TaskResult = { kind: "ok"; task: TaskRecord } | TaskRefusal;

export type CreateTaskArgs = {
  /** Resolved from the caller's active membership, never from the request. */
  accountId: string;
  /** The signed-in user. Recorded, never an authorization input. */
  createdBy: string;
  title: string;
  body?: string;
  status?: TaskStatus;
  priority?: number | null;
  projectId?: string | null;
  assignee?: Assignee | null;
  labelIds?: readonly string[];
  source?: TaskSource;
  /**
   * Publish this task to a provider as it is created, or `undefined` to keep it
   * local.
   *
   * The intent is always stated by the caller and never inferred:
   * `IntegrationRepo.publishNewByDefault` positions a toggle in the UI and is
   * never read on this path, so a client that forgets the field creates a
   * private task rather than a public issue. `repoId` is null when the caller
   * did not choose one, which is a refusal wherever the project offers more than
   * one target.
   */
  publish?: { repoId: string | null };
};

/**
 * Create a task and allocate its per-account display number.
 *
 * One transaction under `pg_advisory_xact_lock(hashtext('task:' || accountId))`
 * holding the max-read and the insert together — without it two concurrent
 * creates read the same maximum and the loser dies on
 * `tasks_account_number_key`.
 *
 * **The `task:` prefix is required, not decoration.** `hashtext` returns an
 * int4 into one GLOBAL advisory namespace, so a bare key — the shape
 * `models/device.ts` uses — would make task numbering contend with device
 * registration on a collision. Namespaced, following the billing code's
 * `hashtext('billing:' || accountId)`.
 */
export async function createTask(db: DB, args: CreateTaskArgs): Promise<TaskResult> {
  return db.$transaction((tx) => createTaskInTx(tx, args));
}

/**
 * The same create, for a caller that is already inside a transaction.
 *
 * Not an optimization: `pg_advisory_xact_lock` is transaction-scoped, so a
 * nested `$transaction` would take the numbering lock in a scope that ends
 * before the caller's own writes commit — and the inbound importer needs the
 * create and the link columns it writes next to land or roll back together.
 */
export async function createTaskInTx(tx: Tx, args: CreateTaskArgs): Promise<TaskResult> {
  const title = TaskTitleSchema.safeParse(args.title);
  if (!title.success) return { kind: "invalid_title" };
  const status = args.status ?? TaskStatusSchema.enum.open;

  const projectId = args.projectId ?? null;
  if (projectId !== null && !(await projectBelongsToAccount(tx, args.accountId, projectId))) {
    return { kind: "project_not_found" };
  }

  const assignee = args.assignee ?? null;
  const assigneeRefusal = await refuseForeignAssignee(tx, args.accountId, assignee);
  if (assigneeRefusal) return assigneeRefusal;

  const labels = await resolveLabelIds(tx, {
    accountId: args.accountId,
    projectId,
    labelIds: args.labelIds ?? [],
  });
  if (labels.kind !== "ok") return labels;

  // The destination is settled BEFORE the row exists: a publish that cannot be
  // addressed must leave nothing behind, and a task created into a refusal is a
  // draft the user never asked for sitting in their list.
  const target =
    args.publish === undefined
      ? null
      : await choosePublishTarget(tx, {
          accountId: args.accountId,
          projectId,
          repoId: args.publish.repoId,
        });
  if (target !== null && target.kind !== "ok") return target;

  await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`task:${args.accountId}`}))`;

  // Soft-deleted rows count deliberately: reissuing their number would
  // silently re-point a `/tasks/ANT-14` link somebody already holds.
  const highest = await tx.task.aggregate({
    where: { accountId: args.accountId },
    _max: { number: true, sortKey: true },
  });

  const row = await tx.task.create({
    data: {
      accountId: args.accountId,
      projectId,
      number: (highest._max.number ?? 0) + 1,
      title: title.data,
      body: args.body ?? "",
      status,
      priority: args.priority ?? null,
      sortKey: keyBetween(highest._max.sortKey ?? null, null),
      source: args.source ?? TaskSourceSchema.enum.local,
      createdBy: args.createdBy,
      closedAt: CLOSED_STATUSES.has(status) ? new Date() : null,
      ...assigneeColumns(assignee),
      labels: { create: labels.labelIds.map((labelId) => ({ labelId })) },
    },
    select: TASK_SELECT,
  });
  if (target === null) return { kind: "ok", task: toRecord(row) };

  // The `tasksync:` lock this needs can only be taken now: it is keyed on an id
  // that did not exist a statement ago, which is also why nothing else can be
  // holding it. Same transaction as the insert, so no reader ever sees the task
  // in the moment between being created and being addressed.
  await publishTaskInTx(tx, {
    taskId: row.id,
    target: target.target,
    fields: {
      title: row.title,
      body: row.body,
      status,
      labels: row.labels.map((entry) => entry.label.name),
    },
  });
  const published = await tx.task.findUniqueOrThrow({ where: { id: row.id }, select: TASK_SELECT });
  return { kind: "ok", task: toRecord(published) };
}

export type TaskPatch = {
  title?: string;
  body?: string;
  status?: TaskStatus;
  priority?: number | null;
  /** `null` unfiles the task from its project. */
  projectId?: string | null;
  /** `null` unassigns. Absent leaves the assignee alone. */
  assignee?: Assignee | null;
  /** Replaces the whole set, which is what a multi-select popover submits. */
  labelIds?: readonly string[];
};

/**
 * Edit a task, addressed the way the API addresses it.
 *
 * Re-filing a task to another project drops whatever repo-scoped labels it was
 * carrying: those belong to the project it left, and keeping them would push a
 * foreign repository's vocabulary the first time the task is linked.
 *
 * A linked task's edit and the `TaskSyncOp` describing it are one transaction,
 * so the outbox can never hold a write the row does not: a rolled-back edit that
 * left an op behind is a value the user never saved arriving in a public
 * repository.
 */
export async function updateTask(
  db: DB,
  args: { accountId: string; number: number; patch: TaskPatch }
): Promise<TaskResult> {
  const { accountId, number, patch } = args;
  const title = patch.title === undefined ? null : TaskTitleSchema.safeParse(patch.title);
  if (title && !title.success) return { kind: "invalid_title" };

  return db.$transaction(async (tx): Promise<TaskResult> => {
    const found = await tx.task.findFirst({
      where: { accountId, number, deletedAt: null },
      select: { id: true },
    });
    if (!found) return { kind: "not_found" };

    // `enqueueSyncOp` requires this lock of its caller, and whether the task is
    // linked at all is itself only readable under it — the inbound importer
    // writes the external columns while holding the same key. So it is taken
    // unconditionally rather than after a linked-or-not test that would be
    // racing the answer it reads. Taken only after the id resolved under
    // `accountId`: a lock keyed on an id a caller named is one a stranger can
    // take. Last in the fixed `ghhook:` -> `taskimport:` -> `tasksync:` order,
    // so taking it alone deadlocks against nothing.
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${found.id}`}))`;

    // Read under the lock, never before it.
    const current = await tx.task.findUnique({
      where: { id: found.id },
      select: {
        id: true,
        projectId: true,
        status: true,
        title: true,
        body: true,
        labels: { select: { label: { select: { name: true } } } },
      },
    });
    if (!current) return { kind: "not_found" };

    const projectId = patch.projectId === undefined ? current.projectId : patch.projectId;
    if (
      projectId !== null &&
      projectId !== current.projectId &&
      !(await projectBelongsToAccount(tx, accountId, projectId))
    ) {
      return { kind: "project_not_found" };
    }

    const assigneeRefusal =
      patch.assignee === undefined
        ? null
        : await refuseForeignAssignee(tx, accountId, patch.assignee);
    if (assigneeRefusal) return assigneeRefusal;

    const labels =
      patch.labelIds === undefined
        ? null
        : await resolveLabelIds(tx, { accountId, projectId, labelIds: patch.labelIds });
    if (labels && labels.kind !== "ok") return labels;

    if (projectId !== current.projectId) {
      await tx.taskLabel.deleteMany({
        where: { taskId: current.id, label: { projectId: { not: null } } },
      });
    }
    if (labels) {
      await tx.taskLabel.deleteMany({
        where: { taskId: current.id, labelId: { notIn: labels.labelIds } },
      });
      await tx.taskLabel.createMany({
        data: labels.labelIds.map((labelId) => ({ taskId: current.id, labelId })),
        skipDuplicates: true,
      });
    }

    const row = await tx.task.update({
      where: { id: current.id },
      data: {
        ...(title ? { title: title.data } : {}),
        ...(patch.body === undefined ? {} : { body: patch.body }),
        ...(patch.priority === undefined ? {} : { priority: patch.priority }),
        ...(patch.projectId === undefined ? {} : { projectId }),
        ...(patch.status === undefined
          ? {}
          : { status: patch.status, ...closedAtPatch(patch.status, current.status) }),
        ...(patch.assignee === undefined ? {} : assigneeColumns(patch.assignee)),
      },
      select: TASK_SELECT,
    });

    await enqueueEditOps(tx, accountId, row, {
      previousTitle: current.title,
      previousBody: current.body,
      previousStatus: parseTaskStatus(current.status) ?? TaskStatusSchema.enum.open,
      previousLabels: current.labels.map((entry) => entry.label.name),
    });
    return { kind: "ok", task: toRecord(row) };
  });
}

/** What the row held before the edit, in Antgrid vocabulary — the only thing
 *  that can answer "did this write move anything a provider can see". */
type PreviousFields = {
  previousTitle: string;
  previousBody: string;
  previousStatus: TaskStatus;
  previousLabels: string[];
};

/**
 * Queue the provider writes one local edit implies.
 *
 * Diffed rather than driven off which fields the patch named: a PATCH restating
 * a value it is not changing is the normal shape of a form submit, and turning
 * each one into a write spends a 500/hour content-creating budget on nothing.
 *
 * **`status` is diffed in PROVIDER space.** `toRemote` is many-to-one, so
 * `in_progress -> blocked` is no change at all to GitHub — and the automatic
 * status writers (`working -> in_progress`, `attention -> blocked`) move only
 * between statuses that project onto the same `state`. An op appearing for one
 * of those is the no-op push loop returning, which is why it is the shape of the
 * comparison and not a special case in the caller.
 *
 * **`assignee` is absent by construction, not by omission.** GitHub drops an
 * assignee lacking push access and answers 200, so a pushed assignee is a loop
 * no response comparison can detect; `TaskSyncOpKindSchema` has no kind for it.
 */
async function enqueueEditOps(
  tx: Tx,
  accountId: string,
  row: TaskRow,
  previous: PreviousFields
): Promise<void> {
  const status = parseTaskStatus(row.status) ?? TaskStatusSchema.enum.open;
  const labels = row.labels.map((entry) => entry.label.name);

  const payloads: TaskSyncOpPayload[] = [];
  if (row.title !== previous.previousTitle) {
    payloads.push({ kind: TaskSyncOpKindSchema.enum["issue.patch.title"], title: row.title });
  }
  if (row.body !== previous.previousBody) {
    payloads.push({ kind: TaskSyncOpKindSchema.enum["issue.patch.body"], body: row.body });
  }
  if (!sameRemoteState(toRemote(status), toRemote(previous.previousStatus))) {
    payloads.push(statePayload(status));
  }
  if (!sameLabelSet(labels, previous.previousLabels)) {
    payloads.push(issueLabelsPayload(labels));
  }
  await enqueueForTask(tx, { accountId, taskId: row.id, payloads });
}

/** `toRemote` is the one mapping onto provider status; a second spelling of it
 *  here is a push loop waiting for the two to disagree. */
function statePayload(status: TaskStatus): TaskSyncOpPayload {
  const remote = toRemote(status);
  return {
    kind: TaskSyncOpKindSchema.enum["issue.state"],
    state: remote.state,
    stateReason: remote.stateReason ?? null,
  };
}

/**
 * Move a task between two neighbours, all three named by the caller and all
 * three re-resolved under the caller's account.
 *
 * One row write: a fractional index never renumbers what it is inserted
 * between. `null` on either side is the end of the list.
 *
 * Neighbours in the wrong order are refused here rather than left to
 * `keyBetween`, which raises for them. Every other bad input in this file is a
 * refusal, and a caller that has to catch for one of them will eventually
 * forget — the exception surfaces as a 500 on a plainly bad request.
 */
export async function moveTask(
  db: DB,
  args: {
    accountId: string;
    number: number;
    /** The task this one lands after, or null for the top. */
    previousNumber: number | null;
    /** The task this one lands before, or null for the bottom. */
    nextNumber: number | null;
  }
): Promise<TaskResult> {
  const { accountId, number } = args;
  return db.$transaction(async (tx): Promise<TaskResult> => {
    const [moving, previousKey, nextKey] = await Promise.all([
      tx.task.findFirst({ where: { accountId, number, deletedAt: null }, select: { id: true } }),
      neighbourKey(tx, accountId, args.previousNumber),
      neighbourKey(tx, accountId, args.nextNumber),
    ]);
    if (!moving) return { kind: "not_found" };
    // A neighbour that resolved to nothing belonged to another account or does
    // not exist; dropping it silently would land the task somewhere the caller
    // did not ask for.
    if (args.previousNumber !== null && previousKey === null) return { kind: "not_found" };
    if (args.nextNumber !== null && nextKey === null) return { kind: "not_found" };
    // Also catches one number named twice, which resolves to one key on both
    // sides and leaves nothing between them.
    if (previousKey !== null && nextKey !== null && previousKey >= nextKey) {
      return { kind: "neighbours_out_of_order" };
    }

    const row = await tx.task.update({
      where: { id: moving.id },
      data: { sortKey: keyBetween(previousKey, nextKey) },
      select: TASK_SELECT,
    });
    return { kind: "ok", task: toRecord(row) };
  });
}

export type ListTasksArgs = {
  accountId: string;
  status?: TaskStatus | TaskStatus[];
  projectId?: string;
  /** "Assigned to me" — still anchored on `accountId`, or the view returns a
   *  former employer's tasks the moment a membership closes. */
  assigneeUserId?: string;
  limit?: number;
};

const LIST_LIMIT_DEFAULT = 100;
const LIST_LIMIT_MAX = 500;

export async function listTasks(db: Tx, args: ListTasksArgs): Promise<TaskRecord[]> {
  const status = args.status === undefined ? undefined : [args.status].flat();
  const limit = Math.min(Math.max(args.limit ?? LIST_LIMIT_DEFAULT, 1), LIST_LIMIT_MAX);
  if (args.projectId !== undefined && !isUuid(args.projectId)) return [];

  const rows = await db.task.findMany({
    where: {
      accountId: args.accountId,
      deletedAt: null,
      ...(status ? { status: { in: status } } : {}),
      ...(args.projectId === undefined ? {} : { projectId: args.projectId }),
      ...(args.assigneeUserId === undefined ? {} : { assigneeUserId: args.assigneeUserId }),
    },
    orderBy: { sortKey: "asc" },
    take: limit,
    select: TASK_SELECT,
  });
  return rows.map(toRecord);
}

export async function getTaskByNumber(
  db: Tx,
  accountId: string,
  number: number
): Promise<TaskRecord | null> {
  const row = await db.task.findFirst({
    where: { accountId, number, deletedAt: null },
    select: TASK_SELECT,
  });
  return row ? toRecord(row) : null;
}

export type SoftDeleteTaskResult =
  | ({ kind: "ok" } & Pick<CancelPendingOpsResult, "keptCreate">)
  | { kind: "not_found" };

/**
 * Soft-delete: the row stays, because its external identity is what an inbound
 * webhook resolves through and a hard delete would let the same issue re-import
 * as a brand-new task.
 *
 * A linked task is marked `unlinked` in the same transaction, and that marker is
 * only HALF of the protection. `tasks_account_external_key` is untouched, so an
 * inbound upsert still resolves straight to this row — what stops it applying
 * remote edits to a task the user believes is gone is the inbound path filtering
 * `deletedAt IS NULL AND syncState <> 'unlinked'`. Nothing here can enforce that
 * from this side; the marker exists so there is something to filter on.
 *
 * The queued provider writes go with it, in the same transaction: a `title := X`
 * applied after the user stopped tracking the task writes to a repository they
 * walked away from.
 */
export async function softDeleteTask(
  db: DB,
  args: { accountId: string; number: number }
): Promise<SoftDeleteTaskResult> {
  const { accountId, number } = args;
  return db.$transaction(async (tx): Promise<SoftDeleteTaskResult> => {
    const found = await tx.task.findFirst({
      where: { accountId, number, deletedAt: null },
      select: { id: true },
    });
    if (found === null) return { kind: "not_found" };

    // Required of `cancelPendingOps`, and taken before the delete rather than
    // after: a drain claiming this task's head op holds the same key, so between
    // an unlocked delete and the cancel it could take an op the delete had
    // already decided was moot.
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${found.id}`}))`;

    const deleted = await tx.task.updateMany({
      where: { id: found.id, deletedAt: null },
      data: { deletedAt: new Date() },
    });
    if (deleted.count === 0) return { kind: "not_found" };
    await tx.task.updateMany({
      where: { id: found.id, externalId: { not: null } },
      data: { syncState: TaskSyncStateSchema.enum.unlinked },
    });

    // `keptCreate` is handed back rather than acted on here. An already-attempted
    // `issue.create` has an unknown outcome — the issue may exist with nothing
    // linking to it — and the read that settles it is a provider call, which this
    // transaction must not hold itself open across.
    const { keptCreate } = await cancelPendingOps(tx, found.id);
    return { kind: "ok", keptCreate };
  });
}

export type PublishTaskRefusal =
  | { kind: "not_found" }
  /** The task already has a live issue. Publishing again would create a second
   *  one, which is why this is a refusal and not an update. */
  | { kind: "already_linked" }
  | PublishRefusal;

export type PublishTaskResult = { kind: "ok"; task: TaskRecord } | PublishTaskRefusal;

/**
 * Publish an existing task — the after-the-fact half of the same mechanism the
 * create path uses, differing only in when the user was asked.
 *
 * An `unlinked` task is publishable on purpose: the tombstone keeps the old
 * identity on the row precisely so the confirm sheet can name the issue that
 * already exists, and the write then clears it, because the new issue is a
 * different one and nothing about the first may survive.
 */
export async function publishTaskByNumber(
  db: DB,
  args: { accountId: string; number: number; repoId: string | null }
): Promise<PublishTaskResult> {
  const { accountId, number, repoId } = args;
  return db.$transaction(async (tx): Promise<PublishTaskResult> => {
    const found = await tx.task.findFirst({
      where: { accountId, number, deletedAt: null },
      select: { id: true },
    });
    if (!found) return { kind: "not_found" };

    // Taken only after the id resolved under `accountId` — a lock keyed on an id
    // a caller named is one a stranger can take — and before the is-it-linked
    // read below, which the inbound importer writes under the same key.
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${found.id}`}))`;

    // Read under the lock, never before it.
    const current = await tx.task.findUnique({
      where: { id: found.id },
      select: {
        id: true,
        deletedAt: true,
        projectId: true,
        title: true,
        body: true,
        status: true,
        externalId: true,
        syncState: true,
        labels: { select: { label: { select: { name: true } } } },
      },
    });
    // `deletedAt` again, under the lock: the first read only proved the task was
    // there before the wait for it, and publishing a task someone deleted in
    // between is the one write here that cannot be undone.
    if (!current || current.deletedAt !== null) return { kind: "not_found" };
    if (isLinked(current)) return { kind: "already_linked" };

    const target = await choosePublishTarget(tx, {
      accountId,
      projectId: current.projectId,
      repoId,
    });
    if (target.kind !== "ok") return target;

    await publishTaskInTx(tx, {
      taskId: current.id,
      target: target.target,
      fields: {
        title: current.title,
        body: current.body,
        status: parseTaskStatus(current.status) ?? TaskStatusSchema.enum.open,
        labels: current.labels.map((entry) => entry.label.name),
      },
    });

    const row = await tx.task.findUniqueOrThrow({ where: { id: current.id }, select: TASK_SELECT });
    return { kind: "ok", task: toRecord(row) };
  });
}

export type UnlinkTaskRefusal = { kind: "not_found" } | { kind: "not_linked" };

export type UnlinkTaskResult = { kind: "ok"; task: TaskRecord } | UnlinkTaskRefusal;

/**
 * Stop syncing a task, leaving the provider's issue exactly as it is.
 *
 * The only reverse of a publish there is: the issue exists and we cannot take it
 * back, so `unlinked` is a tombstone rather than a delete — the external columns
 * stay on the row so the UI can name the issue this task used to be, and so a
 * re-publish can warn that it creates a second one.
 *
 * **Queued ops are deliberately not cancelled here.** `applyOp` already drops an
 * op whose task is unlinked, under the same key this holds, and one code path
 * for that decision is better than two that can disagree.
 */
export async function unlinkTask(
  db: DB,
  args: { accountId: string; number: number }
): Promise<UnlinkTaskResult> {
  const { accountId, number } = args;
  return db.$transaction(async (tx): Promise<UnlinkTaskResult> => {
    const found = await tx.task.findFirst({
      where: { accountId, number, deletedAt: null },
      select: { id: true },
    });
    if (!found) return { kind: "not_found" };

    // What `syncState` says is only readable under the key its other writers
    // hold: the inbound importer and the outbox drain both move it, and an
    // unlink decided against a stale read is a task that keeps pushing.
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${found.id}`}))`;

    const current = await tx.task.findUnique({
      where: { id: found.id },
      select: { id: true, externalId: true, syncState: true },
    });
    if (!current) return { kind: "not_found" };
    if (!isLinked(current)) return { kind: "not_linked" };

    const row = await tx.task.update({
      where: { id: current.id },
      data: { syncState: TaskSyncStateSchema.enum.unlinked },
      select: TASK_SELECT,
    });
    return { kind: "ok", task: toRecord(row) };
  });
}

/** The losing value to restore, already checked against the field's own schema
 *  by whoever read the blob. This layer writes it; it never reads the blob. */
export type ConflictLocalPatch =
  | { field: "title"; value: string }
  | { field: "body"; value: string }
  | { field: "status"; value: TaskStatus }
  | { field: "assignee"; value: Assignee | null };

export type ConflictDecision =
  | {
      kind: "write";
      /** null when the row already holds the winning value and only the blob
       *  moves — taking the remote, or acknowledging a dropped label. */
      patch: ConflictLocalPatch | null;
      /** The blob to store; `null` clears the column. */
      nextConflict: unknown;
      /** Whether a scalar conflict survives. `labelRemoveWins` alone never
       *  raised `conflict`, so it must never hold the row in it. */
      conflictsRemain: boolean;
    }
  | Exclude<ResolveConflictRefusal, { kind: "not_found" } | { kind: "assignee_not_member" }>;

export type ResolveConflictRefusal =
  | { kind: "not_found" }
  | { kind: "not_conflicted"; field: string }
  | { kind: "local_value_unreadable"; field: string }
  | { kind: "labels_local_unsupported" }
  | { kind: "assignee_not_member"; userId: string };

export type ResolveConflictResult = { kind: "ok"; task: TaskRecord } | ResolveConflictRefusal;

/**
 * Adjudicate one field of `Task.localConflict` and clear its entry.
 *
 * The blob is sticky by construction — the inbound merge only ever accumulates
 * into it, so that a later clean delivery cannot downgrade an unresolved row to
 * `synced`. This is the only exit, and without it the "remote wins, we keep your
 * edit" promise raises a badge nobody can dismiss.
 *
 * **`remoteSnapshot` is never touched here.** It is the last state both sides
 * agreed on, and restoring a local value deliberately leaves `local != base`:
 * that is exactly what a future push has to send, and what stops the next
 * inbound delivery — where `remote == base` — from clobbering the same edit a
 * second time. Re-seeding the snapshot to match would silently convert this
 * resolution into a second surrender.
 *
 * **Taking `local` enqueues the push**, on the same terms as any other local
 * edit. Nothing else would ever send it: the outbox is driven by edits and not
 * by a reconcile sweep, and the row is left deliberately ahead of
 * `remoteSnapshot` — so a resolution that queued nothing is a field the user
 * adjudicated once and that then diverges permanently, which is the outcome the
 * whole verb exists to prevent. `take: "remote"` writes no column and so queues
 * nothing, and the `assignee` arm queues nothing because no assignee op exists
 * by construction.
 */
export async function resolveTaskConflict(
  db: DB,
  args: {
    accountId: string;
    number: number;
    /** What to write, given the row as it stands under the lock. The blob is
     *  provider-shaped, so parsing it belongs with the provider rather than in
     *  a layer that speaks only Antgrid vocabulary. */
    decide: (current: { localConflict: unknown; status: TaskStatus }) => ConflictDecision;
  }
): Promise<ResolveConflictResult> {
  const { accountId, number } = args;
  return db.$transaction(async (tx): Promise<ResolveConflictResult> => {
    const found = await tx.task.findFirst({
      where: { accountId, number, deletedAt: null },
      select: { id: true },
    });
    if (!found) return { kind: "not_found" };

    // The lock `src/tasks/merge.ts` requires of every read-merge-write on a task
    // row: this adjudicates the blob the inbound drain folds into, so it must
    // not run against a row a merge is halfway through. Taken only after the id
    // resolved under `accountId` — a lock keyed on an id a caller named is one a
    // stranger can take.
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${found.id}`}))`;

    // Read under the lock, never before it.
    const row = await tx.task.findUnique({
      where: { id: found.id },
      select: {
        id: true,
        title: true,
        body: true,
        status: true,
        syncState: true,
        localConflict: true,
      },
    });
    if (!row) return { kind: "not_found" };

    const decision = args.decide({
      localConflict: row.localConflict,
      status: parseTaskStatus(row.status) ?? TaskStatusSchema.enum.open,
    });
    if (decision.kind !== "write") return decision;

    // A stored `assigneeUserId` is not evidence the user is still a member, so
    // restoring one goes through the same refusal `updateTask` applies.
    if (decision.patch?.field === "assignee") {
      const refusal = await refuseForeignAssignee(tx, accountId, decision.patch.value);
      if (refusal) return refusal;
    }

    const updated = await tx.task.update({
      where: { id: row.id },
      data: {
        ...conflictColumns(decision.patch, row.status),
        localConflict:
          decision.nextConflict === null
            ? Prisma.DbNull
            : (decision.nextConflict as Prisma.InputJsonValue),
        // Only a row actually held in `conflict` moves. `unlinked` is a
        // tombstone and `pending` a task that never synced; promoting either to
        // `synced` would claim an agreement with the provider that this
        // resolution did not reach.
        ...(row.syncState === TaskSyncStateSchema.enum.conflict && !decision.conflictsRemain
          ? { syncState: TaskSyncStateSchema.enum.synced }
          : {}),
      },
      select: TASK_SELECT,
    });

    await enqueueForTask(tx, {
      accountId,
      taskId: row.id,
      payloads: resolutionPayloads(decision.patch, {
        previousTitle: row.title,
        previousBody: row.body,
        previousStatus: parseTaskStatus(row.status) ?? TaskStatusSchema.enum.open,
      }),
    });
    return { kind: "ok", task: toRecord(updated) };
  });
}

/** The restored value, as a push — diffed for the same reason `enqueueEditOps`
 *  diffs, and with `status` in provider space for the same reason again: the
 *  losing local status is stored as `state`/`state_reason`, so two Antgrid
 *  statuses can restore to one GitHub value and neither is a write. */
function resolutionPayloads(
  patch: ConflictLocalPatch | null,
  previous: { previousTitle: string; previousBody: string; previousStatus: TaskStatus }
): TaskSyncOpPayload[] {
  if (patch === null) return [];
  switch (patch.field) {
    case "title":
      return patch.value === previous.previousTitle
        ? []
        : [{ kind: TaskSyncOpKindSchema.enum["issue.patch.title"], title: patch.value }];
    case "body":
      return patch.value === previous.previousBody
        ? []
        : [{ kind: TaskSyncOpKindSchema.enum["issue.patch.body"], body: patch.value }];
    case "status":
      return sameRemoteState(toRemote(patch.value), toRemote(previous.previousStatus))
        ? []
        : [statePayload(patch.value)];
    case "assignee":
      return [];
  }
}

function conflictColumns(patch: ConflictLocalPatch | null, previousStatus: string) {
  if (patch === null) return {};
  switch (patch.field) {
    case "title":
      return { title: patch.value };
    case "body":
      return { body: patch.value };
    case "status":
      return { status: patch.value, ...closedAtPatch(patch.value, previousStatus) };
    case "assignee":
      return assigneeColumns(patch.value);
  }
}

export type ClearPushBlockRefusal =
  | { kind: "not_found" }
  | { kind: "not_blocked"; field: PushField };

export type ClearPushBlockResult = { kind: "ok"; task: TaskRecord } | ClearPushBlockRefusal;

/**
 * Lift the block on one field, addressed the way the API addresses a task.
 *
 * **Lifting it alone would change nothing anyone can see.** The op that carried
 * the field was cancelled where the block was read (`tasks/apply-op.ts`), and
 * the outbox is driven by edits rather than by a reconcile sweep — so a task
 * whose block is merely dropped keeps a value the provider never took until
 * somebody retypes it, which is the permanent divergence the exit exists to
 * end. The push is queued here from the row as it stands, and deliberately NOT
 * diffed the way an edit is: what is being re-sent is exactly a value the row
 * already holds and the provider does not.
 *
 * A field still under `PUSH_BLOCK_THRESHOLD` is refused rather than quietly
 * reset. That counter is the whole mechanism, and a verb that zeroes one
 * mid-count is a way of never reaching it.
 */
export async function clearTaskPushBlockByNumber(
  db: DB,
  args: { accountId: string; number: number; field: PushField }
): Promise<ClearPushBlockResult> {
  const { accountId, number, field } = args;
  return db.$transaction(async (tx): Promise<ClearPushBlockResult> => {
    const found = await tx.task.findFirst({
      where: { accountId, number, deletedAt: null },
      select: { id: true },
    });
    if (!found) return { kind: "not_found" };

    // `clearTaskPushBlock` takes this same key itself; taking it here first is
    // what puts the is-it-blocked read under the lock instead of racing the
    // drain that writes the counter, and re-taking an advisory lock inside one
    // transaction costs nothing. Only after the id resolved under `accountId` —
    // a lock keyed on an id a caller named is one a stranger can take — and
    // last in the fixed `ghhook:` -> `taskimport:` -> `tasksync:` order.
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${found.id}`}))`;

    // Read under the lock, never before it.
    const current = await tx.task.findUnique({
      where: { id: found.id },
      select: { pushBlocked: true },
    });
    if (!current) return { kind: "not_found" };
    if (!isPushBlocked(parsePushBlocked(current.pushBlocked), field)) {
      return { kind: "not_blocked", field };
    }
    await clearTaskPushBlock(tx, { taskId: found.id, field });

    const row = await tx.task.findUniqueOrThrow({
      where: { id: found.id },
      select: TASK_SELECT,
    });
    await enqueueForTask(tx, {
      accountId,
      taskId: found.id,
      payloads: [retryPayload(field, row)],
    });
    return { kind: "ok", task: toRecord(row) };
  });
}

/** The row's current value for one field, as a push. `status` goes through
 *  `statePayload` rather than being spelled a second time here, for the reason
 *  that function exists: two mappings onto provider status is a push loop
 *  waiting for them to disagree. */
function retryPayload(field: PushField, row: TaskRow): TaskSyncOpPayload {
  switch (field) {
    case "title":
      return { kind: TaskSyncOpKindSchema.enum["issue.patch.title"], title: row.title };
    case "body":
      return { kind: TaskSyncOpKindSchema.enum["issue.patch.body"], body: row.body };
    case "status":
      return statePayload(parseTaskStatus(row.status) ?? TaskStatusSchema.enum.open);
    case "labels":
      return issueLabelsPayload(row.labels.map((entry) => entry.label.name));
  }
}

/**
 * The four assignee columns, always written together.
 *
 * This is where the "exactly one identity" invariant lives. Returning the whole
 * quartet from one function means no caller can set `assigneeUserId` and leave
 * a stale provider login beside it — a patch that touches only the column it
 * cares about is not expressible.
 */
export function assigneeColumns(assignee: Assignee | null): {
  assigneeUserId: string | null;
  assigneeExternalId: string | null;
  assigneeLogin: string | null;
  assigneeAvatarUrl: string | null;
} {
  if (assignee === null) {
    return {
      assigneeUserId: null,
      assigneeExternalId: null,
      assigneeLogin: null,
      assigneeAvatarUrl: null,
    };
  }
  if (assignee.kind === "member") {
    return {
      assigneeUserId: assignee.userId,
      assigneeExternalId: null,
      assigneeLogin: null,
      assigneeAvatarUrl: null,
    };
  }
  return {
    assigneeUserId: null,
    assigneeExternalId: assignee.externalId,
    assigneeLogin: assignee.login,
    assigneeAvatarUrl: assignee.avatarUrl ?? null,
  };
}

/**
 * An internal assignee must hold an active membership on this account. A user
 * id is global and the foreign key to `user` proves nothing about which account
 * they are on, so without this a task can be assigned to a non-member — and
 * "assigned to me" would then surface it to them.
 */
async function refuseForeignAssignee(
  tx: Tx,
  accountId: string,
  assignee: Assignee | null
): Promise<{ kind: "assignee_not_member"; userId: string } | null> {
  if (assignee === null || assignee.kind !== "member") return null;
  const member = await tx.accountMember.findFirst({
    where: { accountId, userId: assignee.userId, status: ACCOUNT_MEMBER_STATUS_ACTIVE },
    select: { id: true },
  });
  return member ? null : { kind: "assignee_not_member", userId: assignee.userId };
}

async function projectBelongsToAccount(
  tx: Tx,
  accountId: string,
  projectId: string
): Promise<boolean> {
  if (!isUuid(projectId)) return false;
  const row = await tx.project.findFirst({
    where: { id: projectId, accountId },
    select: { id: true },
  });
  return row !== null;
}

async function neighbourKey(
  tx: Tx,
  accountId: string,
  number: number | null
): Promise<string | null> {
  if (number === null) return null;
  const row = await tx.task.findFirst({
    where: { accountId, number, deletedAt: null },
    select: { sortKey: true },
  });
  return row?.sortKey ?? null;
}

/** An already-closed task changing between `done` and `cancelled` keeps the
 *  moment it closed; only reopening and closing move the timestamp. */
export function closedAtPatch(next: TaskStatus, previous: string): { closedAt?: Date | null } {
  if (!CLOSED_STATUSES.has(next)) return { closedAt: null };
  const wasClosed = CLOSED_STATUSES.has(previous as TaskStatus);
  return wasClosed ? {} : { closedAt: new Date() };
}

function toRecord(row: TaskRow): TaskRecord {
  return {
    id: row.id,
    accountId: row.accountId,
    projectId: row.projectId,
    number: row.number,
    title: row.title,
    body: row.body,
    // A status outside the vocabulary can only come from a hand-written UPDATE.
    // Reading it as `open` keeps the task visible and editable, where dropping
    // the row would hide it from every view that could fix it.
    status: parseTaskStatus(row.status) ?? TaskStatusSchema.enum.open,
    priority: row.priority,
    sortKey: row.sortKey,
    source: row.source,
    assignee: readAssignee(row),
    externalProvider: row.externalProvider,
    externalId: row.externalId,
    externalKey: row.externalKey,
    externalUrl: row.externalUrl,
    syncState: row.syncState,
    remoteSnapshot: row.remoteSnapshot,
    localConflict: row.localConflict,
    pushBlocked: row.pushBlocked,
    createdBy: row.createdBy,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    closedAt: row.closedAt,
    labels: row.labels.map((entry) => entry.label),
  };
}

/** The inverse of `assigneeColumns`, and exported for the same reason: a reader
 *  that picks the columns apart itself is one that can decide the quartet means
 *  something other than "exactly one identity". */
export function readAssignee(row: {
  assigneeUserId: string | null;
  assigneeExternalId: string | null;
  assigneeLogin: string | null;
  assigneeAvatarUrl: string | null;
}): Assignee | null {
  if (row.assigneeUserId !== null) return { kind: "member", userId: row.assigneeUserId };
  if (row.assigneeExternalId !== null) {
    return {
      kind: "external",
      externalId: row.assigneeExternalId,
      login: row.assigneeLogin ?? row.assigneeExternalId,
      avatarUrl: row.assigneeAvatarUrl,
    };
  }
  return null;
}
