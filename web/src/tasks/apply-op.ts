import type { DB, Tx } from "../db/index.js";
import { Prisma } from "../generated/prisma/client.js";
import { resolveProviderIdentities } from "../models/integration-identity.js";
import { TaskSyncStateSchema } from "../models/task.js";
import { GithubApiError } from "../integrations/github-app.js";
import { githubIssueEchoHash } from "../integrations/github-echo.js";
import { GITHUB_PROVIDER, type GithubIssue } from "../integrations/github-events.js";
import {
  githubAssignees,
  githubIssueExternalKey,
  githubIssueNumberFromKey,
  githubIssueToRemote,
  githubRepoFromKey,
  githubStateReason,
  parseGithubTimestamp,
  parseRemoteSnapshot,
} from "../integrations/github-import.js";
import { mergeFetchedIssue } from "../integrations/github-inbound.js";
import {
  findOpKey,
  withOpMarker,
  type GithubIssuePatch,
  type GithubIssueWriter,
  type GithubRepoTarget,
} from "../integrations/github-issues.js";
import { pushOutcome, type GithubBudget } from "../integrations/github-push-policy.js";
import { sameRemoteState, type RemoteState, type SnapshotFields } from "./merge.js";
import {
  clearPushBlocked,
  isEmptyPushBlocked,
  isPushBlocked,
  parsePushBlocked,
  recordNoEffect,
  type PushField,
} from "./push-blocked.js";
import {
  cancelOp,
  completeOp,
  enqueueSyncOp,
  failOp,
  isArrayValuedOpKind,
  markOpAttempted,
  refuseOp,
  throttleOp,
  TaskSyncOpKindSchema,
  TaskSyncOpPayloadSchema,
  type TaskSyncOpPayload,
  type TaskSyncOpRecord,
} from "./sync-op.js";

/**
 * One outbox op, one provider round trip.
 *
 * The shape is fixed and every part of it is load-bearing:
 *
 * ```
 * lock tasksync:<taskId> → read task → decide → UNLOCK (commit)
 *   → HTTP: re-fetch, then write
 * → lock tasksync:<taskId> again → re-read → verify nothing moved → write result
 * ```
 *
 * **Two critical sections, never one.** A transaction held open across a GitHub
 * round trip pins a connection and an `xact` advisory lock for the length of a
 * third party's latency, which is what turns one slow repository into a stalled
 * drain and a blocked webhook processor. The first lock only buys a consistent
 * read; the second one is the actual serialization.
 *
 * **The re-fetch is the compare-and-swap.** GitHub offers no `If-Match` on
 * issues, so a PATCH is blind. Reading the issue immediately before writing and
 * aborting when `remote != base` is the only thing standing between a queued
 * push and a human's edit made while it sat in the queue. Aborting hands the
 * fetched issue to the ordinary import/merge path so the conflict is recorded
 * the normal way, and leaves the op pending.
 *
 * The re-fetch and `Task.pushedHash` are complements. Without the re-fetch we
 * destroy the human's edit before any webhook is classified; without the hash we
 * classify our own write as a third party's and raise a conflict against
 * ourselves. Neither substitutes for the other.
 */

/** How long a task whose conflict nobody has adjudicated waits before the op is
 *  looked at again. Deferred rather than failed: nothing was wrong with the
 *  request, and counting it would drive a queue that is merely waiting into the
 *  abandonment ceiling. */
const CONFLICT_RECHECK_SECONDS = 10 * 60;

/**
 * Tolerance on the `since` anchor for create resolution.
 *
 * `since` filters on GitHub's clock, not ours. A few seconds of skew either way
 * would hide the very issue the listing exists to find, and the cost of looking
 * slightly too far back is a handful of extra rows to scan client-side.
 */
const CREATE_RESOLUTION_SKEW_SECONDS = 60;

export type ApplyOpDeps = {
  db: DB;
  writer: GithubIssueWriter;
  /** The App's slug, for the `creator=app/<slug>` listing that resolves a create
   *  whose response was lost. */
  appSlug: string;
  /** The local write budget. Optional so a caller that owns pacing elsewhere can
   *  omit it; when present, a refusal here is a throttle and never an attempt. */
  budget?: GithubBudget;
  now?: () => Date;
};

/** Why an op was closed without ever reaching the provider. */
export type ApplyOpSkipReason =
  | "op_not_pending"
  | "task_missing"
  /** Deleted or tombstoned. The issue is not ours to keep writing to. */
  | "task_unlinked"
  /** An unadjudicated conflict; pushing over it would release a write nobody
   *  chose. Deferred, not closed. */
  | "task_in_conflict"
  | "not_linked"
  | "already_created"
  | "push_disabled"
  | "integration_revoked"
  | "fields_blocked";

export type ApplyOpOutcome =
  | {
      kind: "applied";
      opId: string;
      taskId: string;
      /** The issue already existed and was found by its op marker, so nothing
       *  was posted. */
      recovered: boolean;
      pushedHash: string;
      /** Fields whose no-effect block this push cleared. */
      cleared: PushField[];
    }
  | {
      kind: "no_effect";
      opId: string;
      taskId: string;
      /** Fields the response came back differing from what was asked for. */
      fields: PushField[];
      /** Of those, the ones that reached `PUSH_BLOCK_THRESHOLD` and stop being
       *  pushed from here on. */
      blocked: PushField[];
      pushedHash: string;
    }
  | {
      kind: "superseded";
      opId: string;
      taskId: string;
      /** `op_key`: the intent moved — a supersede rewrote the op in place while
       *  the request was in flight. `remote_base`: an inbound merge landed in the
       *  gap and wrote a newer snapshot. */
      reason: "op_key" | "remote_base";
    }
  | { kind: "aborted_to_merge"; opId: string; taskId: string; field: PushField; detail: string }
  | {
      kind: "throttled";
      opId: string;
      taskId: string;
      retryAt: Date;
      limit: "primary" | "secondary" | "local";
    }
  | { kind: "failed"; opId: string; taskId: string; attempts: number; gaveUp: boolean; error: string }
  | { kind: "refused"; opId: string; taskId: string; status: number | null; reason: string }
  | { kind: "skipped"; opId: string; taskId: string; reason: ApplyOpSkipReason };

const PUSH_TASK_SELECT = {
  id: true,
  accountId: true,
  externalId: true,
  externalKey: true,
  deletedAt: true,
  syncState: true,
  remoteSnapshot: true,
  pushBlocked: true,
  labels: { select: { label: { select: { name: true } } } },
  integrationRepo: {
    select: {
      id: true,
      integrationId: true,
      repoKey: true,
      pushEnabled: true,
      removedAt: true,
      integration: { select: { revokedAt: true } },
    },
  },
} satisfies Prisma.TaskSelect;

/** What the first critical section settled on, carried across the round trip.
 *  Nothing in here is re-read during the HTTP phase — that is the point. */
type PushPlan = {
  opKey: string;
  /** The op's first hand-off to the provider, or null if this is it. Non-null
   *  means a create's outcome is unknown and must be resolved before posting. */
  attemptedAt: Date | null;
  taskId: string;
  accountId: string;
  integrationId: string;
  integrationRepoId: string;
  repo: GithubRepoTarget;
  repoFullName: string;
  /** The exact bytes read from `remote_snapshot`, so the second critical section
   *  can tell whether an inbound merge moved the base underneath us. */
  baseJson: string;
  base: SnapshotFields | null;
  fields: PushField[];
  request: PushRequest;
};

type PushRequest =
  | { kind: "create"; title: string; body: string; labels: string[]; state: RemoteState }
  | { kind: "patch"; number: number; patch: GithubIssuePatch; state: RemoteState | null };

type Decision =
  | { kind: "push"; plan: PushPlan }
  | { kind: "stop"; outcome: ApplyOpOutcome };

export async function applyOp(
  deps: ApplyOpDeps,
  op: TaskSyncOpRecord
): Promise<ApplyOpOutcome> {
  const clock = deps.now ?? (() => new Date());

  const decision = await deps.db.$transaction((tx) => decide(tx, op, clock()));
  if (decision.kind === "stop") return decision.outcome;
  const plan = decision.plan;

  // Budget before the hand-off, so a purely local throttle never writes an
  // `attemptedAt` that would then have to be reasoned about as an unknown
  // outcome. Throttling is not failure and must not touch `attempts`.
  if (deps.budget) {
    const allowed = deps.budget.take(clock());
    if (!allowed.ok) {
      await deps.db.$transaction((tx) => throttleOp(tx, op.id, allowed.retryAt));
      return { kind: "throttled", opId: op.id, taskId: plan.taskId, retryAt: allowed.retryAt, limit: "local" };
    }
  }

  // In its own committed transaction, immediately BEFORE the call — never after.
  // The retry that has to be recovered from is the one whose request committed
  // and whose response was lost, and a timestamp written after the response is
  // exactly the one that is missing when it matters.
  //
  // First hand-off wins: it is also the `since` anchor for create resolution, and
  // re-stamping it on every retry walks the anchor past the issue the listing is
  // looking for, which is how a duplicate gets posted.
  if (plan.attemptedAt === null) {
    await deps.db.$transaction((tx) => markOpAttempted(tx, op.id, clock()));
  }

  let response: GithubIssue;
  let recovered = false;
  try {
    const sent = await send(deps, plan);
    if (sent.kind === "aborted") {
      const detail = await abortToMerge(deps, plan, sent.issue);
      return {
        kind: "aborted_to_merge",
        opId: op.id,
        taskId: plan.taskId,
        field: sent.field,
        detail,
      };
    }
    response = sent.issue;
    recovered = sent.recovered;
  } catch (err) {
    return failed(deps, plan, op.id, err, clock());
  }

  try {
    return await commit(deps, plan, op.id, response, recovered, clock());
  } catch (err) {
    return failed(deps, plan, op.id, err, clock());
  }
}

/**
 * First critical section: read the task under `tasksync:<taskId>`, settle what
 * would be sent, and commit before anything talks to GitHub.
 */
async function decide(tx: Tx, op: TaskSyncOpRecord, at: Date): Promise<Decision> {
  await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${op.taskId}`}))`;

  // Re-read under the lock rather than trusting the claimed record: an enqueue
  // can supersede an op between the claim and here, and the payload that gets
  // sent must be the current intent.
  const row = await tx.taskSyncOp.findUnique({
    where: { id: op.id },
    select: { status: true, opKey: true, payload: true, attemptedAt: true },
  });
  if (!row || row.status !== "pending") {
    return stop({ kind: "skipped", opId: op.id, taskId: op.taskId, reason: "op_not_pending" });
  }
  const payload = parsePayload(row.payload, op.payload);

  const task = await tx.task.findUnique({ where: { id: op.taskId }, select: PUSH_TASK_SELECT });
  if (!task) {
    await cancelOp(tx, op.id, "task no longer exists");
    return stop({ kind: "skipped", opId: op.id, taskId: op.taskId, reason: "task_missing" });
  }
  if (task.deletedAt !== null || task.syncState === TaskSyncStateSchema.enum.unlinked) {
    await cancelOp(tx, op.id, "task was deleted or unlinked");
    return stop({ kind: "skipped", opId: op.id, taskId: op.taskId, reason: "task_unlinked" });
  }

  // `Task.localConflict` is sticky by construction and only a person clears it.
  // Pushing over it releases a write nobody adjudicated, so the op waits instead
  // — deferred rather than failed, and deferred rather than left due, which
  // would re-claim it on every tick for ever.
  if (task.syncState === TaskSyncStateSchema.enum.conflict) {
    await throttleOp(tx, op.id, new Date(at.getTime() + CONFLICT_RECHECK_SECONDS * 1000));
    return stop({ kind: "skipped", opId: op.id, taskId: op.taskId, reason: "task_in_conflict" });
  }

  const repo = task.integrationRepo;
  if (!repo || repo.removedAt !== null) {
    await cancelOp(tx, op.id, "task is not linked to a reachable repository");
    return stop({ kind: "skipped", opId: op.id, taskId: op.taskId, reason: "not_linked" });
  }
  if (repo.integration.revokedAt !== null) {
    await cancelOp(tx, op.id, "the installation was revoked");
    return stop({ kind: "skipped", opId: op.id, taskId: op.taskId, reason: "integration_revoked" });
  }
  // Outbound consent is per repository and deliberately not implied by
  // `syncEnabled`; withdrawing it has to stop queued writes too, or the consent
  // only governs new ones.
  if (!repo.pushEnabled) {
    await cancelOp(tx, op.id, "outbound writes are off for this repository");
    return stop({ kind: "skipped", opId: op.id, taskId: op.taskId, reason: "push_disabled" });
  }

  const target = githubRepoFromKey(repo.repoKey);
  if (!target) {
    await refuseOp(tx, op.id, `repository key is not addressable: ${repo.repoKey}`);
    return stop({
      kind: "refused",
      opId: op.id,
      taskId: op.taskId,
      status: null,
      reason: "repository key is not addressable",
    });
  }

  const isCreate = payload.kind === TaskSyncOpKindSchema.enum["issue.create"];
  if (isCreate && task.externalId !== null) {
    // The local guard that stands regardless of the marker: a task holding an
    // external id has an issue, and the duplicate a second create posts is
    // public and permanent.
    await cancelOp(tx, op.id, "the task already has an issue");
    return stop({ kind: "skipped", opId: op.id, taskId: op.taskId, reason: "already_created" });
  }

  const blocked = parsePushBlocked(task.pushBlocked);
  const fields = pushFieldsOf(payload);
  // A create is never withheld for a blocked field: the block is about a value
  // the provider keeps declining on an existing issue, and there is no issue yet.
  if (!isCreate && fields.every((field) => isPushBlocked(blocked, field))) {
    await cancelOp(tx, op.id, `not accepted by the provider: ${fields.join(", ")}`);
    return stop({ kind: "skipped", opId: op.id, taskId: op.taskId, reason: "fields_blocked" });
  }

  const localLabels = [...new Set(task.labels.map((entry) => entry.label.name))].sort();
  const request = isCreate
    ? buildCreate(payload, row.opKey)
    : buildPatch(payload, task.externalKey, localLabels);
  if (request === null) {
    const reason = "the task carries no usable issue number";
    await refuseOp(tx, op.id, reason);
    return stop({ kind: "refused", opId: op.id, taskId: op.taskId, status: null, reason });
  }

  return {
    kind: "push",
    plan: {
      opKey: row.opKey,
      attemptedAt: row.attemptedAt,
      taskId: op.taskId,
      accountId: task.accountId,
      integrationId: repo.integrationId,
      integrationRepoId: repo.id,
      repo: target,
      repoFullName: `${target.owner}/${target.repo}`,
      baseJson: JSON.stringify(task.remoteSnapshot ?? null),
      base: parseRemoteSnapshot(task.remoteSnapshot),
      fields,
      request,
    },
  };
}

function stop(outcome: ApplyOpOutcome): Decision {
  return { kind: "stop", outcome };
}

/** The stored payload is authoritative — a supersede between the claim and the
 *  first critical section rewrote it in place, and the current intent is what
 *  must be sent. The claimed record is the fallback for a row whose JSON no
 *  longer parses, which `claimNextOps` would have retired anyway. */
function parsePayload(stored: unknown, claimed: TaskSyncOpPayload): TaskSyncOpPayload {
  const parsed = TaskSyncOpPayloadSchema.safeParse(stored);
  return parsed.success ? parsed.data : claimed;
}

function pushFieldsOf(payload: TaskSyncOpPayload): PushField[] {
  switch (payload.kind) {
    case "issue.create":
      // No `status`: `POST /issues` has no `state` field at all, so a create
      // cannot deliver one and must not be measured as if it had. `commit`
      // queues the state separately when the task was published closed.
      return ["title", "body", "labels"];
    case "issue.patch.title":
      return ["title"];
    case "issue.patch.body":
      return ["body"];
    case "issue.state":
      return ["status"];
    case "issue.labels":
      return ["labels"];
  }
}

function buildCreate(payload: TaskSyncOpPayload, opKey: string): PushRequest | null {
  if (payload.kind !== "issue.create") return null;
  return {
    kind: "create",
    title: payload.title,
    // The marker is what a lost response is resolved through, and it has to be
    // byte-identical across retries of one op — which it is, because an op with
    // `attemptedAt` set is never superseded and so never takes a new key.
    body: withOpMarker(payload.body, opKey),
    // A create's array is not a whole-array REPLACE — the issue does not exist
    // yet, so there is no set a stale array could roll back. It carries the set
    // the user saw on the publish form, which is the one they consented to.
    labels: payload.labels,
    state: { state: payload.state, stateReason: payload.stateReason },
  };
}

function buildPatch(
  payload: TaskSyncOpPayload,
  externalKey: string | null,
  localLabels: string[]
): PushRequest | null {
  const number = githubIssueNumberFromKey(externalKey);
  if (number === null) return null;

  switch (payload.kind) {
    case "issue.create":
      return null;
    case "issue.patch.title":
      return { kind: "patch", number, patch: { title: payload.title }, state: null };
    case "issue.patch.body":
      return { kind: "patch", number, patch: { body: payload.body }, state: null };
    case "issue.state":
      return {
        kind: "patch",
        number,
        patch: { state: payload.state, state_reason: payload.stateReason },
        state: { state: payload.state, stateReason: payload.stateReason },
      };
    case "issue.labels":
      // **Recomputed at send time, never sent as stored.** `PATCH /issues/{n}`
      // with `labels` replaces the whole array, so a delayed replay of the array
      // this op was enqueued with is a set rollback rather than a harmless
      // repeat. `isArrayValuedOpKind` is the authority on which kinds this
      // covers, so a future one cannot be missed by a name test here.
      return {
        kind: "patch",
        number,
        patch: { labels: isArrayValuedOpKind(payload.kind) ? localLabels : payload.labels },
        state: null,
      };
  }
}

type SendResult =
  | { kind: "sent"; issue: GithubIssue; recovered: boolean }
  | { kind: "aborted"; issue: GithubIssue; field: PushField };

/** The provider round trip: no database handle reaches this, by construction. */
async function send(deps: ApplyOpDeps, plan: PushPlan): Promise<SendResult> {
  if (plan.request.kind === "create") {
    if (plan.attemptedAt !== null) {
      // An earlier attempt already handed this create to GitHub and its outcome
      // is unknown: the issue may exist with nothing linking to it. The primary
      // store answers that — strongly consistent, unlike `GET /search/issues`,
      // whose index lag is worst in exactly the fast retry window that matters.
      const since = new Date(
        plan.attemptedAt.getTime() - CREATE_RESOLUTION_SKEW_SECONDS * 1000
      );
      const existing = await deps.writer.listAppIssuesSince(plan.repo, {
        appSlug: deps.appSlug,
        since,
      });
      const found = existing.find((issue) => findOpKey(issue.body) === plan.opKey);
      // A miss does not prove absence — a human can edit the marker out of the
      // body — so this is a hint, not a guard. Posting anyway is nonetheless the
      // right move: the listing THREW rather than returning short if it could not
      // be trusted (`listAppIssuesSince` fails closed on its page ceiling), so a
      // clean miss means the issue is either absent or permanently unfindable,
      // and refusing for ever would leave the task unpushable with no way back.
      // At most one duplicate can follow: this response IS observed, the task
      // takes an `externalId`, and the local guard in `decide` bars any third.
      if (found) return { kind: "sent", issue: found, recovered: true };
    }
    const created = await deps.writer.createIssue(plan.repo, {
      title: plan.request.title,
      body: plan.request.body,
      labels: plan.request.labels,
    });
    return { kind: "sent", issue: created, recovered: false };
  }

  const ref = { ...plan.repo, number: plan.request.number };
  const current = await deps.writer.getIssue(ref);

  // The compare-and-swap approximation. A base we cannot read is treated as a
  // base that moved: there is no safe way to decide a blind PATCH against
  // nothing, and the merge this aborts to is what establishes one.
  const moved = plan.base === null ? "title" : remoteMovedFrom(plan.base, current);
  if (moved !== null) return { kind: "aborted", issue: current, field: moved };

  const patched = await deps.writer.patchIssue(ref, plan.request.patch);
  return { kind: "sent", issue: patched, recovered: false };
}

/**
 * Which field of the base the remote no longer agrees with.
 *
 * `assignee` is deliberately outside the comparison. v1 never writes it, so this
 * push cannot clobber it, and resolving a provider user to a member is a
 * database lookup the HTTP phase does not have and must not acquire — the whole
 * point of the two-critical-section shape.
 */
function remoteMovedFrom(base: SnapshotFields, issue: GithubIssue): PushField | null {
  if (base.title !== issue.title) return "title";
  if (normalizeBody(base.body) !== normalizeBody(issue.body)) return "body";
  const state: RemoteState = {
    state: issue.state,
    stateReason: githubStateReason(issue.state_reason),
  };
  if (!sameRemoteState(base.status, state)) return "status";
  if (!sameLabels(base.labels, (issue.labels ?? []).map((label) => label.name))) return "labels";
  return null;
}

function normalizeBody(value: string | null | undefined): string {
  return (value ?? "").replace(/\r\n/g, "\n");
}

function sameLabels(a: readonly string[], b: readonly string[]): boolean {
  const left = new Set(a);
  const right = new Set(b);
  if (left.size !== right.size) return false;
  for (const value of left) if (!right.has(value)) return false;
  return true;
}

/** Hand the fetched issue to the ordinary import path, so a conflict raised by a
 *  push abort is recorded exactly like one raised by a webhook. The op stays
 *  pending; its lease is what keeps it from being re-claimed immediately. */
async function abortToMerge(
  deps: ApplyOpDeps,
  plan: PushPlan,
  issue: GithubIssue
): Promise<string> {
  const merged = await deps.db.$transaction((tx) =>
    mergeFetchedIssue(tx, { taskId: plan.taskId, issue })
  );
  return merged.kind === "ok" ? merged.detail : `${merged.kind}`;
}

/**
 * Second critical section: verify the row still matches what the first decided
 * on, then write the result.
 *
 * Two independent version tokens, because two different things can move in the
 * gap:
 *
 * - **`TaskSyncOp.opKey`** answers "did the intent move". A supersede rewrites
 *   the op in place and takes a FRESH key precisely so this comparison can see
 *   it; completing an op whose payload was replaced would mark the user's newer
 *   edit as delivered and drop it silently. The window is real: `decide` commits
 *   before `markOpAttempted`, and until that stamp lands an enqueue may still
 *   rewrite the row.
 * - **`Task.remoteSnapshot`** answers "did the base move". An inbound delivery
 *   landing in the gap writes a newer base, and folding our older response over
 *   it rolls the shadow copy backwards.
 *
 * On a key change the observation is still recorded when the base has not moved:
 * our write did land on GitHub, and the response is a true statement about the
 * remote. Dropping it would leave the base behind our own push, so the echo of
 * that push arrives against a stale base and merges as a third party's edit —
 * manufacturing a conflict out of our own write, which is the exact failure the
 * hash exists to prevent.
 */
async function commit(
  deps: ApplyOpDeps,
  plan: PushPlan,
  opId: string,
  response: GithubIssue,
  recovered: boolean,
  at: Date
): Promise<ApplyOpOutcome> {
  return deps.db.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${plan.taskId}`}))`;

    const row = await tx.taskSyncOp.findUnique({
      where: { id: opId },
      select: { status: true, opKey: true },
    });
    const superseded = !row || row.status !== "pending" || row.opKey !== plan.opKey;

    const task = await tx.task.findUnique({
      where: { id: plan.taskId },
      select: { remoteSnapshot: true, pushBlocked: true, deletedAt: true, syncState: true },
    });
    if (!task || task.deletedAt !== null) {
      return { kind: "skipped", opId, taskId: plan.taskId, reason: "task_missing" as const };
    }
    if (JSON.stringify(task.remoteSnapshot ?? null) !== plan.baseJson) {
      return { kind: "superseded", opId, taskId: plan.taskId, reason: "remote_base" as const };
    }

    const members = await resolveProviderIdentities(tx, {
      integrationId: plan.integrationId,
      accountId: plan.accountId,
      provider: GITHUB_PROVIDER,
      users: githubAssignees(response),
    });
    const remote = githubIssueToRemote(response, members);
    const pushedHash = githubIssueEchoHash(response);

    const observation = {
      remoteSnapshot: remote as unknown as Prisma.InputJsonValue,
      remoteUpdatedAt: parseGithubTimestamp(response.updated_at),
      syncedAt: at,
      // The hash of the RESPONSE, in the same transaction as the snapshot it was
      // taken from — one value, one write, nothing to keep in step.
      pushedHash,
      ...(plan.request.kind === "create"
        ? {
            externalProvider: GITHUB_PROVIDER,
            externalId: response.id,
            externalKey: githubIssueExternalKey(plan.repoFullName, response),
            externalUrl: response.html_url ?? null,
            integrationRepoId: plan.integrationRepoId,
          }
        : {}),
    };

    if (superseded) {
      await tx.task.update({ where: { id: plan.taskId }, data: observation });
      return { kind: "superseded", opId, taskId: plan.taskId, reason: "op_key" as const };
    }

    const noEffect = noEffectFields(plan.request, response);
    const blob = parsePushBlocked(task.pushBlocked);
    const took = plan.fields.filter((field) => !noEffect.some((entry) => entry.field === field));
    const next = clearPushBlocked(recordNoEffect(blob, noEffect, at), took);

    await tx.task.update({
      where: { id: plan.taskId },
      data: {
        ...observation,
        pushBlocked: isEmptyPushBlocked(next)
          ? Prisma.DbNull
          : (next as unknown as Prisma.InputJsonValue),
        syncState: TaskSyncStateSchema.enum.synced,
      },
    });
    await completeOp(tx, opId);

    // The state a create could not carry. Queued here rather than left to the
    // publish path because this is the only point where the intent and the
    // response are both in hand — and the `tasksync:` lock `enqueueSyncOp`
    // requires of its caller is already held. A task published closed otherwise
    // stays open on GitHub for ever, with nothing recording that it did.
    if (plan.request.kind === "create" && plan.request.state.state === "closed") {
      await enqueueSyncOp(tx, {
        taskId: plan.taskId,
        integrationId: plan.integrationId,
        provider: GITHUB_PROVIDER,
        payload: {
          kind: TaskSyncOpKindSchema.enum["issue.state"],
          state: plan.request.state.state,
          stateReason: plan.request.state.stateReason ?? null,
        },
      });
    }

    if (noEffect.length > 0) {
      const fields = noEffect.map((entry) => entry.field);
      return {
        kind: "no_effect",
        opId,
        taskId: plan.taskId,
        fields,
        blocked: fields.filter((field) => isPushBlocked(next, field)),
        pushedHash,
      };
    }
    return { kind: "applied", opId, taskId: plan.taskId, recovered, pushedHash, cleared: took.filter((field) => blob[field] !== undefined) };
  });
}

/**
 * What the response declined, field by field.
 *
 * Only a field the provider CHANGED or DROPPED shows up here. A push whose
 * target is already correct in provider space comes back exactly as asked and
 * reads as a clean success — see `push-blocked.ts` for why that blind spot is
 * deliberate and what covers it.
 */
function noEffectFields(
  request: PushRequest,
  response: GithubIssue
): { field: PushField; reason: string }[] {
  const out: { field: PushField; reason: string }[] = [];
  const asked = request.kind === "create" ? request : request.patch;

  if ("title" in asked && asked.title !== undefined && response.title !== asked.title) {
    out.push({ field: "title", reason: "GitHub stored a different title" });
  }
  if (
    "body" in asked &&
    asked.body !== undefined &&
    normalizeBody(response.body) !== normalizeBody(asked.body)
  ) {
    out.push({ field: "body", reason: "GitHub stored a different body" });
  }
  // A create's `state` is carried for the follow-up op, never sent, so comparing
  // it here would record a provider refusal for a field nobody asked for.
  const wantedState = request.kind === "create" ? null : request.state;
  if (wantedState !== null) {
    const got: RemoteState = {
      state: response.state,
      stateReason: githubStateReason(response.state_reason),
    };
    if (!sameRemoteState(wantedState, got)) {
      out.push({
        field: "status",
        reason:
          wantedState.state === got.state
            ? // The `done ↔ cancelled` case, and the reason this counter exists:
              // GitHub documents `state_reason` as ignored unless `state`
              // changes, so the edit can never be delivered by a PATCH.
              "GitHub ignores state_reason unless the open/closed state changes"
            : "GitHub kept the issue in a different state",
      });
    }
  }
  const wantedLabels = request.kind === "create" ? request.labels : request.patch.labels;
  if (wantedLabels !== undefined) {
    const got = (response.labels ?? []).map((label) => label.name);
    if (!sameLabels(wantedLabels, got)) {
      out.push({ field: "labels", reason: "GitHub returned a different label set" });
    }
  }
  return out;
}

/** Classify a thrown provider error, so a throttle can never be counted as an
 *  attempt and a permanent refusal never burns five of them. */
async function failed(
  deps: ApplyOpDeps,
  plan: PushPlan,
  opId: string,
  err: unknown,
  at: Date
): Promise<ApplyOpOutcome> {
  const message = err instanceof Error ? err.message : String(err);

  if (err instanceof GithubApiError && err.failure !== "malformed") {
    const outcome = pushOutcome({ status: err.status, headers: err.headers }, at);
    if (outcome.kind === "throttled") {
      await deps.db.$transaction((tx) => throttleOp(tx, opId, outcome.retryAt));
      return {
        kind: "throttled",
        opId,
        taskId: plan.taskId,
        retryAt: outcome.retryAt,
        limit: outcome.limit,
      };
    }
    if (outcome.kind === "refused") {
      await deps.db.$transaction((tx) => refuseOp(tx, opId, message));
      return { kind: "refused", opId, taskId: plan.taskId, status: err.status, reason: message };
    }
  }

  const result = await deps.db.$transaction((tx) => failOp(tx, opId, message));
  return {
    kind: "failed",
    opId,
    taskId: plan.taskId,
    attempts: result.attempts,
    gaveUp: result.gaveUp,
    error: message,
  };
}
