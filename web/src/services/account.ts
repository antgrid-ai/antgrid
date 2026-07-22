import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import type { RelayPushConfig } from "../relay/push.js";
import { listActiveDevices } from "../models/device.js";
import { revokeUserDevice } from "./device.js";
import { pushExpire } from "../relay/push.js";
import {
  activeSubscriptionForUser,
  cancelAllAccountSubscriptions,
  isPendingCancellation,
} from "../models/subscription.js";
import { ensureProductAccount } from "../models/product-account.js";
import { PLAN_SLUG_FREE } from "../models/plan.js";

export type DeleteAccountResult = "deleted" | "blocked_subscription";

/** Block deletion only while a *paid* subscription will still auto-renew. A free
 *  plan, or a paid plan already pending cancellation, has no future charge and
 *  does not block. */
export async function hasRenewingPaidSubscription(db: DB, userId: string): Promise<boolean> {
  const sub = await activeSubscriptionForUser(db, userId);
  if (!sub) return false;
  const plan = await db.plan.findUnique({ where: { id: sub.planId } });
  if (!plan || plan.slug === PLAN_SLUG_FREE) return false;
  return !isPendingCancellation(sub);
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
      },
    });

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
