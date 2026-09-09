import { randomBytes } from "node:crypto";
import { z } from "zod";
import type { DB, Tx } from "../db/index.js";
import type { RemoteState } from "./merge.js";
import { TaskSyncStateSchema } from "./sync-state.js";

/**
 * The outbox: enqueue, claim, and the three ways an attempt ends.
 *
 * Nothing here talks to a provider. The drain that does lives elsewhere and is
 * built on these verbs, so the ordering and idempotency rules are enforced in
 * one place rather than restated per adapter.
 *
 * **Everything that changes WHICH op is next runs under
 * `pg_advisory_xact_lock(hashtext('tasksync:' || taskId))`** — the same key
 * `src/tasks/merge.ts` requires of every read-merge-write. `enqueueSyncOp` and
 * `cancelPendingOps` require the caller to be holding it already, because they
 * run in the transaction that is also writing the task row; `claimNextOps`
 * takes it itself, with `pg_try_advisory_xact_lock`. That one key is what makes
 * seq allocation, supersede and the claim atomic against each other without a
 * row lock and without a leader. The outcome verbs are single-row writes by id
 * and need nothing beyond it, though the drain calls them inside the same
 * critical section it re-reads the task in.
 *
 * `hashtext` is one global int4 namespace and locks are taken in the fixed
 * order `ghhook:` → `taskimport:` → `tasksync:`, so the outbox deliberately
 * introduces no fourth prefix: a new one would have to be placed in that order,
 * and placing it wrong is a deadlock for no gain.
 */

/**
 * The closed set of writes the outbox can carry.
 *
 * Note the two that are absent. There is no `issue.assignees`: v1 never pushes
 * an assignee, because GitHub silently drops one lacking push access and
 * returns 200, which is a push loop no response comparison can see. There is no
 * `comment.create`: comments are inbound-only, so a comment written in Antgrid
 * stays in Antgrid. Adding either is a schema change *and* a change to what we
 * told users we would send, which is the point of enumerating them.
 */
export const TaskSyncOpKindSchema = z.enum([
  "issue.create",
  "issue.patch.title",
  "issue.patch.body",
  "issue.state",
  "issue.labels",
]);
export type TaskSyncOpKind = z.infer<typeof TaskSyncOpKindSchema>;

export const TaskSyncOpStatusSchema = z.enum([
  "pending",
  "processed",
  "given_up",
  "cancelled",
]);
export type TaskSyncOpStatus = z.infer<typeof TaskSyncOpStatusSchema>;

/** Provider space, never Antgrid vocabulary: `toRemote` is many-to-one, so an
 *  op carrying `in_progress` would be a value the provider cannot represent. */
const RemoteStateReasonSchema = z.enum(["completed", "not_planned", "reopened"]).nullable();

const IssueCreatePayloadSchema = z.object({
  kind: z.literal(TaskSyncOpKindSchema.enum["issue.create"]),
  title: z.string(),
  body: z.string(),
  state: z.enum(["open", "closed"]),
  stateReason: RemoteStateReasonSchema.default(null),
  labels: z.array(z.string()),
});

const IssueTitlePayloadSchema = z.object({
  kind: z.literal(TaskSyncOpKindSchema.enum["issue.patch.title"]),
  title: z.string(),
});

const IssueBodyPayloadSchema = z.object({
  kind: z.literal(TaskSyncOpKindSchema.enum["issue.patch.body"]),
  body: z.string(),
});

const IssueStatePayloadSchema = z.object({
  kind: z.literal(TaskSyncOpKindSchema.enum["issue.state"]),
  state: z.enum(["open", "closed"]),
  stateReason: RemoteStateReasonSchema.default(null),
});

const IssueLabelsPayloadSchema = z.object({
  kind: z.literal(TaskSyncOpKindSchema.enum["issue.labels"]),
  labels: z.array(z.string()),
});

/** Discriminated so a later `applyOp` dispatches over a closed set instead of
 *  comparing strings, and so an unparseable stored payload is a state the drain
 *  can name rather than a runtime cast. */
export const TaskSyncOpPayloadSchema = z.discriminatedUnion("kind", [
  IssueCreatePayloadSchema,
  IssueTitlePayloadSchema,
  IssueBodyPayloadSchema,
  IssueStatePayloadSchema,
  IssueLabelsPayloadSchema,
]);
export type TaskSyncOpPayload = z.infer<typeof TaskSyncOpPayloadSchema>;

type Assert<T extends true> = T;

/** Lockstep with `RemoteState` in merge.ts, checked at compile time: an op
 *  carrying a state the snapshot cannot hold is a push whose response has
 *  nowhere to be stored as the new base. */
type _StatePayloadIsProviderSpace = Assert<
  [z.infer<typeof IssueStatePayloadSchema>] extends [RemoteState] ? true : false
>;

/**
 * Kinds whose payload replaces a whole collection on the provider.
 *
 * `PATCH /issues/{n}` with `labels` replaces the array, so a delayed replay of
 * a stale set is a silent rollback rather than a harmless repeat — one of these
 * must never be sent from the payload as stored, only from a set recomputed
 * against current rows at send time. Membership is data rather than a string
 * match on the kind name, because the rule is enforced somewhere far from here
 * and a `startsWith` test would quietly stop covering a future kind.
 */
export const ARRAY_VALUED_OP_KINDS: ReadonlySet<TaskSyncOpKind> = new Set([
  TaskSyncOpKindSchema.enum["issue.labels"],
]);

export function isArrayValuedOpKind(kind: TaskSyncOpKind): boolean {
  return ARRAY_VALUED_OP_KINDS.has(kind);
}

/**
 * How many failures an op gets before it is abandoned. Mirrors
 * `MAX_WEBHOOK_ATTEMPTS`: the same ceiling for the same reason, so the two
 * halves of the seam do not need to be reasoned about separately.
 */
export const MAX_SYNC_OP_ATTEMPTS = 5;

/** First backoff step. Sized against the write budget (500 content-creating
 *  requests/hour), not against how fast a human would like it retried. */
export const SYNC_OP_BACKOFF_BASE_SECONDS = 30;

/** Backoff ceiling. Past this a longer wait only delays the ceiling that is
 *  already going to abandon the op. */
export const SYNC_OP_BACKOFF_MAX_SECONDS = 30 * 60;

/**
 * How long a claim reserves a task before another worker may take it again.
 *
 * The advisory lock cannot cover the provider call — the plan forbids holding a
 * transaction open across a round trip — so it is released the moment the claim
 * commits. This lease is what stands in for it afterwards: the claimed op's
 * `next_attempt_at` is pushed forward, and since the claim only ever looks at a
 * task's LOWEST pending `seq`, a task with a leased op yields nothing at all
 * until the lease expires. A worker that dies mid-call loses its op for one
 * lease rather than for ever.
 */
export const SYNC_OP_LEASE_SECONDS = 5 * 60;

/** Errors carry provider text; the column is unbounded and the log line is not. */
const MAX_ERROR_CHARS = 1000;

export type TaskSyncOpRecord = {
  id: string;
  taskId: string;
  integrationId: string;
  provider: string;
  kind: TaskSyncOpKind;
  payload: TaskSyncOpPayload;
  opKey: string;
  seq: number;
  attempts: number;
  status: TaskSyncOpStatus;
  nextAttemptAt: Date;
  attemptedAt: Date | null;
};

export type EnqueueSyncOpArgs = {
  taskId: string;
  integrationId: string;
  provider: string;
  /** Carries its own `kind`; supersede and dispatch both read it from here, so
   *  there is no second copy to disagree with the column. */
  payload: TaskSyncOpPayload;
};

export type EnqueueSyncOpResult =
  | {
      kind: "ok";
      op: TaskSyncOpRecord;
      /** The op this one replaced, when it replaced one rather than queueing. */
      superseded: string | null;
    }
  | { kind: "task_not_found" }
  /** An `issue.create` for a task that already carries an `externalId`. */
  | { kind: "already_created" };

/**
 * Queue one provider write for a task.
 *
 * **Precondition: the caller already holds
 * `pg_advisory_xact_lock(hashtext('tasksync:' || taskId))`**, in the same
 * transaction as the `Task` write this op describes. Without it two concurrent
 * edits allocate the same `seq` and neither supersedes the other, so the
 * provider sees this task's writes in an order nothing chose.
 *
 * Two rules live here rather than in the drain:
 *
 * - **Supersede, don't queue.** A pending, not-yet-attempted op of the same
 *   `kind` is rewritten in place, keeping its `seq` and taking a fresh `opKey`.
 *   Matching on `kind` is why the per-field kinds are separate values instead of
 *   one `issue.patch` with a discriminator in the JSON: a partial unique over a
 *   JSON path is not a foundation for a correctness rule. An op that has
 *   already been handed to the provider (`attemptedAt` set) is never rewritten —
 *   its outcome is unknown, and the new value is queued behind it instead so
 *   the later `seq` still wins.
 * - **Never a second create.** A task holding an `externalId` has an issue; the
 *   duplicate a second create would post is public and permanent. This guard is
 *   local and cheap and stands independently of the `opKey` marker the drain
 *   resolves an unknown outcome with.
 */
export async function enqueueSyncOp(
  tx: Tx,
  args: EnqueueSyncOpArgs
): Promise<EnqueueSyncOpResult> {
  const { taskId, integrationId, provider, payload } = args;
  const kind = payload.kind;

  const task = await tx.task.findUnique({
    where: { id: taskId },
    select: { externalId: true },
  });
  if (!task) return { kind: "task_not_found" };
  if (kind === TaskSyncOpKindSchema.enum["issue.create"] && task.externalId !== null) {
    return { kind: "already_created" };
  }

  const opKey = randomBytes(16).toString("hex");
  const now = new Date();

  const superseded = await tx.taskSyncOp.findFirst({
    where: {
      taskId,
      kind,
      status: TaskSyncOpStatusSchema.enum.pending,
      attemptedAt: null,
    },
    orderBy: { seq: "asc" },
    select: { id: true },
  });

  if (superseded) {
    // A fresh `opKey` is not decoration: the drain decides on an op in one
    // critical section and writes its result in another, and comparing the key
    // it decided on against the row's current key is how it notices the payload
    // moved underneath it.
    const row = await tx.taskSyncOp.update({
      where: { id: superseded.id },
      data: {
        integrationId,
        provider,
        payload,
        opKey,
        attempts: 0,
        lastError: null,
        nextAttemptAt: now,
      },
      select: OP_SELECT,
    });
    return { kind: "ok", op: toRecord(row), superseded: superseded.id };
  }

  const [{ seq }] = await tx.$queryRaw<{ seq: number }[]>`
    SELECT COALESCE(MAX(seq), 0) + 1 AS seq FROM task_sync_ops WHERE task_id = ${taskId}::uuid`;

  const row = await tx.taskSyncOp.create({
    data: {
      taskId,
      integrationId,
      provider,
      kind,
      payload,
      opKey,
      seq,
      status: TaskSyncOpStatusSchema.enum.pending,
      nextAttemptAt: now,
    },
    select: OP_SELECT,
  });
  return { kind: "ok", op: toRecord(row), superseded: null };
}


export type PushTarget = {
  /** Whose credentials the op goes out under, pinned at enqueue. */
  integrationId: string;
  provider: string;
};

/**
 * Where a task's provider writes go, or null when they go nowhere.
 *
 * Four separate refusals, and none of them is redundant:
 *
 * - **Not linked.** The external columns are what a write is addressed to, and
 *   `unlinked` is a tombstone — a task the user stopped tracking must not keep
 *   writing to the issue it used to be.
 * - **`pushEnabled` off.** Outbound is opt-in per repository and deliberately
 *   not implied by `syncEnabled`: users treat an imported issue as a private
 *   notes layer over the provider, and an edit reaching GitHub without that
 *   consent is not a bug they can undo.
 * - **The repository is somebody else's.** `tasks.integration_repo_id` has a
 *   foreign key, and a foreign key proves the row exists and nothing about who
 *   owns it — the same rule every id in `models/task.ts` goes through.
 * - **The installation is revoked.** The mirror of the inbound side, where every
 *   resolution of an installation filters `revokedAt IS NULL`: there are no
 *   credentials left to send under, so an op enqueued here could only burn its
 *   attempt ceiling and land in `given_up`. The row is retained rather than
 *   deleted precisely so a task can still name where it came from, which is why
 *   its presence is not evidence that a push is possible.
 *
 * Resolved from the task's own columns under the caller's `accountId`, never
 * from anything the request supplied: a request names a task and gets no say in
 * which installation's credentials its edit goes out under.
 */
export async function resolvePushTarget(
  tx: Tx,
  accountId: string,
  taskId: string
): Promise<PushTarget | null> {
  const row = await tx.task.findFirst({
    where: { id: taskId, accountId },
    select: {
      externalId: true,
      externalProvider: true,
      syncState: true,
      integrationRepo: {
        select: {
          pushEnabled: true,
          integrationId: true,
          integration: { select: { accountId: true, provider: true, revokedAt: true } },
        },
      },
    },
  });
  if (!row) return null;
  if (row.externalId === null || row.externalProvider === null) return null;
  if (row.syncState === null || row.syncState === TaskSyncStateSchema.enum.unlinked) return null;

  const repo = row.integrationRepo;
  if (repo === null || !repo.pushEnabled) return null;
  if (repo.integration.accountId !== accountId) return null;
  if (repo.integration.revokedAt !== null) return null;
  return { integrationId: repo.integrationId, provider: repo.integration.provider };
}

/**
 * Resolve the target and enqueue one edit's worth of ops, in the caller's
 * transaction and under the `tasksync:` lock the caller already holds.
 *
 * The gate lives here rather than in each model so that every local writer of a
 * task asks the same question in the same order — a second copy of it would
 * differ on exactly the refusal that matters, and the failure is a write
 * reaching a public repository nobody consented to.
 *
 * The target is resolved once for the whole batch rather than per payload: they
 * describe one edit, and an op landing under a different installation than its
 * neighbour is a partially-pushed edit nothing would reconcile.
 */
export async function enqueueForTask(
  tx: Tx,
  args: { accountId: string; taskId: string; payloads: readonly TaskSyncOpPayload[] }
): Promise<void> {
  if (args.payloads.length === 0) return;
  const target = await resolvePushTarget(tx, args.accountId, args.taskId);
  if (target === null) return;
  for (const payload of args.payloads) {
    await enqueueSyncOp(tx, {
      taskId: args.taskId,
      integrationId: target.integrationId,
      provider: target.provider,
      payload,
    });
  }
}

/**
 * A whole-array label replace, built in one place because two unrelated writers
 * produce it — the task patch and the label popover — and a payload carrying a
 * partial set from either is the set rollback `ARRAY_VALUED_OP_KINDS` exists to
 * describe.
 */
export function issueLabelsPayload(labels: readonly string[]): TaskSyncOpPayload {
  return { kind: TaskSyncOpKindSchema.enum["issue.labels"], labels: [...labels] };
}

/**
 * Did the label set actually move?
 *
 * Order and duplication are not part of a set's identity, and both writers of
 * `issue.labels` have to answer this the same way: one of them deciding a
 * reordered array is a change is a content-creating write per form submit.
 */
export function sameLabelSet(a: readonly string[], b: readonly string[]): boolean {
  const left = new Set(a);
  const right = new Set(b);
  if (left.size !== right.size) return false;
  for (const name of left) if (!right.has(name)) return false;
  return true;
}

export type ClaimNextOpsArgs = {
  now: Date;
  limit: number;
};

/**
 * Take up to `limit` ops, at most one per task, each the head of its task's
 * queue.
 *
 * **The claim is per task, not per `next_attempt_at`.** Claiming globally by due
 * time reorders a task's writes under backoff: `title := T2` fails once, backs
 * off past `title := T3`, and T2 applies last — so the value the user replaced
 * is the value that survives, permanently, and with exponential backoff that is
 * the normal path for any op that fails once rather than an edge case. So a
 * task offers only its lowest pending `seq`, and if that op is not due the task
 * yields nothing; a later op of the same task is never pulled forward past it.
 *
 * Concurrency rests on two things, and both are needed:
 *
 * - `pg_try_advisory_xact_lock` on `tasksync:<taskId>`, non-blocking, so a task
 *   another instance is already claiming is skipped rather than queued behind —
 *   multiple web instances are the expected deployment, and a blocking lock
 *   would serialize the whole drain behind one slow task. Every other writer of
 *   these rows holds the same key, so the head read and the update below cannot
 *   interleave with an enqueue, a supersede, or a second claimer.
 * - The lease on `next_attempt_at`, because the advisory lock dies with this
 *   transaction and the provider call happens after it commits.
 *
 * **An empty result is not proof of an empty queue.** The `limit` is applied
 * before the try-lock filter, so a pass whose candidate tasks are all held by
 * another instance claims nothing while a backlog exists. A drain must not read
 * that as "done" the way the webhook drain reads a zero-row pass — the work is
 * not lost, but it waits for the next tick.
 *
 * The CTEs are `MATERIALIZED` deliberately: `pg_try_advisory_xact_lock` is
 * volatile, and an inlined subquery would leave it to the planner how many rows
 * it is evaluated for — taking locks on tasks this call never claims.
 */
export async function claimNextOps(
  db: DB,
  args: ClaimNextOpsArgs
): Promise<TaskSyncOpRecord[]> {
  const { now, limit } = args;
  if (limit <= 0) return [];

  return db.$transaction(async (tx) => {
    const leaseUntil = new Date(now.getTime() + SYNC_OP_LEASE_SECONDS * 1000);
    const rows = await tx.$queryRaw<ClaimedRow[]>`
      WITH head AS MATERIALIZED (
        SELECT DISTINCT ON (task_id) id, task_id, next_attempt_at
        FROM task_sync_ops
        WHERE status = ${TaskSyncOpStatusSchema.enum.pending}
        ORDER BY task_id, seq ASC
      ),
      due AS MATERIALIZED (
        SELECT id, task_id FROM head
        WHERE next_attempt_at <= ${now}
        ORDER BY next_attempt_at ASC
        LIMIT ${limit}
      ),
      claimable AS MATERIALIZED (
        SELECT id FROM due
        WHERE pg_try_advisory_xact_lock(hashtext('tasksync:' || task_id::text))
      )
      UPDATE task_sync_ops op
      SET next_attempt_at = ${leaseUntil}
      FROM claimable
      WHERE op.id = claimable.id
      RETURNING
        op.id::text AS id,
        op.task_id::text AS "taskId",
        op.integration_id::text AS "integrationId",
        op.provider,
        op.kind,
        op.payload,
        op.op_key AS "opKey",
        op.seq,
        op.attempts,
        op.status,
        op.next_attempt_at AS "nextAttemptAt",
        op.attempted_at AS "attemptedAt"`;

    const claimed: TaskSyncOpRecord[] = [];
    for (const row of rows) {
      const parsed = TaskSyncOpPayloadSchema.safeParse(row.payload);
      if (!parsed.success || parsed.data.kind !== row.kind) {
        // A payload no schema accepts cannot start parsing on a later pass, so
        // it is abandoned here rather than left to burn the attempt ceiling one
        // provider call at a time. Same call as `markDeliveryProcessed`'s note
        // arm on the inbound side.
        await giveUpUnparseable(tx, row.id);
        continue;
      }
      claimed.push(toRecord(row));
    }
    return claimed;
  });
}

/**
 * Record that the op is about to be handed to the provider.
 *
 * Called in its own committed transaction immediately BEFORE the call, never
 * after: the retry that has to be recovered from is the one whose request
 * committed and whose response was lost, and a timestamp written after the
 * response is exactly the one that is missing when it matters. It is also what
 * `cancelPendingOps` reads to tell an op that may already have posted an issue
 * from one that certainly has not.
 */
export async function markOpAttempted(tx: Tx, id: string, at: Date): Promise<void> {
  await tx.taskSyncOp.update({ where: { id }, data: { attemptedAt: at } });
}

/** The op landed. `attempts` is left as it stands — it is the record of what it
 *  took, not a counter to reset. */
export async function completeOp(tx: Tx, id: string): Promise<void> {
  await tx.taskSyncOp.update({
    where: { id },
    data: { status: TaskSyncOpStatusSchema.enum.processed, lastError: null },
  });
}

export type FailOpResult = {
  attempts: number;
  /** The ceiling was reached on this failure: the op is `given_up` and no drain
   *  will touch it again. */
  gaveUp: boolean;
};

/**
 * Count a failed attempt and push the op out by an exponential backoff.
 *
 * Past `MAX_SYNC_OP_ATTEMPTS` the op is given up — a terminal status rather
 * than a delete, because a write we abandoned is something a person has to be
 * able to find and the error that stopped it is the only explanation they get.
 */
export async function failOp(tx: Tx, id: string, error: string): Promise<FailOpResult> {
  const rows = await tx.$queryRaw<{ attempts: number; status: string }[]>`
    UPDATE task_sync_ops SET
      attempts = attempts + 1,
      last_error = ${truncate(error)},
      next_attempt_at = now() + make_interval(secs =>
        LEAST(
          ${SYNC_OP_BACKOFF_MAX_SECONDS}::double precision,
          ${SYNC_OP_BACKOFF_BASE_SECONDS}::double precision * power(2, attempts)
        )),
      status = CASE
        WHEN attempts + 1 >= ${MAX_SYNC_OP_ATTEMPTS}
        THEN ${TaskSyncOpStatusSchema.enum.given_up}
        ELSE ${TaskSyncOpStatusSchema.enum.pending}
      END
    WHERE id = ${id}::uuid
    RETURNING attempts, status`;

  const row = rows[0];
  if (!row) throw new Error(`failOp: no op ${id}`);
  return { attempts: row.attempts, gaveUp: row.status === TaskSyncOpStatusSchema.enum.given_up };
}

/**
 * Defer the op because we are out of provider budget, not because it failed.
 *
 * **Throttling must never touch `attempts`.** A queue that is merely waiting
 * would otherwise drive itself into exponential backoff and then into the
 * abandonment ceiling, having never made a single request the provider
 * refused.
 */
export async function throttleOp(tx: Tx, id: string, retryAt: Date): Promise<void> {
  await tx.taskSyncOp.update({ where: { id }, data: { nextAttemptAt: retryAt } });
}

/**
 * Retire an op the provider will never accept — a 422 validation error, an issue
 * that no longer exists, a repository whose push consent was withdrawn.
 *
 * Terminal on the first response rather than after `MAX_SYNC_OP_ATTEMPTS`,
 * because a refusal replays identically for ever: the five attempts `failOp`
 * would spend are five content-creating requests out of a 500/hour budget buying
 * a known answer. `given_up` rather than `cancelled` so the row still reads as
 * "we tried and stopped", with `lastError` as the explanation.
 */
export async function refuseOp(tx: Tx, id: string, error: string): Promise<void> {
  await tx.taskSyncOp.update({
    where: { id },
    data: { status: TaskSyncOpStatusSchema.enum.given_up, lastError: truncate(error) },
  });
}

/**
 * Drop one op because the local state says it must not be sent at all.
 *
 * **Not "leave it pending".** `claimNextOps` only ever offers a task's LOWEST
 * pending `seq`, so an op that can never be sent and is never closed is a
 * head-of-line block on every later write for that task — the queue stops
 * silently and nothing reports it. Cancelled rather than `processed`, because it
 * never reached the provider.
 */
export async function cancelOp(tx: Tx, id: string, reason: string): Promise<void> {
  await tx.taskSyncOp.update({
    where: { id },
    data: { status: TaskSyncOpStatusSchema.enum.cancelled, lastError: truncate(reason) },
  });
}

export type CancelPendingOpsResult = {
  cancelled: { id: string; kind: string }[];
  /**
   * An `issue.create` that was already handed to the provider and so was left
   * pending. Its outcome is unknown: the issue may exist with nothing linking
   * to it, and cancelling it blind leaves an orphan in a public repository that
   * our own retry created and our own delete forgot. It has to run its
   * resolution step and record what it finds.
   */
  keptCreate: { id: string; opKey: string } | null;
};

/**
 * Cancel a task's queued provider writes.
 *
 * **Precondition: the caller holds
 * `pg_advisory_xact_lock(hashtext('tasksync:' || taskId))`**, in the same
 * transaction as the delete that motivated it — a `title := X` applied after
 * the user stopped tracking the task writes to a repository they walked away
 * from.
 */
export async function cancelPendingOps(
  tx: Tx,
  taskId: string
): Promise<CancelPendingOpsResult> {
  const cancelled = await tx.$queryRaw<{ id: string; kind: string }[]>`
    UPDATE task_sync_ops SET status = ${TaskSyncOpStatusSchema.enum.cancelled}
    WHERE task_id = ${taskId}::uuid
      AND status = ${TaskSyncOpStatusSchema.enum.pending}
      AND NOT (kind = ${TaskSyncOpKindSchema.enum["issue.create"]} AND attempted_at IS NOT NULL)
    RETURNING id::text AS id, kind`;

  const keptCreate = await tx.taskSyncOp.findFirst({
    where: {
      taskId,
      kind: TaskSyncOpKindSchema.enum["issue.create"],
      status: TaskSyncOpStatusSchema.enum.pending,
      attemptedAt: { not: null },
    },
    select: { id: true, opKey: true },
  });

  return { cancelled, keptCreate };
}

const OP_SELECT = {
  id: true,
  taskId: true,
  integrationId: true,
  provider: true,
  kind: true,
  payload: true,
  opKey: true,
  seq: true,
  attempts: true,
  status: true,
  nextAttemptAt: true,
  attemptedAt: true,
} as const;

type ClaimedRow = {
  id: string;
  taskId: string;
  integrationId: string;
  provider: string;
  kind: string;
  payload: unknown;
  opKey: string;
  seq: number;
  attempts: number;
  status: string;
  nextAttemptAt: Date;
  attemptedAt: Date | null;
};

function toRecord(row: ClaimedRow): TaskSyncOpRecord {
  return {
    id: row.id,
    taskId: row.taskId,
    integrationId: row.integrationId,
    provider: row.provider,
    kind: TaskSyncOpKindSchema.parse(row.kind),
    payload: TaskSyncOpPayloadSchema.parse(row.payload),
    opKey: row.opKey,
    seq: row.seq,
    attempts: row.attempts,
    status: TaskSyncOpStatusSchema.parse(row.status),
    nextAttemptAt: row.nextAttemptAt,
    attemptedAt: row.attemptedAt,
  };
}

async function giveUpUnparseable(tx: Tx, id: string): Promise<void> {
  await tx.taskSyncOp.update({
    where: { id },
    data: {
      status: TaskSyncOpStatusSchema.enum.given_up,
      lastError: "payload does not match any known op kind",
    },
  });
}

function truncate(value: string): string {
  return value.length > MAX_ERROR_CHARS ? `${value.slice(0, MAX_ERROR_CHARS)}…` : value;
}
