import { z } from "zod";
import type { DB, Tx } from "../db/index.js";
import type { Prisma } from "../generated/prisma/client.js";
import { isValidRepoKey } from "../util/repo-key.js";
import { isUuid } from "../util/uuid.js";

/**
 * Integrations: a provider account connected to an Antgrid account, and the
 * repositories inside it.
 *
 * Two rules govern everything here, and they pull in opposite directions.
 *
 * **Outbound-facing reads are account-scoped.** Prisma foreign keys enforce
 * existence, not tenancy — an `integrationId` or repo id from another account is
 * a perfectly valid FK — so every id that arrives from a caller is re-resolved
 * under the caller's `accountId` before it reaches a write, exactly as
 * `models/task.ts` does.
 *
 * **The one inbound read cannot be.** A webhook carries no `accountId`, so
 * `resolveInstallation` has nothing to scope by and must key on something
 * globally unique instead. That function is the single point where a
 * cross-tenant write is prevented; the comment on it says why.
 */

/** Text in the column so a second adapter is a code change rather than a
 *  migration; an enum here so a typo is a refusal rather than a row nothing
 *  will ever route to. */
export const IntegrationProviderSchema = z.enum(["github"]);
export type IntegrationProvider = z.infer<typeof IntegrationProviderSchema>;

/** `suspended` is the provider's own state — a GitHub App installation can be
 *  suspended without being removed — and is not the same as revoked: a
 *  suspension lifts, `revokedAt` never does. */
export const IntegrationStatusSchema = z.enum(["active", "suspended", "revoked"]);
export type IntegrationStatus = z.infer<typeof IntegrationStatusSchema>;

/** Mirrors `integration_repos.visibility`, which the publish consent UI reads
 *  to promise "public if the repo is". */
export const RepoVisibilitySchema = z.enum(["public", "private"]);
export type RepoVisibility = z.infer<typeof RepoVisibilitySchema>;

export const ImportFilterKindSchema = z.enum(["all", "label", "milestone", "assigned_to_member"]);
export type ImportFilterKind = z.infer<typeof ImportFilterKindSchema>;

/** One provider page of comments per issue. The ceiling is an abuse bound and
 *  not a policy — the column exists precisely so the one repository that needs
 *  more can have it — but an unbounded int here is an unbounded import. */
export const CommentImportCapSchema = z.int().min(0).max(10_000);

/** The two halves are one value: `all` and `assigned_to_member` name nothing to
 *  filter on, `label` and `milestone` are meaningless without a name. Modelling
 *  them as a pair is what keeps this in step with
 *  `integration_repos_import_filter_check`, which refuses the other combinations
 *  in the database. */
export type ImportFilter =
  | { kind: "all" | "assigned_to_member"; value: null }
  | { kind: "label" | "milestone"; value: string };

/** `null` for a pair the CHECK constraint would reject, so a caller earns a
 *  refusal rather than a driver error. */
export function parseImportFilter(kind: string, value: string | null): ImportFilter | null {
  const parsed = ImportFilterKindSchema.safeParse(kind);
  if (!parsed.success) return null;
  if (parsed.data === "all" || parsed.data === "assigned_to_member") {
    return value === null ? { kind: parsed.data, value: null } : null;
  }
  const trimmed = value?.trim() ?? "";
  return trimmed === "" ? null : { kind: parsed.data, value: trimmed };
}

const INTEGRATION_SELECT = {
  id: true,
  accountId: true,
  provider: true,
  externalAccountId: true,
  installationId: true,
  displayName: true,
  status: true,
  installedBy: true,
  createdAt: true,
  revokedAt: true,
} satisfies Prisma.IntegrationSelect;

const REPO_SELECT = {
  id: true,
  integrationId: true,
  repoKey: true,
  externalRepoId: true,
  projectId: true,
  visibility: true,
  syncEnabled: true,
  pushEnabled: true,
  publishNewByDefault: true,
  importFilterKind: true,
  importFilterValue: true,
  commentImportCap: true,
  removedAt: true,
  lastFullSyncAt: true,
  lastCursor: true,
  etag: true,
  createdAt: true,
  updatedAt: true,
} satisfies Prisma.IntegrationRepoSelect;

export type IntegrationRecord = Prisma.IntegrationGetPayload<{
  select: typeof INTEGRATION_SELECT;
}>;
export type IntegrationRepoRecord = Prisma.IntegrationRepoGetPayload<{
  select: typeof REPO_SELECT;
}>;

/**
 * Every integration the account holds, revoked ones included.
 *
 * Revoked rows are deliberately not filtered out: they are the provenance of
 * tasks imported through them, and a settings screen that hides them cannot
 * explain where an unlinked task came from. Callers that want live ones filter
 * on `revokedAt`.
 */
export async function listIntegrations(db: Tx, accountId: string): Promise<IntegrationRecord[]> {
  return db.integration.findMany({
    where: { accountId },
    orderBy: { createdAt: "asc" },
    select: INTEGRATION_SELECT,
  });
}

export async function getIntegration(
  db: Tx,
  accountId: string,
  id: string
): Promise<IntegrationRecord | null> {
  if (!isUuid(id)) return null;
  return db.integration.findFirst({ where: { id, accountId }, select: INTEGRATION_SELECT });
}

export type UpsertIntegrationArgs = {
  /** Resolved from the caller's active membership, never from the request. */
  accountId: string;
  provider: string;
  externalAccountId: string;
  /** Null for a provider with no install concept. */
  installationId?: string | null;
  displayName: string;
  status?: IntegrationStatus;
  /** The user who completed the install, already proven to be the caller. */
  installedBy: string;
};

export type UpsertIntegrationResult =
  | { kind: "ok"; integration: IntegrationRecord }
  | { kind: "invalid_provider" }
  /** Another Antgrid account already holds this installation id. Never
   *  overwrite: the row it would take over is the one inbound deliveries for
   *  that installation route through. */
  | { kind: "installation_taken" };

/**
 * Record a completed install, or re-record one the account already had.
 *
 * Upserts on `[accountId, provider, externalAccountId]` — the install flow knows
 * which provider account it just connected, and reconnecting one the account
 * previously revoked should revive that row rather than leave two behind. The
 * revive clears `revokedAt`, which is safe here and only here: this path has an
 * authenticated caller and a resolved `accountId`, whereas the inbound path has
 * neither and never writes.
 */
export async function upsertIntegration(
  db: DB,
  args: UpsertIntegrationArgs
): Promise<UpsertIntegrationResult> {
  const provider = IntegrationProviderSchema.safeParse(args.provider);
  if (!provider.success) return { kind: "invalid_provider" };

  const installationId = args.installationId ?? null;
  const status = args.status ?? IntegrationStatusSchema.enum.active;
  const mutable = {
    installationId,
    displayName: args.displayName,
    status,
    revokedAt: null,
  };

  try {
    const row = await db.integration.upsert({
      where: {
        accountId_provider_externalAccountId: {
          accountId: args.accountId,
          provider: provider.data,
          externalAccountId: args.externalAccountId,
        },
      },
      create: {
        accountId: args.accountId,
        provider: provider.data,
        externalAccountId: args.externalAccountId,
        installedBy: args.installedBy,
        ...mutable,
      },
      // `installedBy` is left alone: it records who connected the account, and a
      // later member re-running the flow does not rewrite that history.
      update: mutable,
      select: INTEGRATION_SELECT,
    });
    return { kind: "ok", integration: row };
  } catch (err) {
    // The only other unique on this table is `[provider, installationId]`, and
    // it is global — so a violation here means the id belongs to somebody else.
    if (!isUniqueViolation(err)) throw err;
    return { kind: "installation_taken" };
  }
}

/**
 * Retire an integration without losing what it explains.
 *
 * Never a delete: the row is the provenance of every task imported through it,
 * and `revokedAt` is what `resolveInstallation` reads to stop routing to it.
 * Returns whether anything moved, so a second uninstall webhook is a no-op
 * rather than a second revocation timestamp.
 */
export async function revokeIntegration(db: Tx, accountId: string, id: string): Promise<boolean> {
  if (!isUuid(id)) return false;
  const result = await db.integration.updateMany({
    where: { id, accountId, revokedAt: null },
    data: { revokedAt: new Date(), status: IntegrationStatusSchema.enum.revoked },
  });
  return result.count > 0;
}

/**
 * Resolve an inbound delivery to the account that owns it.
 *
 * **This is the single point where a cross-tenant write is prevented.** A
 * webhook carries no `accountId`, so this lookup has nothing to scope by; it
 * keys on `[provider, installationId]` because that pair is unique across all
 * accounts, and on nothing else. Resolving through
 * `[accountId, provider, externalAccountId]` instead would be unscoped by
 * construction — it is unique only within one account, and two accounts
 * legitimately hold one `externalAccountId` after an uninstall/reinstall — so it
 * would hand one tenant's private issue bodies to another.
 *
 * The `revokedAt` filter is half of that guarantee, not hygiene. Revoked rows
 * are retained by design, so without it the reinstall case turns from a
 * harmless miss into exactly the mis-route above.
 */
export async function resolveInstallation(
  db: Tx,
  provider: string,
  installationId: string
): Promise<IntegrationRecord | null> {
  const parsed = IntegrationProviderSchema.safeParse(provider);
  if (!parsed.success) return null;
  if (!installationId) return null;
  return db.integration.findFirst({
    where: { provider: parsed.data, installationId, revokedAt: null },
    select: INTEGRATION_SELECT,
  });
}

/**
 * The repositories of one integration.
 *
 * The relation filter is the tenancy check, not a convenience: it makes
 * `accountId` part of the where-clause the database evaluates, so a foreign
 * `integrationId` returns nothing rather than another account's repository list.
 */
export async function listIntegrationRepos(
  db: Tx,
  accountId: string,
  integrationId: string
): Promise<IntegrationRepoRecord[]> {
  if (!isUuid(integrationId)) return [];
  return db.integrationRepo.findMany({
    where: { integrationId, integration: { accountId } },
    orderBy: { repoKey: "asc" },
    select: REPO_SELECT,
  });
}

export type UpsertIntegrationRepoArgs = {
  /** Resolved from the caller, never from the request body. */
  accountId: string;
  integrationId: string;
  repoKey: string;
  externalRepoId: string;
  projectId?: string | null;
  visibility: RepoVisibility;
  /** Applied on create only — see the note on the function. */
  syncEnabled: boolean;
  pushEnabled?: boolean;
  publishNewByDefault?: boolean;
  importFilter?: ImportFilter;
  commentImportCap?: number;
};

export type UpsertIntegrationRepoResult =
  | { kind: "ok"; repo: IntegrationRepoRecord; created: boolean }
  | { kind: "integration_not_found" }
  | { kind: "project_not_found" }
  | { kind: "invalid_repo_key" }
  | { kind: "invalid_visibility" }
  | { kind: "invalid_comment_cap" }
  /** Another repository of this integration already answers to this `repoKey` —
   *  what a rename that swaps two repositories' names produces. Refusing leaves
   *  both rows pointing at the repositories they were imported from. */
  | { kind: "repo_key_conflict" };

/**
 * Record a repository of an integration, or refresh one already recorded.
 *
 * Keyed on `[integrationId, externalRepoId]`, because the provider's repo id
 * survives a rename and `repoKey` does not.
 *
 * The update half rewrites only what the provider owns — `repoKey`, `visibility`,
 * `removedAt` and the project link. Every consent below them (`syncEnabled`, `pushEnabled`,
 * `publishNewByDefault`, the import filter, the comment cap) is applied on
 * create and never on update, so a routine re-discovery cannot silently reset a
 * choice the user made. Changing one afterwards is `setRepoSyncSettings`.
 *
 * `repo_key_conflict` is only actionable when this runs OUTSIDE a transaction.
 * The unique violation it reports comes from Postgres, which aborts the whole
 * transaction on the error regardless of the catch here, so a caller inside
 * `$transaction` gets the refusal and then fails on its next statement. Callers
 * that drain a batch (`integrations/github-inbound.ts`) treat that as a failed
 * delivery on purpose rather than pretending they can carry on.
 */
export async function upsertIntegrationRepo(
  db: Tx,
  args: UpsertIntegrationRepoArgs
): Promise<UpsertIntegrationRepoResult> {
  if (!isValidRepoKey(args.repoKey)) return { kind: "invalid_repo_key" };
  const visibility = RepoVisibilitySchema.safeParse(args.visibility);
  if (!visibility.success) return { kind: "invalid_visibility" };
  if (
    args.commentImportCap !== undefined &&
    !CommentImportCapSchema.safeParse(args.commentImportCap).success
  ) {
    return { kind: "invalid_comment_cap" };
  }

  // A caller-supplied uuid is merely well-formed until this read; the FK below
  // would accept another account's integration without complaint.
  const integration = await getIntegration(db, args.accountId, args.integrationId);
  if (!integration) return { kind: "integration_not_found" };

  const projectId = args.projectId ?? null;
  if (projectId !== null) {
    if (!isUuid(projectId)) return { kind: "project_not_found" };
    const project = await db.project.findFirst({
      where: { id: projectId, accountId: args.accountId },
      select: { id: true },
    });
    if (!project) return { kind: "project_not_found" };
  }

  const filter = args.importFilter;
  const existing = await db.integrationRepo.findUnique({
    where: {
      integrationId_externalRepoId: {
        integrationId: integration.id,
        externalRepoId: args.externalRepoId,
      },
    },
    select: { id: true },
  });

  try {
    const row = await db.integrationRepo.upsert({
      where: {
        integrationId_externalRepoId: {
          integrationId: integration.id,
          externalRepoId: args.externalRepoId,
        },
      },
      create: {
        integrationId: integration.id,
        repoKey: args.repoKey,
        externalRepoId: args.externalRepoId,
        projectId,
        visibility: visibility.data,
        syncEnabled: args.syncEnabled,
        ...(args.pushEnabled === undefined ? {} : { pushEnabled: args.pushEnabled }),
        ...(args.publishNewByDefault === undefined
          ? {}
          : { publishNewByDefault: args.publishNewByDefault }),
        ...(filter === undefined
          ? {}
          : { importFilterKind: filter.kind, importFilterValue: filter.value }),
        ...(args.commentImportCap === undefined ? {} : { commentImportCap: args.commentImportCap }),
      },
      update: {
        repoKey: args.repoKey,
        visibility: visibility.data,
        ...(args.projectId === undefined ? {} : { projectId }),
        // Rediscovering the repository is proof it is reachable again, and that
        // is the only fact this clears. `syncEnabled` stays where it is: a
        // repository leaving the installation and coming back is not consent to
        // resume importing, and it is applied on create anyway.
        removedAt: null,
      },
      select: REPO_SELECT,
    });
    return { kind: "ok", repo: row, created: existing === null };
  } catch (err) {
    if (!isUniqueViolation(err)) throw err;
    return { kind: "repo_key_conflict" };
  }
}

export type SetRepoSyncSettingsArgs = {
  /** Resolved from the caller, never from the request body. */
  accountId: string;
  repoId: string;
  syncEnabled?: boolean;
  pushEnabled?: boolean;
  publishNewByDefault?: boolean;
  importFilter?: ImportFilter;
  commentImportCap?: number;
};

export type SetRepoSyncSettingsResult =
  | { kind: "ok"; repo: IntegrationRepoRecord }
  | { kind: "not_found" }
  | { kind: "invalid_comment_cap" };

/**
 * Change the per-repository consents.
 *
 * Deliberately the only writer of them, so the settings screen and a background
 * re-discovery cannot both claim to own a toggle. The repository is re-resolved
 * under the caller's account first: the id is a bare uuid from a request body,
 * and the update would otherwise turn on outbound writes for a repository
 * belonging to somebody else.
 */
export async function setRepoSyncSettings(
  db: DB,
  args: SetRepoSyncSettingsArgs
): Promise<SetRepoSyncSettingsResult> {
  if (
    args.commentImportCap !== undefined &&
    !CommentImportCapSchema.safeParse(args.commentImportCap).success
  ) {
    return { kind: "invalid_comment_cap" };
  }

  const repo = await resolveIntegrationRepo(db, args.accountId, args.repoId);
  if (!repo) return { kind: "not_found" };

  const updated = await db.integrationRepo.update({
    where: { id: repo.id },
    data: {
      ...(args.syncEnabled === undefined ? {} : { syncEnabled: args.syncEnabled }),
      ...(args.pushEnabled === undefined ? {} : { pushEnabled: args.pushEnabled }),
      ...(args.publishNewByDefault === undefined
        ? {}
        : { publishNewByDefault: args.publishNewByDefault }),
      ...(args.importFilter === undefined
        ? {}
        : {
            importFilterKind: args.importFilter.kind,
            importFilterValue: args.importFilter.value,
          }),
      ...(args.commentImportCap === undefined ? {} : { commentImportCap: args.commentImportCap }),
    },
    select: REPO_SELECT,
  });
  return { kind: "ok", repo: updated };
}

/**
 * Re-resolve a caller-supplied repo id under the caller's account.
 *
 * What every path binding a task to a repository goes through.
 * `tasks.integration_repo_id` has a foreign key, and a foreign key proves the
 * row exists and nothing about who owns it.
 */
export async function resolveIntegrationRepo(
  db: Tx,
  accountId: string,
  repoId: string
): Promise<IntegrationRepoRecord | null> {
  if (!isUuid(repoId)) return null;
  return db.integrationRepo.findFirst({
    where: { id: repoId, integration: { accountId } },
    select: REPO_SELECT,
  });
}

/**
 * Stamp every repository of an integration that the provider no longer offers.
 *
 * The install flow reads the repository list from the provider directly, so
 * that list is authoritative at the moment it is read — which is what lets a
 * user deselecting a repository on GitHub take effect here without waiting for
 * an `installation_repositories` delivery that may never have been recorded.
 *
 * `syncEnabled` is turned off with it, because a repository we can no longer
 * reach cannot be imported from and leaving the toggle on would promise
 * otherwise. Turning it back on is the user's, through `setRepoSyncSettings`,
 * after the repository comes back.
 *
 * The caller must not pass an empty `present` set as a way of clearing
 * everything: an empty provider response is far more likely to be an error we
 * failed to notice than an installation with no repositories, and acting on it
 * would silently disable every import the account has.
 */
export async function markMissingReposRemoved(
  db: Tx,
  args: { accountId: string; integrationId: string; present: string[] }
): Promise<number> {
  if (!isUuid(args.integrationId) || args.present.length === 0) return 0;
  const result = await db.integrationRepo.updateMany({
    where: {
      integrationId: args.integrationId,
      integration: { accountId: args.accountId },
      externalRepoId: { notIn: args.present },
      removedAt: null,
    },
    data: { syncEnabled: false, removedAt: new Date() },
  });
  return result.count;
}

function isUniqueViolation(err: unknown): boolean {
  return typeof err === "object" && err !== null && "code" in err && err.code === "P2002";
}
