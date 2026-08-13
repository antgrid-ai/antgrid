import type { DB } from "../db/index.js";
import { pushRevoke, type RelayPushConfig } from "../relay/push.js";
import { listActiveDevices } from "../models/device.js";
import { ensureProductAccount } from "../models/product-account.js";
import {
  ACCOUNT_MEMBER_STATUS_ACTIVE,
  closeActiveMembership,
  countOtherActiveOwners,
  type AccountMemberStatus,
} from "../models/account-member.js";

export class RemoveMemberError extends Error {
  constructor(
    readonly code: "NOT_A_MEMBER" | "ACCOUNT_OWNER" | "LAST_OWNER",
    message?: string
  ) {
    super(message ?? code);
    this.name = "RemoveMemberError";
  }
}

/** How the membership ended, which is the whole difference between the two
 *  verbs — the row is the only record of whether someone was shown the door or
 *  walked out, and both close through here. */
export type MembershipExit = Extract<AccountMemberStatus, "left" | "removed">;

/**
 * Take a user off an account's bill and hand them back their own.
 *
 * The single close site for both verbs. An owner removing someone and a member
 * leaving differ only in the status written and in who is allowed to ask, so
 * splitting them into two functions would give the last-owner guard two places
 * to be wrong in.
 *
 * Under `pg_advisory_xact_lock(hashtext('billing:' || accountId))` — byte-for-byte
 * the key `addAccountMember`, `createAccountInvite`, `updateSubscriptionSeats`
 * and the reducer take. Every read the refusals depend on happens after the lock
 * and inside the same transaction, so two of the last owners leaving at once
 * serialize: the second transaction's owner count is taken after the first has
 * committed its close, and sees zero.
 *
 * Deliberately does NOT touch the subscription. Removing someone frees a seat
 * and never lowers the invoice — the provider is the source of truth for what is
 * billed, and a helpful `seats--` here would be a refund this codebase has no
 * path for.
 *
 * The departing user's personal account is restored but NOT locked: two advisory
 * locks in one transaction is how two people leaving each other's teams
 * deadlock, and the personal account is one this transaction is the only writer
 * of — nothing else can be adding a member to an account whose owner is only
 * now returning to it.
 */
export async function removeAccountMember(
  db: DB,
  relay: RelayPushConfig,
  args: { accountId: string; userId: string; as: MembershipExit },
  fetchImpl: typeof fetch = fetch
): Promise<void> {
  const { accountId, userId, as } = args;

  await db.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`billing:${accountId}`}))`;

    const membership = await tx.accountMember.findFirst({
      where: { accountId, userId, status: ACCOUNT_MEMBER_STATUS_ACTIVE },
      select: { id: true },
    });
    if (!membership) throw new RemoveMemberError("NOT_A_MEMBER");

    // Two refusals, not one, because an account with no owner is unrecoverable
    // and there are two independent ways to arrive at one.
    //
    // `ProductAccount.userId` is unique and there is no ownership transfer, so
    // the account holder can never be replaced: letting them out would strand a
    // live subscription, its members and its invites behind a row nobody can
    // act on. It would not even move them — `ensureProductAccount` upserts on
    // `{ userId }`, so the account they were handed back is the one they just
    // left.
    const account = await tx.productAccount.findUniqueOrThrow({
      where: { id: accountId },
      select: { userId: true },
    });
    if (account.userId === userId) {
      throw new RemoveMemberError(
        "ACCOUNT_OWNER",
        "this account belongs to that user; it cannot be left or taken from them"
      );
    }
    // And a second owner may leave only while another remains. Counting OTHER
    // owners answers both callers with one query — a departing owner is
    // excluded from their own count, and a departing member never was in it —
    // and a role string outside the schema is not counted, so an unreadable row
    // can never be the owner something else is relying on.
    if ((await countOtherActiveOwners(tx, accountId, userId)) === 0) {
      throw new RemoveMemberError(
        "LAST_OWNER",
        "this account would be left with no owner; make someone else an owner first"
      );
    }

    await closeActiveMembership(tx, userId, as);
    // Restores the owner membership on their own account too, which is what
    // makes `resolveBillingAccountId` answer with it again — the membership leg
    // is consulted before the ownership fallback.
    const personal = await ensureProductAccount(tx, userId);
    // Direct update, never `syncUserAccountId`: that helper's
    // `accountId IS NULL OR accountId = <new>` guard declines to move a member's
    // pointer, and this user is still pointed at the team.
    await tx.user.update({ where: { id: userId }, data: { accountId: personal.id } });
  });

  // Per device, and revoke rather than expire. Expiring drops the license cache
  // and closes the sockets, but the device row keeps `revokedAt: null` and mints
  // a fresh token seconds later — which is fine for a downgrade and useless for
  // a removal. Revoking is what ends the session in progress. The rows are left
  // active on purpose: these are the ex-member's OWN registrations, they follow
  // them to their personal account, and destroying them would make leaving a
  // team cost someone their machines.
  const devices = await listActiveDevices(db, userId);
  await Promise.all(devices.map((d) => pushRevoke(relay, d.deviceId, userId, fetchImpl)));
}
