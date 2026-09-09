import type { Tx } from "../db/index.js";
import { ACCOUNT_MEMBER_STATUS_ACTIVE } from "./account-member.js";

/**
 * Provider identities: which provider user is which Antgrid member, per
 * integration.
 *
 * Better-Auth's `account` row records the provider's numeric user id in
 * `accountId` and never the login, so an inbound assignee is unmatchable
 * without a table that holds both. Rows accumulate for unresolved users too —
 * their login and avatar are what the UI renders for an assignee that is not a
 * member.
 */

/** One provider user as an inbound payload described them. */
export type ProviderUser = { externalUserId: string; login: string; avatarUrl: string | null };

/**
 * Provider users → the Antgrid member ids they resolve to, for the ones that
 * resolve at all, recording every one of them on the way.
 *
 * **The membership filter is the security property of this file.** A provider
 * user resolves only through an `account` row whose user holds an ACTIVE
 * membership of `args.accountId` — the account this integration belongs to.
 * Without that filter, one tenant's issue assigned to a GitHub user who happens
 * to have signed into Antgrid elsewhere would land on a member of an unrelated
 * account, which is the same cross-tenant leak the integration-scoped unique on
 * this table exists to prevent, arriving through the resolver instead of
 * through the key.
 *
 * Never clears an existing `userId`: a member who unlinked their GitHub OAuth
 * has not stopped being the assignee of the issues already imported, and an
 * inbound payload is not evidence about who a person is.
 */
export async function resolveProviderIdentities(
  tx: Tx,
  args: { integrationId: string; accountId: string; provider: string; users: ProviderUser[] }
): Promise<Map<string, string>> {
  const { integrationId, accountId, provider } = args;

  // Last mention wins, so one payload naming a user twice refreshes to the
  // login it carried last rather than upserting the same row twice.
  const byExternalId = new Map<string, ProviderUser>();
  for (const user of args.users) byExternalId.set(user.externalUserId, user);
  if (byExternalId.size === 0) return new Map();

  const externalUserIds = [...byExternalId.keys()];
  const existing = await tx.integrationIdentity.findMany({
    where: { integrationId, externalUserId: { in: externalUserIds } },
    select: { externalUserId: true, userId: true },
  });

  const resolved = new Map<string, string>();
  for (const row of existing) {
    if (row.userId !== null) resolved.set(row.externalUserId, row.userId);
  }

  const unresolved = externalUserIds.filter((id) => !resolved.has(id));
  const linked = await findMembersByProviderId(tx, { accountId, provider, unresolved });

  // Sorted, and the order is the whole point. `ON CONFLICT DO UPDATE` takes a
  // row lock held to commit, so two drainers upserting the same two identities
  // in payload order deadlock the moment two issues name the same people in
  // different orders — one holds X waiting for Y while the other holds Y waiting
  // for X. Postgres kills one, and the delivery it kills burns an attempt.
  // A single global order across every transaction is what makes that cycle
  // unconstructible.
  const now = new Date();
  for (const externalUserId of [...byExternalId.keys()].sort()) {
    const user = byExternalId.get(externalUserId)!;
    const newlyLinked = linked.get(externalUserId) ?? null;
    await recordIdentity(tx, {
      integrationId,
      provider,
      user,
      userId: newlyLinked,
      linkedAt: now,
    });
    if (newlyLinked !== null) resolved.set(externalUserId, newlyLinked);
  }

  return resolved;
}

/**
 * One query for the whole batch, never one per assignee: an issue may name ten
 * of them and this sits on the webhook drain's critical path.
 */
async function findMembersByProviderId(
  tx: Tx,
  args: { accountId: string; provider: string; unresolved: string[] }
): Promise<Map<string, string>> {
  if (args.unresolved.length === 0) return new Map();

  const rows = await tx.account.findMany({
    where: {
      providerId: args.provider,
      accountId: { in: args.unresolved },
      user: {
        memberships: { some: { accountId: args.accountId, status: ACCOUNT_MEMBER_STATUS_ACTIVE } },
      },
    },
    select: { accountId: true, userId: true },
  });

  // Nothing stops two Antgrid users in one account from holding the same
  // provider identity, and there is no way to tell which of them is the real
  // one. Picking either assigns somebody else's work to a colleague, so an
  // ambiguous identity stays unresolved and renders as the external user it
  // provably is.
  const claims = new Map<string, string | null>();
  for (const row of rows) {
    const seen = claims.get(row.accountId);
    claims.set(row.accountId, seen === undefined || seen === row.userId ? row.userId : null);
  }

  const linked = new Map<string, string>();
  for (const [externalUserId, userId] of claims) {
    if (userId !== null) linked.set(externalUserId, userId);
  }
  return linked;
}

/**
 * Raw ON CONFLICT rather than a Prisma upsert because it is the only spelling
 * that is both atomic against a concurrent delivery and able to say "link, but
 * never unlink" in the write itself: `COALESCE` keeps whatever the row already
 * holds, so no ordering of two drainers can produce an unlinked row.
 *
 * The login and avatar refresh unconditionally — a renamed GitHub login held
 * forever is a wrong name on every assignee chip that reads it.
 */
async function recordIdentity(
  tx: Tx,
  args: {
    integrationId: string;
    provider: string;
    user: ProviderUser;
    userId: string | null;
    linkedAt: Date;
  }
): Promise<void> {
  await tx.$executeRaw`
    INSERT INTO integration_identities
      (integration_id, provider, external_user_id, external_login, avatar_url, user_id, linked_at)
    VALUES (
      ${args.integrationId}::uuid,
      ${args.provider},
      ${args.user.externalUserId},
      ${args.user.login},
      ${args.user.avatarUrl},
      ${args.userId},
      ${args.userId === null ? null : args.linkedAt}
    )
    ON CONFLICT (integration_id, external_user_id) DO UPDATE SET
      external_login = EXCLUDED.external_login,
      avatar_url = EXCLUDED.avatar_url,
      user_id = COALESCE(integration_identities.user_id, EXCLUDED.user_id),
      linked_at = CASE
        WHEN integration_identities.user_id IS NULL AND EXCLUDED.user_id IS NOT NULL
          THEN EXCLUDED.linked_at
        ELSE integration_identities.linked_at
      END,
      updated_at = now()`;
}
