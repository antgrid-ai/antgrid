export type ProviderId = "paddle" | "razorpay";
export type PlanId = "trial" | "pro_yearly";

/** Card-on-file trial length before first charge (day 8). */
export const TRIAL_DAYS = 7;

/** Signed-in users without a paid subscription. */
export const FREE_TIER = "free";
/** Machines a free account may run an agent on — the wall, and the only paywall
 *  enforced on a server. Keep in lockstep with the `free` entry in
 *  CATALOG_PLANS and with `plans.worker_limit` in the migrations. */
export const FREE_WORKER_LIMIT = 1;

export interface PlanPricing {
  listPriceCents: number;
  offerPriceCents?: number;
  offerPercent?: number;
  trial: boolean;
  recurring: boolean;
}

export const PRICING: Record<PlanId, PlanPricing> = {
  trial: {
    listPriceCents: 9900,
    offerPriceCents: 4900,
    offerPercent: 50,
    trial: true,
    recurring: true,
  },
  pro_yearly: {
    listPriceCents: 9900,
    offerPriceCents: 4900,
    offerPercent: 50,
    trial: false,
    recurring: true,
  },
};

export function isPlanId(x: string): x is PlanId {
  return x === "trial" || x === "pro_yearly";
}

export function formatUsd(cents: number): string {
  return `$${(cents / 100).toFixed(cents % 100 === 0 ? 0 : 2)}`;
}

export type BillingEnv = {
  YEARLY_OFFER_ACTIVE?: boolean;
  /** Single Paddle yearly price (trial_period on the price is OK — Pro Yearly checkout clones it without trial). */
  PADDLE_PRICE_YEARLY?: string;
  PADDLE_DISCOUNT_ID_YEARLY_OFFER?: string;
  RAZORPAY_PLAN_TRIAL?: string;
  RAZORPAY_PLAN_YEARLY?: string;
};

export function yearlyOfferActive(env: BillingEnv): boolean {
  return env.YEARLY_OFFER_ACTIVE === true;
}

export function displayPriceCents(planId: PlanId, env: BillingEnv): number {
  const p = PRICING[planId];
  if (yearlyOfferActive(env) && p.offerPriceCents != null) return p.offerPriceCents;
  return p.listPriceCents;
}

export function resolvePaddleDiscountId(env: BillingEnv): string | undefined {
  if (!yearlyOfferActive(env)) return undefined;
  const id = env.PADDLE_DISCOUNT_ID_YEARLY_OFFER;
  return id && id.length > 0 ? id : undefined;
}

export function resolveCheckoutSku(
  planId: PlanId,
  provider: ProviderId,
  env: BillingEnv
): string | undefined {
  if (provider === "paddle") {
    // One Paddle yearly price (sandbox/production) — trial uses trial_period; pro_yearly skips it.
    return env.PADDLE_PRICE_YEARLY;
  }
  if (planId === "trial") return env.RAZORPAY_PLAN_TRIAL ?? env.RAZORPAY_PLAN_YEARLY;
  return env.RAZORPAY_PLAN_YEARLY;
}
