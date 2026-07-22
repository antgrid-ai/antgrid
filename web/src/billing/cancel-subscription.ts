import type { DB } from "../db/index.js";
import type { RelayPushConfig } from "../relay/push.js";
import type { PlanRow } from "../models/plan.js";
import type { SubscriptionRow } from "../models/subscription.js";
import {
  ensureFreeSubscription,
  isPendingCancellation,
} from "../models/subscription.js";
import { pushExpire } from "../relay/push.js";
import type { CheckoutEnv } from "./checkout.js";
import {
  getPaddleClient,
  paddleCancelSubscription,
  paddlePeriodEnd,
  paddleResumePendingCancellation,
} from "./paddle.js";
import {
  getRazorpayClient,
  razorpayCancelSubscription,
  razorpayPeriodEnd,
  razorpayResumePendingCancellation,
} from "./razorpay.js";

export type CancelEffective = "immediately" | "end_of_period";

export class CancelSubscriptionError extends Error {
  constructor(
    readonly code:
      | "NOT_RECURRING"
      | "NO_ACTIVE_SUBSCRIPTION"
      | "NO_PROVIDER_SUBSCRIPTION"
      | "UNSUPPORTED_PROVIDER"
      | "PADDLE_NOT_CONFIGURED"
      | "RAZORPAY_NOT_CONFIGURED"
      | "PROVIDER_CANCEL_FAILED",
    message?: string
  ) {
    super(message ?? code);
    this.name = "CancelSubscriptionError";
  }
}

export class ResumeSubscriptionError extends Error {
  constructor(
    readonly code:
      | "NOT_RECURRING"
      | "NOT_PENDING_CANCELLATION"
      | "NO_PROVIDER_SUBSCRIPTION"
      | "UNSUPPORTED_PROVIDER"
      | "PADDLE_NOT_CONFIGURED"
      | "RAZORPAY_NOT_CONFIGURED"
      | "PROVIDER_RESUME_FAILED",
    message?: string
  ) {
    super(message ?? code);
    this.name = "ResumeSubscriptionError";
  }
}

function cancelEffectiveForPlan(plan: PlanRow): CancelEffective {
  return plan.trial ? "immediately" : "end_of_period";
}

function periodEndForSubscription(subscription: SubscriptionRow, now: Date): Date {
  return (
    subscription.currentPeriodEnd ?? new Date(now.getTime() + 365 * 24 * 60 * 60 * 1000)
  );
}

type ProviderCancelResult = { effective: CancelEffective; periodEnd: Date | null };

async function cancelAtProvider(
  env: CheckoutEnv,
  args: {
    provider: string;
    providerSubscriptionId: string;
    plan: PlanRow;
  }
): Promise<ProviderCancelResult> {
  const effective = cancelEffectiveForPlan(args.plan);
  const cancelAtCycleEnd = effective === "end_of_period";

  if (args.provider === "paddle") {
    if (!env.PADDLE_API_KEY) throw new CancelSubscriptionError("PADDLE_NOT_CONFIGURED");
    const paddle = getPaddleClient(env);
    try {
      const updated = await paddleCancelSubscription(
        paddle,
        args.providerSubscriptionId,
        cancelAtCycleEnd
      );
      return { effective, periodEnd: paddlePeriodEnd(updated) };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      throw new CancelSubscriptionError("PROVIDER_CANCEL_FAILED", msg);
    }
  }

  if (args.provider === "razorpay") {
    if (!env.RAZORPAY_KEY_ID || !env.RAZORPAY_KEY_SECRET) {
      throw new CancelSubscriptionError("RAZORPAY_NOT_CONFIGURED");
    }
    const razorpay = getRazorpayClient(env.RAZORPAY_KEY_ID, env.RAZORPAY_KEY_SECRET);
    try {
      const updated = await razorpayCancelSubscription(
        razorpay,
        args.providerSubscriptionId,
        cancelAtCycleEnd
      );
      return { effective, periodEnd: razorpayPeriodEnd(updated) };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      throw new CancelSubscriptionError("PROVIDER_CANCEL_FAILED", msg);
    }
  }

  throw new CancelSubscriptionError("UNSUPPORTED_PROVIDER", args.provider);
}

async function resumeAtProvider(
  env: CheckoutEnv,
  args: {
    provider: string;
    providerSubscriptionId: string;
  }
): Promise<void> {
  if (args.provider === "paddle") {
    if (!env.PADDLE_API_KEY) throw new ResumeSubscriptionError("PADDLE_NOT_CONFIGURED");
    const paddle = getPaddleClient(env);
    try {
      await paddleResumePendingCancellation(paddle, args.providerSubscriptionId);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      throw new ResumeSubscriptionError("PROVIDER_RESUME_FAILED", msg);
    }
    return;
  }

  if (args.provider === "razorpay") {
    if (!env.RAZORPAY_KEY_ID || !env.RAZORPAY_KEY_SECRET) {
      throw new ResumeSubscriptionError("RAZORPAY_NOT_CONFIGURED");
    }
    const razorpay = getRazorpayClient(env.RAZORPAY_KEY_ID, env.RAZORPAY_KEY_SECRET);
    try {
      await razorpayResumePendingCancellation(razorpay, args.providerSubscriptionId);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      throw new ResumeSubscriptionError("PROVIDER_RESUME_FAILED", msg);
    }
    return;
  }

  throw new ResumeSubscriptionError("UNSUPPORTED_PROVIDER", args.provider);
}

async function markPendingCancellation(
  db: DB,
  subscriptionId: string,
  subscription: SubscriptionRow,
  now: Date,
  providerPeriodEnd: Date | null
): Promise<void> {
  const periodEnd = providerPeriodEnd ?? periodEndForSubscription(subscription, now);
  await db.subscription.update({
    where: { id: subscriptionId },
    data: {
      cancelledAt: periodEnd,
      currentPeriodEnd: periodEnd,
      updatedAt: now,
    },
  });
}

/** Cancel a recurring subscription at the gateway; final entitlement change on webhook (or immediately for trial/dev). */
export async function cancelRecurringSubscription(
  db: DB,
  relay: RelayPushConfig,
  env: CheckoutEnv,
  args: {
    accountId: string;
    subscription: SubscriptionRow & { plan: PlanRow };
  },
  fetchImpl: typeof fetch = fetch
): Promise<{ effective: CancelEffective }> {
  const { subscription, accountId } = args;

  if (!subscription.plan.recurring) {
    throw new CancelSubscriptionError("NOT_RECURRING");
  }
  if (subscription.status !== "active" || isPendingCancellation(subscription)) {
    throw new CancelSubscriptionError("NO_ACTIVE_SUBSCRIPTION");
  }

  const provider = subscription.provider;
  const providerSubscriptionId = subscription.providerSubscriptionId;
  const effective = cancelEffectiveForPlan(subscription.plan);
  const now = new Date();

  if (provider === "dev" || provider === null) {
    if (effective === "immediately") {
      await db.$transaction(async (tx) => {
        await tx.subscription.update({
          where: { id: subscription.id },
          data: { status: "canceled", cancelledAt: now, updatedAt: now },
        });
        await ensureFreeSubscription(tx, accountId);
      });
      const account = await db.productAccount.findUnique({
        where: { id: accountId },
        select: { userId: true },
      });
      if (account) await pushExpire(relay, account.userId, fetchImpl);
      return { effective: "immediately" };
    }

    await markPendingCancellation(db, subscription.id, subscription, now, null);
    return { effective: "end_of_period" };
  }

  if (!providerSubscriptionId) {
    throw new CancelSubscriptionError("NO_PROVIDER_SUBSCRIPTION");
  }

  if (effective === "end_of_period") {
    const estimatedEnd = periodEndForSubscription(subscription, now);
    await markPendingCancellation(db, subscription.id, subscription, now, estimatedEnd);
    try {
      const { periodEnd } = await cancelAtProvider(env, {
        provider,
        providerSubscriptionId,
        plan: subscription.plan,
      });
      if (periodEnd && periodEnd.getTime() !== estimatedEnd.getTime()) {
        await db.subscription.update({
          where: { id: subscription.id },
          data: { cancelledAt: periodEnd, currentPeriodEnd: periodEnd, updatedAt: now },
        });
      }
    } catch (e) {
      await db.subscription.update({
        where: { id: subscription.id },
        data: { cancelledAt: null, updatedAt: now },
      });
      throw e;
    }
    return { effective: "end_of_period" };
  }

  const { effective: providerEffective } = await cancelAtProvider(env, {
    provider,
    providerSubscriptionId,
    plan: subscription.plan,
  });

  return { effective: providerEffective };
}

/** Undo a pending period-end cancellation in our DB and at the gateway. */
export async function resumeRecurringSubscription(
  db: DB,
  env: CheckoutEnv,
  args: {
    subscription: SubscriptionRow & { plan: PlanRow };
  }
): Promise<void> {
  const { subscription } = args;

  if (!subscription.plan.recurring) {
    throw new ResumeSubscriptionError("NOT_RECURRING");
  }
  if (!isPendingCancellation(subscription)) {
    throw new ResumeSubscriptionError("NOT_PENDING_CANCELLATION");
  }

  const provider = subscription.provider;
  const providerSubscriptionId = subscription.providerSubscriptionId;
  const now = new Date();

  if (provider === "dev" || provider === null) {
    await db.subscription.update({
      where: { id: subscription.id },
      data: { cancelledAt: null, updatedAt: now },
    });
    return;
  }

  if (!providerSubscriptionId) {
    throw new ResumeSubscriptionError("NO_PROVIDER_SUBSCRIPTION");
  }

  await resumeAtProvider(env, { provider, providerSubscriptionId });
  await db.subscription.update({
    where: { id: subscription.id },
    data: { cancelledAt: null, updatedAt: now },
  });
}
