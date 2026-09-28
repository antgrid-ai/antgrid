// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { DB, Tx } from "../db/index.js";

export type BindLocalProjectArgs = {
  /** Resolved from the caller's ACTIVE membership, never from the request body.
   *  Which project the binding points at; see `userId` for who it belongs to. */
  accountId: string;
  /** The signed-in user, already proven to own `deviceId`. Recorded on the
   *  binding so a later account switch can be told from a stranger's device. */
  userId: string;
  /** Shape-gated by `util/repo-key.ts` before it gets here. */
  repoKey: string;
  displayName: string;
  /** `devices.device_id`, already proven to belong to the caller. */
  deviceId: string;
  localProjectId: string;
  localPath: string;
};

export type BindLocalProjectResult =
  | { kind: "ok"; projectId: string; bindingId: string }
  | { kind: "device_conflict" };

/**
 * Resolve-or-create the repository this checkout belongs to, then record where it
 * sits on this machine. Run inside the caller's transaction: the two writes are
 * one fact, and a project created without its binding is a repository no machine
 * can be found at.
 *
 * A machine re-binding a folder whose origin remote changed is ordinary, so the
 * binding is re-pointed at the new project rather than refused. So is a machine
 * whose ACCOUNT changed — joining or leaving a team flips `findActiveMembership`
 * without touching a single device — so a binding is re-pointed whenever its
 * existing owner is the caller's own user, and refused only when it belongs to
 * someone else.
 */
export async function bindLocalProject(
  tx: Tx,
  args: BindLocalProjectArgs
): Promise<BindLocalProjectResult> {
  const { accountId, userId, repoKey, displayName, deviceId, localProjectId, localPath } = args;

  // The tenancy check below is a check-then-act over a globally unique pair that
  // two accounts can both name, so without serialization the loser of a race
  // re-points the winner's binding — the very thing the check exists to refuse.
  // Same advisory-lock pattern as the device cap, and namespaced for the same
  // reason: `hashtext` collapses every key into one global int4 space, so a bare
  // key would contend with billing and task-number allocation.
  await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`projectbind:${deviceId}:${localProjectId}`}))`;

  const existing = await tx.projectBinding.findUnique({
    where: { deviceId_localProjectId: { deviceId, localProjectId } },
    select: { id: true, userId: true },
  });
  // A device uuid is chosen by the client at registration and unique only per
  // user, so two accounts can present the same (deviceId, localProjectId) pair —
  // and the unique index on it is global. `userId`, not `accountId`, is what
  // decides ownership here: the same person's active membership moves between
  // accounts (joining or leaving a team) with no device involved at all, and
  // that must re-point the binding rather than read as a stranger's. Only a
  // binding whose SAVED owner differs from the caller is refused — the index is
  // what makes the pair addressable at all, so this is the only place tenancy
  // can be asserted for it.
  if (existing && existing.userId !== userId) return { kind: "device_conflict" };

  const project = await tx.project.upsert({
    where: { accountId_repoKey: { accountId, repoKey } },
    // First machine to report the repository names it. Re-writing the label on
    // every bind would let each machine's folder name overwrite the last, so a
    // rename is a deliberate edit rather than a side effect of a heartbeat.
    create: { accountId, repoKey, displayName },
    update: {},
    select: { id: true },
  });

  // The other half of the repoKey join `upsertIntegrationRepo` performs: a
  // GitHub repo discovered before any machine reported this checkout has no
  // project to auto-match against yet, so catch it up now that one exists.
  // `projectId: null` keeps this from clobbering an explicit manual link.
  await tx.integrationRepo.updateMany({
    where: { integration: { accountId }, repoKey, projectId: null },
    data: { projectId: project.id },
  });

  const now = new Date();
  const binding = await tx.projectBinding.upsert({
    where: { deviceId_localProjectId: { deviceId, localProjectId } },
    create: {
      projectId: project.id,
      deviceId,
      userId,
      localProjectId,
      localPath,
      lastSeenAt: now,
    },
    // `userId` moves with the account switch this upsert exists to allow: the
    // row must record the CURRENT owner, or the next call's tenancy check
    // compares against a name that is already stale.
    update: { projectId: project.id, userId, localPath, lastSeenAt: now },
    select: { id: true },
  });

  return { kind: "ok", projectId: project.id, bindingId: binding.id };
}

export type ProjectFromRepoResult =
  | { kind: "ok"; project: { id: string; repoKey: string; displayName: string } }
  | { kind: "repo_not_found" };

/**
 * The account project for a repository its GitHub App can see, created if no
 * machine has reported a checkout of it yet.
 *
 * This is the same resolve-or-create `bindLocalProject` performs — keyed on
 * `[accountId, repoKey]`, so a machine that opens the folder later lands on the
 * row made here rather than a second one — minus the machine, which is exactly
 * what is missing. It records no binding and enables nothing: import and push
 * stay off until the user switches them on, so this changes what a task may be
 * filed against and no more.
 *
 * Scoped to the caller's account through the integration, and a repository of a
 * revoked installation, or one GitHub stopped listing, is not found: naming
 * somebody else's repo id, or a dead one, must not mint a project.
 */
export async function projectFromIntegrationRepo(
  db: DB,
  args: { accountId: string; repoId: string }
): Promise<ProjectFromRepoResult> {
  return db.$transaction(async (tx): Promise<ProjectFromRepoResult> => {
    const repo = await tx.integrationRepo.findFirst({
      where: {
        id: args.repoId,
        removedAt: null,
        integration: { accountId: args.accountId, revokedAt: null },
      },
      select: { id: true, repoKey: true, projectId: true },
    });
    if (!repo) return { kind: "repo_not_found" };

    // The label a person would give it: the last segment of the normalised key.
    const displayName = repo.repoKey.split("/").pop() || repo.repoKey;

    const project = await tx.project.upsert({
      where: { accountId_repoKey: { accountId: args.accountId, repoKey: repo.repoKey } },
      create: { accountId: args.accountId, repoKey: repo.repoKey, displayName },
      update: {},
      select: { id: true, repoKey: true, displayName: true },
    });

    // `projectId: null` in the filter keeps an explicit manual link intact.
    await tx.integrationRepo.updateMany({
      where: { id: repo.id, projectId: null },
      data: { projectId: project.id },
    });

    return { kind: "ok", project };
  });
}
