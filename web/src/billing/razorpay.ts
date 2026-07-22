import { createHmac } from "node:crypto";
import Razorpay from "razorpay";
import { validatePaymentVerification } from "razorpay/dist/utils/razorpay-utils.js";
import { isPlanId, type PlanId } from "./plans.js";
import type { NormalizedEvent, PaymentProvider } from "./events.js";

type RazorpayNotes = { accountId?: string; planId?: string };

let razorpayCached: { key: string; client: Razorpay } | null = null;

export function getRazorpayClient(keyId: string, keySecret: string): Razorpay {
  const cacheKey = `${keyId}:${keySecret}`;
  if (!razorpayCached || razorpayCached.key !== cacheKey) {
    razorpayCached = { key: cacheKey, client: new Razorpay({ key_id: keyId, key_secret: keySecret }) };
  }
  return razorpayCached.client;
}

export type RazorpaySubscriptionEntity = {
  current_end?: number | null;
  status?: string;
};

/** Cancel immediately (trial) or at current cycle end (pro yearly). */
export async function razorpayCancelSubscription(
  razorpay: Razorpay,
  subscriptionId: string,
  cancelAtCycleEnd: boolean
): Promise<RazorpaySubscriptionEntity> {
  return (await razorpay.subscriptions.cancel(
    subscriptionId,
    cancelAtCycleEnd
  )) as RazorpaySubscriptionEntity;
}

/** Undo a pending period-end cancellation (Razorpay cancel_scheduled_changes). */
export async function razorpayResumePendingCancellation(
  razorpay: Razorpay,
  subscriptionId: string
): Promise<RazorpaySubscriptionEntity> {
  return (await razorpay.subscriptions.cancelScheduledChanges(
    subscriptionId
  )) as RazorpaySubscriptionEntity;
}

export function razorpayPeriodEnd(entity: RazorpaySubscriptionEntity): Date | null {
  if (entity.current_end == null) return null;
  return new Date(entity.current_end * 1000);
}

/** HMAC-SHA256 over `payload` — webhook body or `orderId|paymentId` callback. */
export function verifyRazorpayHmac(payload: string, secret: string, signature: string): boolean {
  if (payload.includes("|")) {
    const [orderId, paymentId] = payload.split("|");
    if (orderId && paymentId) {
      return validatePaymentVerification({ order_id: orderId, payment_id: paymentId }, signature, secret);
    }
  }
  return Razorpay.validateWebhookSignature(payload, signature, secret);
}

function readNotes(notes: RazorpayNotes | undefined): { accountId: string; planId: PlanId } | null {
  if (!notes || typeof notes.accountId !== "string" || typeof notes.planId !== "string") return null;
  if (!isPlanId(notes.planId)) return null;
  return { accountId: notes.accountId, planId: notes.planId };
}

function readPaymentId(envelope: RazorpayWebhook): string | undefined {
  const id = envelope.payload?.payment?.entity?.id;
  return typeof id === "string" && id.length > 0 ? id : undefined;
}

type RazorpayWebhook = {
  event: string;
  payload?: {
    payment?: {
      entity?: { id?: string; order_id?: string; customer_id?: string; notes?: RazorpayNotes };
    };
    subscription?: {
      entity?: {
        id?: string;
        customer_id?: string;
        status?: string;
        notes?: RazorpayNotes;
        current_end?: number;
      };
    };
  };
};

export function logRazorpayPaymentFailure(rawBody: string): boolean {
  let envelope: RazorpayWebhook;
  try {
    envelope = JSON.parse(rawBody) as RazorpayWebhook;
  } catch {
    return false;
  }
  if (envelope.event !== "payment.failed") return false;

  const payment = envelope.payload?.payment?.entity as
    | {
        id?: string;
        order_id?: string;
        subscription_id?: string;
        customer_id?: string;
        notes?: RazorpayNotes;
        error_code?: string;
        error_description?: string;
      }
    | undefined;
  const cd = readNotes(payment?.notes);
  console.warn("[billing] razorpay payment failed", {
    paymentId: payment?.id,
    orderId: payment?.order_id,
    subscriptionId: payment?.subscription_id,
    customerId: payment?.customer_id,
    accountId: cd?.accountId,
    planId: cd?.planId,
    errorCode: payment?.error_code,
    errorDescription: payment?.error_description,
  });
  return true;
}

export class RazorpayProvider implements PaymentProvider {
  readonly id = "razorpay" as const;

  constructor(private readonly cfg: { webhookSecret: string }) {}

  async verifyWebhook(rawBody: string, signature: string | undefined): Promise<NormalizedEvent | null> {
    if (!signature) throw new Error("missing razorpay signature");
    if (!Razorpay.validateWebhookSignature(rawBody, signature, this.cfg.webhookSecret)) {
      throw new Error("invalid razorpay signature");
    }

    const envelope = JSON.parse(rawBody) as RazorpayWebhook;
    const eventId = `${envelope.event}:${rawBody.length}:${createHmac("sha256", "id").update(rawBody).digest("hex").slice(0, 16)}`;

    if (envelope.event === "payment.captured") {
      const payment = envelope.payload?.payment?.entity;
      const cd = readNotes(payment?.notes);
      if (!cd || cd.planId !== "pro_lifetime" || !payment?.id) return null;
      const customerId = payment.customer_id;
      if (!customerId) return null;
      return {
        provider: "razorpay",
        providerEventId: eventId,
        type: "activated",
        accountId: cd.accountId,
        planId: cd.planId,
        customerId,
        providerTransactionId: payment.id,
      };
    }

    if (envelope.event === "subscription.authenticated") {
      const sub = envelope.payload?.subscription?.entity;
      const cd = readNotes(sub?.notes);
      if (!cd || cd.planId !== "trial" || !sub?.id) return null;
      const customerId = sub.customer_id;
      if (!customerId) return null;
      return {
        provider: "razorpay",
        providerEventId: eventId,
        type: "activated",
        accountId: cd.accountId,
        planId: cd.planId,
        customerId,
        providerSubscriptionId: sub.id,
        providerTransactionId: readPaymentId(envelope),
      };
    }

    if (envelope.event === "subscription.activated" || envelope.event === "subscription.charged") {
      const sub = envelope.payload?.subscription?.entity;
      const cd = readNotes(sub?.notes);
      if (!cd || !sub?.id) return null;
      const ends = sub.current_end ? new Date(sub.current_end * 1000) : undefined;
      const customerId = sub.customer_id;
      if (!customerId) return null;
      return {
        provider: "razorpay",
        providerEventId: eventId,
        type: envelope.event === "subscription.charged" ? "renewed" : "activated",
        accountId: cd.accountId,
        planId: cd.planId,
        customerId,
        providerSubscriptionId: sub.id,
        providerTransactionId: readPaymentId(envelope),
        currentPeriodEnd: ends,
      };
    }

    if (envelope.event === "subscription.cancelled") {
      const sub = envelope.payload?.subscription?.entity;
      if (!sub?.id) return null;
      const customerId = sub.customer_id;
      if (!customerId) return null;
      const cd = readNotes(sub.notes);
      return {
        provider: "razorpay",
        providerEventId: eventId,
        type: "canceled",
        accountId: cd?.accountId ?? "",
        planId: cd?.planId ?? "pro_yearly",
        customerId,
        providerSubscriptionId: sub.id,
      };
    }

    return null;
  }
}

export { validatePaymentVerification };
