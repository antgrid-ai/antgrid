// Marketing pricing — KEEP IN LOCKSTEP with web/src/billing/plans.ts (PRICING) and
// web/src/models/plan.ts (workerLimit, maxSeats). The paid axis is SEATS: one seat
// per person, priced per seat per year. Worker machines are a fair-use bound that
// every seat gets its own copy of (the cap is counted per user in
// checkCapAndUpsert, so a team never pools them) — the only place a machine count
// is a paywall is Free. If YEARLY_OFFER_ACTIVE is turned off in web, set
// OFFER_ACTIVE=false here so the founding-price line disappears and the card
// shows list. YEARLY_LIST_USD is a price we have not charged yet, so it is only
// ever rendered forwards ("$99 at launch"), never struck through as a former one.
//
// Checkout is deliberately unwired this release: every card that would charge carries
// `comingSoon`, which swaps the checkout link for the founding-pricing capture
// (`WaitlistCta.astro`). Clearing it here re-points the CTA at web's live `/checkout`
// (`web/src/routes/ui.tsx`), but the same shutter is duplicated on web's own pricing
// page (web/src/ui/pricing.tsx) and on the app's WORKER_CAP Upgrade button
// (app/lib/screens/device_cap_dialog.dart) — flip all three together, or the funnel
// sells a plan two of its three entry points still refuse.
import { links } from "../config";

// Single switch for the beta-free period: banners the pricing page, hides the
// trial card, and swaps the hero pill, closing-CTA and paid-card copy. Flip to
// false when plans activate — and update support.md's beta note by hand, it is
// static markdown.
export const BETA_FREE = true;

export const TRIAL_DAYS = 7;
export const FREE_WORKERS = 1;
export const TRIAL_WORKERS = 10;
export const PRO_WORKERS = 10;
export const PRO_MAX_SEATS = 25;
// Per SEAT, per year — both figures. A total is never quoted here because it
// depends on a seat count only checkout knows.
export const YEARLY_LIST_USD = 99;
export const YEARLY_OFFER_USD = 49;
export const OFFER_ACTIVE = true;

const seatPriceUsd = OFFER_ACTIVE ? YEARLY_OFFER_USD : YEARLY_LIST_USD;

/** Which surface a founding-pricing address came from — sent as `source` to
 *  web's /api/waitlist, which bounds it to `/^[a-z0-9][a-z0-9_-]*$/`. A closed
 *  union rather than `string` so a surface added with a space or a capital fails
 *  `astro check` instead of 400ing at every reader with copy that blames their
 *  email address. Adding a member needs no web deploy — the endpoint takes any
 *  slug of that shape — but it must not collide with a source web sends itself
 *  (`app_pricing`), or the two surfaces become one row. */
export type WaitlistSource = "pricing";

export type PlanCardData = {
  id: "free" | "trial" | "pro_yearly";
  // checkoutId overrides the planId sent to the checkout URL (e.g. yearly trial uses sku "trial").
  checkoutId?: string;
  // ctaHref bypasses checkout entirely — for CTAs that are just sign-in links.
  ctaHref?: string;
  // Renders the founding-price capture (WaitlistCta.astro) in place of the
  // checkout CTA.
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
  note: "One machine, one person · no card",
  features: [
    `${FREE_WORKERS} worker machine`,
    "Encrypted remote control from your phone",
    "Unlimited projects, terminals & sessions",
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
  note: `Full Pro for ${TRIAL_DAYS} days, then $${seatPriceUsd} per seat / year`,
  features: [
    "Handler AI assistant — stack instructions, evidence-gated \"done\", one-tap undo",
    `Up to ${TRIAL_WORKERS} worker machines`,
    "One seat — invite your team once the trial converts",
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
  name: "Pro",
  priceUsd: seatPriceUsd,
  listUsd: OFFER_ACTIVE ? YEARLY_LIST_USD : undefined,
  unit: "/ seat / year",
  // Under BETA_FREE the card's CTA is an interest capture, not a checkout, so the
  // copy must not promise a startable trial or a running subscription.
  note: BETA_FREE
    ? "Free while the beta runs"
    : `${TRIAL_DAYS}-day free trial, then $${seatPriceUsd} per seat / year`,
  features: [
    "Handler AI assistant — stack instructions, evidence-gated \"done\", one-tap undo",
    `Up to ${PRO_WORKERS} worker machines per person`,
    "Invite your team — every seat brings its own machines",
    `Up to ${PRO_MAX_SEATS} seats · add or remove them any time`,
    "Shared fleet view across the team",
    "E2E zero-knowledge relay · priority support",
  ],
  cta: "Get Pro",
  // No figure on this line while the CTA is a capture: the reader is agreeing to
  // hear from us, not to a price, and the headline above already carries the number.
  ctaFooter: BETA_FREE
    ? "Founding pricing at launch · no card, nothing charged during the beta"
    : `$${seatPriceUsd} per seat / year · renews automatically · cancel anytime`,
  recommended: true,
};

/** Pricing FAQ. Every answer states something the product actually enforces —
 *  the seat/machine split, what a seat release does and does not do to the
 *  bill, and where the beta ends — so none of it needs revisiting at the flip
 *  except the entries keyed on BETA_FREE. */
export const faq: { q: string; a: string }[] = [
  {
    q: "What counts as a seat?",
    a: `One person on your account. Each seat signs in as themselves, gets their own worker machines, and sees the team's fleet. Pro covers up to ${PRO_MAX_SEATS} seats; past that, talk to us about Enterprise.`,
  },
  {
    q: "What counts as a worker machine?",
    a: `One computer running antgrid — your laptop, your desktop, a box under the desk. Projects, terminals, sessions and agents on it are unlimited. Free covers ${FREE_WORKERS}; on Pro every seat gets up to ${PRO_WORKERS} of its own, so machines are never pooled or traded between teammates.`,
  },
  {
    q: "Do you charge per agent run, per token or per minute?",
    a: "No. You bring your own machines and your own agent subscriptions — Claude Code, Codex, Cursor, whatever you already pay for. antgrid never sits between you and your model provider, so there is nothing for us to meter.",
  },
  {
    q: "Someone left the team. What happens to their seat?",
    a: "Remove them and the seat opens for the next person immediately. It does not lower the bill on its own — the seat stays yours for the term until you reduce the seat count, which you can do at any time down to your current headcount.",
  },
  {
    q: "Can I add seats mid-year?",
    a: "Yes. Seats change straight away and your payment provider prorates the difference against the term you are already in.",
  },
  {
    q: BETA_FREE ? "What happens when the beta ends?" : "Is there a free trial?",
    a: BETA_FREE
      ? `Nothing switches off without warning. Paid plans activate${OFFER_ACTIVE ? ` at the founding prices on this page — below the $${YEARLY_LIST_USD} list price at launch` : " at the prices on this page"}, and Pro starts with a ${TRIAL_DAYS}-day free trial. The free plan stays free.`
      : `Yes — Pro starts with a ${TRIAL_DAYS}-day free trial on one seat. Your card is not charged until the trial ends, and cancelling before then costs nothing.`,
  },
  {
    q: "Does antgrid see my code?",
    a: "No. Every agent-to-app message is end-to-end encrypted, and the relay that routes them holds no decryption keys — it moves opaque blobs between your machine and your phone. That is true on every plan, including Free.",
  },
];
