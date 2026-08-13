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
  previewBillingProvider,
  updateProductAccountCountry,
} from "../models/product-account.js";
import { listActivePlans } from "../models/plan.js";
import {
  displayPriceCents,
  formatUsd,
  isPlanId,
  PRICING,
  yearlyOfferActive,
  type PlanId,
} from "../billing/plans.js";
import { detectCountryFromIp } from "../billing/geo.js";
import type { ClientIpResolver } from "../util/client-ip.js";
import { MAX_CHECKOUT_SEATS } from "../billing/checkout.js";
import { startCheckout } from "../billing/start-checkout.js";
import {
  cancelRecurringSubscription,
  CancelSubscriptionError,
  resumeRecurringSubscription,
  ResumeSubscriptionError,
} from "../billing/cancel-subscription.js";
import { updateSubscriptionSeats, UpdateSeatsError } from "../billing/update-seats.js";
import {
  activeSubscriptionForUser,
  provisionProductAccountForUser,
} from "../models/subscription.js";
import { PLAN_SLUG_FREE } from "../models/plan.js";
import { isBillingAccountOwner } from "../models/account-member.js";
import type { RelayPushConfig } from "../relay/push.js";

const ConfirmCountryBody = z.object({
  country: z.string().length(2),
});

const CheckoutSessionBody = z.object({
  planId: z.string(),
  country: z.string().length(2).optional(),
  // Strict number, not `z.coerce.number()`: coercion turns `true` into 1 and
  // `""` into 0, so a malformed body would buy a seat count nobody chose.
  // Absent is the only permitted default, and it is one seat.
  seats: z.number().int().min(1).max(MAX_CHECKOUT_SEATS).optional(),
});

/** Required and never defaulted, unlike checkout's: a resize request whose seat
 *  count fell out of the body has no sensible reading, and treating it as one
 *  seat would cancel a team. Strict for the same reason as above. */
const SeatsBody = z.object({
  seats: z.number().int().min(1).max(MAX_CHECKOUT_SEATS),
});

function razorpayCallbackRedirect(c: import("hono").Context): Response {
  const target = "/dashboard?purchase=success";
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

  /** Razorpay redirect-mode checkout POSTs here (no session cookie).
   *  Subscriptions provision via webhook, so the redirect is optimistic. */
  r.post("/billing/razorpay/callback", async (c) => razorpayCallbackRedirect(c));

  r.use("/billing/*", requireUser({ auth: deps.auth }));

  /**
   * Owner-only routes, listed rather than gated per handler so the set is
   * readable in one place — `requireUser` sets no role and there is no session
   * field carrying one, so each of these costs a DB read and nothing fails
   * loudly when one is forgotten.
   *
   * The mutations they perform are account-wide, and two are irreversible:
   * `lockBillingProvider` early-returns on an existing value, so a member merely
   * reaching checkout would pin the whole team's gateway and tax treatment to
   * their own country for good. Cancel and resume are the loud ones; the country
   * and provider writes are the ones that cannot be undone.
   *
   * Every handler named here must be registered BELOW this loop. Hono runs a
   * path-scoped `use` only for handlers registered after it, so one placed above
   * keeps its entry in this list, reads as gated, and is not.
   */
  const OWNER_ONLY_PATHS = [
    "/billing/checkout-intent",
    "/billing/confirm-country",
    "/billing/checkout",
    "/billing/checkout-session",
    "/billing/cancel-subscription",
    "/billing/resume-subscription",
    "/billing/seats",
  ];
  for (const path of OWNER_ONLY_PATHS) {
    r.use(path, async (c, next) => {
      if (!(await isBillingAccountOwner(deps.db, c.get("userId")))) {
        return c.json({ error: "NOT_ACCOUNT_OWNER" }, 403);
      }
      await next();
    });
  }

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
            app_device_limit: p.appDeviceLimit,
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
          // `session_limit` is the retired name for `worker_limit`, and this is
          // the response the app actually reads the limit from: `fromJson` in
          // app/lib/models/subscription_info.dart prefers `worker_limit` and
          // falls back to this key, but builds predating the rename cast
          // `session_limit` as non-null and throw when it is absent.
          // TODO(billing): drop this and every other `session_limit` mirror in
          // web/src/routes once no pre-rename app build is still in the field.
          session_limit: p.workerLimit,
          app_device_limit: p.appDeviceLimit,
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

    const result = await startCheckout(deps.db, deps.env, {
      userId: c.get("userId"),
      planId: parsed.data.planId,
      ...(parsed.data.country ? { country: parsed.data.country } : {}),
      seats: parsed.data.seats ?? 1,
      clientIp: deps.clientIp(c),
      origin: new URL(c.req.url).origin,
    });
    if (result.ok) return c.json(result.session);
    return c.json(
      {
        error: result.error,
        ...(result.error === "SEATS_ABOVE_PLAN_MAX" ? { max_seats: result.maxSeats } : {}),
      },
      result.status
    );
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

  /** Resize the seats the account is billed for. Registered below the
   *  OWNER_ONLY_PATHS loop — see the note there; above it the gate is inert. */
  r.post("/billing/seats", async (c) => {
    const parsed = SeatsBody.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) return c.json({ error: "BAD_REQUEST" }, 400);

    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    const sub = await activeSubscriptionForUser(deps.db, userId);
    if (!sub) return c.json({ error: "NO_SUBSCRIPTION" }, 404);

    const plan = await deps.db.plan.findUnique({ where: { id: sub.planId } });
    if (!plan) return c.json({ error: "NO_SUBSCRIPTION" }, 404);
    if (plan.slug === PLAN_SLUG_FREE) return c.json({ error: "NOT_RECURRING" }, 400);
    if (!plan.recurring) return c.json({ error: "NOT_RECURRING" }, 400);

    try {
      const result = await updateSubscriptionSeats(deps.db, deps.env, {
        accountId: sub.accountId,
        subscription: { ...sub, plan },
        seats: parsed.data.seats,
      });
      return c.json({ ok: true, ...result });
    } catch (e) {
      if (e instanceof UpdateSeatsError) {
        const status =
          e.code === "SEATS_BELOW_HEADCOUNT"
            ? 409
            : e.code === "SEATS_ABOVE_PLAN_MAX" ||
                e.code === "NOT_RECURRING" ||
                e.code === "NO_ACTIVE_SUBSCRIPTION" ||
                e.code === "NO_PROVIDER_SUBSCRIPTION"
              ? 400
              : e.code === "PADDLE_NOT_CONFIGURED" || e.code === "RAZORPAY_NOT_CONFIGURED"
                ? 503
                : 502;
        return c.json(
          {
            error: e.code,
            message: e.message,
            ...(e.code === "SEATS_BELOW_HEADCOUNT" ? { headcount: e.limit } : {}),
            ...(e.code === "SEATS_ABOVE_PLAN_MAX" ? { max_seats: e.limit } : {}),
          },
          status
        );
      }
      throw e;
    }
  });

  return r;
}
