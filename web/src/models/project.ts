import type { Tx } from "../db/index.js";

export type BindLocalProjectArgs = {
  /** Resolved from the caller, never from the request body. */
  accountId: string;
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
 * binding is re-pointed at the new project rather than refused.
 */
export async function bindLocalProject(
  tx: Tx,
  args: BindLocalProjectArgs
): Promise<BindLocalProjectResult> {
  const { accountId, repoKey, displayName, deviceId, localProjectId, localPath } = args;

  // The tenancy check below is a check-then-act over a globally unique pair that
  // two accounts can both name, so without serialization the loser of a race
  // re-points the winner's binding — the very thing the check exists to refuse.
  // Same advisory-lock pattern as the device cap, and namespaced for the same
  // reason: `hashtext` collapses every key into one global int4 space, so a bare
  // key would contend with billing and task-number allocation.
  await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`projectbind:${deviceId}:${localProjectId}`}))`;

  const existing = await tx.projectBinding.findUnique({
    where: { deviceId_localProjectId: { deviceId, localProjectId } },
    select: { id: true, project: { select: { accountId: true } } },
  });
  // A device uuid is chosen by the client at registration and unique only per
  // user, so two accounts can present the same (deviceId, localProjectId) pair —
  // and the unique index on it is global. Without this check the second caller's
  // upsert would silently re-point the first account's binding at its own
  // project. Refuse instead; the index is what makes the pair addressable at all,
  // so this is the only place tenancy can be asserted for it.
  if (existing && existing.project.accountId !== accountId) return { kind: "device_conflict" };

  const project = await tx.project.upsert({
    where: { accountId_repoKey: { accountId, repoKey } },
    // First machine to report the repository names it. Re-writing the label on
    // every bind would let each machine's folder name overwrite the last, so a
    // rename is a deliberate edit rather than a side effect of a heartbeat.
    create: { accountId, repoKey, displayName },
    update: {},
    select: { id: true },
  });

  const now = new Date();
  const binding = await tx.projectBinding.upsert({
    where: { deviceId_localProjectId: { deviceId, localProjectId } },
    create: {
      projectId: project.id,
      deviceId,
      localProjectId,
      localPath,
      lastSeenAt: now,
    },
    update: { projectId: project.id, localPath, lastSeenAt: now },
    select: { id: true },
  });

  return { kind: "ok", projectId: project.id, bindingId: binding.id };
}
