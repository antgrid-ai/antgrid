import { Hono } from "hono";
import { z } from "zod";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import type { Env } from "../env.js";
import { requireUser, type AuthVars } from "../auth/middleware.js";
import {
  ensureProductAccount,
  ensureProductAccountCountry,
  isBillingProviderLocked,
  lockBillingProvider,
  previewBillingProvider,
  updateProductAccountCountry,
} from "../models/product-account.js";
import {
  findBillingCustomer,
  upsertBillingCustomer,
} from "../models/billing-customer.js";
import { listActivePlans } from "../models/plan.js";
import {
  displayPriceCents,
  formatUsd,
  isPlanId,
  PRICING,
  yearlyOfferActive,
  type PlanId,
  type ProviderId,
} from "../billing/plans.js";
import { detectCountryFromIp } from "../billing/geo.js";
import type { ClientIpResolver } from "../util/client-ip.js";
import {
  createCheckoutSession,
  isCheckoutConfigError,
  verifyPayment,
} from "../billing/checkout.js";
import {
  cancelRecurringSubscription,
  CancelSubscriptionError,
  resumeRecurringSubscription,
  ResumeSubscriptionError,
} from "../billing/cancel-subscription.js";
import {
  activeSubscriptionForUser,
  provisionProductAccountForUser,
} from "../models/subscription.js";
import { PLAN_SLUG_FREE } from "../models/plan.js";
import type { RelayPushConfig } from "../relay/push.js";

const ConfirmCountryBody = z.object({
  country: z.string().length(2),
});

const CheckoutSessionBody = z.object({
  planId: z.string(),
  currency: z.string().length(3).optional(),
  country: z.string().length(2).optional(),
});

const VerifyPaymentBody = z.discriminatedUnion("provider", [
  z.object({
    provider: z.literal("razorpay"),
    orderId: z.string().min(1),
    paymentId: z.string().min(1),
    signature: z.string().min(1),
  }),
  z.object({
    provider: z.literal("paddle"),
    transactionId: z.string().min(1),
  }),
]);


function razorpayCallbackRedirect(c: import("hono").Context, planId: string, ok: boolean): Response {
  const target = ok
    ? "/dashboard?purchase=success"
    : `/checkout?planId=${encodeURIComponent(planId)}&payment=failed`;
  // 3DS completes in a Razorpay popup; hand off to the opener when possible.
  const html = `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Payment</title></head><body><script>
try {
  if (window.opener && !window.opener.closed) {
    window.opener.location.replace(${JSON.stringify(target)});
    window.close();
  } else {
    window.location.replace(${JSON.stringify(target)});
  }
} catch {
  window.location.replace(${JSON.stringify(target)});
}
</script></body></html>`;
  return c.html(html);
}

export function billingRoutes(deps: {
  db: DB;
  auth: Auth;
  env: Env;
  relay: RelayPushConfig;
  clientIp: ClientIpResolver;
}) {
  const r = new Hono<{ Variables: AuthVars }>();

  /** Razorpay redirect-mode checkout POSTs here (no session cookie). */
  r.post("/billing/razorpay/callback", async (c) => {
    const planId = c.req.query("planId") ?? "pro_lifetime";
    const body = await c.req.parseBody();
    const orderId = body.razorpay_order_id;
    const paymentId = body.razorpay_payment_id;
    const signature = body.razorpay_signature;

    if (
      typeof orderId === "string" &&
      typeof paymentId === "string" &&
      typeof signature === "string" &&
      orderId.length > 0 &&
      paymentId.length > 0 &&
      signature.length > 0
    ) {
      try {
        await verifyPayment(deps.db, deps.relay, deps.env, {
          provider: "razorpay",
          orderId,
          paymentId,
          signature,
        });
      } catch {
        return razorpayCallbackRedirect(c, planId, false);
      }
    }

    // Subscriptions provision via webhook; redirect is optimistic after auth charge.
    return razorpayCallbackRedirect(c, planId, true);
  });

  r.use("/billing/*", requireUser({ auth: deps.auth }));

  r.get("/billing/checkout-intent", async (c) => {
    const userId = c.get("userId");
    const { id: accountId } = await provisionProductAccountForUser(deps.db, userId);
    let account = await ensureProductAccount(deps.db, userId);
    const detected =
      account.country ??
      (await detectCountryFromIp(deps.clientIp(c), deps.env.IPINFO_TOKEN));
    if (!account.country && detected) {
      account = await ensureProductAccountCountry(deps.db, accountId, detected, "ipinfo");
    }
    const country = account.country ?? detected;
    const provider = previewBillingProvider(account, country);
    const providerLocked = isBillingProviderLocked(account);
    return c.json({
      detected_country: country,
      provider,
      provider_locked: providerLocked,
      country_locked: false,
      yearly_offer_active: yearlyOfferActive(deps.env),
    });
  });

  r.get("/billing/plans", async (c) => {
    const plans = await listActivePlans(deps.db);
    const offerActive = yearlyOfferActive(deps.env);
    return c.json({
      yearly_offer_active: offerActive,
      plans: plans.map((p) => {
        if (!isPlanId(p.slug)) {
          return {
            id: p.slug,
            slug: p.slug,
            label: p.label,
            tier: p.tier,
            worker_limit: p.workerLimit,
            session_limit: p.workerLimit,
            device_limit: p.deviceLimit,
            recurring: p.recurring,
            trial: p.trial,
            list_price_cents: null,
            price_cents: null,
            price_display: null,
            list_price_display: null,
            offer_percent: null,
          };
        }
        const planId = p.slug;
        const pricing = PRICING[planId];
        const priceCents = displayPriceCents(planId, deps.env);
        return {
          id: p.slug,
          slug: p.slug,
          label: p.label,
          tier: p.tier,
          worker_limit: p.workerLimit,
          // Compatibility mirror for app builds already in the field, which
          // parse `session_limit` as non-null. Drop once the worker_limit app
          // release ships — see "Deploy order" in
          // docs/plans/2026-07-30-worker-limit-pricing.md.
          session_limit: p.workerLimit,
          device_limit: p.deviceLimit,
          recurring: p.recurring,
          trial: p.trial,
          list_price_cents: pricing.listPriceCents,
          price_cents: priceCents,
          price_display: formatUsd(priceCents),
          list_price_display: formatUsd(pricing.listPriceCents),
          offer_percent:
            (planId === "pro_yearly" || planId === "trial") && offerActive
              ? pricing.offerPercent
              : null,
        };
      }),
    });
  });

  r.post("/billing/confirm-country", async (c) => {
    const parsed = ConfirmCountryBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST" }, 400);

    const userId = c.get("userId");
    const { id: accountId } = await provisionProductAccountForUser(deps.db, userId);
    const country = parsed.data.country.toUpperCase();
    await updateProductAccountCountry(deps.db, accountId, country, "manual");
    const updated = await ensureProductAccount(deps.db, userId);
    const provider = previewBillingProvider(updated, country);
    return c.json({ country, provider });
  });

  /** HTMX redirect helper — pricing uses direct /checkout links instead. */
  r.post("/billing/checkout", async (c) => {
    let rawPlanId: string | null = null;
    const json = await c.req.json().catch(() => null);
    if (json && typeof json.planId === "string") rawPlanId = json.planId;
    if (!rawPlanId) {
      const form = await c.req.formData().catch(() => null);
      const fromForm = form?.get("planId");
      if (typeof fromForm === "string") rawPlanId = fromForm;
    }
    const planId = rawPlanId && isPlanId(rawPlanId) ? rawPlanId : null;
    if (!planId) return c.json({ error: "BAD_REQUEST" }, 400);

    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);

    c.header("HX-Redirect", `/checkout?planId=${planId}`);
    return c.text("");
  });

  /** Single checkout entry — routes to Paddle or Razorpay based on billing country. */
  r.post("/billing/checkout-session", async (c) => {
    const parsed = CheckoutSessionBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success || !isPlanId(parsed.data.planId)) {
      return c.json({ error: "BAD_REQUEST" }, 400);
    }

    const userId = c.get("userId");
    const { id: accountId } = await provisionProductAccountForUser(deps.db, userId);
    let account = await ensureProductAccount(deps.db, userId);
    const detected =
      account.country ??
      (await detectCountryFromIp(deps.clientIp(c), deps.env.IPINFO_TOKEN));
    if (!account.country && detected) {
      account = await ensureProductAccountCountry(deps.db, accountId, detected, "ipinfo");
    }
    const country = (parsed.data.country ?? account.country ?? detected)?.toUpperCase();
    if (!country) return c.json({ error: "COUNTRY_REQUIRED" }, 400);

    const locked = isBillingProviderLocked(account);
    let provider: ProviderId;
    let billingCountry: string;

    if (locked) {
      billingCountry = country;
      provider = account.billingProvider as ProviderId;
      if (parsed.data.country || country !== account.country) {
        await updateProductAccountCountry(deps.db, accountId, billingCountry, "manual");
      }
    } else {
      if (!account.country || parsed.data.country) {
        await updateProductAccountCountry(deps.db, accountId, country, "manual");
      }
      billingCountry = country;
      provider = await lockBillingProvider(deps.db, accountId, country);
    }

    const billingCustomer = await findBillingCustomer(deps.db, accountId, provider);
    const user = await deps.db.user.findUnique({
      where: { id: userId },
      select: { email: true },
    });

    const origin = new URL(c.req.url).origin;
    const razorpayCallbackUrl = `${origin}/billing/razorpay/callback?planId=${encodeURIComponent(parsed.data.planId)}`;

    try {
      const session = await createCheckoutSession(deps.env, {
        planId: parsed.data.planId,
        accountId,
        country: billingCountry,
        provider,
        currency: parsed.data.currency,
        email: user?.email,
        providerCustomerId: billingCustomer?.providerCustomerId,
        razorpayCallbackUrl,
        // Persist the Razorpay customer the instant it's created — before the
        // order/subscription call that can fail and orphan it (no fetch-by-email
        // API to recover it cheaply). Sole persistence site: the reused-customer
        // path already has the id in the DB, so no post-success upsert is needed.
        onCustomerCreated: async (providerCustomerId) => {
          await upsertBillingCustomer(deps.db, {
            accountId,
            provider: "razorpay",
            providerCustomerId,
          });
        },
      });
      return c.json(session);
    } catch (e) {
      const msg = e instanceof Error ? e.message : "checkout failed";
      if (isCheckoutConfigError(msg)) return c.json({ error: msg }, 503);
      throw e; // unexpected → central onError logs the stack and returns 500
    }
  });

  /** Single post-payment verify — Razorpay lifetime orders; Paddle is webhook-driven. */
  r.post("/billing/verify-payment", async (c) => {
    const parsed = VerifyPaymentBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST" }, 400);

    try {
      const result = await verifyPayment(deps.db, deps.relay, deps.env, parsed.data);
      return c.json(result);
    } catch (e) {
      const msg = e instanceof Error ? e.message : "verify failed";
      if (msg === "RAZORPAY_NOT_CONFIGURED") return c.json({ error: msg }, 503);
      if (msg === "INVALID_SIGNATURE" || msg === "INVALID_PAYMENT") {
        return c.json({ error: msg }, 400);
      }
      throw e; // unexpected → central onError logs the stack and returns 500
    }
  });

  /** Cancel recurring subscription at the gateway; entitlement updates via webhook. */
  r.post("/billing/cancel-subscription", async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    const sub = await activeSubscriptionForUser(deps.db, userId);
    if (!sub) return c.json({ error: "NO_SUBSCRIPTION" }, 404);

    const plan = await deps.db.plan.findUnique({ where: { id: sub.planId } });
    if (!plan) return c.json({ error: "NO_SUBSCRIPTION" }, 404);
    if (plan.slug === PLAN_SLUG_FREE) return c.json({ error: "NOT_RECURRING" }, 400);
    if (!plan.recurring) return c.json({ error: "NOT_RECURRING" }, 400);

    try {
      const result = await cancelRecurringSubscription(deps.db, deps.relay, deps.env, {
        accountId: sub.accountId,
        subscription: { ...sub, plan },
      });
      return c.json(result);
    } catch (e) {
      if (e instanceof CancelSubscriptionError) {
        const status =
          e.code === "NO_ACTIVE_SUBSCRIPTION" || e.code === "NO_PROVIDER_SUBSCRIPTION"
            ? 400
            : e.code === "PADDLE_NOT_CONFIGURED" || e.code === "RAZORPAY_NOT_CONFIGURED"
              ? 503
              : 502;
        return c.json({ error: e.code, message: e.message }, status);
      }
      throw e;
    }
  });

  /** Resume a pending period-end cancellation at the gateway and in our DB. */
  r.post("/billing/resume-subscription", async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    const sub = await activeSubscriptionForUser(deps.db, userId);
    if (!sub) return c.json({ error: "NO_SUBSCRIPTION" }, 404);

    const plan = await deps.db.plan.findUnique({ where: { id: sub.planId } });
    if (!plan) return c.json({ error: "NO_SUBSCRIPTION" }, 404);
    if (plan.slug === PLAN_SLUG_FREE) return c.json({ error: "NOT_RECURRING" }, 400);
    if (!plan.recurring) return c.json({ error: "NOT_RECURRING" }, 400);

    try {
      await resumeRecurringSubscription(deps.db, deps.env, {
        subscription: { ...sub, plan },
      });
      return c.json({ ok: true });
    } catch (e) {
      if (e instanceof ResumeSubscriptionError) {
        const status =
          e.code === "NOT_PENDING_CANCELLATION" || e.code === "NO_PROVIDER_SUBSCRIPTION"
            ? 400
            : e.code === "PADDLE_NOT_CONFIGURED" || e.code === "RAZORPAY_NOT_CONFIGURED"
              ? 503
              : 502;
        return c.json({ error: e.code, message: e.message }, status);
      }
      throw e;
    }
  });

  return r;
}
