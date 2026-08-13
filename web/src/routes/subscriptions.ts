import { Hono } from "hono";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import { requireUser, type AuthVars } from "../auth/middleware.js";
import {
  countActiveSeatHolders,
  findActiveMembership,
  resolveBillingAccountId,
} from "../models/account-member.js";
import {
  activeSubscriptionForUser,
  provisionProductAccountForUser,
  resolveEntitlement,
} from "../models/subscription.js";
import { countActiveAppDevices } from "../models/device.js";

export function subscriptionRoutes(deps: { db: DB; auth: Auth }) {
  const r = new Hono<{ Variables: AuthVars }>();
  r.use("/subscriptions/*", requireUser({ auth: deps.auth }));

  r.get("/subscriptions/me", async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    // Same resolution as the subscription below it: read the owned account here
    // and a member's top-level `account_id` would name their orphan personal
    // account while `subscription.account_id` names the team's.
    const accountId = await resolveBillingAccountId(deps.db, userId);
    const [sub, count, membership] = await Promise.all([
      activeSubscriptionForUser(deps.db, userId),
      countActiveAppDevices(deps.db, userId),
      findActiveMembership(deps.db, userId),
    ]);
    if (!sub) return c.json({ error: "NO_SUBSCRIPTION" }, 500);
    // Counted on the subscription's own account, not on `accountId` above: the
    // two are the same account in every reachable state, and reading seats and
    // seat holders off one row keeps them that way if they ever stop being.
    const seatsUsed = await countActiveSeatHolders(deps.db, sub.accountId);
    const { tier, workerLimit, appDeviceLimit, promotional, capabilities } =
      resolveEntitlement(sub);
    return c.json({
      account_id: accountId,
      subscription: {
        id: sub.id,
        account_id: sub.accountId,
        tier: sub.tier,
        plan_id: sub.planId,
        provider: sub.provider,
        status: sub.status,
        worker_limit: sub.workerLimit,
        session_limit: sub.workerLimit,
        app_device_limit: sub.appDeviceLimit,
        seats: sub.seats,
        promotional: sub.promotional,
        trial_started_at: sub.trialStartedAt,
        trial_ends_at: sub.trialEndsAt,
        current_period_end: sub.currentPeriodEnd,
        cancelled_at: sub.cancelledAt,
      },
      tier,
      worker_limit: workerLimit,
      // `session_limit` is the retired name for `worker_limit`, kept in
      // lockstep with the `/billing/plans` mirror (web/src/routes/billing.ts)
      // that app builds predating the rename hard-require. Drop them together
      // once no such build is still in the field.
      session_limit: workerLimit,
      app_device_limit: appDeviceLimit,
      promotional,
      active_app_devices: count,
      // Additive, and additive only: nothing above changed name, type or
      // meaning, so a client that ignores these four reads exactly what it
      // read before. `role` is null when the stored value is outside the
      // schema — a role we cannot read must not be presented as ownership.
      role: membership?.role ?? null,
      seats: sub.seats,
      seats_used: seatsUsed,
      // The names inside are the capability registry's own
      // (src/billing/capabilities.ts), not this file's snake_case: they are one
      // vocabulary every reader shares, and re-spelling them per response would
      // fork it. A capability this build does not know is already gone by here.
      capabilities,
    });
  });

  return r;
}
