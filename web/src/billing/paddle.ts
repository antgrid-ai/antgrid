import { createHmac, timingSafeEqual } from "node:crypto";
import { Environment, Paddle, type Subscription } from "@paddle/paddle-node-sdk";
import { isPlanId, type PlanId } from "./plans.js";
import type { CheckoutEnv } from "./checkout.js";
import type { NormalizedEvent, NormalizedEventType, PaymentProvider } from "./events.js";

/** Paddle webhook signatures older than this are rejected (replay protection). */
export const PADDLE_MAX_AGE_MS = 5 * 60 * 1000;

let paddleRuntimeReady = false;
let paddleCached: { key: string; client: Paddle } | null = null;

/** Paddle webhook HMAC needs NodeRuntime crypto — initialized by constructing Paddle once. */
function ensurePaddleRuntime(): void {
  if (paddleRuntimeReady) return;
  new Paddle("runtime_init", { environment: Environment.sandbox });
  paddleRuntimeReady = true;
}

/** Short-lived token for Paddle.js to present saved payment methods for a returning customer. */
export async function paddleCustomerCheckoutAuth(
  paddle: Paddle,
  customerId: string
): Promise<{ customerAuthToken: string } | null> {
  try {
    const auth = await paddle.customers.generateAuthToken(customerId);
    if (!auth.customerAuthToken) return null;
    return { customerAuthToken: auth.customerAuthToken };
  } catch {
    return null;
  }
}

export function getPaddleClient(env: CheckoutEnv): Paddle {
  if (!env.PADDLE_API_KEY) throw new Error("PADDLE_NOT_CONFIGURED");
  const envName = env.PADDLE_ENVIRONMENT === "sandbox" ? Environment.sandbox : Environment.production;
  const cacheKey = `${env.PADDLE_API_KEY}:${envName}`;
  if (!paddleCached || paddleCached.key !== cacheKey) {
    ensurePaddleRuntime();
    paddleCached = {
      key: cacheKey,
      client: new Paddle(env.PADDLE_API_KEY, { environment: envName }),
    };
  }
  return paddleCached.client;
}

/** Cancel immediately (trial) or at next billing period (pro yearly). */
export async function paddleCancelSubscription(
  paddle: Paddle,
  subscriptionId: string,
  cancelAtCycleEnd: boolean
): Promise<Subscription> {
  return paddle.subscriptions.cancel(subscriptionId, {
    effectiveFrom: cancelAtCycleEnd ? "next_billing_period" : "immediately",
  });
}

/** Remove a pending period-end cancellation (Paddle scheduled_change). */
export async function paddleResumePendingCancellation(
  paddle: Paddle,
  subscriptionId: string
): Promise<Subscription> {
  return paddle.subscriptions.update(subscriptionId, { scheduledChange: null });
}

export function paddlePeriodEnd(subscription: Subscription): Date | null {
  const effectiveAt = subscription.scheduledChange?.effectiveAt;
  if (effectiveAt) return new Date(effectiveAt);
  const endsAt = subscription.currentBillingPeriod?.endsAt;
  if (endsAt) return new Date(endsAt);
  return null;
}

type PaddleCustomData = { accountId?: string; planId?: string } | null | undefined;

const SUB_STATUS_TO_TYPE: Record<string, NormalizedEventType> = {
  active: "activated",
  trialing: "activated",
  past_due: "past_due",
  canceled: "canceled",
  paused: "past_due",
};

function mapPaddleSubscriptionEvent(
  eventType: string,
  status: string
): NormalizedEventType | null {
  if (eventType === "subscription.canceled") return "canceled";
  if (eventType === "subscription.past_due") return "past_due";
  return SUB_STATUS_TO_TYPE[status] ?? null;
}

function verifyPaddleSignature(rawBody: string, secret: string, signature: string): boolean {
  const parts = signature.split(";");
  let ts = "";
  let h1 = "";
  for (const part of parts) {
    const eq = part.indexOf("=");
    if (eq === -1) continue;
    const key = part.slice(0, eq);
    const value = part.slice(eq + 1);
    if (key === "ts") ts = value;
    else if (key === "h1") h1 = value;
  }
  if (!ts || !h1) return false;

  const tsNum = parseInt(ts, 10);
  if (Number.isNaN(tsNum)) return false;
  if (Math.abs(Date.now() - tsNum * 1000) > PADDLE_MAX_AGE_MS) return false;

  const expected = createHmac("sha256", secret).update(`${ts}:${rawBody}`).digest("hex");
  if (expected.length !== h1.length) return false;
  return timingSafeEqual(Buffer.from(expected), Buffer.from(h1));
}

function readCustomData(data: {
  custom_data?: PaddleCustomData;
  customData?: PaddleCustomData;
}): { accountId: string; planId: PlanId } | null {
  const cd = data.custom_data ?? data.customData ?? null;
  if (!cd || typeof cd.accountId !== "string" || typeof cd.planId !== "string" || !isPlanId(cd.planId)) {
    return null;
  }
  return { accountId: cd.accountId, planId: cd.planId };
}

type PaddleBillingPeriod = { starts_at?: string; ends_at?: string; startsAt?: string; endsAt?: string };

type PaddlePayload = {
  event_id: string;
  event_type: string;
  data: {
    id?: string;
    customer_id?: string;
    customerId?: string;
    subscription_id?: string;
    subscriptionId?: string;
    status?: string;
    custom_data?: PaddleCustomData;
    customData?: PaddleCustomData;
    current_billing_period?: PaddleBillingPeriod;
    currentBillingPeriod?: PaddleBillingPeriod;
    billing_period?: PaddleBillingPeriod;
    billingPeriod?: PaddleBillingPeriod;
    details?: {
      totals?: { grand_total?: string; grandTotal?: string };
    };
  };
};

function readSubscriptionId(data: PaddlePayload["data"]): string | undefined {
  return data.subscription_id ?? data.subscriptionId;
}

function readPeriodEnd(data: PaddlePayload["data"]): Date | undefined {
  const bp =
    data.billing_period ??
    data.billingPeriod ??
    data.current_billing_period ??
    data.currentBillingPeriod;
  const endsAt = bp?.ends_at ?? bp?.endsAt;
  return endsAt ? new Date(endsAt) : undefined;
}

/** Grand total in minor units (cents). Zero for card-on-file trial checkout. */
function readTransactionTotalCents(data: PaddlePayload["data"]): number {
  const raw = data.details?.totals?.grand_total ?? data.details?.totals?.grandTotal ?? "0";
  const n = parseInt(raw, 10);
  return Number.isNaN(n) ? 0 : n;
}

export function logPaddlePaymentFailure(rawBody: string): boolean {
  let event: PaddlePayload;
  try {
    event = JSON.parse(rawBody) as PaddlePayload;
  } catch {
    return false;
  }
  if (event.event_type !== "transaction.payment_failed") return false;

  const data = event.data ?? {};
  const cd = readCustomData(data);
  const payments = (data as { payments?: { status?: string; error_code?: string; errorCode?: string }[] })
    .payments;
  const lastAttempt = payments?.at(-1);
  console.warn("[billing] paddle payment failed", {
    eventId: event.event_id,
    transactionId: data.id,
    customerId: data.customer_id ?? data.customerId,
    subscriptionId: readSubscriptionId(data),
    accountId: cd?.accountId,
    planId: cd?.planId,
    errorCode: lastAttempt?.error_code ?? lastAttempt?.errorCode,
    paymentStatus: lastAttempt?.status,
  });
  return true;
}

export class PaddleProvider implements PaymentProvider {
  readonly id = "paddle" as const;

  constructor(private readonly cfg: { webhookSecret: string }) {}

  async verifyWebhook(rawBody: string, signature: string | undefined): Promise<NormalizedEvent | null> {
    if (!signature) throw new Error("missing paddle-signature header");

    if (!verifyPaddleSignature(rawBody, this.cfg.webhookSecret, signature)) {
      throw new Error("invalid paddle signature");
    }

    const event = JSON.parse(rawBody) as PaddlePayload;
    const data = event.data ?? {};
    const cd = readCustomData(data);
    const customerId = data.customer_id ?? data.customerId;

    const base = {
      provider: "paddle" as const,
      providerEventId: event.event_id,
      accountId: cd?.accountId ?? "",
      planId: cd?.planId ?? ("pro_yearly" as PlanId),
      customerId: customerId ?? "",
    };

    if (event.event_type.startsWith("subscription.")) {
      const type = mapPaddleSubscriptionEvent(event.event_type, data.status ?? "");
      if (!type || !data.id || !customerId) return null;
      return {
        ...base,
        type,
        providerSubscriptionId: data.id,
        currentPeriodEnd: readPeriodEnd(data),
      };
    }

    if (!cd || !customerId) return null;

    if (event.event_type === "transaction.completed" && data.id) {
      const subscriptionId = readSubscriptionId(data);
      const periodEnd = readPeriodEnd(data);
      const totalCents = readTransactionTotalCents(data);

      if (cd.planId === "pro_lifetime") {
        return { ...base, type: "activated", providerTransactionId: data.id };
      }

      // Trial checkout completes as $0 transaction.completed (subscription_id + billing_period).
      if (cd.planId === "trial") {
        if (!subscriptionId) return null;
        if (totalCents === 0) {
          return {
            ...base,
            type: "activated",
            providerSubscriptionId: subscriptionId,
            providerTransactionId: data.id,
            currentPeriodEnd: periodEnd,
          };
        }
        return {
          ...base,
          type: "renewed",
          providerSubscriptionId: subscriptionId,
          providerTransactionId: data.id,
          currentPeriodEnd: periodEnd,
        };
      }

      // Pro Yearly without trial — provision from transaction when subscription.* webhooks are absent.
      if (cd.planId === "pro_yearly" && subscriptionId && totalCents > 0) {
        return {
          ...base,
          type: "activated",
          providerSubscriptionId: subscriptionId,
          providerTransactionId: data.id,
          currentPeriodEnd: periodEnd,
        };
      }
    }

    return null;
  }
}
