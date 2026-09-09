import type { Tx } from "../db/index.js";
import { Prisma } from "../generated/prisma/client.js";
import { githubRepoFromKey } from "../integrations/github-import.js";
import { isUuid } from "../util/uuid.js";
import { toRemote, type TaskStatus } from "./merge.js";
import { TaskSyncStateSchema } from "./sync-state.js";
import { enqueueSyncOp, TaskSyncOpKindSchema } from "./sync-op.js";

/**
 * Publishing a local task to a provider: which repositories may receive one,
 * and the single write that sends it.
 *
 * The rule the whole file exists for is that **publication is never a
 * consequence of something else**. `IntegrationRepo.publishNewByDefault`
 * positions a control the submitter can see; it is a UI hint and is deliberately
 * never read here, so an older client or a field dropped on retry fails rather
 * than posting to a public repository. The required `publish` boolean on the
 * create route is the enforcement point (`docs/tasks-and-integrations-plan.md`,
 * "Publishing a local task to GitHub").
 *
 * A publish is irreversible in the way that matters: deleting a GitHub issue is
 * admin-only and the content is already in every watcher's inbox. So every
 * refusal below is a refusal rather than a fallback.
 */


/** A repository a task may be published into, resolved to the `owner/name` the
 *  consent UI must render: what the user approves has to be what the API will
 *  address, and the project's own label is not that. */
export type PublishTarget = {
  id: string;
  owner: string;
  name: string;
  /** The raw column. Mutable on the provider, and it backs the "public if the
   *  repo is" line, so it is reported rather than interpreted. */
  visibility: string;
  /** UI hint only — the initial position of a visible toggle. Never an input to
   *  whether anything is published. */
  publishNewByDefault: boolean;
  integrationId: string;
  provider: string;
};

/**
 * The repositories of one project that can receive a new issue.
 *
 * The join is `IntegrationRepo.projectId`, and the address comes from
 * `IntegrationRepo.repoKey`, which the install flow writes from the provider's
 * own granted-repo list. **`Project.repoKey` is client-asserted** — a device can
 * claim any origin for any folder — so resolving a publish destination through
 * it would let a user address a stranger's repository.
 *
 * `pushEnabled` is required at the offer point rather than only at send time:
 * `applyOp` cancels a create for a repository whose outbound consent is off, so
 * offering such a target would show the user a choice whose outcome is a silent
 * cancellation.
 *
 * A row whose `repoKey` does not resolve is skipped rather than emitted
 * half-formed — there is no `owner/name` to put in front of the user.
 */
export async function listPublishTargets(
  tx: Tx,
  args: { accountId: string; projectId: string }
): Promise<PublishTarget[]> {
  if (!isUuid(args.projectId)) return [];
  const rows = await tx.integrationRepo.findMany({
    where: {
      projectId: args.projectId,
      removedAt: null,
      pushEnabled: true,
      integration: { accountId: args.accountId, revokedAt: null },
    },
    orderBy: { repoKey: "asc" },
    select: {
      id: true,
      repoKey: true,
      visibility: true,
      publishNewByDefault: true,
      integrationId: true,
      integration: { select: { provider: true } },
    },
  });

  return rows.flatMap((row) => {
    const ref = githubRepoFromKey(row.repoKey);
    if (ref === null) return [];
    return [
      {
        id: row.id,
        owner: ref.owner,
        name: ref.repo,
        visibility: row.visibility,
        publishNewByDefault: row.publishNewByDefault,
        integrationId: row.integrationId,
        provider: row.integration.provider,
      },
    ];
  });
}

export type PublishRefusal =
  | { kind: "publish_not_available" }
  | { kind: "publish_repo_ambiguous" }
  | { kind: "publish_repo_not_found" };

export type PublishTargetChoice = { kind: "ok"; target: PublishTarget } | PublishRefusal;

/**
 * Which repository this publish is addressed to.
 *
 * Several targets and no choice is a refusal, never a pick: there is no
 * account-level fallback repository and no "first one wins", because the one
 * thing the user has to have seen is the name of the repository the issue lands
 * in. A named id is re-resolved against this list rather than against
 * `IntegrationRepo` directly — the foreign key on `tasks.integration_repo_id`
 * proves existence and nothing about tenancy — so a repo belonging to another
 * account, another project, or a revoked installation is `not_found` and not a
 * write.
 */
export async function choosePublishTarget(
  tx: Tx,
  args: { accountId: string; projectId: string | null; repoId: string | null }
): Promise<PublishTargetChoice> {
  if (args.projectId === null) return { kind: "publish_not_available" };
  const targets = await listPublishTargets(tx, {
    accountId: args.accountId,
    projectId: args.projectId,
  });
  if (targets.length === 0) return { kind: "publish_not_available" };

  if (args.repoId !== null) {
    const chosen = targets.find((target) => target.id === args.repoId);
    return chosen ? { kind: "ok", target: chosen } : { kind: "publish_repo_not_found" };
  }
  if (targets.length > 1) return { kind: "publish_repo_ambiguous" };
  return { kind: "ok", target: targets[0]! };
}

export type PublishFields = {
  title: string;
  body: string;
  status: TaskStatus;
  /** The label NAMES the task carries after this transaction's label write —
   *  the create posts them by name, and ids mean nothing to the provider. */
  labels: readonly string[];
};

/**
 * Bind a task to a repository and queue its `issue.create`.
 *
 * **One transaction, under `pg_advisory_xact_lock(hashtext('tasksync:' ||
 * taskId))`, taken here before the columns move** — `enqueueSyncOp` requires the
 * caller to hold that key in the transaction writing the task, or two writers
 * allocate one `seq` and the provider sees this task's writes in an order
 * nothing chose. Re-taking it inside a transaction that already holds it costs
 * nothing, so callers do not have to reason about who took it first.
 *
 * **Every trace of a previous link is cleared.** Re-publishing an unlinked task
 * creates a *second* issue, so `remoteSnapshot`, the conflict blob and the
 * no-effect counters must not describe the first one — and `enqueueSyncOp`
 * refuses an `issue.create` outright while `externalId` is non-null, which makes
 * this load-bearing rather than tidiness.
 *
 * `source` is deliberately untouched: it records where the task was born, not
 * where it now lives.
 */
export async function publishTaskInTx(
  tx: Tx,
  args: { taskId: string; target: PublishTarget; fields: PublishFields }
): Promise<void> {
  const { taskId, target, fields } = args;
  await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${taskId}`}))`;

  await tx.task.update({
    where: { id: taskId },
    data: {
      integrationRepoId: target.id,
      syncState: TaskSyncStateSchema.enum.pending,
      externalProvider: null,
      externalId: null,
      externalKey: null,
      externalUrl: null,
      remoteSnapshot: Prisma.DbNull,
      remoteUpdatedAt: null,
      syncedAt: null,
      syncError: null,
      pushedHash: null,
      localConflict: Prisma.DbNull,
      pushBlocked: Prisma.DbNull,
    },
  });

  const remote = toRemote(fields.status);
  await enqueueSyncOp(tx, {
    taskId,
    integrationId: target.integrationId,
    provider: target.provider,
    payload: {
      kind: TaskSyncOpKindSchema.enum["issue.create"],
      title: fields.title,
      body: fields.body,
      state: remote.state,
      stateReason: remote.stateReason ?? null,
      labels: [...fields.labels],
    },
  });
}

/**
 * Whether a task already has an issue, or is on its way to having one.
 *
 * `unlinked` is a tombstone — the identity stays on the row so the UI can name
 * the issue it used to be — so it reads as unpublished here while `externalId`
 * is still set.
 *
 * **`pending` counts even though `externalId` is still null.** That is a create
 * already in the outbox, and one whose first attempt was handed to the provider
 * is never superseded, so a second publish would queue a second create behind an
 * unknown outcome and post a duplicate public issue. The identity arrives only
 * when the drain writes the response back, so waiting for it is waiting through
 * exactly the window that matters.
 */
export function isLinked(row: { externalId: string | null; syncState: string | null }): boolean {
  if (row.syncState === TaskSyncStateSchema.enum.pending) return true;
  return row.externalId !== null && row.syncState !== TaskSyncStateSchema.enum.unlinked;
}
