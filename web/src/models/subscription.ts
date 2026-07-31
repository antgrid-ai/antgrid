import type { Subscription } from "../generated/prisma/client.js";
import type { Tx } from "../db/index.js";
import { FREE_TIER } from "../billing/plans.js";
import type { PlanRow } from "./plan.js";
import { findPlanBySlug, PLAN_SLUG_FREE } from "./plan.js";
import { ensureProductAccount } from "./product-account.js";

export type SubscriptionRow = Subscription;

/** Create ProductAccount + default (promotional pro) subscription when a user is provisioned. */
export async function provisionProductAccountForUser(
  db: Tx,
  userId: string
): Promise<{ id: string; userId: string }> {
  const account = await ensureProductAccount(db, userId);
  await ensureDefaultSubscription(db, account.id);
  return account;
}

export function resolveEntitlement(sub: SubscriptionRow): {
  tier: string;
  workerLimit: number;
  deviceLimit: number;
  promotional: boolean;
} {
  return {
    tier: sub.tier,
    workerLimit: sub.workerLimit,
    deviceLimit: sub.deviceLimit,
    promotional: sub.promotional,
  };
}

/** Active sub with cancelledAt in the future — cancel takes effect at period end via webhook. */
export function isPendingCancellation(sub: SubscriptionRow, now = new Date()): boolean {
  return sub.status === "active" && sub.cancelledAt !== null && sub.cancelledAt > now;
}

export function isActiveSubscription(sub: SubscriptionRow, now = new Date()): boolean {
  if (sub.status !== "active") return false;
  if (sub.cancelledAt !== null && sub.cancelledAt <= now) return false;
  if (sub.trialEndsAt !== null && sub.trialEndsAt <= now) return false;
  if (sub.currentPeriodEnd !== null && sub.currentPeriodEnd <= now) return false;
  return true;
}

function activeSubscriptionWhere(accountId: string, now = new Date()) {
  return {
    accountId,
    status: "active" as const,
    OR: [{ cancelledAt: null }, { cancelledAt: { gt: now } }],
    AND: [
      { OR: [{ trialEndsAt: null }, { trialEndsAt: { gt: now } }] },
      { OR: [{ currentPeriodEnd: null }, { currentPeriodEnd: { gt: now } }] },
    ],
  };
}

export async function activeSubscriptionForUser(db: Tx, userId: string): Promise<SubscriptionRow | null> {
  const account = await db.productAccount.findUnique({ where: { userId } });
  if (!account) return null;
  return activeSubscriptionForAccount(db, account.id);
}

export async function activeSubscriptionForAccount(
  db: Tx,
  accountId: string
): Promise<SubscriptionRow | null> {
  const subs = await db.subscription.findMany({
    where: activeSubscriptionWhere(accountId),
    orderBy: { createdAt: "desc" },
    include: { plan: true },
  });
  const paid = subs.find((s) => s.plan.slug !== PLAN_SLUG_FREE);
  return paid ?? subs[0] ?? null;
}

export async function findSubscriptionById(db: Tx, id: string): Promise<SubscriptionRow | null> {
  return db.subscription.findUnique({ where: { id } });
}

/** Never resurrect billing on a tombstoned account. A deleted account's subs
 *  stay canceled; reactivating or creating one here would silently un-delete it
 *  at the billing layer. (The billing reducer blocks the webhook path; this
 *  guards every other caller of the shared provisioning layer.) Returns the
 *  account's most recent canceled subscription to use as a fallback when the
 *  account is tombstoned, or null when the account isn't tombstoned. */
async function tombstonedAccountFallback(db: Tx, accountId: string): Promise<SubscriptionRow | null> {
  const owner = await db.productAccount.findUnique({
    where: { id: accountId },
    select: { deletedAt: true },
  });
  if (!owner?.deletedAt) return null;

  const canceled = await db.subscription.findFirst({
    where: { accountId, status: "canceled" },
    orderBy: { cancelledAt: "desc" },
  });
  if (canceled) return canceled;
  throw new Error("cannot provision a subscription for a deleted account");
}

export async function ensureFreeSubscription(db: Tx, accountId: string): Promise<SubscriptionRow> {
  const existing = await activeSubscriptionForAccount(db, accountId);
  if (existing) return existing;

  const tombstoned = await tombstonedAccountFallback(db, accountId);
  if (tombstoned) return tombstoned;

  const freePlan = await findPlanBySlug(db, PLAN_SLUG_FREE);
  if (!freePlan) throw new Error("free plan not seeded");

  const canceledFree = await db.subscription.findFirst({
    where: { accountId, planId: freePlan.id, status: "canceled" },
    orderBy: { cancelledAt: "desc" },
  });
  if (canceledFree) {
    const now = new Date();
    return db.subscription.update({
      where: { id: canceledFree.id },
      data: {
        status: "active",
        cancelledAt: null,
        updatedAt: now,
      },
    });
  }

  return db.subscription.create({
    data: {
      accountId,
      planId: freePlan.id,
      tier: FREE_TIER,
      status: "active",
      workerLimit: freePlan.workerLimit,
      deviceLimit: freePlan.deviceLimit,
    },
  });
}

/** TEMP-PROMO: provisioning-time default while in-app purchases aren't live —
 *  grep "TEMP-PROMO" repo-wide for every related spot (this grant + the
 *  disabled checkout UI in web/src/ui/pricing.tsx and
 *  app/lib/screens/upgrade_screen.dart). Grants full pro access as a
 *  temporary, unpurchased promotion, so no user is blocked from remote
 *  sessions in the meantime. Distinct from ensureFreeSubscription, which is
 *  the real free-tier grant used when an actual subscription lapses/cancels
 *  — that transition must stay genuinely free, not silently re-promoted.
 *  Idempotent: a no-op for an account that already has a paid or promotional
 *  subscription.
 *
 *  TO RETIRE ONCE PAYMENT INTEGRATION SHIPS: repoint
 *  `provisionProductAccountForUser` and `provisionBillingAccount`
 *  (web/src/auth/better-auth.ts) back to `ensureFreeSubscription`, then
 *  decide how to reconcile existing `promotional: true` rows (leave them
 *  grandfathered, or run a downgrade migration) before deleting this
 *  function. */
export async function ensureDefaultSubscription(db: Tx, accountId: string): Promise<SubscriptionRow> {
  const existing = await activeSubscriptionForAccount(db, accountId);
  if (existing && existing.tier !== FREE_TIER) return existing;

  if (!existing) {
    const tombstoned = await tombstonedAccountFallback(db, accountId);
    if (tombstoned) return tombstoned;
  }

  const proPlan = await findPlanBySlug(db, "pro_yearly");
  if (!proPlan) throw new Error("pro_yearly plan not seeded");

  return applyPlanToAccountSubscription(db, accountId, proPlan, {
    provider: "promo",
    promotional: true,
  });
}

export async function cancelFreeSubscription(db: Tx, accountId: string): Promise<void> {
  const freePlan = await findPlanBySlug(db, PLAN_SLUG_FREE);
  if (!freePlan) return;

  await db.subscription.updateMany({
    where: {
      accountId,
      planId: freePlan.id,
      status: "active",
      cancelledAt: null,
    },
    data: {
      status: "canceled",
      cancelledAt: new Date(),
      updatedAt: new Date(),
    },
  });
}

/** Cancel every active subscription for the account (clears provider ids for unique reuse). */
export async function cancelActiveSubscriptions(db: Tx, accountId: string): Promise<void> {
  const now = new Date();
  await db.subscription.updateMany({
    where: {
      accountId,
      status: "active",
      cancelledAt: null,
    },
    data: {
      status: "canceled",
      cancelledAt: now,
      providerSubscriptionId: null,
      providerTransactionId: null,
      updatedAt: now,
    },
  });
}

/** Tombstone path: cancel EVERY still-active subscription for the account
 *  (pending-cancel rows included) AND detach provider ids from ALL rows — even
 *  ones a provider webhook already moved to "canceled" with their provider ids
 *  still attached (the reducer's cancel path leaves them set). The retained
 *  billing row must carry no live provider linkage, and the unique provider-id
 *  slots must be freed. Distinct from cancelActiveSubscriptions, which skips
 *  pending-cancel rows for the plan-switch path. */
export async function cancelAllAccountSubscriptions(db: Tx, accountId: string): Promise<void> {
  const now = new Date();
  await db.subscription.updateMany({
    where: { accountId, status: "active" },
    data: {
      status: "canceled",
      cancelledAt: now,
      updatedAt: now,
    },
  });
  await db.subscription.updateMany({
    where: {
      accountId,
      OR: [{ providerSubscriptionId: { not: null } }, { providerTransactionId: { not: null } }],
    },
    data: {
      providerSubscriptionId: null,
      providerTransactionId: null,
      updatedAt: now,
    },
  });
}

/** Cancel prior subs and create a fresh row for the new plan. */
export async function applyPlanToAccountSubscription(
  db: Tx,
  accountId: string,
  plan: PlanRow,
  fields: {
    provider: string;
    providerSubscriptionId?: string | null;
    providerTransactionId?: string | null;
    currentPeriodEnd?: Date | null;
    trialStartedAt?: Date | null;
    trialEndsAt?: Date | null;
    /** Temporary unpurchased grant (see ensureDefaultSubscription). Real
     *  purchases must omit this — it defaults to false. */
    promotional?: boolean;
  }
): Promise<SubscriptionRow> {
  const now = new Date();
  await cancelActiveSubscriptions(db, accountId);

  const data = {
    accountId,
    planId: plan.id,
    tier: plan.tier,
    workerLimit: plan.workerLimit,
    deviceLimit: plan.deviceLimit,
    provider: fields.provider,
    providerSubscriptionId: fields.providerSubscriptionId ?? null,
    providerTransactionId: fields.providerTransactionId ?? null,
    status: "active",
    cancelledAt: null,
    currentPeriodEnd: fields.currentPeriodEnd ?? null,
    trialStartedAt: fields.trialStartedAt ?? null,
    trialEndsAt: fields.trialEndsAt ?? null,
    promotional: fields.promotional ?? false,
    updatedAt: now,
  };

  if (fields.providerSubscriptionId) {
    const existing = await db.subscription.findUnique({
      where: { providerSubscriptionId: fields.providerSubscriptionId },
    });
    if (existing) {
      return db.subscription.update({ where: { id: existing.id }, data });
    }
  }
  if (fields.providerTransactionId) {
    const existing = await db.subscription.findUnique({
      where: { providerTransactionId: fields.providerTransactionId },
    });
    if (existing) {
      return db.subscription.update({ where: { id: existing.id }, data });
    }
  }

  return db.subscription.create({ data });
}

export async function grantDevSubscription(
  db: Tx,
  userId: string,
  opts: Partial<{
    tier: string;
    planSlug: string;
    workerLimit: number;
    status: string;
    currentPeriodEnd: Date;
  }> = {}
): Promise<SubscriptionRow> {
  const account = await provisionProductAccountForUser(db, userId);

  // Skip only a genuine paid subscription — a promotional grant (from
  // provisionProductAccountForUser's default) must not block an explicit
  // dev/test grant of a specific plan.
  const existing = await activeSubscriptionForAccount(db, account.id);
  if (existing && existing.tier !== FREE_TIER && !existing.promotional) return existing;

  const planSlug = opts.planSlug ?? "pro_yearly";
  const plan = await findPlanBySlug(db, planSlug);
  if (!plan) throw new Error(`unknown plan slug: ${planSlug}`);

  return applyPlanToAccountSubscription(db, account.id, plan, {
    provider: "dev",
    currentPeriodEnd: opts.currentPeriodEnd ?? new Date(Date.now() + 365 * 24 * 3600 * 1000),
  });
}
