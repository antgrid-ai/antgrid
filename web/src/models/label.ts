import { z } from "zod";
import type { DB, Tx } from "../db/index.js";
import { isUuid } from "../util/uuid.js";
import { enqueueForTask, issueLabelsPayload, sameLabelSet } from "../tasks/sync-op.js";

/**
 * Labels: the vocabulary a task list is triaged by, account-scoped like
 * everything else here.
 *
 * Deliberately below `models/task.ts` in the dependency order — task creation
 * resolves label ids through `resolveLabelIds` — so nothing in this file may
 * import from there. `tasks/sync-op.ts` sits below both, which is why the
 * outbox gate both models need lives down there rather than in either one.
 *
 * The tenancy rule is the same one that governs every id in this feature:
 * Prisma foreign keys enforce EXISTENCE, not tenancy. A `labelId` from another
 * account is a perfectly valid FK, and writing one leaks that account's label
 * names into this one's UI and (once an integration exists) into its issues. So
 * every id that arrives from a caller is re-resolved under the caller's
 * `accountId` before it reaches a write.
 */

/** GitHub's own shape: six hex digits, no leading `#`. Stored verbatim so the
 *  round-trip back to the provider is byte-exact. */
export const LabelColorSchema = z.string().regex(/^[0-9a-fA-F]{6}$/);

/** GitHub caps label names at 50 characters, and matching it keeps a name that
 *  round-trips from becoming a push that fails forever. */
export const LabelNameSchema = z.string().trim().min(1).max(50);

export type LabelRecord = {
  id: string;
  accountId: string;
  projectId: string | null;
  name: string;
  color: string;
  description: string | null;
  createdAt: Date;
};

const LABEL_SELECT = {
  id: true,
  accountId: true,
  projectId: true,
  name: true,
  color: true,
  description: true,
  createdAt: true,
} as const;

export type GetOrCreateLabelArgs = {
  /** Resolved from the caller, never from the request body. */
  accountId: string;
  /** null for an account-wide label (`needs-triage`); a project for a
   *  repo-specific one (`area/relay`). */
  projectId?: string | null;
  name: string;
  color: string;
  description?: string | null;
};

export type GetOrCreateLabelResult =
  | { kind: "ok"; label: LabelRecord; created: boolean }
  | { kind: "project_not_found" }
  | { kind: "invalid_name" }
  | { kind: "invalid_color" };

/**
 * Resolve a label by name, creating it if this account does not have one.
 *
 * Case-insensitive by construction: `labels.name` is CITEXT, so the lookup and
 * both unique indexes fold case in the database rather than in a normalization
 * step callers could forget. `Bug` and `bug` are one label.
 *
 * The read-then-create is racy — two importers naming one label — so the unique
 * violation is caught and re-read rather than prevented. An upsert cannot do
 * the job: Prisma's compound-unique `where` will not accept a null
 * `projectId`, which is exactly the account-wide case.
 *
 * That recovery only works OUTSIDE a transaction. Postgres aborts the whole
 * transaction on the unique violation regardless of the catch here, so a caller
 * inside `$transaction` gets the re-read as its next failing statement — the
 * same caveat `upsertIntegrationRepo` carries, and the inbound drain treats it
 * the same way: a failed delivery that converges on the retry.
 */
export async function getOrCreateLabel(
  db: Tx,
  args: GetOrCreateLabelArgs
): Promise<GetOrCreateLabelResult> {
  const name = LabelNameSchema.safeParse(args.name);
  if (!name.success) return { kind: "invalid_name" };
  const color = LabelColorSchema.safeParse(args.color);
  if (!color.success) return { kind: "invalid_color" };

  const projectId = args.projectId ?? null;
  if (projectId !== null && !(await projectBelongsToAccount(db, args.accountId, projectId))) {
    return { kind: "project_not_found" };
  }

  const existing = await db.label.findFirst({
    where: { accountId: args.accountId, projectId, name: name.data },
    select: LABEL_SELECT,
  });
  if (existing) return { kind: "ok", label: existing, created: false };

  try {
    const created = await db.label.create({
      data: {
        accountId: args.accountId,
        projectId,
        name: name.data,
        color: color.data,
        description: args.description ?? null,
      },
      select: LABEL_SELECT,
    });
    return { kind: "ok", label: created, created: true };
  } catch (err) {
    if (!isUniqueViolation(err)) throw err;
    const raced = await db.label.findFirst({
      where: { accountId: args.accountId, projectId, name: name.data },
      select: LABEL_SELECT,
    });
    if (!raced) throw err;
    return { kind: "ok", label: raced, created: false };
  }
}

/**
 * Every label a task in `projectId` may carry: the account-wide vocabulary plus
 * that project's own. Passing no project lists the account-wide set alone,
 * which is the whole vocabulary a task with no project can use.
 */
export async function listLabels(
  db: Tx,
  args: { accountId: string; projectId?: string | null }
): Promise<LabelRecord[]> {
  const projectId = args.projectId ?? null;
  const scoped = projectId !== null && isUuid(projectId) ? [{ projectId }] : [];
  return db.label.findMany({
    where: { accountId: args.accountId, OR: [{ projectId: null }, ...scoped] },
    orderBy: { name: "asc" },
    select: LABEL_SELECT,
  });
}

/** Deleting a label detaches it from every task by cascade — a label nobody can
 *  see must not stay on rows the merge will later push. */
export async function deleteLabel(
  db: Tx,
  args: { accountId: string; labelId: string }
): Promise<boolean> {
  if (!isUuid(args.labelId)) return false;
  const result = await db.label.deleteMany({
    where: { id: args.labelId, accountId: args.accountId },
  });
  return result.count > 0;
}

export type LabelResolution =
  | { kind: "ok"; labelIds: string[] }
  | { kind: "label_not_found"; labelId: string }
  | { kind: "label_out_of_scope"; labelId: string };

/**
 * Re-resolve caller-supplied label ids under the caller's account, and refuse a
 * repo-scoped label whose project is not the task's.
 *
 * The second half is not tidiness: `area/relay` on a task in another repository
 * is meaningless locally and, once the task is linked, would push a label name
 * into a repository that never had it.
 */
export async function resolveLabelIds(
  tx: Tx,
  args: { accountId: string; projectId: string | null; labelIds: readonly string[] }
): Promise<LabelResolution> {
  const wanted = [...new Set(args.labelIds)];
  if (wanted.length === 0) return { kind: "ok", labelIds: [] };
  const malformed = wanted.find((id) => !isUuid(id));
  if (malformed !== undefined) return { kind: "label_not_found", labelId: malformed };

  const rows = await tx.label.findMany({
    where: { id: { in: wanted }, accountId: args.accountId },
    select: { id: true, projectId: true },
  });
  const found = new Map(rows.map((row) => [row.id, row.projectId]));
  for (const labelId of wanted) {
    if (!found.has(labelId)) return { kind: "label_not_found", labelId };
    const scope = found.get(labelId)!;
    if (scope !== null && scope !== args.projectId) {
      return { kind: "label_out_of_scope", labelId };
    }
  }
  return { kind: "ok", labelIds: wanted };
}

export type TaskLabelResult =
  | { kind: "ok" }
  | { kind: "task_not_found" }
  | { kind: "label_not_found"; labelId: string }
  | { kind: "label_out_of_scope"; labelId: string };

/**
 * Put a label on a task, both named by the caller and both re-resolved under
 * the caller's account first. Re-attaching an attached label is a no-op rather
 * than an error — the UI toggles, and a double-tap is not a failure.
 */
export async function attachLabel(
  db: DB,
  args: { accountId: string; taskId: string; labelId: string }
): Promise<TaskLabelResult> {
  return db.$transaction(async (tx) => {
    const task = await liveTask(tx, args.accountId, args.taskId);
    if (!task) return { kind: "task_not_found" };
    await lockTaskSync(tx, task.id);
    const before = await labelNames(tx, task.id);

    const resolved = await resolveLabelIds(tx, {
      accountId: args.accountId,
      projectId: task.projectId,
      labelIds: [args.labelId],
    });
    if (resolved.kind !== "ok") return resolved;

    await tx.taskLabel.createMany({
      data: [{ taskId: task.id, labelId: args.labelId }],
      skipDuplicates: true,
    });
    await enqueueLabelPush(tx, args.accountId, task.id, before);
    return { kind: "ok" };
  });
}

/** Removing a label the task does not carry is a no-op, for the same reason
 *  attaching twice is. */
export async function detachLabel(
  db: DB,
  args: { accountId: string; taskId: string; labelId: string }
): Promise<TaskLabelResult> {
  if (!isUuid(args.labelId)) return { kind: "label_not_found", labelId: args.labelId };
  return db.$transaction(async (tx) => {
    const task = await liveTask(tx, args.accountId, args.taskId);
    if (!task) return { kind: "task_not_found" };
    await lockTaskSync(tx, task.id);
    const before = await labelNames(tx, task.id);
    await tx.taskLabel.deleteMany({ where: { taskId: task.id, labelId: args.labelId } });
    await enqueueLabelPush(tx, args.accountId, task.id, before);
    return { kind: "ok" };
  });
}

/**
 * Replace a task's label set outright — what a multi-select popover submits.
 * One transaction, because a task briefly wearing neither the old set nor the
 * new one is a state the list can render.
 */
export async function setTaskLabels(
  db: DB,
  args: { accountId: string; taskId: string; labelIds: readonly string[] }
): Promise<TaskLabelResult> {
  return db.$transaction(async (tx) => {
    const task = await liveTask(tx, args.accountId, args.taskId);
    if (!task) return { kind: "task_not_found" };
    await lockTaskSync(tx, task.id);
    const before = await labelNames(tx, task.id);
    const result = await setTaskLabelsInTx(tx, args);
    if (result.kind !== "ok") return result;
    await enqueueLabelPush(tx, args.accountId, task.id, before);
    return result;
  });
}

/**
 * The same replacement for a caller already inside a transaction — the inbound
 * importer, whose whole delivery has to land or roll back as one.
 *
 * **Deliberately silent on the outbox**, unlike the wrapper above. The importer
 * is the one caller that reaches this, and the set it writes is the one it just
 * merged the provider's own labels into; enqueueing there would push the
 * provider's state back at it, which is the loop the one-way import exists to
 * avoid. The lock this needs is already held by the delivery that called it.
 */
export async function setTaskLabelsInTx(
  tx: Tx,
  args: { accountId: string; taskId: string; labelIds: readonly string[] }
): Promise<TaskLabelResult> {
  const task = await liveTask(tx, args.accountId, args.taskId);
  if (!task) return { kind: "task_not_found" };

  const resolved = await resolveLabelIds(tx, {
    accountId: args.accountId,
    projectId: task.projectId,
    labelIds: args.labelIds,
  });
  if (resolved.kind !== "ok") return resolved;

  await tx.taskLabel.deleteMany({
    where: { taskId: task.id, labelId: { notIn: resolved.labelIds } },
  });
  await tx.taskLabel.createMany({
    data: resolved.labelIds.map((labelId) => ({ taskId: task.id, labelId })),
    skipDuplicates: true,
  });
  return { kind: "ok" };
}

/**
 * The lock `enqueueForTask` requires of its caller, and the one every
 * read-merge-write on a task row takes (`src/tasks/merge.ts`).
 *
 * Taken only after the id has resolved under the caller's `accountId`: a lock
 * keyed on an id a caller named is one a stranger can take. Last in the fixed
 * `ghhook:` -> `taskimport:` -> `tasksync:` order, so taking it alone deadlocks
 * against nothing.
 */
async function lockTaskSync(tx: Tx, taskId: string): Promise<void> {
  await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${taskId}`}))`;
}

async function labelNames(tx: Tx, taskId: string): Promise<string[]> {
  const rows = await tx.taskLabel.findMany({
    where: { taskId },
    select: { label: { select: { name: true } } },
  });
  return rows.map((row) => row.label.name);
}

/**
 * Queue the label replace this write implies, if it moved the set at all.
 *
 * Diffed rather than queued unconditionally because every verb here is a no-op
 * on a double-tap by design — re-attaching an attached label, detaching one the
 * task never had — and a content-creating provider write per double-tap is not
 * something the user can see coming.
 */
async function enqueueLabelPush(
  tx: Tx,
  accountId: string,
  taskId: string,
  before: readonly string[]
): Promise<void> {
  const after = await labelNames(tx, taskId);
  if (sameLabelSet(after, before)) return;
  await enqueueForTask(tx, { accountId, taskId, payloads: [issueLabelsPayload(after)] });
}

async function liveTask(
  tx: Tx,
  accountId: string,
  taskId: string
): Promise<{ id: string; projectId: string | null } | null> {
  if (!isUuid(taskId)) return null;
  return tx.task.findFirst({
    where: { id: taskId, accountId, deletedAt: null },
    select: { id: true, projectId: true },
  });
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

function isUniqueViolation(err: unknown): boolean {
  return typeof err === "object" && err !== null && "code" in err && err.code === "P2002";
}
