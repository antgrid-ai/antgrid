import { z } from "zod";
import type { Tx } from "../db/index.js";

export const AccountMemberRoleSchema = z.enum(["owner", "member"]);
export const AccountMemberStatusSchema = z.enum(["active", "left", "removed"]);
export type AccountMemberRole = z.infer<typeof AccountMemberRoleSchema>;
export type AccountMemberStatus = z.infer<typeof AccountMemberStatusSchema>;

/** The one status the partial unique index and every entitlement read key on.
 *  Derived from the schema rather than spelled inline so a widened union cannot
 *  leave a bare `"active"` string behind in a where-clause. */
export const ACCOUNT_MEMBER_STATUS_ACTIVE: AccountMemberStatus =
  AccountMemberStatusSchema.enum.active;

/** `role` is null when the stored value is outside the schema. Fail closed: an
 *  unrecognized role must never satisfy an owner check, and it must not block
 *  entitlement resolution either — which account the user bills against does not
 *  depend on their capacity on it. */
export type ActiveMembership = { accountId: string; role: AccountMemberRole | null };

export async function findActiveMembership(
  db: Tx,
  userId: string
): Promise<ActiveMembership | null> {
  const row = await db.accountMember.findFirst({
    where: { userId, status: ACCOUNT_MEMBER_STATUS_ACTIVE },
    select: { accountId: true, role: true },
  });
  if (!row) return null;
  const role = AccountMemberRoleSchema.safeParse(row.role);
  return { accountId: row.accountId, role: role.success ? role.data : null };
}

/**
 * The account a user's entitlement is read from: their active membership if they
 * have one, otherwise the account they own.
 *
 * Order matters and is not interchangeable. Membership first means a user who
 * leaves a team resolves back to their personal account on the very next read;
 * resolving the personal account first and overriding would make that transient
 * answer the wrong one. The fallback is also why this can never return null for
 * a signed-in user — the personal ProductAccount always exists — so a missing or
 * malformed membership row degrades to "their own entitlement", never to an
 * error. Nothing downstream will surface that for you.
 */
export async function resolveBillingAccountId(db: Tx, userId: string): Promise<string | null> {
  const membership = await findActiveMembership(db, userId);
  if (membership) return membership.accountId;
  const account = await db.productAccount.findUnique({
    where: { userId },
    select: { id: true },
  });
  return account?.id ?? null;
}

/**
 * Whether the user may act on the contract they bill against — cancel it, resume
 * it, lock its gateway, rewrite its country.
 *
 * A user with no membership row is an owner by construction: `resolveBillingAccountId`
 * then falls back to the account they OWN, so there is no one else's contract to
 * protect. A role outside the schema reads back as null and fails closed.
 */
export async function isBillingAccountOwner(db: Tx, userId: string): Promise<boolean> {
  const membership = await findActiveMembership(db, userId);
  if (!membership) return true;
  return membership.role === AccountMemberRoleSchema.enum.owner;
}

/**
 * Active members of `accountId` other than `userId`.
 *
 * Deliberately "other": the owner holds an active membership on their own
 * account, so counting the whole set and testing `> 0` would refuse every solo
 * owner's deletion while looking exactly like the intended team guard.
 */
export async function countOtherActiveMembers(
  db: Tx,
  accountId: string,
  userId: string
): Promise<number> {
  return db.accountMember.count({
    where: { accountId, status: ACCOUNT_MEMBER_STATUS_ACTIVE, userId: { not: userId } },
  });
}

/**
 * Active owners of `accountId` other than `userId` — what the last-owner guard
 * asks before letting someone out.
 *
 * "Other" rather than "all" so one query answers both verbs: a departing owner
 * excludes themselves, and a departing member was never in the set, so zero
 * means the same thing either way. Matching on the schema's literal and not a
 * bare string keeps a stored role outside the union uncounted — an unreadable
 * row must never be the owner the account is left resting on.
 */
export async function countOtherActiveOwners(
  db: Tx,
  accountId: string,
  userId: string
): Promise<number> {
  return db.accountMember.count({
    where: {
      accountId,
      status: ACCOUNT_MEMBER_STATUS_ACTIVE,
      role: AccountMemberRoleSchema.enum.owner,
      userId: { not: userId },
    },
  });
}

/**
 * People occupying a seat on `accountId`: active `account_members` rows, owner
 * included, and nothing else.
 *
 * One definition, deliberately, because invite and resize disagreeing about the
 * same team is a bug nobody can reproduce — `POST /billing/seats` clamps against
 * this number and Phase 4's SEAT_CAP must refuse against the same one.
 *
 * Two neighbours are the wrong number and look right. `countOtherActiveMembers`
 * excludes a named user, so `+ 1` over-counts whenever that caller holds no row
 * on this account — and `isBillingAccountOwner` returns true for exactly that
 * user, so passing the owner gate is no evidence they hold one. And unlike
 * `listBillingAccountUserIds`, the ProductAccount owner is NOT added on top of
 * the query: `ensureOwnerMembership` heals their row on every provisioning call,
 * so counting a row nobody holds would refuse a decrease that is legal.
 */
export async function countActiveSeatHolders(db: Tx, accountId: string): Promise<number> {
  return db.accountMember.count({
    where: { accountId, status: ACCOUNT_MEMBER_STATUS_ACTIVE },
  });
}

export type ActiveMember = {
  userId: string;
  email: string;
  role: AccountMemberRole | null;
  joinedAt: Date;
};

/**
 * Who is on `accountId` right now, oldest first, with the address that
 * identifies them.
 *
 * Exactly the rows `countActiveSeatHolders` counts, so a page showing the meter
 * beside the table cannot show a number the list disagrees with. Note the owner
 * is here on the strength of their membership row and not added on top — a team
 * whose owner row is missing is a seat the meter does not count either.
 */
export async function listActiveMembers(db: Tx, accountId: string): Promise<ActiveMember[]> {
  const rows = await db.accountMember.findMany({
    where: { accountId, status: ACCOUNT_MEMBER_STATUS_ACTIVE },
    orderBy: { joinedAt: "asc" },
    select: {
      userId: true,
      role: true,
      joinedAt: true,
      user: { select: { email: true } },
    },
  });
  return rows.map((row) => ({
    userId: row.userId,
    email: row.user.email,
    role: AccountMemberRoleSchema.safeParse(row.role).data ?? null,
    joinedAt: row.joinedAt,
  }));
}

/**
 * Every user whose entitlement resolves to `accountId` — the fan-out set for an
 * account-level entitlement change.
 *
 * The owner is included unconditionally rather than trusted to hold a membership
 * row: `resolveBillingAccountId` falls back to the account a user owns, so an
 * owner reads entitlement from it either way, and a fan-out that dropped them
 * would be indistinguishable from one that worked.
 */
export async function listBillingAccountUserIds(db: Tx, accountId: string): Promise<string[]> {
  const [members, account] = await Promise.all([
    db.accountMember.findMany({
      where: { accountId, status: ACCOUNT_MEMBER_STATUS_ACTIVE },
      select: { userId: true },
    }),
    db.productAccount.findUnique({ where: { id: accountId }, select: { userId: true } }),
  ]);
  const ids = new Set(members.map((m) => m.userId));
  if (account) ids.add(account.userId);
  return [...ids];
}

/**
 * End the user's active membership, freeing the seat.
 *
 * Account deletion tombstones the User row rather than deleting it, so
 * `account_members.user_id ON DELETE CASCADE` never fires — without this the row
 * stays `active` forever and the owner keeps paying for a ghost.
 */
export async function closeActiveMembership(
  db: Tx,
  userId: string,
  status: Extract<AccountMemberStatus, "left" | "removed">
): Promise<void> {
  await db.accountMember.updateMany({
    where: { userId, status: ACCOUNT_MEMBER_STATUS_ACTIVE },
    data: { status, endedAt: new Date() },
  });
}

/**
 * Record the owner membership for a personal account.
 *
 * A no-op when the user already holds an active membership — it is either this
 * same row or a team's, and `account_members_one_active_per_user_idx` permits
 * exactly one either way. Membership is never taken away here: leaving a team is
 * a billing decision, not a side effect of ensuring an account row exists.
 */
export async function ensureOwnerMembership(
  db: Tx,
  accountId: string,
  userId: string
): Promise<void> {
  const active = await db.accountMember.findFirst({
    where: { userId, status: ACCOUNT_MEMBER_STATUS_ACTIVE },
    select: { id: true },
  });
  if (active) return;
  await db.accountMember.upsert({
    where: { accountId_userId: { accountId, userId } },
    create: {
      accountId,
      userId,
      role: AccountMemberRoleSchema.enum.owner,
      status: ACCOUNT_MEMBER_STATUS_ACTIVE,
    },
    update: {
      role: AccountMemberRoleSchema.enum.owner,
      status: ACCOUNT_MEMBER_STATUS_ACTIVE,
      endedAt: null,
    },
  });
}
