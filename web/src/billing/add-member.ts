import type { DB, Tx } from "../db/index.js";
import { PLAN_SLUG_FREE } from "../models/plan.js";
import {
  ACCOUNT_MEMBER_STATUS_ACTIVE,
  closeActiveMembership,
  countActiveSeatHolders,
  type AccountMemberRole,
} from "../models/account-member.js";
import {
  activeSubscriptionForAccount,
  cancelActiveSubscriptions,
} from "../models/subscription.js";

export class AddMemberError extends Error {
  constructor(
    readonly code:
      | "ALREADY_ON_THIS_ACCOUNT"
      | "NO_ACTIVE_SUBSCRIPTION"
      | "SEAT_CAP"
      | "HAS_PAID_SUBSCRIPTION",
    message?: string,
    /** The number the refusal is about — seats purchased, for SEAT_CAP. An owner
     *  told only "full" cannot tell what to do next. */
    readonly limit?: number
  ) {
    super(message ?? code);
    this.name = "AddMemberError";
  }
}

/**
 * Whether this account is paying for a subscription of its own.
 *
 * `promotional` rows are NOT purchased, and that half carries the policy. Every
 * account provisioned while in-app purchases are shuttered holds a
 * `promotional: true` grant at tier pro (`ensureDefaultSubscription`), so a
 * predicate reading `tier !== "free"` — the obvious one, and the one a future
 * reader will "fix" this into — would refuse an invite to the entire
 * pre-activation cohort. Nobody was charged for those rows, so cancelling one
 * costs no one money. The price is that ACCEPTING AN INVITE SPENDS THE
 * GRANDFATHERED GRANT, which the invite screen has to say in plain words; it is
 * the one place a user can lose Pro without buying anything. Leaving the row
 * active instead is not the kinder option — it would resurface as a free Pro the
 * moment they left the team.
 *
 * A `dev` grant reads as purchased: it is a stand-in for a real purchase, and
 * the dev fixture waives this check outright rather than the predicate carving
 * out a provider name.
 */
async function holdsPurchasedSubscription(tx: Tx, accountId: string): Promise<boolean> {
  const sub = await activeSubscriptionForAccount(tx, accountId);
  if (sub === null || sub.promotional) return false;
  // The plan is not on SubscriptionRow's type even though the query joins it, so
  // it is re-read by id — the same thing POST /billing/seats does.
  const plan = await tx.plan.findUniqueOrThrow({ where: { id: sub.planId } });
  return plan.slug !== PLAN_SLUG_FREE && plan.recurring;
}

/**
 * Put a user on an account's bill. The single place a membership is ever
 * created — every invite acceptance and every fixture goes through here, or the
 * two insert sites drift and only one of them checks seats.
 *
 * One transaction under `pg_advisory_xact_lock(hashtext('billing:' ||
 * accountId))` — byte-for-byte the key `applySubscriptionEvent` and
 * `updateSubscriptionSeats` take, or the mutual exclusion is fiction. Every read
 * a refusal depends on happens under it, so a webhook or a seat resize cannot
 * land between the count and the insert.
 *
 * Nothing with a side effect outside the database belongs inside: Prisma aborts
 * an interactive transaction at 5s and the lock blocks every webhook for the
 * account meanwhile. Confirmation mail and the entitlement push go after the
 * commit, best-effort, the way the reducer does it.
 *
 * The five steps are ordered, not incidental:
 *   a. seats — an unbilled member is the bug the whole seat feature exists to
 *      close;
 *   b. the invitee's own purchased subscription — step (d) would cancel it and
 *      there is no refund path anywhere in this codebase;
 *   c. close their prior active membership. REQUIRED, not defensive:
 *      `ensureProductAccount` heals an owner row on nearly every authenticated
 *      request, so every user who has ever signed in holds one and
 *      `account_members_one_active_per_user_idx` would reject step (e);
 *   d. cancel the personal row, whatever it is, so it cannot resurface behind
 *      the membership;
 *   e. the membership itself plus the denormalized `user.account_id`.
 *
 * Refusals are thrown out of the transaction, never swallowed. Half of this
 * committed either bills nobody for a working member, or strands a user on a
 * personal account whose subscription (d) has already cancelled.
 *
 * `waive` exists for `POST /dev/billing/member` and nothing else. An
 * over-subscribed team and a member who once bought Pro are both legal states
 * the product has to be testable against, and no enforcing path can build
 * either. Production callers pass nothing.
 */
export async function addAccountMember(
  db: DB,
  args: { accountId: string; userId: string; role: AccountMemberRole },
  waive: { seatCap?: boolean; paidSubscription?: boolean } = {}
): Promise<{ seatHolders: number }> {
  const { accountId, userId, role } = args;

  return db.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`billing:${accountId}`}))`;

    const personal = await tx.productAccount.findUnique({
      where: { userId },
      select: { id: true },
    });

    // Ahead of every other refusal for two independent reasons. Step (d) is
    // pointed at the personal account, and for a self-join that IS the team's
    // account — the function would cancel the subscription it is adding a seat
    // to. And someone already holding a seat is inside the number the seat check
    // counts, so a full team would answer their duplicate accept with SEAT_CAP,
    // which is not what happened.
    if (personal?.id === accountId) {
      throw new AddMemberError("ALREADY_ON_THIS_ACCOUNT");
    }
    const held = await tx.accountMember.findFirst({
      where: { accountId, userId, status: ACCOUNT_MEMBER_STATUS_ACTIVE },
      select: { id: true },
    });
    if (held) throw new AddMemberError("ALREADY_ON_THIS_ACCOUNT");

    if (!waive.seatCap) {
      const sub = await activeSubscriptionForAccount(tx, accountId);
      // Not a default of one: an account with no live contract has no seat to
      // sell, and inventing one is how a member lands on a lapsed team.
      if (!sub) throw new AddMemberError("NO_ACTIVE_SUBSCRIPTION");
      const seatHolders = await countActiveSeatHolders(tx, accountId);
      // `>=`, not `>`: the arriving member occupies the next seat.
      if (seatHolders >= sub.seats) {
        throw new AddMemberError(
          "SEAT_CAP",
          `this account has no free seat (${seatHolders}/${sub.seats} taken); buy another before adding someone`,
          sub.seats
        );
      }
    }

    if (personal && !waive.paidSubscription) {
      if (await holdsPurchasedSubscription(tx, personal.id)) {
        throw new AddMemberError(
          "HAS_PAID_SUBSCRIPTION",
          "this account pays for a subscription of its own; cancel it before joining a team"
        );
      }
    }

    await closeActiveMembership(tx, userId, "left");
    if (personal) await cancelActiveSubscriptions(tx, personal.id);

    // Upsert, not create: `account_members_account_user_key` is a PLAIN unique on
    // (account_id, user_id), so anyone rejoining a team they once left already
    // has a row and a create would 23505. `joinedAt` is reset because the table
    // has no separate created_at — "member since" is about this membership, not
    // the one that ended.
    await tx.accountMember.upsert({
      where: { accountId_userId: { accountId, userId } },
      create: { accountId, userId, role, status: ACCOUNT_MEMBER_STATUS_ACTIVE },
      update: {
        role,
        status: ACCOUNT_MEMBER_STATUS_ACTIVE,
        endedAt: null,
        joinedAt: new Date(),
      },
    });
    // Direct update, never `syncUserAccountId`: that helper's
    // `accountId IS NULL OR accountId = <new>` guard exists precisely to decline
    // to move a member's pointer.
    await tx.user.update({ where: { id: userId }, data: { accountId } });

    return { seatHolders: await countActiveSeatHolders(tx, accountId) };
  });
}
