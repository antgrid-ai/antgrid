import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import type { RelayPushConfig } from "../relay/push.js";
import { listActiveDevices } from "../models/device.js";
import { revokeUserDevice } from "./device.js";
import { pushExpire } from "../relay/push.js";
import {
  activeSubscriptionForAccount,
  cancelAllAccountSubscriptions,
  isPendingCancellation,
} from "../models/subscription.js";
import {
  ensureProductAccount,
  findProductAccountByUserId,
} from "../models/product-account.js";
import {
  closeActiveMembership,
  countOtherActiveMembers,
  findActiveMembership,
} from "../models/account-member.js";
import { PLAN_SLUG_FREE } from "../models/plan.js";

export type DeleteAccountResult = "deleted" | "blocked_subscription" | "blocked_team";

/** Block deletion only while a *paid* subscription will still auto-renew. A free
 *  plan, a promotional grant, or a paid plan already pending cancellation has no
 *  future charge and does not block.
 *
 *  Scoped to the account the user OWNS, not the one they bill against. A member
 *  inherits their owner's renewing subscription and cannot cancel it, so
 *  resolving through membership here would 409 them out of deleting their own
 *  user permanently. */
export async function hasRenewingPaidSubscription(db: DB, userId: string): Promise<boolean> {
  const owned = await findProductAccountByUserId(db, userId);
  if (!owned) return false;
  const sub = await activeSubscriptionForAccount(db, owned.id);
  if (!sub) return false;
  // An unpurchased grant renews nothing and bills nobody, so it is not a reason
  // to refuse. Checked BEFORE the slug test because the grant rides a paid
  // plan's row — `ensureDefaultSubscription` hands every new account
  // `pro_yearly` while checkout is disabled, so the slug alone cannot tell it
  // apart from a real purchase, and every account would be refused deletion
  // with nothing to cancel.
  if (sub.promotional) return false;
  const plan = await db.plan.findUnique({ where: { id: sub.planId } });
  if (!plan || plan.slug === PLAN_SLUG_FREE) return false;
  return !isPendingCancellation(sub);
}

/**
 * Block deletion of an owner whose team still has members: ProductAccount.userId
 * is unique, so the account cannot be handed to one of them self-serve, and
 * cascading the deletion would take the team's contract with it. Transfer is a
 * support operation.
 *
 * Exported so `/account` renders the same answer `DELETE /account/me` gives —
 * the page and the endpoint drifting apart is how an owner learns they are
 * blocked only after typing DELETE.
 */
export async function isBlockedByTeamMembers(db: DB, userId: string): Promise<boolean> {
  const owned = await findProductAccountByUserId(db, userId);
  if (!owned) return false;
  // Keyed on the account they OWN — the one this deletion tombstones — not the
  // one they bill against. A member is blocked by nobody: their own account holds
  // no other members. An owner who has since joined someone else's team still
  // owns theirs, and deleting would tombstone it under its members.
  return (await countOtherActiveMembers(db, owned.id, userId)) > 0;
}

/**
 * Immediately and irreversibly delete `userId`'s account.
 *
 * The User row is TOMBSTONED, not deleted: ProductAccount.userId cascades from
 * User, so deleting the user would wipe the retained billing/tax trail. We scrub
 * identity instead and keep the account row (deletedAt-marked) to anchor it.
 */
export async function deleteUserAccount(
  db: DB,
  relay: RelayPushConfig,
  auth: Auth,
  args: { userId: string; headers: Headers }
): Promise<DeleteAccountResult> {
  const { userId, headers } = args;

  // Guarantee a ProductAccount row exists so the tombstone always lands, even
  // for a user whose post-signup provisioning never created one — otherwise the
  // identity scrub below would run while deletedAt stays unset (not idempotent,
  // and the webhook resurrection guard, which keys on deletedAt, never arms).
  const account = await ensureProductAccount(db, userId);
  // Already tombstoned → idempotent success.
  if (account.deletedAt) return "deleted";

  // A member's membership points at someone else's account; only their own is
  // touched below. Everything from here down stays on `account` for exactly that
  // reason — resolving the team here would let a member's self-deletion cancel
  // the owner's subscriptions and tombstone the team.
  const membership = await findActiveMembership(db, userId);
  const isTeamMember = membership !== null && membership.accountId !== account.id;

  // Both guards run before any mutation.
  if (await isBlockedByTeamMembers(db, userId)) return "blocked_team";

  if (await hasRenewingPaidSubscription(db, userId)) return "blocked_subscription";

  // Per-device teardown (OAuth client deletion via Better-Auth + relay revoke).
  // Runs before the DB transaction because it makes external/adapter calls that
  // can't live inside a PG tx. Each device is best-effort: a single device's
  // external teardown failing must not abort the whole deletion — the tx below
  // hard-deletes the device rows regardless, and the relay token TTL is the
  // fallback for any token we couldn't revoke now.
  //
  // Run in parallel: the revokes are independent (distinct device rows), so
  // wall-clock stays ~one relay-call timeout regardless of device count rather
  // than stacking per device and blowing the request's response budget.
  const devices = await listActiveDevices(db, userId);
  await Promise.all(
    devices.map(async (d) => {
      try {
        await revokeUserDevice(db, relay, auth, { userId, deviceUuid: d.id, headers });
      } catch (err) {
        console.error("[account] device teardown failed during deletion; continuing", {
          userId,
          deviceId: d.id,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    })
  );

  const now = new Date();
  await db.$transaction(async (tx) => {
    // Scrub identity on the retained User row.
    await tx.user.update({
      where: { id: userId },
      data: {
        email: `deleted+${userId}@deleted.antgrid.invalid`,
        name: "Deleted user",
        image: null,
        // A member's account_id names the team, which survives this deletion.
        // syncUserAccountId only ever fills a null or matching value, so a
        // scrubbed user would otherwise keep pointing at a live team forever.
        ...(isTeamMember ? { accountId: null } : {}),
      },
    });

    // Frees the seat. The owner's own row is closed too: nothing may hold an
    // active membership on the account tombstoned below.
    await closeActiveMembership(tx, userId, "left");

    // Hard-delete pure PII / credentials. OAuth client deletions cascade to
    // their access/refresh tokens and consents (schema FK onDelete: Cascade).
    await tx.session.deleteMany({ where: { userId } });
    await tx.account.deleteMany({ where: { userId } });
    await tx.oauthClient.deleteMany({ where: { userId } });
    await tx.device.deleteMany({ where: { userId } });

    // Cancel every residual subscription (free, pending-cancel, or already
    // provider-canceled) and detach provider ids; the block rule guarantees no
    // renewing paid sub remains.
    await cancelAllAccountSubscriptions(tx, account.id);
    await tx.productAccount.update({ where: { id: account.id }, data: { deletedAt: now } });
  });

  // Best-effort: sever any live relay tokens immediately (TTL fallback on fail).
  await pushExpire(relay, userId);
  return "deleted";
}
