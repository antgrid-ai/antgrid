// Marketing pricing — KEEP IN LOCKSTEP with web/src/billing/plans.ts (PRICING) and
// web/src/models/plan.ts (sessionLimit). Marketing labels the cap as "concurrent remote
// agents"; the backend currently enforces a paired-device cap (web/src/models/device.ts) —
// alignment is tracked separately (see the landing design spec). If YEARLY_OFFER_ACTIVE is
// turned off in web, set OFFER_ACTIVE=false here so the struck price/discount disappear.
export const TRIAL_DAYS = 7;
export const REMOTE_AGENT_CAP = 3;
export const YEARLY_LIST_USD = 99;
export const YEARLY_OFFER_USD = 49;
export const LIFETIME_USD = 99;
export const OFFER_ACTIVE = true;

export type PlanCardData = {
  id: "pro_yearly" | "pro_lifetime";
  // checkoutId overrides the planId sent to the checkout URL (e.g. yearly trial uses sku "trial").
  checkoutId?: string;
  name: string;
  priceUsd: number;
  listUsd?: number;
  unit: string;
  note: string;
  features: string[];
  cta: string;
  ctaFooter: string;
  recommended?: boolean;
};

export const proYearly: PlanCardData = {
  id: "pro_yearly",
  // Yearly entry point is the trial sku; converts to pro_yearly after 7 days.
  checkoutId: "trial",
  name: "Pro Yearly",
  priceUsd: OFFER_ACTIVE ? YEARLY_OFFER_USD : YEARLY_LIST_USD,
  listUsd: OFFER_ACTIVE ? YEARLY_LIST_USD : undefined,
  unit: "/ year",
  note: `${TRIAL_DAYS}-day free trial, then $${OFFER_ACTIVE ? YEARLY_OFFER_USD : YEARLY_LIST_USD}/year`,
  features: [
    `Up to ${REMOTE_AGENT_CAP} concurrent remote agents`,
    "Encrypted remote control from your phone",
    "Fleet view across all your machines",
    "AI supervisor — wakes you only when it matters",
    "File explorer, git & browser preview",
    "E2E zero-knowledge relay · priority support",
  ],
  cta: "Start 7-day trial",
  ctaFooter: "Card not charged until day 8 · cancel anytime",
};

export const proLifetime: PlanCardData = {
  id: "pro_lifetime",
  name: "Pro Lifetime",
  priceUsd: LIFETIME_USD,
  unit: "one-time",
  note: "Pay once, use forever · best long-term value",
  features: [
    "Everything in Pro Yearly",
    "Lifetime updates",
    "No renewal fees, ever",
    `Up to ${REMOTE_AGENT_CAP} concurrent remote agents`,
  ],
  cta: "Get Lifetime",
  ctaFooter: "One-time payment · no subscription",
  recommended: true,
};
