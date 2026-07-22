import type { Prisma } from "../generated/prisma/client.js";
import type { DB, Tx } from "../db/index.js";
import { pushExpire, type RelayPushConfig } from "../relay/push.js";
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

/** Webhook payloads may omit custom_data on subscription.canceled — resolve from our row. */
async function resolveEventIdentity(db: DB, event: NormalizedEvent): Promise<NormalizedEvent | null> {
  if (event.accountId && event.planId) {
    const plan = await findPlanBySlug(db, event.planId);
    if (plan) return event;
  }

  if (event.providerSubscriptionId) {
    const sub = await db.subscription.findUnique({
      where: { providerSubscriptionId: event.providerSubscriptionId },
      include: { plan: true },
    });
    if (sub && isPlanId(sub.plan.slug)) {
      return { ...event, accountId: sub.accountId, planId: sub.plan.slug };
    }
  }

  if (event.providerTransactionId) {
    const sub = await db.subscription.findUnique({
      where: { providerTransactionId: event.providerTransactionId },
      include: { plan: true },
    });
    if (sub && isPlanId(sub.plan.slug)) {
      return { ...event, accountId: sub.accountId, planId: sub.plan.slug };
    }
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
  return isActiveSubscription(sub, now);
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
    });
    return;
  }

  await applyPlanToAccountSubscription(tx, event.accountId, plan, {
    provider: event.provider,
    providerSubscriptionId: event.providerSubscriptionId ?? null,
    providerTransactionId: event.providerTransactionId ?? null,
    currentPeriodEnd: event.currentPeriodEnd ?? null,
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
        await provisionActivatedPlan(tx, event, plan, now);
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

  const owner = await db.productAccount.findUnique({
    where: { id: event.accountId },
    select: { userId: true },
  });
  if (owner) {
    await pushExpire(relay, owner.userId, fetchImpl);
  }

  return { duplicate: false };
}
