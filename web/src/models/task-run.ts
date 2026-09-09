import { z } from "zod";
import type { DB, Tx } from "../db/index.js";
import type { Prisma } from "../generated/prisma/client.js";
import { getTaskByNumber, TaskStatusSchema, type TaskRecord } from "./task.js";
import type { TaskStatus } from "../tasks/merge.js";

/**
 * Task runs: the join between a task and a real agent session.
 *
 * The bridge reports the same session repeatedly as its status changes, so
 * every report is an upsert on the session rather than a new row — see
 * `task_runs_device_session_key`.
 *
 * Two things here are authorization, not bookkeeping. `deviceId` is the
 * caller's own verified device and never a value it named, so a machine can
 * only report runs for itself; and the task is resolved by
 * `(accountId, number)`, so a run reported against another account's task
 * misses rather than lands.
 */

/** The bridge's per-session `WorkStatus`, mirrored by hand from
 *  `bridge/src/work-status.ts` — the two live in different runtimes with no
 *  shared package between them (`packages/antgrid-wire` is Apache-2.0 and the
 *  licence boundary is one-way), so a value added there and not here is stored
 *  by nothing. */
export const TaskRunStatusSchema = z.enum(["working", "attention", "error", "done"]);
export type TaskRunStatus = z.infer<typeof TaskRunStatusSchema>;

/** The column is `VARCHAR(200)`, so this bound is a floor rather than a
 *  formality: over it, Postgres raises instead of returning a refusal. */
export const RESULT_SUMMARY_MAX = 200;

const RUN_SELECT = {
  taskId: true,
  deviceId: true,
  localProjectId: true,
  sessionId: true,
  checkoutId: true,
  tool: true,
  status: true,
  branch: true,
  prUrl: true,
  startedAt: true,
  endedAt: true,
  resultSummary: true,
} satisfies Prisma.TaskRunSelect;

type TaskRunRow = Prisma.TaskRunGetPayload<{ select: typeof RUN_SELECT }>;

export type TaskRunRecord = {
  deviceId: string;
  localProjectId: string;
  sessionId: string;
  checkoutId: string | null;
  tool: string | null;
  status: TaskRunStatus;
  branch: string | null;
  prUrl: string | null;
  startedAt: Date;
  endedAt: Date | null;
  resultSummary: string | null;
};

export type RecordTaskRunArgs = {
  /** Resolved from the caller's active membership, never from the request. */
  accountId: string;
  /** The task's per-account display number, the only address a client holds. */
  number: number;
  /** The caller's own device, taken from its verified token. */
  deviceId: string;
  localProjectId: string;
  sessionId: string;
  checkoutId?: string | null;
  tool?: string | null;
  status: TaskRunStatus;
  branch?: string | null;
  prUrl?: string | null;
  /** The session is over. Stamps `endedAt` once; a later report never moves it,
   *  because the first end is the one that happened. */
  ended?: boolean;
  resultSummary?: string | null;
};

export type TaskRunRefusal =
  | { kind: "not_found" }
  /** `boundNumber` is the task the session already belongs to, and is null when
   *  that task is another account's — the caller learns that its session is
   *  taken without learning anything about who took it. */
  | { kind: "session_task_conflict"; boundNumber: number | null }
  | { kind: "result_summary_too_long" };

export type TaskRunResult =
  | { kind: "ok"; run: TaskRunRecord; task: TaskRecord }
  | TaskRunRefusal;

/**
 * Record where a session has got to, and let it move the task if the transition
 * is one of the two that may.
 *
 * The run write and the `Task.status` write share a transaction so a reader can
 * never see a task dragged to `in_progress` by a run that does not exist.
 */
export async function recordTaskRun(db: DB, args: RecordTaskRunArgs): Promise<TaskRunResult> {
  if (args.resultSummary != null && args.resultSummary.length > RESULT_SUMMARY_MAX) {
    return { kind: "result_summary_too_long" };
  }

  return db.$transaction(async (tx): Promise<TaskRunResult> => {
    // The session check below is a check-then-act over the unique pair the
    // upsert then writes, so without serialization two adverts for one session
    // both pass it and the loser re-points the run — the exact thing the check
    // refuses. Same pattern and same namespacing rule as `bindLocalProject`:
    // `hashtext` collapses every key into one global int4 space, so a bare key
    // would contend with billing, task numbering and project binding.
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`taskrun:${args.deviceId}:${args.sessionId}`}))`;

    const task = await tx.task.findFirst({
      where: { accountId: args.accountId, number: args.number, deletedAt: null },
      select: { id: true, status: true },
    });
    // Identical to a number that never existed: the address is a small
    // sequential key, so another account's task must not be distinguishable
    // from a miss.
    if (!task) return { kind: "not_found" };

    const existing = await tx.taskRun.findUnique({
      where: { deviceId_sessionId: { deviceId: args.deviceId, sessionId: args.sessionId } },
      select: { id: true, taskId: true, endedAt: true },
    });
    // A session belongs to one task for its whole life. Silently re-pointing it
    // would move a finished run's branch and PR onto a task that never ran it.
    if (existing && existing.taskId !== task.id) {
      // Re-read under `accountId` rather than following the relation: the run
      // this session is bound to may be another account's, and the display
      // number is a small sequential key that must not cross that line.
      const bound = await tx.task.findFirst({
        where: { id: existing.taskId, accountId: args.accountId },
        select: { number: true },
      });
      return { kind: "session_task_conflict", boundNumber: bound?.number ?? null };
    }

    const stampEnd = args.ended === true && (existing?.endedAt ?? null) === null;
    const mutable = {
      status: args.status,
      ...(args.checkoutId === undefined ? {} : { checkoutId: args.checkoutId }),
      ...(args.tool === undefined ? {} : { tool: args.tool }),
      ...(args.branch === undefined ? {} : { branch: args.branch }),
      ...(args.prUrl === undefined ? {} : { prUrl: args.prUrl }),
      ...(args.resultSummary === undefined ? {} : { resultSummary: args.resultSummary }),
      ...(stampEnd ? { endedAt: new Date() } : {}),
    };

    const row = await tx.taskRun.upsert({
      where: { deviceId_sessionId: { deviceId: args.deviceId, sessionId: args.sessionId } },
      create: {
        taskId: task.id,
        deviceId: args.deviceId,
        localProjectId: args.localProjectId,
        sessionId: args.sessionId,
        ...mutable,
      },
      // `localProjectId` is left alone: it is where this session was started,
      // and a project id that changed under a live session is a report about a
      // different session wearing its id.
      update: mutable,
      select: RUN_SELECT,
    });

    await applyRunStatusToTask(tx, {
      taskId: task.id,
      observed: task.status,
      runStatus: args.status,
    });

    const updated = await getTaskByNumber(tx, args.accountId, args.number);
    // Unreachable while the transaction holds: the same read found the task a
    // few statements ago.
    if (!updated) return { kind: "not_found" };
    return { kind: "ok", run: toRecord(row), task: updated };
  });
}

/**
 * The task status a run status implies, or null for the ones that imply
 * nothing.
 *
 * These two are the only automatic writers `Task.status` will ever have, and
 * both are guarded on the state they move FROM as well as the one they move to.
 *
 * `done` is the finding this function exists to hold. `WorkStatus.done` means
 * *no turn is open* — an agent that finished, an agent that went idle, and a
 * freshly-opened chat all report it — so closing a task on it would close a task
 * every time the user stopped typing. `error` writes nothing either: it is a
 * property of the run, and a failed attempt does not block the task, which is
 * what `blocked` would claim.
 *
 * Refusing the other two directions has a real cost. `open`, `in_progress` and
 * `blocked` all project onto GitHub `open`, so without these writers the
 * distinction between them is hand-maintained — and a hand-maintained status
 * field is the most reliably abandoned field in every tracker ever shipped.
 */
export function autoTaskStatusFor(runStatus: TaskRunStatus, observed: string): TaskStatus | null {
  if (runStatus === "working" && observed === TaskStatusSchema.enum.open) {
    return TaskStatusSchema.enum.in_progress;
  }
  if (
    runStatus === "attention" &&
    (observed === TaskStatusSchema.enum.open || observed === TaskStatusSchema.enum.in_progress)
  ) {
    return TaskStatusSchema.enum.blocked;
  }
  return null;
}

/**
 * Compare-and-set on the observed status.
 *
 * The observed value goes in the `WHERE` clause, so a status that moved between
 * the read and the write updates nothing and the caller carries on. Without it,
 * the gap between a `working` advert arriving and this write landing is enough
 * for a user to close the task from the app, and the automatic write drags a
 * finished task back to `in_progress` — an automatic writer undoing a human one,
 * which is the failure that makes people stop trusting the field.
 *
 * Zero rows updated is a no-op and not an error; the return value is for tests
 * and for callers that want to know whether anything moved.
 */
export async function applyRunStatusToTask(
  tx: Tx,
  args: { taskId: string; observed: string; runStatus: TaskRunStatus }
): Promise<boolean> {
  const next = autoTaskStatusFor(args.runStatus, args.observed);
  if (next === null) return false;
  const result = await tx.task.updateMany({
    where: { id: args.taskId, status: args.observed, deletedAt: null },
    data: { status: next },
  });
  return result.count > 0;
}

export async function listTaskRuns(
  db: Tx,
  args: { accountId: string; number: number }
): Promise<TaskRunRecord[]> {
  const rows = await db.taskRun.findMany({
    where: { task: { accountId: args.accountId, number: args.number, deletedAt: null } },
    orderBy: { startedAt: "desc" },
    select: RUN_SELECT,
  });
  return rows.map(toRecord);
}

function toRecord(row: TaskRunRow): TaskRunRecord {
  const status = TaskRunStatusSchema.safeParse(row.status);
  return {
    deviceId: row.deviceId,
    localProjectId: row.localProjectId,
    sessionId: row.sessionId,
    checkoutId: row.checkoutId,
    tool: row.tool,
    // A status outside the vocabulary can only come from a hand-written UPDATE.
    // `done` is the reading that claims least about a run nobody can interpret.
    status: status.success ? status.data : TaskRunStatusSchema.enum.done,
    branch: row.branch,
    prUrl: row.prUrl,
    startedAt: row.startedAt,
    endedAt: row.endedAt,
    resultSummary: row.resultSummary,
  };
}
