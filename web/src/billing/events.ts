import { z } from "zod";
import type { PlanId, ProviderId } from "./plans.js";

export type NormalizedEventType = "activated" | "renewed" | "canceled" | "past_due" | "expired";

export interface NormalizedEvent {
  provider: ProviderId;
  providerEventId: string;
  type: NormalizedEventType;
  accountId: string;
  planId: PlanId;
  customerId: string;
  providerSubscriptionId?: string;
  providerTransactionId?: string;
  currentPeriodEnd?: Date;
  /** Seats the provider is billing for. ABSENT means this delivery carried no
   *  seat information — every unrelated payment-method or address update does —
   *  and must leave the stored count alone. Never fill it in with a default: a
   *  0 strands a whole team and a 1 silently downgrades every account but the
   *  smallest. */
  quantity?: number;
}

/** Gateways are loose about numeric types (razorpay declares `remaining_count`
 *  as a string), so a digit string is a seat count; 0, negatives, fractions and
 *  everything else are not seat information at all. */
const SeatQuantitySchema = z
  .union([z.number(), z.string().regex(/^\d+$/)])
  .transform((v) => (typeof v === "string" ? Number(v) : v))
  .pipe(z.number().int().positive());

export function readSeatQuantity(raw: unknown): number | undefined {
  const parsed = SeatQuantitySchema.safeParse(raw);
  return parsed.success ? parsed.data : undefined;
}

export interface PaymentProvider {
  readonly id: ProviderId;
  verifyWebhook(rawBody: string, signature: string | undefined): Promise<NormalizedEvent | null>;
}
