// Marketing pricing — KEEP IN LOCKSTEP with web/src/billing/plans.ts (PRICING) and
// web/src/models/plan.ts (workerLimit). A "worker" is one machine running antgrid;
// projects, terminals and sessions on that machine are uncapped, so this is the only
// number the tiers differ on. If YEARLY_OFFER_ACTIVE is turned off in web, set
// OFFER_ACTIVE=false here so the struck price/discount disappear.
//
// Checkout is deliberately unwired this release: every card that would charge carries
// `comingSoon`, which swaps the checkout link for a disabled button. Clearing the flag
// is what re-opens the paid path — see docs/plans/2026-07-30-worker-limit-pricing.md.
import { links } from "../config";

export const TRIAL_DAYS = 7;
export const FREE_WORKERS = 2;
export const TRIAL_WORKERS = 2;
export const PRO_WORKERS = 3;
export const YEARLY_LIST_USD = 99;
export const YEARLY_OFFER_USD = 49;
export const OFFER_ACTIVE = true;

export type PlanCardData = {
  id: "free" | "trial" | "pro_yearly" | "pro_lifetime";
  // checkoutId overrides the planId sent to the checkout URL (e.g. yearly trial uses sku "trial").
  checkoutId?: string;
  // ctaHref bypasses checkout entirely — for CTAs that are just sign-in links.
  ctaHref?: string;
  // Renders a disabled "Coming soon" button in place of the checkout CTA.
  comingSoon?: boolean;
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

export const free: PlanCardData = {
  id: "free",
  ctaHref: links.startFree,
  name: "Free",
  priceUsd: 0,
  unit: "forever",
  note: "Remote control included · no card",
  features: [
    `Up to ${FREE_WORKERS} worker machines`,
    "Encrypted remote control from your phone",
    "Unlimited projects, terminals & sessions",
    "Fleet view across your machines",
    "File explorer, git & browser preview",
    "E2E zero-knowledge relay",
  ],
  cta: "Start free",
  ctaFooter: "No card required · Windows, macOS & Linux",
};

export const trial: PlanCardData = {
  id: "trial",
  comingSoon: true,
  name: "Pro Trial",
  priceUsd: 0,
  unit: `/ ${TRIAL_DAYS} days`,
  note: `Full Pro for ${TRIAL_DAYS} days, then $${OFFER_ACTIVE ? YEARLY_OFFER_USD : YEARLY_LIST_USD}/year`,
  features: [
    "AI supervisor — evidence-gated \"done\", wakes you for the rest",
    `Up to ${TRIAL_WORKERS} worker machines`,
    "Everything in Free",
  ],
  cta: `Start ${TRIAL_DAYS}-day trial`,
  ctaFooter: "Card not charged until day 8 · cancel anytime",
};

export const proYearly: PlanCardData = {
  id: "pro_yearly",
  // Yearly entry point is the trial sku; converts to pro_yearly after 7 days.
  checkoutId: "trial",
  comingSoon: true,
  name: "Pro Yearly",
  priceUsd: OFFER_ACTIVE ? YEARLY_OFFER_USD : YEARLY_LIST_USD,
  listUsd: OFFER_ACTIVE ? YEARLY_LIST_USD : undefined,
  unit: "/ year",
  note: `${TRIAL_DAYS}-day free trial, then $${OFFER_ACTIVE ? YEARLY_OFFER_USD : YEARLY_LIST_USD}/year`,
  features: [
    "AI supervisor — evidence-gated \"done\", wakes you for the rest",
    `Up to ${PRO_WORKERS} worker machines`,
    "Encrypted remote control from your phone",
    "Fleet view across all your machines",
    "File explorer, git & browser preview",
    "E2E zero-knowledge relay · priority support",
  ],
  cta: "Get Pro Yearly",
  ctaFooter: `$${OFFER_ACTIVE ? YEARLY_OFFER_USD : YEARLY_LIST_USD}/year · renews automatically · cancel anytime`,
  recommended: true,
};
