import { Hono } from "hono";
import { z } from "zod";
import type { DB } from "../db/index.js";
import { grantDevSubscription } from "../models/subscription.js";

/**
 * Dev-only billing control. Lets a developer set a subscription directly,
 * bypassing the real payment + webhook flow. This route is mounted ONLY in
 * non-production with DEV_BILLING_ENABLED=true (see app.ts) — it must never
 * exist on a live money deployment, since it grants paid state for free and
 * is intentionally unauthenticated for dev ergonomics.
 */
const BodySchema = z.object({
  email: z.email(),
  planSlug: z.string().min(1).optional(),
  tier: z.string().min(1).optional(),
  status: z.string().min(1).optional(),
  sessionLimit: z.number().int().positive().optional(),
  // ISO-8601 instant for the period end (e.g. "2027-01-01T00:00:00Z").
  currentPeriodEnd: z.iso.datetime().optional(),
});

export function devBillingRoutes(deps: { db: DB }) {
  const r = new Hono();

  r.post("/dev/billing/subscription", async (c) => {
    const parsed = BodySchema.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) {
      return c.json({ error: "INVALID_REQUEST", issues: parsed.error.issues }, 400);
    }
    const { email, currentPeriodEnd, ...rest } = parsed.data;

    const user = await deps.db.user.findUnique({ where: { email } });
    if (!user) return c.json({ error: "USER_NOT_FOUND", email }, 404);

    const sub = await grantDevSubscription(deps.db, user.id, {
      ...rest,
      ...(currentPeriodEnd ? { currentPeriodEnd: new Date(currentPeriodEnd) } : {}),
    });

    return c.json({
      ok: true,
      subscription: {
        id: sub.id,
        account_id: sub.accountId,
        tier: sub.tier,
        plan_id: sub.planId,
        provider: sub.provider,
        status: sub.status,
        session_limit: sub.sessionLimit,
        device_limit: sub.deviceLimit,
        current_period_end: sub.currentPeriodEnd,
      },
    });
  });

  return r;
}
