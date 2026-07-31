import { Hono } from "hono";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import { requireUser, type AuthVars } from "../auth/middleware.js";
import { findProductAccountByUserId } from "../models/product-account.js";
import {
  activeSubscriptionForUser,
  provisionProductAccountForUser,
  resolveEntitlement,
} from "../models/subscription.js";
import { countActiveDevices } from "../models/device.js";

export function subscriptionRoutes(deps: { db: DB; auth: Auth }) {
  const r = new Hono<{ Variables: AuthVars }>();
  r.use("/subscriptions/*", requireUser({ auth: deps.auth }));

  r.get("/subscriptions/me", async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    const account = await findProductAccountByUserId(deps.db, userId);
    const [sub, count] = await Promise.all([
      activeSubscriptionForUser(deps.db, userId),
      countActiveDevices(deps.db, userId),
    ]);
    if (!sub) return c.json({ error: "NO_SUBSCRIPTION" }, 500);
    const { tier, workerLimit, deviceLimit, promotional } = resolveEntitlement(sub);
    return c.json({
      account_id: account?.id ?? null,
      subscription: {
        id: sub.id,
        account_id: sub.accountId,
        tier: sub.tier,
        plan_id: sub.planId,
        provider: sub.provider,
        status: sub.status,
        worker_limit: sub.workerLimit,
        session_limit: sub.workerLimit,
        device_limit: sub.deviceLimit,
        promotional: sub.promotional,
        trial_started_at: sub.trialStartedAt,
        trial_ends_at: sub.trialEndsAt,
        current_period_end: sub.currentPeriodEnd,
        cancelled_at: sub.cancelledAt,
      },
      tier,
      worker_limit: workerLimit,
      // `session_limit` is a compatibility mirror for app builds already in the
      // field, which parse it as non-null. Drop once the worker_limit app
      // release ships — see "Deploy order" in
      // docs/plans/2026-07-30-worker-limit-pricing.md.
      session_limit: workerLimit,
      device_limit: deviceLimit,
      promotional,
      active_devices: count,
    });
  });

  return r;
}
