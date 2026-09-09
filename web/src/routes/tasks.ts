import { Hono, type Context, type MiddlewareHandler } from "hono";
import { z } from "zod";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import type { Env } from "../env.js";
import { requireUserOrBearer, type AuthVars } from "../auth/middleware.js";
import { findActiveMembership } from "../models/account-member.js";
import {
  clearTaskPushBlockByNumber,
  createTask,
  getTaskByNumber,
  listTasks,
  moveTask,
  publishTaskByNumber,
  resolveTaskConflict,
  softDeleteTask,
  unlinkTask,
  updateTask,
  TaskStatusSchema,
  TaskTitleSchema,
  type ClearPushBlockRefusal,
  type ConflictDecision,
  type ConflictLocalPatch,
  type PublishTaskRefusal,
  type ResolveConflictRefusal,
  type TaskRecord,
  type TaskRefusal,
  type UnlinkTaskRefusal,
} from "../models/task.js";
import { listPublishTargets, type PublishRefusal, type PublishTarget } from "../tasks/publish.js";
import { blockedFields, parsePushBlocked, PushFieldSchema } from "../tasks/push-blocked.js";
import { formatTaskId, parseTaskId } from "../tasks/display-id.js";
import { fromRemote, sameAssignee, type Assignee, type TaskStatus } from "../tasks/merge.js";
import {
  isEmptyLocalConflict,
  parseLocalConflict,
  parseRemoteSnapshot,
  type LocalConflictBlob,
} from "../integrations/github-import.js";
import {
  listTaskRuns,
  recordTaskRun,
  RESULT_SUMMARY_MAX,
  TaskRunStatusSchema,
  type TaskRunRecord,
  type TaskRunRefusal,
} from "../models/task-run.js";
import {
  attachLabel,
  deleteLabel,
  detachLabel,
  getOrCreateLabel,
  listLabels,
  setTaskLabels,
  type GetOrCreateLabelResult,
  type LabelRecord,
  type TaskLabelResult,
} from "../models/label.js";

/**
 * Tasks and labels over HTTP.
 *
 * **One router behind one gate that accepts either credential**, rather than two
 * routers or the same router mounted twice. The app and browser arrive with the
 * Better-Auth session cookie and the bridge with a device JWT, but both carriers
 * resolve to a `userId` and every handler below is identical from that point on
 * — two routers would duplicate a dozen path declarations for no behavioural
 * difference, and a second mount would change the URL, which is not a thing a
 * carrier may decide. The actor-type signal survives the merge: only the Bearer
 * path sets `deviceId` on the context, so publishing (phase 5, the one
 * irreversible verb) can still refuse a programmatic caller by testing for it.
 *
 * A task is addressed by its per-account `number`, never by uuid. That is a
 * small sequential key, so a miss and another account's task must be the same
 * 404 — see `models/task.ts`, whose reads are built for it.
 *
 * No subscription gate: task routes ship free
 * (`docs/tasks-open-decisions.md`), so membership is the only thing between a
 * caller and an account's tasks.
 */

type TaskVars = AuthVars & { accountId: string };

/** GitHub's ceiling on an issue body. A body that cannot round-trip is a push
 *  that fails forever, so it is refused where it is typed rather than at the
 *  seam — the same reasoning that caps a label name at 50. */
const BODY_MAX = 65536;

/** Only the member arm of `Assignee` is writable over HTTP. The external triple
 *  is a read-only snapshot of a provider identity, written by the import path
 *  and by nothing a client can reach. */
const AssigneeSchema = z.object({ kind: z.literal("member"), userId: z.string().min(1) });

/**
 * `publish` is REQUIRED and has no server-side default.
 *
 * This is the enforcement point for the one irreversible verb here: a create
 * that omits it is a 400, so an older client, a non-form caller, or a field
 * dropped on retry fails loudly instead of posting a private note into a public
 * repository. `IntegrationRepo.publishNewByDefault` positions the toggle in the
 * UI and is never consulted on this path — a default that can decide the outcome
 * is the auto-publish the whole design rules out
 * (`docs/tasks-and-integrations-plan.md`, "Publishing a local task to GitHub").
 */
const CreateTaskBody = z.object({
  title: z.string(),
  body: z.string().max(BODY_MAX).optional(),
  status: TaskStatusSchema.optional(),
  priority: z.number().int().nullable().optional(),
  projectId: z.uuid().nullable().optional(),
  assignee: AssigneeSchema.nullable().optional(),
  labelIds: z.array(z.uuid()).optional(),
  publish: z.boolean(),
  /** Required wherever the project offers more than one target; validated even
   *  when it does not, so a client naming a repository it may not reach is a
   *  refusal rather than a silent redirection to the only one available. */
  publishRepoId: z.uuid().optional(),
});

/** Same ambiguity rule as the create path. An absent body is read as `{}`: this
 *  verb takes no required input, and a client that posts none is asking for the
 *  unambiguous case. */
const PublishTaskBody = z.object({ repoId: z.uuid().optional() });

const PublishTargetsQuery = z.object({ projectId: z.uuid() });

const UpdateTaskBody = z.object({
  title: z.string().optional(),
  body: z.string().max(BODY_MAX).optional(),
  status: TaskStatusSchema.optional(),
  priority: z.number().int().nullable().optional(),
  /** `null` unfiles the task from its project. */
  projectId: z.uuid().nullable().optional(),
  /** `null` unassigns; absent leaves the assignee alone. */
  assignee: AssigneeSchema.nullable().optional(),
  labelIds: z.array(z.uuid()).optional(),
});

/** `labels` is the odd one out and stays in the same enum on purpose: the marker
 *  it clears lives in the same blob, and a caller holding a conflict badge
 *  should not have to know which half of it a field came from. */
const ConflictFieldSchema = z.enum(["title", "body", "status", "assignee", "labels"]);
type ConflictField = z.infer<typeof ConflictFieldSchema>;
type ScalarConflictField = Exclude<ConflictField, "labels">;

const ResolveConflictBody = z.object({
  field: ConflictFieldSchema,
  take: z.enum(["local", "remote"]),
});

/** The pushable fields, straight from the counter's own enum — a second
 *  spelling here would let the route accept a name nothing can ever block. */
const ClearPushBlockBody = z.object({ field: PushFieldSchema });

/** How `mergeTask` stored a losing `status`: provider space, not Antgrid
 *  vocabulary, because status is compared there to keep the many-to-one mapping
 *  from manufacturing a push loop. */
const RemoteStateSchema = z.object({
  state: z.enum(["open", "closed"]),
  stateReason: z.enum(["completed", "not_planned", "reopened"]).nullish(),
});

const MoveTaskBody = z.object({
  previousNumber: z.number().int().positive().nullable().optional(),
  nextNumber: z.number().int().positive().nullable().optional(),
});

const ListTasksQuery = z.object({
  status: z.array(TaskStatusSchema).optional(),
  projectId: z.uuid().optional(),
  /** A member's user id, or `me`. Resolved against the caller before it reaches
   *  the model, which anchors the query on `accountId` either way. */
  assignee: z.string().min(1).optional(),
  limit: z.coerce.number().int().min(1).max(500).optional(),
});

const CreateLabelBody = z.object({
  name: z.string(),
  color: z.string(),
  description: z.string().max(200).nullable().optional(),
  projectId: z.uuid().nullable().optional(),
});

const AttachLabelBody = z.object({ labelId: z.uuid() });
const SetLabelsBody = z.object({ labelIds: z.array(z.uuid()) });

/**
 * What a bridge reports about one session.
 *
 * `deviceUuid` is an assertion, not an input: the run is always written against
 * the device the token resolved to, and this field is compared with it so a
 * machine reporting under someone else's id fails loudly instead of quietly
 * attributing its work elsewhere.
 *
 * `resultSummary` is capped here as well as by the column, so an over-long one
 * is a refusal rather than a Postgres error — and a refusal rather than a silent
 * truncation, because the caller is the only party that knows what to cut.
 */
const ReportRunBody = z.object({
  deviceUuid: z.uuid(),
  localProjectId: z.string().min(1).max(200),
  sessionId: z.string().min(1).max(200),
  checkoutId: z.string().min(1).max(200).nullable().optional(),
  tool: z.string().min(1).max(100).nullable().optional(),
  status: TaskRunStatusSchema,
  branch: z.string().min(1).max(255).nullable().optional(),
  /** `httpUrl`, not `url`: the plain form accepts any scheme `new URL()` parses,
   *  so `javascript:` would round-trip to an app that renders this as a tappable
   *  link. */
  prUrl: z.httpUrl().max(2048).nullable().optional(),
  /** The session is over. Stamps `endedAt` once; later reports never move it. */
  ended: z.boolean().optional(),
  resultSummary: z.string().max(RESULT_SUMMARY_MAX).nullable().optional(),
});

export function taskRoutes(deps: { db: DB; auth: Auth; env: Env }) {
  const r = new Hono<{ Variables: TaskVars }>();

  const gate = requireUserOrBearer(deps);
  const account = requireAccount(deps.db);
  for (const path of ["/tasks", "/tasks/*", "/labels", "/labels/*"]) {
    r.use(path, gate);
    r.use(path, account);
  }

  r.get("/tasks", async (c) => {
    const parsed = ListTasksQuery.safeParse({
      status: c.req.queries("status"),
      projectId: c.req.query("projectId"),
      assignee: c.req.query("assignee"),
      limit: c.req.query("limit"),
    });
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);
    const query = parsed.data;

    const tasks = await listTasks(deps.db, {
      accountId: c.get("accountId"),
      status: query.status,
      projectId: query.projectId,
      assigneeUserId:
        query.assignee === undefined
          ? undefined
          : query.assignee === "me"
            ? c.get("userId")
            : query.assignee,
      limit: query.limit,
    });
    return c.json({ tasks: tasks.map(taskJson) });
  });

  // `source` is deliberately not accepted: it records which system the task was
  // born in, and everything arriving here was born local.
  r.post("/tasks", async (c) => {
    const parsed = CreateTaskBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);
    const body = parsed.data;
    if (body.publish) {
      const refused = publishFromDevice(c);
      if (refused) return refused;
    }

    const result = await createTask(deps.db, {
      accountId: c.get("accountId"),
      createdBy: c.get("userId"),
      title: body.title,
      body: body.body,
      status: body.status,
      priority: body.priority,
      projectId: body.projectId,
      assignee: body.assignee,
      labelIds: body.labelIds,
      publish: body.publish ? { repoId: body.publishRepoId ?? null } : undefined,
    });
    if (result.kind !== "ok") return refuseTask(c, result);
    return c.json({ task: taskJson(result.task) }, 201);
  });

  /**
   * Where a task filed against this project could be published.
   *
   * Declared before `/tasks/:number` because Hono matches in registration order
   * and this is a literal path, not a task id.
   *
   * Targets resolve through `IntegrationRepo.repoKey`, written by the install
   * flow from the provider's own granted-repo list — never through
   * `Project.repoKey`, which a device asserts about a folder on a developer's
   * machine and can name any repository at all.
   */
  r.get("/tasks/publish-targets", async (c) => {
    const parsed = PublishTargetsQuery.safeParse({ projectId: c.req.query("projectId") });
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);

    const targets = await listPublishTargets(deps.db, {
      accountId: c.get("accountId"),
      projectId: parsed.data.projectId,
    });
    return c.json({ targets: targets.map(publishTargetJson) });
  });

  /**
   * Publish a task that was created without the option.
   *
   * The same mechanism as the toggle on the create form, and deliberately the
   * same refusals: the two entry points differ only in when the user was asked.
   */
  r.post("/tasks/:number/publish", async (c) => {
    const number = taskNumber(c);
    if (number === null) return c.json({ error: "NOT_FOUND" }, 404);
    const refused = publishFromDevice(c);
    if (refused) return refused;
    const parsed = PublishTaskBody.safeParse(await c.req.json().catch(() => ({})));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);

    const result = await publishTaskByNumber(deps.db, {
      accountId: c.get("accountId"),
      number,
      repoId: parsed.data.repoId ?? null,
    });
    if (result.kind !== "ok") return refusePublish(c, result);
    return c.json({ task: taskJson(result.task) });
  });

  /**
   * Stop syncing, and leave the issue alone.
   *
   * There is no unpublish — the issue exists — so this is the only reverse
   * operation there is, and it keeps the external identity on the row so a
   * re-publish can name the issue that already exists rather than describing the
   * hazard in the abstract.
   */
  r.post("/tasks/:number/unlink", async (c) => {
    const number = taskNumber(c);
    if (number === null) return c.json({ error: "NOT_FOUND" }, 404);

    const result = await unlinkTask(deps.db, { accountId: c.get("accountId"), number });
    if (result.kind !== "ok") return refuseUnlink(c, result);
    return c.json({ task: taskJson(result.task) });
  });

  r.get("/tasks/:number", async (c) => {
    const number = taskNumber(c);
    if (number === null) return c.json({ error: "NOT_FOUND" }, 404);
    const task = await getTaskByNumber(deps.db, c.get("accountId"), number);
    if (!task) return c.json({ error: "NOT_FOUND" }, 404);
    return c.json({ task: taskJson(task) });
  });

  r.patch("/tasks/:number", async (c) => {
    const number = taskNumber(c);
    if (number === null) return c.json({ error: "NOT_FOUND" }, 404);
    const parsed = UpdateTaskBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);

    const result = await updateTask(deps.db, {
      accountId: c.get("accountId"),
      number,
      patch: parsed.data,
    });
    if (result.kind !== "ok") return refuseTask(c, result);
    return c.json({ task: taskJson(result.task) });
  });

  /**
   * Dismiss one field of an import conflict.
   *
   * The badge is raised by the inbound merge and by nothing else, and the blob
   * behind it only ever grows — so this is the only way a task ever leaves
   * `conflict`. One field per call rather than a whole-blob "resolve": each
   * entry is a separate adjudication, and a caller that has read one of them is
   * not thereby entitled to discard the rest.
   */
  r.post("/tasks/:number/conflict/resolve", async (c) => {
    const number = taskNumber(c);
    if (number === null) return c.json({ error: "NOT_FOUND" }, 404);
    const parsed = ResolveConflictBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);
    const { field, take } = parsed.data;

    const result = await resolveTaskConflict(deps.db, {
      accountId: c.get("accountId"),
      number,
      decide: (current) => decideConflict(current, field, take),
    });
    if (result.kind !== "ok") return refuseTaskConflict(c, result);
    return c.json({ task: taskJson(result.task) });
  });

  /**
   * Start sending one field again.
   *
   * The block deliberately has no expiry — a timer would restart the loop it
   * exists to stop — so this is the only exit there is, and a field without one
   * diverges from the provider permanently. One field per call, like the
   * conflict resolve beside it: each block is its own judgement about its own
   * value, and reading one is not entitlement to lift the rest.
   *
   * The task uuid never crosses the wire, so the number is resolved to an id
   * under the caller's account inside the verb rather than an id being accepted
   * from the body.
   */
  r.post("/tasks/:number/push-block/clear", async (c) => {
    const number = taskNumber(c);
    if (number === null) return c.json({ error: "NOT_FOUND" }, 404);
    const parsed = ClearPushBlockBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);

    const result = await clearTaskPushBlockByNumber(deps.db, {
      accountId: c.get("accountId"),
      number,
      field: parsed.data.field,
    });
    if (result.kind !== "ok") return refusePushBlock(c, result);
    return c.json({ task: taskJson(result.task) });
  });

  r.post("/tasks/:number/move", async (c) => {
    const number = taskNumber(c);
    if (number === null) return c.json({ error: "NOT_FOUND" }, 404);
    const parsed = MoveTaskBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);

    const result = await moveTask(deps.db, {
      accountId: c.get("accountId"),
      number,
      previousNumber: parsed.data.previousNumber ?? null,
      nextNumber: parsed.data.nextNumber ?? null,
    });
    if (result.kind !== "ok") return refuseTask(c, result);
    return c.json({ task: taskJson(result.task) });
  });

  r.delete("/tasks/:number", async (c) => {
    const number = taskNumber(c);
    if (number === null) return c.json({ error: "NOT_FOUND" }, 404);
    // Through the same mapper as every other verb, narrow union or not: a
    // refusal added to the delete path later has to land on a chosen status
    // rather than inherit whichever one this handler happened to spell.
    const result = await softDeleteTask(deps.db, { accountId: c.get("accountId"), number });
    if (result.kind !== "ok") return refuseTask(c, result);
    return c.json({ ok: true });
  });

  /**
   * The bridge reporting where one session has got to.
   *
   * Bearer-only, enforced on the actor-type signal rather than by a second gate
   * on the same path: `deviceId` is set by `requireBearerJwt` and by nothing
   * else, so its absence is a cookie caller — and a browser has no session to
   * report. Registering a bearer-only middleware here would not narrow the
   * route anyway, since the `/tasks/*` gate above already matches it.
   *
   * The device is the caller's own, never the body's. A machine may only report
   * its own runs, and `deviceUuid` in the body is checked against the token
   * rather than trusted — the reverse of the bindings route, where the body
   * names a *target* machine and the caller may legitimately be another one.
   */
  r.post("/tasks/:number/runs", async (c) => {
    const deviceId = c.get("deviceId");
    if (deviceId === undefined) return c.json({ error: "DEVICE_REQUIRED" }, 403);
    const number = taskNumber(c);
    if (number === null) return c.json({ error: "NOT_FOUND" }, 404);
    const parsed = ReportRunBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);
    const body = parsed.data;
    if (body.deviceUuid !== deviceId) return c.json({ error: "DEVICE_MISMATCH" }, 403);

    const result = await recordTaskRun(deps.db, {
      accountId: c.get("accountId"),
      number,
      deviceId,
      localProjectId: body.localProjectId,
      sessionId: body.sessionId,
      checkoutId: body.checkoutId,
      tool: body.tool,
      status: body.status,
      branch: body.branch,
      prUrl: body.prUrl,
      ended: body.ended,
      resultSummary: body.resultSummary,
    });
    if (result.kind !== "ok") return refuseTaskRun(c, result);
    return c.json({ run: runJson(result.run), task: taskJson(result.task) });
  });

  r.get("/tasks/:number/runs", async (c) => {
    const number = taskNumber(c);
    if (number === null) return c.json({ error: "NOT_FOUND" }, 404);
    const task = await getTaskByNumber(deps.db, c.get("accountId"), number);
    if (!task) return c.json({ error: "NOT_FOUND" }, 404);
    const runs = await listTaskRuns(deps.db, { accountId: c.get("accountId"), number });
    return c.json({ runs: runs.map(runJson) });
  });

  // The three label verbs take a task uuid and a client never holds one, so the
  // number is resolved here rather than a uuid being accepted from the wire.
  // Both the resolve and the write scope to `accountId`; the second is not
  // leaning on the first for tenancy.
  r.put("/tasks/:number/labels", async (c) => {
    const task = await resolveTask(c, deps.db);
    if (task === null) return c.json({ error: "NOT_FOUND" }, 404);
    const parsed = SetLabelsBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);

    const result = await setTaskLabels(deps.db, {
      accountId: c.get("accountId"),
      taskId: task.id,
      labelIds: parsed.data.labelIds,
    });
    return respondWithTask(c, deps.db, task.number, result);
  });

  r.post("/tasks/:number/labels", async (c) => {
    const task = await resolveTask(c, deps.db);
    if (task === null) return c.json({ error: "NOT_FOUND" }, 404);
    const parsed = AttachLabelBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);

    const result = await attachLabel(deps.db, {
      accountId: c.get("accountId"),
      taskId: task.id,
      labelId: parsed.data.labelId,
    });
    return respondWithTask(c, deps.db, task.number, result);
  });

  r.delete("/tasks/:number/labels/:labelId", async (c) => {
    const task = await resolveTask(c, deps.db);
    if (task === null) return c.json({ error: "NOT_FOUND" }, 404);

    const result = await detachLabel(deps.db, {
      accountId: c.get("accountId"),
      taskId: task.id,
      labelId: c.req.param("labelId"),
    });
    return respondWithTask(c, deps.db, task.number, result);
  });

  r.get("/labels", async (c) => {
    const projectId = c.req.query("projectId");
    if (projectId !== undefined && !z.uuid().safeParse(projectId).success) {
      return c.json({ error: "BAD_REQUEST" }, 400);
    }
    const labels = await listLabels(deps.db, { accountId: c.get("accountId"), projectId });
    return c.json({ labels: labels.map(labelJson) });
  });

  // Get-or-create rather than create: a label is identified by its name, that
  // name is CITEXT, and two clients naming `bug` mean one label. A caller that
  // already holds it gets 200 and the row it meant.
  r.post("/labels", async (c) => {
    const parsed = CreateLabelBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST", issues: parsed.error.issues }, 400);
    const body = parsed.data;

    const result = await getOrCreateLabel(deps.db, {
      accountId: c.get("accountId"),
      projectId: body.projectId,
      name: body.name,
      color: body.color,
      description: body.description,
    });
    if (result.kind !== "ok") return refuseLabel(c, result);
    return c.json({ label: labelJson(result.label) }, result.created ? 201 : 200);
  });

  r.delete("/labels/:id", async (c) => {
    const deleted = await deleteLabel(deps.db, {
      accountId: c.get("accountId"),
      labelId: c.req.param("id"),
    });
    if (!deleted) return c.json({ error: "NOT_FOUND" }, 404);
    return c.json({ ok: true });
  });

  return r;
}

/**
 * The account every handler below operates on.
 *
 * `findActiveMembership`, never `resolveBillingAccountId` and never
 * `user.accountId`: the owner fallback would write a task to the user's personal
 * account while they are acting on a team, and the team would never see it.
 * Resolving it once, here, is what stops that choice being re-taken per handler.
 */
function requireAccount(db: DB): MiddlewareHandler<{ Variables: TaskVars }> {
  return async (c, next) => {
    const membership = await findActiveMembership(db, c.get("userId"));
    if (!membership) return c.json({ error: "NO_ACCOUNT" }, 403);
    c.set("accountId", membership.accountId);
    await next();
  };
}

/** Bounded rather than a bare `Number()`: the column is `int4`, so an
 *  out-of-range literal would reach Postgres as an error instead of a 404. */
/** Both `14` and `ANT-14` address the same task: the second is the form a person
 *  reads, copies, and gets written into a GitHub issue body, so a route that took
 *  only the first would 404 on the link this app itself published. */
function taskNumber(c: Context<{ Variables: TaskVars }>): number | null {
  const raw = c.req.param("number");
  return raw === undefined ? null : parseTaskId(raw);
}

async function resolveTask(
  c: Context<{ Variables: TaskVars }>,
  db: DB
): Promise<TaskRecord | null> {
  const number = taskNumber(c);
  if (number === null) return null;
  return getTaskByNumber(db, c.get("accountId"), number);
}

/**
 * What resolving one field costs the row, decided from the stored blob.
 *
 * `take: "remote"` writes no column at all: the merge already applied the remote
 * value when it raised the conflict, so the row holds it. Re-deriving it from
 * the blob and writing it back would clobber whatever the user has edited since
 * — the entry records what the merge *saw*, not what the row says now.
 */
function decideConflict(
  current: { localConflict: unknown; status: TaskStatus },
  field: ConflictField,
  take: "local" | "remote"
): ConflictDecision {
  const blob = parseLocalConflict(current.localConflict);

  if (field === "labels") {
    // Acknowledge-only, whichever side the caller named. Restoring a dropped
    // label locally would leave it on our row and absent from the provider with
    // no push to reconcile it, and re-adding it through the label routes is the
    // same edit with none of that asymmetry.
    if (take === "local") return { kind: "labels_local_unsupported" };
    if (blob.labelRemoveWins.length === 0) return { kind: "not_conflicted", field };
    return writeDecision({ conflicts: blob.conflicts, labelRemoveWins: [] }, null);
  }

  const entry = blob.conflicts[field];
  // Also where a retry of a resolve that already landed arrives, which is the
  // right answer: the second call is not a no-op, it is a call about an entry
  // that no longer exists.
  if (entry === undefined) return { kind: "not_conflicted", field };

  const { [field]: _resolved, ...conflicts } = blob.conflicts;
  const next = { conflicts, labelRemoveWins: blob.labelRemoveWins };
  if (take === "remote") return writeDecision(next, null);

  const patch = localPatch(field, entry.localValue, current.status);
  if (patch === null) return { kind: "local_value_unreadable", field };
  return writeDecision(next, patch);
}

function writeDecision(next: LocalConflictBlob, patch: ConflictLocalPatch | null): ConflictDecision {
  return {
    kind: "write",
    patch,
    nextConflict: isEmptyLocalConflict(next) ? null : next,
    conflictsRemain: Object.keys(next.conflicts).length > 0,
  };
}

/**
 * The stored losing value, checked against the field's own schema.
 *
 * The blob is JSON a merge wrote at some point in the past and nothing has
 * validated since; a value that no longer parses is refused rather than written,
 * because the column it would land in is the one every other reader trusts.
 */
function localPatch(
  field: ScalarConflictField,
  value: unknown,
  currentStatus: TaskStatus
): ConflictLocalPatch | null {
  switch (field) {
    case "title": {
      const parsed = TaskTitleSchema.safeParse(value);
      return parsed.success ? { field, value: parsed.data } : null;
    }
    case "body": {
      const parsed = z.string().max(BODY_MAX).safeParse(value);
      return parsed.success ? { field, value: parsed.data } : null;
    }
    case "status": {
      const parsed = RemoteStateSchema.safeParse(value);
      // The sub-status the local row lost is not in the blob — `in_progress` and
      // `blocked` both store as `open` — so the current row is the hint, exactly
      // as it is on the inbound path.
      return parsed.success ? { field, value: fromRemote(parsed.data, currentStatus) } : null;
    }
    case "assignee": {
      // The member-only schema the write path uses: the external triple is a
      // read-only snapshot of a provider identity, and a resolve is a client
      // asking for a write like any other.
      const parsed = AssigneeSchema.nullable().safeParse(value);
      return parsed.success ? { field, value: parsed.data } : null;
    }
  }
}

/**
 * `not_conflicted` and `local_value_unreadable` are 409s: both requests are
 * well-formed and the caller is entitled to everything they named, and what
 * refuses them is the state of the blob. `labels_local_unsupported` is a 400 —
 * that combination is never valid on any row.
 */
function refuseTaskConflict(
  c: Context<{ Variables: TaskVars }>,
  refusal: ResolveConflictRefusal
): Response {
  switch (refusal.kind) {
    case "not_found":
      return c.json({ error: "NOT_FOUND" }, 404);
    case "not_conflicted":
      return c.json({ error: "NOT_CONFLICTED", field: refusal.field }, 409);
    case "local_value_unreadable":
      return c.json({ error: "LOCAL_VALUE_UNREADABLE", field: refusal.field }, 409);
    case "labels_local_unsupported":
      return c.json(
        {
          error: "LABELS_LOCAL_UNSUPPORTED",
          message:
            "A dropped label cannot be restored from here: it would sit on this task and not on the issue, with nothing to push it. Re-add it through the label routes.",
        },
        400
      );
    case "assignee_not_member":
      return c.json({ error: "ASSIGNEE_NOT_MEMBER", userId: refusal.userId }, 400);
    default:
      return unhandledRefusal(refusal);
  }
}

/**
 * `not_blocked` is a 409 for the reason `not_conflicted` is one: the request is
 * well-formed and the caller is entitled to everything it named, and what
 * refuses it is the state of the blob — which a push that finally landed may
 * have changed a moment before the tap.
 */
function refusePushBlock(
  c: Context<{ Variables: TaskVars }>,
  refusal: ClearPushBlockRefusal
): Response {
  switch (refusal.kind) {
    case "not_found":
      return c.json({ error: "NOT_FOUND" }, 404);
    case "not_blocked":
      return c.json({ error: "NOT_BLOCKED", field: refusal.field }, 409);
    default:
      return unhandledRefusal(refusal);
  }
}

/** The label verbs answer `{ kind: "ok" }` and nothing else, but a client that
 *  just changed a task's labels wants the task rather than a second round trip. */
async function respondWithTask(
  c: Context<{ Variables: TaskVars }>,
  db: DB,
  number: number,
  result: TaskLabelResult
): Promise<Response> {
  if (result.kind !== "ok") return refuseTaskLabel(c, result);
  const task = await getTaskByNumber(db, c.get("accountId"), number);
  if (!task) return c.json({ error: "NOT_FOUND" }, 404);
  return c.json({ task: taskJson(task) });
}

/**
 * Every refusal the task model can return, mapped exhaustively.
 *
 * The `never` arm is the point: a variant added to `TaskRefusal` later stops
 * this file compiling instead of falling through to a 500.
 *
 * 404 versus 400 splits on *what was named*. The task in the path is addressed
 * by a small sequential number, so a miss must look identical whether the number
 * never existed or belongs to another account. An id in the body names a
 * reference supplied alongside a task the caller can already see, so it is a bad
 * request rather than a missing resource. `moveTask` collapses an unresolvable
 * neighbour into `not_found` and so answers 404 for a body field — the neighbour
 * is addressed by number too, and the anti-enumeration argument applies to it
 * unchanged.
 */
function refuseTask(c: Context<{ Variables: TaskVars }>, refusal: TaskRefusal): Response {
  switch (refusal.kind) {
    case "not_found":
      return c.json({ error: "NOT_FOUND" }, 404);
    case "invalid_title":
      return c.json({ error: "INVALID_TITLE" }, 400);
    case "project_not_found":
      return c.json({ error: "PROJECT_NOT_FOUND" }, 400);
    case "assignee_not_member":
      return c.json({ error: "ASSIGNEE_NOT_MEMBER", userId: refusal.userId }, 400);
    case "neighbours_out_of_order":
      return c.json({ error: "NEIGHBOURS_OUT_OF_ORDER" }, 400);
    case "label_not_found":
      return c.json({ error: "LABEL_NOT_FOUND", labelId: refusal.labelId }, 400);
    case "label_out_of_scope":
      return c.json({ error: "LABEL_OUT_OF_SCOPE", labelId: refusal.labelId }, 400);
    case "publish_not_available":
    case "publish_repo_ambiguous":
    case "publish_repo_not_found":
      return refusePublishTarget(c, refusal);
    default:
      return unhandledRefusal(refusal);
  }
}

/**
 * Publishing is the one verb on this router a programmatic caller may not reach.
 *
 * `requireBearerJwt` blanks `sessionId`, so nothing inside a Bearer request
 * separates a person from an agent driving the bridge — and a publish cannot be
 * taken back: deleting a GitHub issue is admin-only and the content is already
 * in every watcher's inbox. The required `publish` field is the primary defence
 * and holds whatever the carrier, but it records an intent rather than proving
 * who formed it, so the carrier that cannot be asked is refused outright
 * (`docs/tasks-and-integrations-plan.md`, "Publishing a local task to GitHub").
 *
 * `deviceId` is set by exactly one gate, so this tests the credential rather
 * than anything the caller supplies. It costs the app nothing — it is already
 * on the cookie — and it deliberately does not cover unlink, which writes
 * nothing to the provider, or the targets read.
 */
function publishFromDevice(c: Context<{ Variables: TaskVars }>): Response | null {
  if (c.get("deviceId") === undefined) return null;
  return c.json({ error: "PUBLISH_REQUIRES_SESSION" }, 403);
}

/**
 * The three ways a publish destination fails to resolve, mapped once for every
 * route that can reach them.
 *
 * 409 for the first two: the request is well-formed and what refuses it is the
 * state of the account's integrations — a repository whose push consent was
 * withdrawn between the form rendering and the submit lands here. 404 for a
 * named repo id, which is a resource the caller asked for by identity and may
 * not have, and it is the same answer whether the row belongs to another
 * account, to another project, or does not exist.
 */
function refusePublishTarget(
  c: Context<{ Variables: TaskVars }>,
  refusal: PublishRefusal
): Response {
  switch (refusal.kind) {
    case "publish_not_available":
      return c.json({ error: "PUBLISH_NOT_AVAILABLE" }, 409);
    case "publish_repo_ambiguous":
      return c.json({ error: "PUBLISH_REPO_AMBIGUOUS" }, 409);
    case "publish_repo_not_found":
      return c.json({ error: "PUBLISH_REPO_NOT_FOUND" }, 404);
    default:
      return unhandledRefusal(refusal);
  }
}

/** `already_linked` is a 409 for the reason `not_conflicted` is one: the caller
 *  is entitled to everything it named, and what refuses it is the row already
 *  holding an issue — which a create that landed a moment ago may have given it. */
function refusePublish(
  c: Context<{ Variables: TaskVars }>,
  refusal: PublishTaskRefusal
): Response {
  switch (refusal.kind) {
    case "not_found":
      return c.json({ error: "NOT_FOUND" }, 404);
    case "already_linked":
      return c.json({ error: "ALREADY_LINKED" }, 409);
    default:
      return refusePublishTarget(c, refusal);
  }
}

/** `not_linked` is a 409 rather than a 404 for the same reason: the task is
 *  there and the caller may address it — it simply has nothing to unlink. */
function refuseUnlink(
  c: Context<{ Variables: TaskVars }>,
  refusal: UnlinkTaskRefusal
): Response {
  switch (refusal.kind) {
    case "not_found":
      return c.json({ error: "NOT_FOUND" }, 404);
    case "not_linked":
      return c.json({ error: "NOT_LINKED" }, 409);
    default:
      return unhandledRefusal(refusal);
  }
}

/**
 * `session_task_conflict` is a 409 rather than a 400: the request is
 * well-formed and the caller is entitled to everything it named — the session
 * simply already belongs to a different task, which is state rather than input.
 * `boundNumber` names that task so a reporter can correct itself, and is null
 * when the task belongs to another account.
 */
function refuseTaskRun(c: Context<{ Variables: TaskVars }>, refusal: TaskRunRefusal): Response {
  switch (refusal.kind) {
    case "not_found":
      return c.json({ error: "NOT_FOUND" }, 404);
    case "session_task_conflict":
      return c.json({ error: "SESSION_TASK_CONFLICT", boundNumber: refusal.boundNumber }, 409);
    case "result_summary_too_long":
      return c.json({ error: "RESULT_SUMMARY_TOO_LONG", max: RESULT_SUMMARY_MAX }, 400);
    default:
      return unhandledRefusal(refusal);
  }
}

function refuseLabel(
  c: Context<{ Variables: TaskVars }>,
  refusal: Exclude<GetOrCreateLabelResult, { kind: "ok" }>
): Response {
  switch (refusal.kind) {
    case "project_not_found":
      return c.json({ error: "PROJECT_NOT_FOUND" }, 400);
    case "invalid_name":
      return c.json({ error: "INVALID_LABEL_NAME" }, 400);
    case "invalid_color":
      return c.json({ error: "INVALID_LABEL_COLOR" }, 400);
    default:
      return unhandledRefusal(refusal);
  }
}

function refuseTaskLabel(
  c: Context<{ Variables: TaskVars }>,
  refusal: Exclude<TaskLabelResult, { kind: "ok" }>
): Response {
  switch (refusal.kind) {
    case "task_not_found":
      return c.json({ error: "NOT_FOUND" }, 404);
    case "label_not_found":
      return c.json({ error: "LABEL_NOT_FOUND", labelId: refusal.labelId }, 400);
    case "label_out_of_scope":
      return c.json({ error: "LABEL_OUT_OF_SCOPE", labelId: refusal.labelId }, 400);
    default:
      return unhandledRefusal(refusal);
  }
}

function unhandledRefusal(refusal: never): never {
  throw new Error(`unhandled task refusal: ${JSON.stringify(refusal)}`);
}

/** `integrationId` and `provider` stay off the wire: they are internal routing,
 *  and the client names a target by `id` and needs only what the consent UI
 *  renders. `publishNewByDefault` travels as the hint it is — it positions a
 *  toggle and never decides an outcome. */
function publishTargetJson(target: PublishTarget) {
  return {
    id: target.id,
    owner: target.owner,
    name: target.name,
    visibility: target.visibility,
    publishNewByDefault: target.publishNewByDefault,
  };
}

/** No `id`: `number` is the address, and a uuid on the wire is a second one
 *  clients would start addressing tasks by. `accountId` is the caller's own and
 *  tells them nothing they did not already know. */
function taskJson(task: TaskRecord) {
  return {
    number: task.number,
    /** The prefix is the server's to own — a client that builds `ANT-${number}`
     *  itself is a second place to change when it stops being one constant. */
    displayId: formatTaskId(task.number),
    title: task.title,
    body: task.body,
    status: task.status,
    priority: task.priority,
    projectId: task.projectId,
    sortKey: task.sortKey,
    source: task.source,
    assignee: task.assignee,
    labels: task.labels,
    externalProvider: task.externalProvider,
    externalId: task.externalId,
    externalKey: task.externalKey,
    externalUrl: task.externalUrl,
    syncState: task.syncState,
    conflict: conflictJson(task),
    pushBlocked: pushBlockedJson(task),
    otherAssignees: otherAssignees(task),
    createdBy: task.createdBy,
    createdAt: task.createdAt.toISOString(),
    updatedAt: task.updatedAt.toISOString(),
    closedAt: task.closedAt?.toISOString() ?? null,
  };
}

/**
 * What the import dropped, in the order it was dropped — the badge, and the only
 * place a user can read the edit that lost.
 *
 * An array rather than the blob's map, and sorted here rather than left as the
 * blob has it: jsonb stores keys in its own order, so the column cannot supply
 * one at all. `null` rather than an empty shape, so a clean task carries no
 * conflict UI. Values go over as stored: `title` and `body` are strings, `assignee` is
 * an `Assignee | null`, and `status` is PROVIDER space (`{ state, stateReason }`),
 * because that is where the merge compares it.
 *
 * **`remoteValue` for `body` is provider text a stranger may have written.** It
 * is no more exposed than `task.body`, which the same import already overwrote —
 * but the app's untrusted-body rule keys on `source` and the external columns
 * and knows nothing about this field, so nothing downstream will stop it
 * becoming an agent's opening instruction. It must never be fed to one from
 * here.
 */
function conflictJson(task: TaskRecord) {
  const blob = parseLocalConflict(task.localConflict);
  if (isEmptyLocalConflict(blob)) return null;
  const fields = Object.entries(blob.conflicts).map(([field, entry]) => ({
    field,
    localValue: entry.localValue,
    remoteValue: entry.remoteValue,
    at: entry.at,
  }));
  fields.sort(
    (a, b) =>
      a.at.localeCompare(b.at) ||
      conflictFieldRank(a.field) - conflictFieldRank(b.field) ||
      a.field.localeCompare(b.field)
  );
  return { fields, labelRemoveWins: blob.labelRemoveWins };
}

/**
 * The fields that stopped being pushed, and why — the marker, and the only
 * account a user gets of a value that is saved here and nowhere else.
 *
 * Only fields past `PUSH_BLOCK_THRESHOLD`: one mid-count is still being sent,
 * and naming it would report a stall that has not happened. `null` rather than
 * an empty shape, so a task that syncs cleanly carries no UI.
 *
 * Ordered by `blockedFields`, which walks the field enum rather than the blob.
 * That is the whole reason it is not `Object.entries`: jsonb does not preserve
 * key insertion order, so the column cannot supply an order at all and one read
 * off it could differ between two reads of the same row.
 */
function pushBlockedJson(task: TaskRecord) {
  const blob = parsePushBlocked(task.pushBlocked);
  const fields = blockedFields(blob).flatMap((field) => {
    const entry = blob[field];
    if (entry === undefined) return [];
    // The reason travels as the sentence it was written as, not as a code: it
    // is the only explanation there is for why this value stopped moving.
    return [{ field, reason: entry.reason, count: entry.count, lastAt: entry.lastAt }];
  });
  return fields.length === 0 ? null : { fields };
}

/** Oldest loss first, then the order a task is read in — one merge stamps every
 *  entry it raises with the same `at`, so the tie needs breaking somewhere. */
const CONFLICT_FIELD_ORDER = ["title", "body", "status", "assignee"];

function conflictFieldRank(field: string): number {
  const index = CONFLICT_FIELD_ORDER.indexOf(field);
  return index < 0 ? CONFLICT_FIELD_ORDER.length : index;
}

/**
 * The co-assignees the local column pair could not hold — the "+n others on
 * GitHub" marker.
 *
 * Sourced from `remoteSnapshot` rather than from a join table because the
 * column pair holds one assignee by design and the snapshot already carries the
 * full remote array; counting the rest needs no second table. The snapshot
 * itself never goes on the wire — it mirrors the body and would ship a second
 * copy of it on every task.
 */
function otherAssignees(task: TaskRecord): Assignee[] {
  const remote = parseRemoteSnapshot(task.remoteSnapshot)?.assignees ?? [];
  const rest = [...remote];
  // Removing one element rather than filtering by a predicate: the column kept
  // exactly one of these, so exactly one comes out.
  const chosen = rest.findIndex((assignee) => sameAssignee(assignee, task.assignee));
  if (chosen >= 0) rest.splice(chosen, 1);
  return rest;
}

/** No `id`: a run is addressed by the session it belongs to, which the reporter
 *  already holds, and every reader wants it grouped by session anyway. */
function runJson(run: TaskRunRecord) {
  return {
    deviceId: run.deviceId,
    localProjectId: run.localProjectId,
    sessionId: run.sessionId,
    checkoutId: run.checkoutId,
    tool: run.tool,
    status: run.status,
    branch: run.branch,
    prUrl: run.prUrl,
    startedAt: run.startedAt.toISOString(),
    endedAt: run.endedAt?.toISOString() ?? null,
    resultSummary: run.resultSummary,
  };
}

/** A label's uuid does cross the wire: it is the only handle the attach, detach
 *  and set verbs have, and unlike a task it carries no second address. */
function labelJson(label: LabelRecord) {
  return {
    id: label.id,
    projectId: label.projectId,
    name: label.name,
    color: label.color,
    description: label.description,
    createdAt: label.createdAt.toISOString(),
  };
}
