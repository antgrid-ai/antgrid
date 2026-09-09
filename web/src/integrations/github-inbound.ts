import type { z } from "zod";
import type { DB, Tx } from "../db/index.js";
import { Prisma } from "../generated/prisma/client.js";
import {
  IntegrationStatusSchema,
  resolveInstallation,
  revokeIntegration,
  upsertIntegrationRepo,
  type IntegrationRecord,
} from "../models/integration.js";
import {
  createTaskInTx,
  assigneeColumns,
  closedAtPatch,
  parseTaskStatus,
  readAssignee,
  TaskSourceSchema,
  TaskStatusSchema,
  TaskSyncStateSchema,
} from "../models/task.js";
import { getOrCreateLabel, setTaskLabelsInTx } from "../models/label.js";
import { resolveProviderIdentities } from "../models/integration-identity.js";
import { fromRemote, mergeTask, type LocalFields, type SnapshotFields } from "../tasks/merge.js";
import {
  GITHUB_HANDLED_EVENTS,
  GITHUB_PROVIDER,
  InstallationEventSchema,
  InstallationRepositoriesEventSchema,
  IssueCommentEventSchema,
  IssuesEventSchema,
  RepositoryEventSchema,
  StoredGithubDeliverySchema,
  carriesPullRequest,
  githubRepoKey,
  type GithubIssue,
  type GithubIssueComment,
  type GithubRepoRef,
} from "./github-events.js";
import { isOwnEcho } from "./github-echo.js";
import {
  DEFAULT_LABEL_COLOR,
  foldLocalConflict,
  githubAssignees,
  githubCommentAuthorLogin,
  githubCommentBody,
  githubExternalId,
  githubIssueExternalKey,
  githubIssueToRemote,
  githubLabelColors,
  isEmptyLocalConflict,
  matchesImportFilter,
  parseGithubTimestamp,
  parseLocalConflict,
  parseRemoteSnapshot,
  githubRepoFullName,
  snapshotFromLocal,
} from "./github-import.js";
import {
  MAX_WEBHOOK_ATTEMPTS,
  markDeliveryProcessed,
  recordDeliveryFailure,
} from "./webhook-events.js";

/**
 * The drain: recorded GitHub deliveries, applied one row at a time.
 *
 * **Two web instances draining at once is safe by construction, not by
 * election.** Each row is claimed under a transaction-scoped advisory lock and
 * re-read inside it, so a second drainer blocks, sees the row processed, and
 * moves on. The alternative — one `pg_try_advisory_lock` leader — is a
 * session-scoped lock taken through a *pooled* adapter: the unlock may land on a
 * different connection than the lock, at which point no instance can ever
 * acquire it again and the drain stops entirely, silently.
 */

/** `hashtext` returns int4 into one global advisory-lock namespace shared with
 *  `billing:`, `task:`, `tasksync:`, `projectbind:` and `taskrun:`, so the
 *  prefix is what keeps a webhook row from colliding with an account. */
function lockKey(eventId: string): string {
  return `ghhook:${eventId}`;
}

const DEFAULT_BATCH_SIZE = 50;

export type GithubDrainReport = {
  /** Rows the claim query returned — the ceiling on work this pass. */
  scanned: number;
  applied: number;
  /** Resolved to nothing we own, or an action with no handler: normal, and
   *  marked processed rather than retried for ever. */
  dropped: number;
  /** Another drainer had already finished the row by the time the lock was ours. */
  skipped: number;
  /** Payloads no schema accepts. Closed rather than retried — a deterministic
   *  parse failure cannot succeed on a second pass — with the reason recorded on
   *  the row. */
  invalid: number;
  failed: number;
  /** Failures that took a row to the attempt ceiling on this pass. */
  gaveUp: number;
};

export type DropReason =
  | "unknown_installation"
  | "unhandled_event"
  | "unhandled_action"
  | "unknown_repo"
  /** The repository is discovered but nobody turned import on for it. */
  | "sync_disabled"
  | "pull_request"
  /** The issue was deleted on GitHub and we deliberately kept the task — a
   *  different statement from "we did not recognize this action". */
  | "issue_deleted"
  | "filtered_out"
  /** The task exists but the user deleted or unlinked it — see `importIssue`. */
  | "task_unlinked"
  | "unknown_task"
  | "unknown_comment"
  | "comment_cap"
  /** The delivery is the echo of our own push — its normalized field set hashes
   *  equal to `Task.pushedHash`. */
  | "own_echo"
  /** A push abort handed us an issue for a task whose repository or installation
   *  no longer resolves. */
  | "unknown_integration";

type ApplyOutcome =
  | { kind: "applied"; detail: string }
  | { kind: "dropped"; reason: DropReason }
  | { kind: "invalid"; error: string };

type ClaimOutcome = ApplyOutcome | { kind: "skipped" };

/**
 * Apply every claimable GitHub delivery, oldest first.
 *
 * The claim filters on the handled event set rather than on the row alone: the
 * deferred types (`label` today) are recorded with
 * `processed_at` null on purpose, and a drain that claimed them would either
 * lose them or spin on them.
 */
export async function drainGithubWebhooks(
  db: DB,
  opts: { batchSize?: number } = {}
): Promise<GithubDrainReport> {
  const batchSize = opts.batchSize ?? DEFAULT_BATCH_SIZE;
  const claimable = await db.$queryRaw<{ id: string }[]>`
    SELECT id::text AS id
    FROM webhook_events
    WHERE provider = ${GITHUB_PROVIDER}
      AND processed_at IS NULL
      AND attempts < ${MAX_WEBHOOK_ATTEMPTS}
      AND type IN (${Prisma.join([...GITHUB_HANDLED_EVENTS])})
    ORDER BY received_at ASC
    LIMIT ${batchSize}`;

  const report: GithubDrainReport = {
    scanned: claimable.length,
    applied: 0,
    dropped: 0,
    skipped: 0,
    invalid: 0,
    failed: 0,
    gaveUp: 0,
  };

  for (const { id } of claimable) {
    try {
      const outcome = await db.$transaction(async (tx) => claimAndApply(tx, id));
      report[outcome.kind === "applied" ? "applied" : outcome.kind] += 1;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const attempts = await recordDeliveryFailure(db, id, message);
      report.failed += 1;
      if (attempts >= MAX_WEBHOOK_ATTEMPTS) {
        report.gaveUp += 1;
        // The only moment a row's abandonment is observable as it happens;
        // afterwards it is `listGivenUpDeliveries`.
        console.error(
          `[github-webhook] delivery ${id} gave up after ${attempts} attempts: ${message}`
        );
      }
    }
  }
  return report;
}

async function claimAndApply(tx: Tx, id: string): Promise<ClaimOutcome> {
  await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${lockKey(id)}))`;

  // Re-read under the lock, never before it: the row a concurrent drainer was
  // half way through looked claimable when the batch was selected.
  const row = await tx.webhookEvent.findUnique({
    where: { id },
    select: { type: true, payload: true, processedAt: true, attempts: true },
  });
  if (!row || row.processedAt !== null || row.attempts >= MAX_WEBHOOK_ATTEMPTS) {
    return { kind: "skipped" };
  }

  const stored = StoredGithubDeliverySchema.safeParse(row.payload);
  const outcome: ApplyOutcome = stored.success
    ? await applyDelivery(tx, row.type, stored.data.body)
    : { kind: "invalid", error: "payload is not a stored github delivery" };

  await markDeliveryProcessed(tx, id, outcome.kind === "invalid" ? outcome.error : undefined);
  return outcome;
}

async function applyDelivery(tx: Tx, type: string, body: unknown): Promise<ApplyOutcome> {
  switch (type) {
    case "installation":
      return applyInstallation(tx, body);
    case "installation_repositories":
      return applyInstallationRepositories(tx, body);
    case "repository":
      return applyRepository(tx, body);
    case "issues":
      return applyIssue(tx, body);
    case "issue_comment":
      return applyIssueComment(tx, body);
    default:
      return { kind: "dropped", reason: "unhandled_event" };
  }
}

/**
 * Install lifecycle.
 *
 * `created` refreshes what the install flow recorded — for an installation no
 * account has connected there is nothing to attach it to, and the delivery is
 * dropped. Suspension moves `status` and nothing else: `revokedAt` is the one
 * state that never lifts, and `resolveInstallation` deliberately carries no
 * status filter so an `unsuspend` can still route and lift it.
 */
async function applyInstallation(tx: Tx, body: unknown): Promise<ApplyOutcome> {
  const parsed = InstallationEventSchema.safeParse(body);
  if (!parsed.success) return invalid("installation", parsed.error);

  const integration = await resolveInstallation(tx, GITHUB_PROVIDER, parsed.data.installation.id);
  if (!integration) return { kind: "dropped", reason: "unknown_installation" };

  switch (parsed.data.action) {
    case "created": {
      const login = parsed.data.installation.account?.login;
      await tx.integration.update({
        where: { id: integration.id },
        data: {
          status: IntegrationStatusSchema.enum.active,
          ...(login ? { displayName: login } : {}),
        },
      });
      const repos = parsed.data.repositories ?? [];
      for (const repo of repos) await recordRepo(tx, integration, repo);
      return { kind: "applied", detail: `installation.created repos=${repos.length}` };
    }
    case "deleted": {
      await revokeIntegration(tx, integration.accountId, integration.id);
      return { kind: "applied", detail: "installation.deleted" };
    }
    case "suspend":
    case "unsuspend": {
      const status =
        parsed.data.action === "suspend"
          ? IntegrationStatusSchema.enum.suspended
          : IntegrationStatusSchema.enum.active;
      await tx.integration.update({ where: { id: integration.id }, data: { status } });
      return { kind: "applied", detail: `installation.${parsed.data.action}` };
    }
    default:
      return { kind: "dropped", reason: "unhandled_action" };
  }
}

/** Repositories entering or leaving the installation. Both arrays are applied
 *  whatever `action` says — a payload carries the one that moved, and trusting
 *  presence rather than the label keeps a mixed delivery correct. */
async function applyInstallationRepositories(tx: Tx, body: unknown): Promise<ApplyOutcome> {
  const parsed = InstallationRepositoriesEventSchema.safeParse(body);
  if (!parsed.success) return invalid("installation_repositories", parsed.error);

  const integration = await resolveInstallation(tx, GITHUB_PROVIDER, parsed.data.installation.id);
  if (!integration) return { kind: "dropped", reason: "unknown_installation" };

  const added = parsed.data.repositories_added ?? [];
  const removed = parsed.data.repositories_removed ?? [];
  for (const repo of added) await recordRepo(tx, integration, repo);
  for (const repo of removed) await stopSyncing(tx, integration.id, repo.id);

  return {
    kind: "applied",
    detail: `installation_repositories added=${added.length} removed=${removed.length}`,
  };
}

/**
 * Rename, transfer, and the visibility flip.
 *
 * `visibility` backs the "public if the repo is" line in the publish consent, so
 * a private → public flip retroactively exposes every issue published under the
 * opposite assurance: the column has to be right here even though telling the
 * user is a later phase's job. It is written even when the new name cannot be
 * folded into a repoKey, since a name we refuse must not also cost us the flip.
 */
async function applyRepository(tx: Tx, body: unknown): Promise<ApplyOutcome> {
  const parsed = RepositoryEventSchema.safeParse(body);
  if (!parsed.success) return invalid("repository", parsed.error);

  const integration = await resolveInstallation(tx, GITHUB_PROVIDER, parsed.data.installation.id);
  if (!integration) return { kind: "dropped", reason: "unknown_installation" };

  const repo = parsed.data.repository;
  const existing = await tx.integrationRepo.findUnique({
    where: {
      integrationId_externalRepoId: {
        integrationId: integration.id,
        externalRepoId: repo.id,
      },
    },
    select: { id: true },
  });
  if (!existing) return { kind: "dropped", reason: "unknown_repo" };

  if (parsed.data.action === "deleted") {
    await stopSyncing(tx, integration.id, repo.id);
    return { kind: "applied", detail: "repository.deleted" };
  }

  const visibility = repo.private ? "private" : "public";
  const repoKey = githubRepoKey(repo.full_name);
  await tx.integrationRepo.update({
    where: { id: existing.id },
    data: { visibility, ...(repoKey ? { repoKey } : {}) },
  });
  return { kind: "applied", detail: `repository.${parsed.data.action} visibility=${visibility}` };
}

/**
 * Record a repository the App has access to.
 *
 * `syncEnabled: false` because discovery is not consent — the row exists so the
 * settings screen can offer the repository, and importing starts when the user
 * says so. `upsertIntegrationRepo` applies every consent on create only, which
 * is what stops a re-discovery from resetting a choice already made.
 */
async function recordRepo(
  tx: Tx,
  integration: IntegrationRecord,
  repo: GithubRepoRef
): Promise<boolean> {
  const repoKey = githubRepoKey(repo.full_name);
  if (!repoKey) return false;
  const result = await upsertIntegrationRepo(tx, {
    accountId: integration.accountId,
    integrationId: integration.id,
    repoKey,
    externalRepoId: repo.id,
    visibility: repo.private ? "private" : "public",
    syncEnabled: false,
  });
  return result.kind === "ok";
}

/**
 * Losing access is never a delete: tasks imported through the repository point
 * at this row, and `Task.integrationRepoId` is ON DELETE SET NULL — deleting
 * would strip the provenance the UI needs to say where a task came from.
 *
 * `removedAt` is stamped alongside because `syncEnabled: false` on its own is
 * the same row the user's own toggle produces, and the settings page has to
 * tell the two apart to explain an off state nobody chose.
 */
async function stopSyncing(tx: Tx, integrationId: string, externalRepoId: string): Promise<void> {
  await tx.integrationRepo.updateMany({
    where: { integrationId, externalRepoId },
    data: { syncEnabled: false, removedAt: new Date() },
  });
}

/**
 * The one-way import: a GitHub issue becomes, or updates, an Antgrid task.
 *
 * Everything below runs inside the delivery's own transaction, so it inherits
 * the `ghhook:` claim — which serializes drainers against each other and says
 * nothing about the other consumer of a task row. The `tasksync:` lock taken in
 * `mergeImportedTask` is what `src/tasks/merge.ts` requires of every caller, and
 * it is the only thing standing between this path and phase 5's outbox raising
 * a conflict against our own in-flight write.
 *
 * Every refusal on the way in is a DROP that marks the delivery processed, never
 * a throw. A payload we deliberately do not want is not a transient failure, and
 * retrying it five times only delays the same answer while burning the ceiling
 * a genuinely broken delivery needs.
 */

export const IMPORT_REPO_SELECT = {
  id: true,
  projectId: true,
  syncEnabled: true,
  importFilterKind: true,
  importFilterValue: true,
  commentImportCap: true,
} satisfies Prisma.IntegrationRepoSelect;

const IMPORT_TASK_SELECT = {
  id: true,
  projectId: true,
  title: true,
  body: true,
  status: true,
  assigneeUserId: true,
  assigneeExternalId: true,
  assigneeLogin: true,
  assigneeAvatarUrl: true,
  remoteSnapshot: true,
  localConflict: true,
  pushedHash: true,
  labels: { select: { label: { select: { name: true } } } },
} satisfies Prisma.TaskSelect;

export type ImportRoute = {
  integration: IntegrationRecord;
  repo: Prisma.IntegrationRepoGetPayload<{ select: typeof IMPORT_REPO_SELECT }>;
  repositoryFullName: string;
};

type IssueRoutingEvent = {
  installation: { id: string };
  repository: GithubRepoRef;
  issue: GithubIssue;
};

export type ImportIssueOutcome =
  /** `created` tells the two success paths apart without reading `detail`, which
   *  is a log line and not a contract. The reconcile poll counts a first import
   *  and a merge separately — one is a new task in a user's list, the other is
   *  usually nothing changing at all. */
  | { kind: "ok"; taskId: string; created: boolean; detail: string }
  | { kind: "dropped"; reason: DropReason }
  | { kind: "invalid"; error: string };

/** Prisma's `InputJsonValue` is a structural union a declared `interface` cannot
 *  satisfy — it has no index signature — so a snapshot crosses the boundary as a
 *  value rather than as its type. */
function asJson(value: unknown): Prisma.InputJsonValue {
  return value as Prisma.InputJsonValue;
}

/**
 * Where an issue-bearing delivery is allowed to land, in the order that makes
 * each refusal cheapest to explain.
 *
 * `resolveInstallation` is the only inbound routing key there is — never
 * `externalAccountId`, never `repoKey` — and the repository is then looked up
 * inside that installation, so a payload can only ever reach repositories of the
 * account it resolved to.
 */
async function routeIssue(
  tx: Tx,
  event: IssueRoutingEvent
): Promise<{ kind: "ok"; route: ImportRoute } | { kind: "dropped"; reason: DropReason }> {
  const integration = await resolveInstallation(tx, GITHUB_PROVIDER, event.installation.id);
  if (!integration) return { kind: "dropped", reason: "unknown_installation" };

  const repo = await tx.integrationRepo.findUnique({
    where: {
      integrationId_externalRepoId: {
        integrationId: integration.id,
        externalRepoId: event.repository.id,
      },
    },
    select: IMPORT_REPO_SELECT,
  });
  if (!repo) return { kind: "dropped", reason: "unknown_repo" };

  // Discovery is not consent: `recordRepo` writes every repository the App can
  // see with sync off, so the row existing says only that we can see it.
  if (!repo.syncEnabled) return { kind: "dropped", reason: "sync_disabled" };

  // GitHub models pull requests as issues and delivers them on this event; the
  // only discriminator is the key's presence. Unfiltered, every PR in the
  // repository becomes a task and buries the list this feature exists to keep
  // scannable.
  if (carriesPullRequest(event)) return { kind: "dropped", reason: "pull_request" };

  return {
    kind: "ok",
    route: { integration, repo, repositoryFullName: event.repository.full_name },
  };
}

/**
 * An `issues` delivery.
 *
 * Deliberately not switched on `action`. The payload carries the whole issue
 * whichever field moved, so every action but one is the same merge over the same
 * object — and an action GitHub invents next year is then handled the day it
 * ships instead of silently dropped as unrecognized.
 *
 * `deleted` is the exception, and it is a drop rather than a local delete:
 * removing a task because its issue vanished discards whatever local edits,
 * runs and comments it accumulated, and nothing in a one-way import earns that.
 */
async function applyIssue(tx: Tx, body: unknown): Promise<ApplyOutcome> {
  const parsed = IssuesEventSchema.safeParse(body);
  if (!parsed.success) return invalid("issues", parsed.error);
  if (parsed.data.action === "deleted") return { kind: "dropped", reason: "issue_deleted" };

  const routed = await routeIssue(tx, parsed.data);
  if (routed.kind !== "ok") return routed;

  const result = await importIssue(tx, routed.route, parsed.data.issue);
  if (result.kind !== "ok") return result;
  return { kind: "applied", detail: `issues.${parsed.data.action} ${result.detail}` };
}

/**
 * The task behind one issue: created if this account has never seen it, merged
 * if it has.
 *
 * The lookup is the `[accountId, externalProvider, externalId]` unique and
 * nothing else — the schema calls that "the whole inbound idempotency
 * mechanism", and a second lookup keyed on anything else is how one issue
 * becomes two tasks.
 *
 * Exported because the reconcile poll (`github-poll.ts`) imports a LISTED issue
 * through this same function rather than through a copy: the
 * `[accountId, externalProvider, externalId]` lookup, the `taskimport:` lock,
 * the import filter, the tombstone filter and the assignee resolution are the
 * whole idempotency mechanism, and a second implementation of them is two
 * answers to "have we seen this issue" that can drift apart silently.
 */
export async function importIssue(
  tx: Tx,
  route: ImportRoute,
  issue: GithubIssue
): Promise<ImportIssueOutcome> {
  const accountId = route.integration.accountId;
  const externalId = githubExternalId(issue);

  // Once per delivery, before anything reads an assignee. Both the import
  // filter and the snapshot mapping need the same answer, and resolving twice
  // would mean two chances to disagree about who a login is.
  const members = await resolveProviderIdentities(tx, {
    integrationId: route.integration.id,
    accountId,
    provider: GITHUB_PROVIDER,
    users: githubAssignees(issue),
  });

  const context = {
    remote: githubIssueToRemote(issue, members),
    remoteUpdatedAt: parseGithubTimestamp(issue.updated_at),
    now: new Date(),
  };

  // Serializes the does-it-exist-yet question across drainers. The delivery's
  // own `ghhook:` lock keys on the delivery, not the issue, so two instances
  // holding two deliveries for the SAME new issue both read "absent" and both
  // create; the second then dies on `tasks_account_external_key` and aborts a
  // transaction Postgres will not let the JS catch rescue. That is self-healing
  // — the retry finds the task and merges — but it burns one of five attempts
  // for something a lock costs nothing to prevent. Taken before the read, and
  // after `ghhook:` on every path, so the order can never invert.
  await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`taskimport:${accountId}:${externalId}`}))`;

  const found = await tx.task.findFirst({
    where: { accountId, externalProvider: GITHUB_PROVIDER, externalId },
    select: { id: true, deletedAt: true, syncState: true },
  });

  // A deleted task keeps its external identity precisely so this lookup still
  // resolves, and `softDeleteTask` says the tombstone is only half the
  // protection — this filter is the other half. Without it the next remote edit
  // re-animates a task the user believes is gone, and importing a fresh one
  // instead is impossible anyway: the tombstone still holds the unique key.
  if (found && (found.deletedAt !== null || found.syncState === TaskSyncStateSchema.enum.unlinked)) {
    return { kind: "dropped", reason: "task_unlinked" };
  }

  if (!found) {
    // The filter bounds what a repository may pull IN, and is asked once, on the
    // way in. A task already imported and then relabelled out of scope keeps
    // receiving updates on purpose: a task that silently stops tracking its
    // issue is a worse outcome than one that arguably should not have been
    // imported, and only the second is visible to the user.
    if (!matchesImportFilter(route.repo, issue, members)) {
      return { kind: "dropped", reason: "filtered_out" };
    }
    return createImportedTask(tx, route, issue, externalId, context);
  }

  return mergeImportedTask(tx, route, issue, found.id, context);
}

type ImportContext = {
  remote: SnapshotFields;
  remoteUpdatedAt: Date | null;
  now: Date;
};

async function createImportedTask(
  tx: Tx,
  route: ImportRoute,
  issue: GithubIssue,
  externalId: string,
  context: ImportContext
): Promise<ImportIssueOutcome> {
  const accountId = route.integration.accountId;
  const labelIds = await resolveRemoteLabels(tx, {
    accountId,
    projectId: route.repo.projectId,
    names: context.remote.labels,
    colors: githubLabelColors(issue),
  });

  const created = await createTaskInTx(tx, {
    accountId,
    // `Task.createdBy` is a foreign key to a real user and an issue's GitHub
    // author is not one. The installer is the closest true statement available:
    // this task exists because they connected the repository.
    createdBy: route.integration.installedBy,
    title: issue.title,
    body: context.remote.body,
    status: fromRemote(context.remote.status, TaskStatusSchema.enum.open),
    // The repository's project, so the task and its repo-scoped labels share one
    // scope — `resolveLabelIds` refuses a project label on a task filed
    // elsewhere, so the two cannot be chosen independently.
    projectId: route.repo.projectId,
    assignee: context.remote.assignee,
    labelIds,
    source: TaskSourceSchema.enum.github,
  });
  if (created.kind !== "ok") {
    return { kind: "invalid", error: `issues: create refused (${created.kind})` };
  }

  // Provenance is a security property here, not a display field. The app's
  // launch sheet reads `source` and the external columns to decide a body is
  // untrusted and must be shown to a human before it becomes an agent's opening
  // instruction (`app/lib/providers/task_launcher.dart`, `taskLaunchBrief`).
  // Left at `local`, that mitigation turns off silently.
  //
  // Two statements rather than one because `createTaskInTx` owns the number
  // allocation and the sort key and models nothing about a provider link; both
  // land in the delivery's transaction, so no reader ever sees the gap.
  await tx.task.update({
    where: { id: created.task.id },
    data: {
      integrationRepoId: route.repo.id,
      externalProvider: GITHUB_PROVIDER,
      externalId,
      externalKey: githubIssueExternalKey(route.repositoryFullName, issue),
      externalUrl: issue.html_url ?? null,
      remoteSnapshot: asJson(context.remote),
      remoteUpdatedAt: context.remoteUpdatedAt,
      syncedAt: context.now,
      syncState: TaskSyncStateSchema.enum.synced,
    },
  });

  return {
    kind: "ok",
    taskId: created.task.id,
    created: true,
    detail: `imported #${issue.number}`,
  };
}

async function mergeImportedTask(
  tx: Tx,
  route: ImportRoute,
  issue: GithubIssue,
  taskId: string,
  context: ImportContext
): Promise<ImportIssueOutcome> {
  // Required of every caller by `src/tasks/merge.ts`. The delivery's own
  // `ghhook:` lock serializes drainers and nothing else; this one serializes the
  // read-merge-write against phase 5's outbox, which is the consumer that turns
  // an unlocked merge into a conflict raised against our own push.
  await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${taskId}`}))`;

  // Read under the lock, never before it — the row a concurrent consumer was
  // half way through is exactly the one the routing lookup just saw.
  const row = await tx.task.findUnique({ where: { id: taskId }, select: IMPORT_TASK_SELECT });
  if (!row) return { kind: "dropped", reason: "unknown_task" };

  // Our own write coming back. The key is WHAT was written, never when: the
  // obvious `updated_at` scheme drops a human's edit that our blind PATCH
  // clobbered a second earlier, records no conflict, and cannot be recovered by
  // a later poll because remote and base then agree. So anything whose field set
  // hashes differently is a third party's write and is merged **however old its
  // timestamp** — see `github-echo.ts`.
  //
  // Not cleared on a match, so a GitHub redelivery of the same echo is dropped
  // too; cleared below by the next merge that actually applies a remote change,
  // because after that the last thing both sides agreed on is no longer our push.
  if (isOwnEcho(row.pushedHash, issue)) return { kind: "dropped", reason: "own_echo" };

  const local: LocalFields = {
    title: row.title,
    body: row.body,
    status: parseTaskStatus(row.status) ?? TaskStatusSchema.enum.open,
    labels: row.labels.map((entry) => entry.label.name),
    assignee: readAssignee(row),
  };

  // An unreadable snapshot is an ABSENT one: there is no safe way to merge
  // against a base we cannot read, and pretending otherwise picks a winner
  // silently. Absent means the remote is taken wholesale, which is the correct
  // first-sync behaviour and the reason the substitute base is derived from
  // `local` rather than from `remote` — see `snapshotFromLocal`.
  const base = parseRemoteSnapshot(row.remoteSnapshot) ?? snapshotFromLocal(local);
  const result = mergeTask({ base, local, remote: context.remote });

  // `result.push` and `result.labelsPush` are dropped on purpose. 4c is a
  // one-way import and phase 5's outbox owns the outbound half; nothing is lost
  // by ignoring them, since both are recomputable from the row and the snapshot
  // this write leaves behind. Read the omission as deliberate, not as a bug.
  const conflict = foldLocalConflict(parseLocalConflict(row.localConflict), result, context.now);
  const { apply } = result;
  const appliedRemoteChange = Object.keys(apply).length > 0;

  await tx.task.update({
    where: { id: taskId },
    data: {
      ...(apply.title === undefined ? {} : { title: apply.title }),
      ...(apply.body === undefined ? {} : { body: apply.body }),
      ...(apply.status === undefined
        ? {}
        : { status: apply.status, ...closedAtPatch(apply.status, row.status) }),
      ...(apply.assignee === undefined ? {} : assigneeColumns(apply.assignee)),
      // Re-stated on every merge so a task linked before a column existed, or by
      // a path that set fewer of them, converges rather than staying half-linked.
      integrationRepoId: route.repo.id,
      externalKey: githubIssueExternalKey(route.repositoryFullName, issue),
      externalUrl: issue.html_url ?? null,
      remoteSnapshot: asJson(context.remote),
      remoteUpdatedAt: context.remoteUpdatedAt,
      syncedAt: context.now,
      // A remote change landed, so the last agreed state is no longer the push
      // `pushedHash` describes and keeping it would suppress a genuine later
      // delivery. A merge that applied nothing leaves it, so an echo redelivered
      // twice is dropped twice.
      ...(appliedRemoteChange ? { pushedHash: null } : {}),
      localConflict: isEmptyLocalConflict(conflict) ? Prisma.DbNull : asJson(conflict),
      // Sticky by construction: the blob accumulates and only the UI clears it,
      // so an unresolved conflict cannot be downgraded to `synced` by the next
      // clean delivery — which in phase 5 would release a push over an edit
      // nobody ever adjudicated. `labelRemoveWins` deliberately does not count:
      // it is a marker, not a conflict.
      syncState:
        Object.keys(conflict.conflicts).length > 0
          ? TaskSyncStateSchema.enum.conflict
          : TaskSyncStateSchema.enum.synced,
    },
  });

  if (result.labelsChanged && apply.labels) {
    // Scoped by the TASK's project, not the repository's: a task re-filed
    // elsewhere still has to satisfy `resolveLabelIds`, which refuses a project
    // label belonging to a project the task is not in.
    const labelIds = await resolveRemoteLabels(tx, {
      accountId: route.integration.accountId,
      projectId: row.projectId,
      names: apply.labels,
      colors: githubLabelColors(issue),
    });
    const set = await setTaskLabelsInTx(tx, {
      accountId: route.integration.accountId,
      taskId,
      labelIds,
    });
    if (set.kind !== "ok") return { kind: "invalid", error: `issues: labels refused (${set.kind})` };
  }

  return { kind: "ok", taskId, created: false, detail: `merged #${issue.number}` };
}

/**
 * Merge an issue this service fetched itself, rather than one a webhook carried.
 *
 * The outbox's pre-push re-fetch is the only caller: when the remote no longer
 * equals the base, the push is abandoned and the fetched issue comes here so the
 * conflict is recorded by the SAME code that records a webhook's, with the same
 * lock, the same `localConflict` accumulation and the same stickiness. A second
 * merge implementation for the outbound direction is two three-way merges that
 * can disagree about who won.
 *
 * The route is rebuilt from the TASK's own repository rather than from anything
 * the caller supplies, and the integration is re-resolved through
 * `resolveInstallation` — which carries the `revokedAt` filter, so an issue
 * fetched just before an uninstall is dropped instead of merged into a link the
 * account no longer has.
 */
export async function mergeFetchedIssue(
  tx: Tx,
  args: { taskId: string; issue: GithubIssue }
): Promise<ImportIssueOutcome> {
  const task = await tx.task.findUnique({
    where: { id: args.taskId },
    select: { integrationRepoId: true },
  });
  if (!task?.integrationRepoId) return { kind: "dropped", reason: "unknown_task" };

  const repo = await tx.integrationRepo.findUnique({
    where: { id: task.integrationRepoId },
    select: { ...IMPORT_REPO_SELECT, repoKey: true, integration: { select: { installationId: true } } },
  });
  if (!repo) return { kind: "dropped", reason: "unknown_repo" };

  // An integration with no installation id was never completed against GitHub,
  // so there is nothing to route through and nothing to merge into.
  const installationId = repo.integration.installationId;
  const integration = installationId
    ? await resolveInstallation(tx, GITHUB_PROVIDER, installationId)
    : null;
  if (!integration) return { kind: "dropped", reason: "unknown_integration" };

  const repositoryFullName = githubRepoFullName(repo.repoKey);
  if (repositoryFullName === null) return { kind: "dropped", reason: "unknown_repo" };

  const members = await resolveProviderIdentities(tx, {
    integrationId: integration.id,
    accountId: integration.accountId,
    provider: GITHUB_PROVIDER,
    users: githubAssignees(args.issue),
  });

  return mergeImportedTask(
    tx,
    { integration, repo, repositoryFullName },
    args.issue,
    args.taskId,
    {
      remote: githubIssueToRemote(args.issue, members),
      remoteUpdatedAt: parseGithubTimestamp(args.issue.updated_at),
      now: new Date(),
    }
  );
}

/** Remote label names → local label ids, creating what this account has not seen.
 *  A name the local vocabulary cannot hold is skipped rather than failing the
 *  delivery: GitHub caps its own names at 50 too, so such a name could never
 *  round-trip, and the issue itself still deserves to import. */
async function resolveRemoteLabels(
  tx: Tx,
  args: {
    accountId: string;
    projectId: string | null;
    names: readonly string[];
    colors: Map<string, string>;
  }
): Promise<string[]> {
  const ids: string[] = [];
  for (const name of args.names) {
    const label = await getOrCreateLabel(tx, {
      accountId: args.accountId,
      projectId: args.projectId,
      name,
      // Only a label this account has never seen takes its colour from the
      // payload; an existing row keeps the one it has, so an import cannot
      // repaint a label somebody recoloured.
      color: args.colors.get(name) ?? DEFAULT_LABEL_COLOR,
    });
    if (label.kind === "ok") ids.push(label.label.id);
  }
  return ids;
}

/**
 * An `issue_comment` delivery.
 *
 * The comment's own payload embeds the whole issue, so a comment can be the
 * first delivery we ever successfully process for it — the `issues` event that
 * opened it may have arrived while the repository was still disabled, or given
 * up at the attempt ceiling. Importing the embedded issue first is what stops a
 * thread being dropped for want of a parent that will never be redelivered.
 */
async function applyIssueComment(tx: Tx, body: unknown): Promise<ApplyOutcome> {
  const parsed = IssueCommentEventSchema.safeParse(body);
  if (!parsed.success) return invalid("issue_comment", parsed.error);

  const action = parsed.data.action;
  if (action !== "created" && action !== "edited" && action !== "deleted") {
    return { kind: "dropped", reason: "unhandled_action" };
  }

  const routed = await routeIssue(tx, parsed.data);
  if (routed.kind !== "ok") return routed;

  const issue = await importIssue(tx, routed.route, parsed.data.issue);
  if (issue.kind !== "ok") return issue;

  return applyComment(tx, routed.route, issue.taskId, parsed.data.comment, action);
}

async function applyComment(
  tx: Tx,
  route: ImportRoute,
  taskId: string,
  comment: GithubIssueComment,
  action: "created" | "edited" | "deleted"
): Promise<ApplyOutcome> {
  const externalId = githubExternalId(comment);
  const existing = await tx.taskComment.findFirst({
    where: { taskId, externalId },
    select: { id: true },
  });

  if (action === "deleted") {
    if (!existing) return { kind: "dropped", reason: "unknown_comment" };
    // Soft, never a row delete: `[taskId, externalId]` is what makes a
    // redelivery idempotent, and removing the row lets the same comment import
    // again as a brand-new one.
    await tx.taskComment.update({ where: { id: existing.id }, data: { deletedAt: new Date() } });
    return { kind: "applied", detail: "issue_comment.deleted" };
  }

  const fields = {
    body: githubCommentBody(comment),
    // No provider-identity → member mapping exists, so the author is a
    // display-only snapshot and `authorUserId` stays null — the same shape the
    // external assignee takes.
    authorExternalLogin: githubCommentAuthorLogin(comment),
  };

  // An edit to a comment already imported always applies: the cap bounds how
  // much third-party text a thread pulls in, and refusing an edit would leave a
  // stale body rather than saving anything.
  if (existing) {
    await tx.taskComment.update({ where: { id: existing.id }, data: fields });
    return { kind: "applied", detail: `issue_comment.${action} updated` };
  }

  // `commentImportCap` is read as per TASK, not per repository. The column lives
  // on the repository because that is where the consent lives, but the quantity
  // it bounds is a thread: the plan's rationale is one provider page of comments
  // per issue, and a page is per issue too, so the API-budget argument lands on
  // the same number applied per task. Read as a repository-wide total it would
  // instead mean the 101st issue imports no comments at all, which no part of
  // the plan asks for and which nothing in the UI could explain.
  const imported = await tx.taskComment.count({
    where: { taskId, deletedAt: null, externalId: { not: null } },
  });
  if (imported >= route.repo.commentImportCap) return { kind: "dropped", reason: "comment_cap" };

  await tx.taskComment.create({ data: { taskId, externalId, ...fields } });
  return { kind: "applied", detail: `issue_comment.${action} imported` };
}

function invalid(event: string, error: z.ZodError): ApplyOutcome {
  const detail = error.issues
    .slice(0, 3)
    .map((issue) => `${issue.path.join(".") || "<root>"}: ${issue.message}`)
    .join("; ");
  return { kind: "invalid", error: `${event}: ${detail}` };
}
