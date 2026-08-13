import type { Subscription } from "../generated/prisma/client.js";
import type { Tx } from "../db/index.js";
import { FREE_TIER } from "../billing/plans.js";
import { readCapabilities, type Capabilities } from "../billing/capabilities.js";
import type { PlanRow } from "./plan.js";
import { findPlanBySlug, PLAN_SLUG_FREE } from "./plan.js";
import { ensureProductAccount } from "./product-account.js";
import { findActiveMembership, resolveBillingAccountId } from "./account-member.js";

export type SubscriptionRow = Subscription;

/**
 * `subscriptions.provider` for a contract a human agreed rather than a gateway
 * sold.
 *
 * Load-bearing, not a label: every catalog re-sync guards on this exact value
 * (`WHERE "provider" IS DISTINCT FROM 'manual'`, see
 * 20260815000000_enterprise_catalog), so a negotiated row written under any
 * other provider is silently reset to the list price by the next catalog
 * migration. Keep it in lockstep with that guard.
 */
export const MANUAL_PROVIDER = "manual";

/**
 * The account a user provisions against, created with a default (promotional
 * pro) subscription if it is their own.
 *
 * A member gets the team's account back and nothing is written: membership never
 * mutates the bill, so granting here would hand the team a promotional Pro row
 * the owner never bought. It must also stay in step with
 * `resolveBillingAccountId` — a caller that provisions one account and then reads
 * entitlement from another (checkout metadata is the sharp case: the gateway
 * writes the plan back to whatever id it was handed) fails silently.
 */
export async function provisionProductAccountForUser(
  db: Tx,
  userId: string
): Promise<{ id: string; userId: string }> {
  const membership = await findActiveMembership(db, userId);
  if (membership) {
    const billing = await db.productAccount.findUnique({
      where: { id: membership.accountId },
      select: { id: true, userId: true },
    });
    if (billing && billing.userId !== userId) return billing;
  }
  const account = await ensureProductAccount(db, userId);
  await ensureDefaultSubscription(db, account.id);
  return account;
}

export function resolveEntitlement(sub: SubscriptionRow): {
  tier: string;
  workerLimit: number;
  appDeviceLimit: number;
  promotional: boolean;
  capabilities: Capabilities;
} {
  return {
    tier: sub.tier,
    workerLimit: sub.workerLimit,
    appDeviceLimit: sub.appDeviceLimit,
    promotional: sub.promotional,
    // Read off the subscription like every other limit here, never off the
    // plan: the row IS the contract, so an account that negotiated its own set
    // must not be answered with the list price. Validated on the way out
    // because the column is jsonb and holds whatever was written to it.
    capabilities: readCapabilities(sub.capabilities),
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
  const accountId = await resolveBillingAccountId(db, userId);
  if (!accountId) return null;
  return activeSubscriptionForAccount(db, accountId);
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
      appDeviceLimit: freePlan.appDeviceLimit,
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
    /** Machines and app devices this contract was sold, when they are not the
     *  plan's. Omitted takes the plan's, which is what every gateway-driven
     *  apply does — the numbers follow the plan a customer is on. */
    workerLimit?: number;
    appDeviceLimit?: number;
    /** Seats the provider is billing for. Omitted means the caller learned
     *  nothing about seats, which on a fresh row is the column default of one
     *  and on an existing row is whatever was already negotiated — never a
     *  reset to one. */
    seats?: number;
    /** What this contract unlocks, when it is not the plan's list price.
     *  Follows the `seats` rule rather than the limits above: a fresh row
     *  snapshots the plan, an existing row keeps what it was sold. The two
     *  differ because a gateway re-applying a plan carries no opinion about
     *  capabilities at all, and a re-apply that silently stripped a negotiated
     *  grant would be indistinguishable from one that never had it. */
    capabilities?: Capabilities;
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
    workerLimit: fields.workerLimit ?? plan.workerLimit,
    appDeviceLimit: fields.appDeviceLimit ?? plan.appDeviceLimit,
    provider: fields.provider,
    providerSubscriptionId: fields.providerSubscriptionId ?? null,
    providerTransactionId: fields.providerTransactionId ?? null,
    status: "active",
    cancelledAt: null,
    currentPeriodEnd: fields.currentPeriodEnd ?? null,
    trialStartedAt: fields.trialStartedAt ?? null,
    trialEndsAt: fields.trialEndsAt ?? null,
    ...(fields.seats !== undefined ? { seats: fields.seats } : {}),
    ...(fields.capabilities !== undefined ? { capabilities: fields.capabilities } : {}),
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
  return db.subscription.create({
    data: {
      ...data,
      // The snapshot: a fresh row starts at the plan's set unless the caller
      // negotiated its own, so a later edit to the list price cannot reach a
      // contract already sold. Validated on the way in as well as on the way
      // out — a catalog blob nobody can read must not become a contract.
      capabilities: fields.capabilities ?? readCapabilities(plan.capabilities),
    },
  });
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
    seats: number;
  }> = {}
): Promise<SubscriptionRow> {
  // Lands on the account the user BILLS against, team included: a grant written
  // anywhere else is one `activeSubscriptionForUser` would never read back, so
  // the dev tool would answer `{ok: true}` having changed nothing observable.
  // The cost is that granting to a member rewrites the team's contract, which is
  // what `applyPlanToAccountSubscription` does to any account it is pointed at.
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
    ...(opts.seats !== undefined ? { seats: opts.seats } : {}),
  });
}

/**
 * Write a negotiated contract onto the account a user bills against.
 *
 * This is the per-customer half of the Enterprise mechanism: the plan row is the
 * list price and one row serves every customer, while the ceilings, seats and
 * capabilities a human agreed live here, on the subscription `resolveEntitlement`
 * already reads. No purchase path can produce this row — a contact-sales plan is
 * refused at checkout — and it goes through the same apply function every
 * gateway uses, so a contract can never occupy a state a purchase could not.
 *
 * Omitted values take the plan's, which is what makes a contract that negotiated
 * only capabilities cost nothing to write.
 */
export async function grantManualContract(
  db: Tx,
  userId: string,
  opts: Partial<{
    planSlug: string;
    workerLimit: number;
    appDeviceLimit: number;
    seats: number;
    capabilities: Capabilities;
    /** Open-ended by default: a contract with no agreed end is active until one
     *  is written, and `isActiveSubscription` reads a null period end as such. */
    currentPeriodEnd: Date;
  }> = {}
): Promise<SubscriptionRow> {
  const account = await provisionProductAccountForUser(db, userId);

  const planSlug = opts.planSlug ?? "enterprise";
  const plan = await findPlanBySlug(db, planSlug);
  if (!plan) throw new Error(`unknown plan slug: ${planSlug}`);

  return applyPlanToAccountSubscription(db, account.id, plan, {
    provider: MANUAL_PROVIDER,
    ...(opts.currentPeriodEnd ? { currentPeriodEnd: opts.currentPeriodEnd } : {}),
    ...(opts.workerLimit !== undefined ? { workerLimit: opts.workerLimit } : {}),
    ...(opts.appDeviceLimit !== undefined ? { appDeviceLimit: opts.appDeviceLimit } : {}),
    ...(opts.seats !== undefined ? { seats: opts.seats } : {}),
    ...(opts.capabilities !== undefined ? { capabilities: opts.capabilities } : {}),
  });
}
