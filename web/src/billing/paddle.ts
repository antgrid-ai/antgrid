import { createHmac, timingSafeEqual } from "node:crypto";
import { Environment, Paddle, type Subscription } from "@paddle/paddle-node-sdk";
import { z } from "zod";
import { isPlanId, type PlanId } from "./plans.js";
import type { CheckoutEnv } from "./checkout.js";
import { readSeatQuantity } from "./events.js";
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

/**
 * Rebill the subscription for `quantity` seats.
 *
 * The prices are read off the live subscription and resubmitted, never taken
 * from the catalog: `buildPaddleTransactionItems` clones a non-catalog price
 * with `trialPeriod: null` for `pro_yearly`, so the catalog id is a DIFFERENT
 * price for exactly the plan people buy — sending it would move the customer
 * onto a trial period and whatever amount the catalog currently holds.
 *
 * `items` replaces the whole line set, so a subscription carrying more than one
 * live line has no unambiguous answer to which one the seats are on; the seat
 * reader on the webhook side refuses the same shape for the same reason.
 * `inactive` lines are already-removed ones and are not resubmitted.
 *
 * The proration mode is stated rather than defaulted: Paddle's default is an
 * account-level setting, so leaving it off makes what the customer is charged
 * depend on a dashboard toggle nobody here can see.
 */
export async function paddleUpdateSubscriptionQuantity(
  paddle: Paddle,
  subscriptionId: string,
  quantity: number
): Promise<Subscription> {
  const current = await paddle.subscriptions.get(subscriptionId);
  const live = (current.items ?? []).filter((item) => item.status !== "inactive");
  if (live.length !== 1) {
    throw new Error(`PADDLE_AMBIGUOUS_SUBSCRIPTION_ITEMS: ${live.length} live items`);
  }
  const priceId = live[0]?.price?.id;
  if (!priceId) throw new Error("PADDLE_SUBSCRIPTION_ITEM_HAS_NO_PRICE");

  return paddle.subscriptions.update(subscriptionId, {
    items: [{ priceId, quantity }],
    prorationBillingMode: "prorated_immediately",
  });
}

/**
 * Seats Paddle is billing on this subscription right now, or null when it
 * reports none this side can read.
 *
 * The read half of `paddleUpdateSubscriptionQuantity`, and it asks the same
 * question of the same field — `items[].quantity` on the one live line — because
 * a reader that disagreed with the writer would report drift the moment we
 * ourselves wrote the count.
 *
 * Null where the write twin throws: this runs over every subscription in a
 * sweep, and a shape nothing can interpret is a subscription to leave alone, not
 * a run to abort. An unreadable quantity is emphatically NOT zero — writing one
 * would strand a whole team on a number no gateway ever billed.
 */
export async function paddleReadSubscriptionQuantity(
  paddle: Paddle,
  subscriptionId: string
): Promise<number | null> {
  const current = await paddle.subscriptions.get(subscriptionId);
  return readPaddleQuantity(current.items) ?? null;
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
    items?: unknown;
    details?: {
      totals?: { grand_total?: string; grandTotal?: string };
    };
  };
};

/** Only the two fields a seat read may touch. `quantity` stays `unknown` so the
 *  seat parser, not this schema, decides what counts as a seat count. */
const PaddleItemsSchema = z.array(
  z.object({
    status: z.string().optional(),
    quantity: z.unknown().optional(),
  })
);

/**
 * Seats billed on this subscription, or undefined when the line set says nothing
 * about them.
 *
 * Seats live on `items[].quantity`. Never on `price.quantity` — that is an
 * allowed `{minimum, maximum}` range which reads as a plausible small integer
 * and never moves when seats do. `inactive` items are removed lines that Paddle
 * still lists.
 *
 * `buildPaddleTransactionItems` builds exactly one billable line per
 * subscription, so two live lines means the payload is not one of ours and
 * nothing here can tell which line carries the seats. Summing them would count
 * removed lines and proration entries. Report nothing rather than guess.
 *
 * Takes the lines rather than a payload so the webhook and the API read share
 * it: the SDK's `Subscription` entity is camelCase throughout, but `items`,
 * `status` and `quantity` are spelled the same on both, and one rule is the only
 * way a fetched count and a pushed one can agree.
 */
function readPaddleQuantity(items: unknown): number | undefined {
  const parsed = PaddleItemsSchema.safeParse(items);
  if (!parsed.success) return undefined;

  const live = parsed.data.filter((item) => item.status !== "inactive");
  if (live.length !== 1) {
    if (live.length > 1) {
      console.warn("[billing] paddle payload has several live items; seat count not read", {
        liveItems: live.length,
      });
    }
    return undefined;
  }
  return readSeatQuantity(live[0]?.quantity);
}

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
      quantity: readPaddleQuantity(data.items),
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
