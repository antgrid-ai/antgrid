import type { Prisma } from "../generated/prisma/client.js";
import type { DB, Tx } from "../db/index.js";
import { pushExpireAll, type RelayPushConfig } from "../relay/push.js";
import { listBillingAccountUserIds } from "../models/account-member.js";
import { upsertBillingCustomer } from "../models/billing-customer.js";
import { findPlanBySlug, type PlanRow } from "../models/plan.js";
import {
  applyPlanToAccountSubscription,
  ensureFreeSubscription,
  isActiveSubscription,
} from "../models/subscription.js";
import { isPlanId, TRIAL_DAYS } from "./plans.js";
import type { NormalizedEvent, NormalizedEventType } from "./events.js";

const STATUS_BY_TYPE: Record<NormalizedEventType, string> = {
  activated: "active",
  renewed: "active",
  past_due: "past_due",
  canceled: "canceled",
  expired: "expired",
};

function isUniqueViolation(e: unknown): boolean {
  return typeof e === "object" && e !== null && (e as { code?: string }).code === "P2002";
}

/**
 * Who and what this event is about.
 *
 * The row we already hold wins over gateway metadata. `notes.planId` and
 * `custom_data.planId` are written once at checkout and never rewritten, so a
 * subscription this reducer converted from trial to pro_yearly keeps reporting
 * `trial` on every later event — and re-applying that would cancel the paid row
 * and mint a fresh 7-day trial. Metadata is the fallback for a subscription we
 * have never seen, which is the only case where it is the only thing there is
 * (payloads may also omit custom_data entirely on subscription.canceled).
 */
async function resolveEventIdentity(db: DB, event: NormalizedEvent): Promise<NormalizedEvent | null> {
  if (event.providerSubscriptionId) {
    const sub = await db.subscription.findUnique({
      where: { providerSubscriptionId: event.providerSubscriptionId },
      include: { plan: true },
    });
    if (sub && isPlanId(sub.plan.slug)) {
      return { ...event, accountId: sub.accountId, planId: sub.plan.slug };
    }
  }

  if (event.accountId && event.planId) {
    const plan = await findPlanBySlug(db, event.planId);
    if (plan) return event;
  }

  return null;
}

async function upgradeTrialToProYearlyOnRenewal(
  tx: Tx,
  event: NormalizedEvent
): Promise<boolean> {
  if (!event.providerSubscriptionId) return false;

  const active = await tx.subscription.findFirst({
    where: {
      providerSubscriptionId: event.providerSubscriptionId,
      status: "active",
      cancelledAt: null,
    },
    include: { plan: true },
  });
  if (!active || active.plan.slug !== "trial") return false;

  const yearly = await findPlanBySlug(tx, "pro_yearly");
  if (!yearly) throw new Error("pro_yearly plan missing");

  await applyPlanToAccountSubscription(tx, event.accountId, yearly, {
    provider: event.provider,
    providerSubscriptionId: event.providerSubscriptionId,
    providerTransactionId: event.providerTransactionId ?? null,
    currentPeriodEnd: event.currentPeriodEnd ?? null,
    seats: event.quantity,
  });
  return true;
}

async function isDuplicateActivation(
  db: DB,
  event: NormalizedEvent,
  now = new Date()
): Promise<boolean> {
  if (event.type !== "activated" || !event.providerSubscriptionId) return false;

  const sub = await db.subscription.findUnique({
    where: { providerSubscriptionId: event.providerSubscriptionId },
    include: { plan: true },
  });
  if (!sub || !isPlanId(sub.plan.slug)) return false;
  if (sub.accountId !== event.accountId || sub.plan.slug !== event.planId) return false;
  // A portal seat edit is otherwise indistinguishable from a replay: same
  // subscription, same account, same plan, still active. Only the count moved,
  // and swallowing it here is what makes the edit invisible end to end — no
  // write, no audit row, and a 200 the provider never retries.
  if (event.quantity !== undefined && event.quantity !== sub.seats) return false;
  return isActiveSubscription(sub, now);
}

/**
 * Write a seat count onto a subscription we already hold, in place.
 *
 * Returns whether it handled the event: false means there is no such live row
 * and the caller should provision one instead. Recomputed here rather than
 * trusted from the dedup read, which runs outside the advisory lock — two
 * concurrent seat events would otherwise both see the pre-change count.
 *
 * Absolute, never a delta. Razorpay derives its providerEventId from a body
 * hash, so a redelivery can genuinely run twice and has to land on the same
 * number.
 *
 * The provider is the source of truth for what is billed, so a count below
 * active headcount is written too and no member is removed. Clamping belongs to
 * POST /billing/seats, the path we control; a reducer that clamped would leave
 * the row disagreeing with the invoice.
 */
async function applySeatChangeInPlace(
  tx: Tx,
  event: NormalizedEvent,
  now: Date
): Promise<boolean> {
  if (event.quantity === undefined || !event.providerSubscriptionId) return false;

  const sub = await tx.subscription.findUnique({
    where: { providerSubscriptionId: event.providerSubscriptionId },
    include: { plan: true },
  });
  if (!sub || sub.accountId !== event.accountId || sub.plan.slug !== event.planId) return false;
  if (!isActiveSubscription(sub, now)) return false;

  await tx.subscription.update({
    where: { id: sub.id },
    data: { seats: event.quantity, updatedAt: now },
  });
  return true;
}

async function provisionActivatedPlan(
  tx: Tx,
  event: NormalizedEvent,
  plan: PlanRow,
  now: Date
): Promise<void> {
  await upsertBillingCustomer(tx, {
    accountId: event.accountId,
    provider: event.provider,
    providerCustomerId: event.customerId,
  });

  if (plan.slug === "trial") {
    const trialEndsAt =
      event.currentPeriodEnd ?? new Date(now.getTime() + TRIAL_DAYS * 24 * 60 * 60 * 1000);
    await applyPlanToAccountSubscription(tx, event.accountId, plan, {
      provider: event.provider,
      providerSubscriptionId: event.providerSubscriptionId ?? null,
      providerTransactionId: event.providerTransactionId ?? null,
      currentPeriodEnd: event.currentPeriodEnd ?? null,
      trialStartedAt: now,
      trialEndsAt,
      seats: event.quantity,
    });
    return;
  }

  await applyPlanToAccountSubscription(tx, event.accountId, plan, {
    provider: event.provider,
    providerSubscriptionId: event.providerSubscriptionId ?? null,
    providerTransactionId: event.providerTransactionId ?? null,
    currentPeriodEnd: event.currentPeriodEnd ?? null,
    seats: event.quantity,
  });
}

export async function applySubscriptionEvent(
  db: DB,
  relay: RelayPushConfig,
  event: NormalizedEvent,
  rawPayload: unknown,
  fetchImpl: typeof fetch = fetch
): Promise<{ duplicate: boolean }> {
  const existing = await db.webhookEvent.findUnique({
    where: { providerEventId: event.providerEventId },
  });
  if (existing) return { duplicate: true };

  const resolved = await resolveEventIdentity(db, event);
  if (!resolved) {
    console.warn("[billing] webhook event could not be resolved to a subscription", {
      provider: event.provider,
      type: event.type,
      providerEventId: event.providerEventId,
      providerSubscriptionId: event.providerSubscriptionId,
    });
    return { duplicate: false };
  }
  event = resolved;

  const account = await db.productAccount.findUnique({
    where: { id: event.accountId },
    select: { id: true, deletedAt: true },
  });
  if (!account) {
    console.warn("[billing] webhook account not found", {
      provider: event.provider,
      type: event.type,
      providerEventId: event.providerEventId,
      accountId: event.accountId,
    });
    return { duplicate: false };
  }
  // A deleted (tombstoned) account must never be resurrected by a late webhook.
  if (account.deletedAt) {
    console.warn("[billing] webhook for deleted account ignored", {
      provider: event.provider,
      type: event.type,
      providerEventId: event.providerEventId,
      accountId: event.accountId,
    });
    // Record the event so provider redeliveries short-circuit at the dedup check
    // above instead of re-resolving on every retry. Tolerate a concurrent insert.
    try {
      await db.webhookEvent.create({
        data: {
          provider: event.provider,
          providerEventId: event.providerEventId,
          type: event.type,
          payload: (rawPayload ?? {}) as Prisma.InputJsonValue,
          processedAt: new Date(),
        },
      });
    } catch (e) {
      if (!isUniqueViolation(e)) throw e;
    }
    return { duplicate: false };
  }

  const status = STATUS_BY_TYPE[event.type];
  const isActivation = status === "active" && event.type === "activated";
  const plan = await findPlanBySlug(db, event.planId);
  if (!plan) throw new Error(`unknown plan: ${event.planId}`);

  if (isActivation && (await isDuplicateActivation(db, event))) {
    return { duplicate: true };
  }

  const now = new Date();

  try {
    await db.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`billing:${event.accountId}`}))`;

      await tx.webhookEvent.create({
        data: {
          provider: event.provider,
          providerEventId: event.providerEventId,
          type: event.type,
          payload: (rawPayload ?? {}) as Prisma.InputJsonValue,
          processedAt: now,
        },
      });

      if (event.type === "renewed") {
        const converted = await upgradeTrialToProYearlyOnRenewal(tx, event);
        if (converted) return;

        if (event.providerSubscriptionId) {
          const existing = await tx.subscription.findUnique({
            where: { providerSubscriptionId: event.providerSubscriptionId },
          });
          if (!existing) {
            await provisionActivatedPlan(tx, event, plan, now);
            return;
          }

          await tx.subscription.updateMany({
            where: { providerSubscriptionId: event.providerSubscriptionId },
            data: {
              status,
              currentPeriodEnd: event.currentPeriodEnd ?? undefined,
              // The cycle-end catch-up: a seat change razorpay scheduled rather
              // than applied is only observable once it has been charged for.
              ...(event.quantity !== undefined ? { seats: event.quantity } : {}),
              ...(event.providerTransactionId
                ? { providerTransactionId: event.providerTransactionId }
                : {}),
              updatedAt: now,
            },
          });
        }
        return;
      }

      if (isActivation) {
        // A seat change on a live subscription must never be routed through
        // provisioning: applyPlanToAccountSubscription detaches provider ids
        // before its own lookup, so it would create a fresh row per portal
        // edit, re-snapshotting limits from the current plan and losing the
        // original createdAt — while every read still returns the newest row.
        if (!(await applySeatChangeInPlace(tx, event, now))) {
          await provisionActivatedPlan(tx, event, plan, now);
        }
      } else if (event.providerSubscriptionId) {
        const cancelledAt = event.type === "canceled" || event.type === "expired" ? now : undefined;
        await tx.subscription.updateMany({
          where: { providerSubscriptionId: event.providerSubscriptionId },
          data: {
            status,
            ...(cancelledAt ? { cancelledAt } : {}),
            updatedAt: now,
          },
        });
        if (event.type === "canceled" || event.type === "expired") {
          await ensureFreeSubscription(tx, event.accountId);
        }
      } else {
        console.warn("[billing] subscription event ignored: no providerSubscriptionId", {
          provider: event.provider,
          type: event.type,
          providerEventId: event.providerEventId,
        });
      }
    });
  } catch (e) {
    if (isUniqueViolation(e)) return { duplicate: true };
    throw e;
  }

  // A webhook is an ACCOUNT-level entitlement change, so it reaches every active
  // member and not just the owner. Best-effort by position: this sits outside
  // the transaction above.
  await pushExpireAll(relay, await listBillingAccountUserIds(db, event.accountId), fetchImpl);

  return { duplicate: false };
}
