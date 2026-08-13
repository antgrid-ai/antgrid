import { createHmac } from "node:crypto";
import Razorpay from "razorpay";
import { validatePaymentVerification } from "razorpay/dist/utils/razorpay-utils.js";
import { isPlanId, type PlanId } from "./plans.js";
import { readSeatQuantity } from "./events.js";
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
  /** `unknown` for the same reason the webhook schema leaves it so — the seat
   *  parser, not this type, decides what counts as a seat count. */
  quantity?: unknown;
  has_scheduled_changes?: boolean;
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

/**
 * Rebill the subscription for `quantity` seats.
 *
 * `schedule_change_at` is stated rather than left to Razorpay's default because
 * the two values are not interchangeable to us: a `cycle_end` change makes the
 * subscription report `has_scheduled_changes`, and `readRazorpayQuantity`
 * treats that as no seat information at all, so the count we just asked for
 * would be unreadable until the charge that applies it.
 */
export async function razorpayUpdateSubscriptionQuantity(
  razorpay: Razorpay,
  subscriptionId: string,
  quantity: number
): Promise<RazorpaySubscriptionEntity> {
  return (await razorpay.subscriptions.update(subscriptionId, {
    quantity,
    schedule_change_at: "now",
  })) as RazorpaySubscriptionEntity;
}

/**
 * Seats Razorpay is billing on this subscription right now, or null when it
 * reports none this side can read.
 *
 * `subscriptions.fetch` returns the very entity the webhook nests under
 * `payload.subscription.entity` — same snake_case, no SDK mapping — so the
 * pushed and pulled counts go through one reader and cannot disagree.
 *
 * A subscription carrying scheduled changes reads as null, not as its current
 * `quantity`: that number is the one the next charge will move past, so a sweep
 * that stored it would record a count the invoice has already left behind.
 * `razorpayUpdateSubscriptionQuantity` sends `schedule_change_at: "now"` for
 * exactly this reason — our own writes stay readable here.
 */
export async function razorpayReadSubscriptionQuantity(
  razorpay: Razorpay,
  subscriptionId: string
): Promise<number | null> {
  const entity = (await razorpay.subscriptions.fetch(subscriptionId)) as RazorpaySubscriptionEntity;
  return readRazorpayQuantity(entity) ?? null;
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
        quantity?: unknown;
        has_scheduled_changes?: boolean;
      };
    };
  };
};

/** The only two fields a seat read touches, so the webhook entity and the
 *  fetched one both satisfy it. */
type RazorpaySeatFields = { quantity?: unknown; has_scheduled_changes?: boolean };

/**
 * Seats billed on this subscription, or undefined when the payload says nothing
 * usable about them.
 *
 * On the subscription entity the seat count is genuinely `quantity` — not
 * `total_count`, `paid_count` or `remaining_count`, which are billing cycles,
 * and not the `unit` an invoice line-item payload would spell it with.
 *
 * A change scheduled for cycle end leaves `quantity` at the PREVIOUS count until
 * it applies, so reading it would record a number the invoice has already moved
 * past. The applied count arrives on the next `subscription.charged`, which is
 * why the renewal path writes seats too.
 */
function readRazorpayQuantity(entity: RazorpaySeatFields | undefined): number | undefined {
  if (entity?.has_scheduled_changes === true) return undefined;
  return readSeatQuantity(entity?.quantity);
}

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
        quantity: readRazorpayQuantity(sub),
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
        quantity: readRazorpayQuantity(sub),
      };
    }

    // A portal seat edit arrives here and nowhere else. It normalizes as
    // "activated" so it lands on the same still-active subscription the
    // reducer already holds; only `status: active` qualifies, because a seat
    // count on a created/halted subscription has no live row to be written to
    // and must not provision one.
    if (envelope.event === "subscription.updated") {
      const sub = envelope.payload?.subscription?.entity;
      if (!sub?.id || sub.status !== "active") return null;
      const customerId = sub.customer_id;
      if (!customerId) return null;
      // Notes are absent on any subscription not created through our checkout.
      // The reducer resolves identity from the row it already holds, so
      // tolerate them the way the cancelled branch does rather than dropping
      // the seat change with a 200.
      const cd = readNotes(sub.notes);
      return {
        provider: "razorpay",
        providerEventId: eventId,
        type: "activated",
        accountId: cd?.accountId ?? "",
        planId: cd?.planId ?? "pro_yearly",
        customerId,
        providerSubscriptionId: sub.id,
        currentPeriodEnd: sub.current_end ? new Date(sub.current_end * 1000) : undefined,
        quantity: readRazorpayQuantity(sub),
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
