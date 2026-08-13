import { Hono } from "hono";
import { z } from "zod";
import type { DB } from "../db/index.js";
import {
  activeSubscriptionForAccount,
  grantDevSubscription,
  grantManualContract,
  provisionProductAccountForUser,
} from "../models/subscription.js";
import { ensureProductAccount } from "../models/product-account.js";
import { AccountMemberRoleSchema } from "../models/account-member.js";
import { addAccountMember, AddMemberError } from "../billing/add-member.js";
import { CapabilitiesSchema } from "../billing/capabilities.js";

/**
 * Dev-only billing control. Lets a developer set a subscription directly and
 * assemble a team, bypassing the real payment + webhook flow and the invite
 * flow. These routes are mounted ONLY in non-production with
 * DEV_BILLING_ENABLED=true (see app.ts) — they must never exist on a live money
 * deployment, since they grant paid state for free, move a user onto someone
 * else's account, and are intentionally unauthenticated for dev ergonomics.
 */
const BodySchema = z.object({
  email: z.email(),
  planSlug: z.string().min(1).optional(),
  tier: z.string().min(1).optional(),
  status: z.string().min(1).optional(),
  workerLimit: z.number().int().positive().optional(),
  seats: z.number().int().positive().optional(),
  // ISO-8601 instant for the period end (e.g. "2027-01-01T00:00:00Z").
  currentPeriodEnd: z.iso.datetime().optional(),
});

/**
 * The negotiated half of a contract. Every field is optional and every omitted
 * one takes the plan's value, so the smallest useful body is an email.
 *
 * `capabilities` is strict where {@link readCapabilities} is lenient, and the
 * asymmetry is the point: a reader strips a name it does not know so that an
 * older build never loses the grants it does understand, but a name typed into
 * this body is a typo, and stripping it would answer `ok: true` having granted
 * nothing.
 */
const ContractBodySchema = z.object({
  email: z.email(),
  /** Any plan can carry a contract; Enterprise is simply the row seeded for it. */
  planSlug: z.string().min(1).optional(),
  workerLimit: z.number().int().positive().optional(),
  appDeviceLimit: z.number().int().positive().optional(),
  seats: z.number().int().positive().optional(),
  capabilities: z.strictObject(CapabilitiesSchema.shape).optional(),
  currentPeriodEnd: z.iso.datetime().optional(),
});

const MemberBodySchema = z.object({
  /** The user to move onto the team. */
  email: z.email(),
  /** Whoever holds the contract the new member will bill against. */
  ownerEmail: z.email(),
  role: AccountMemberRoleSchema.optional(),
});

/** The `/subscriptions/me` nested shape, so a fixture-built row can be read back
 *  with the same keys the product answers with. */
function subscriptionJson(sub: {
  id: string;
  accountId: string;
  tier: string;
  planId: string;
  provider: string | null;
  status: string;
  workerLimit: number;
  appDeviceLimit: number;
  seats: number;
  capabilities: unknown;
  currentPeriodEnd: Date | null;
}) {
  return {
    id: sub.id,
    account_id: sub.accountId,
    tier: sub.tier,
    plan_id: sub.planId,
    provider: sub.provider,
    status: sub.status,
    worker_limit: sub.workerLimit,
    // `session_limit` is the retired name for `worker_limit`. No app build
    // reaches this dev-only route; the old key is echoed only to keep a
    // dev-granted subscription the same shape as the real ones. Drop it in the
    // same commit as the production mirrors — web/src/routes/billing.ts carries
    // the condition.
    session_limit: sub.workerLimit,
    app_device_limit: sub.appDeviceLimit,
    seats: sub.seats,
    capabilities: sub.capabilities,
    current_period_end: sub.currentPeriodEnd,
  };
}

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

    return c.json({ ok: true, subscription: subscriptionJson(sub) });
  });

  /**
   * Build a negotiated contract — the per-customer half of the Enterprise
   * design, and a state no purchase can reach: Enterprise is contact-sales, so
   * checkout refuses it, and the plan row alone carries only the list price.
   *
   * The write goes through `grantManualContract` like the real admin path will,
   * for the reason the member route gives: a fixture with its own insert is a
   * fixture that can build states the product cannot.
   *
   * `provider` is not in the body. It comes from `grantManualContract` as
   * `MANUAL_PROVIDER`, the exact value every catalog re-sync guards on — letting
   * a fixture choose it would let a fixture build a contract the next migration
   * silently overwrites with the list price.
   */
  r.post("/dev/billing/contract", async (c) => {
    const parsed = ContractBodySchema.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) {
      return c.json({ error: "INVALID_REQUEST", issues: parsed.error.issues }, 400);
    }
    const { email, currentPeriodEnd, ...negotiated } = parsed.data;

    const user = await deps.db.user.findUnique({ where: { email } });
    if (!user) return c.json({ error: "USER_NOT_FOUND", email }, 404);

    const sub = await grantManualContract(deps.db, user.id, {
      ...negotiated,
      ...(currentPeriodEnd ? { currentPeriodEnd: new Date(currentPeriodEnd) } : {}),
    });

    return c.json({ ok: true, subscription: subscriptionJson(sub) });
  });

  /**
   * Build a team: move `email` onto the account `ownerEmail` bills against.
   *
   * There is otherwise no way to construct a multi-member account, which is how
   * a seat bug reaches production having never been seen. The membership itself
   * goes through `addAccountMember` like every other caller — a fixture with its
   * own insert is a fixture that can build states the product cannot.
   *
   * Both refusals are waived, and neither waiver is laziness. The settled policy
   * makes an over-subscribed team representable, so a fixture that enforced the
   * cap could not build one; and a dev-granted `pro_yearly` row reads as
   * purchased, so the paid-subscription refusal would make the dev grant a trap
   * that locks its holder out of every team.
   */
  r.post("/dev/billing/member", async (c) => {
    const parsed = MemberBodySchema.safeParse(await c.req.json().catch(() => null));
    if (!parsed.success) {
      return c.json({ error: "INVALID_REQUEST", issues: parsed.error.issues }, 400);
    }
    const { email, ownerEmail, role = AccountMemberRoleSchema.enum.member } = parsed.data;

    const [member, owner] = await Promise.all([
      deps.db.user.findUnique({ where: { email } }),
      deps.db.user.findUnique({ where: { email: ownerEmail } }),
    ]);
    if (!member) return c.json({ error: "USER_NOT_FOUND", email }, 404);
    if (!owner) return c.json({ error: "USER_NOT_FOUND", email: ownerEmail }, 404);

    const teamAccount = await provisionProductAccountForUser(deps.db, owner.id);
    await provisionProductAccountForUser(deps.db, member.id);
    // Provisioned ahead of the call rather than left to it: `addAccountMember`
    // reads the personal account to cancel it, and a user who has never had one
    // would silently skip that cancellation.
    await ensureProductAccount(deps.db, member.id);

    let headcount: number;
    try {
      ({ seatHolders: headcount } = await addAccountMember(
        deps.db,
        { accountId: teamAccount.id, userId: member.id, role },
        { seatCap: true, paidSubscription: true }
      ));
    } catch (e) {
      if (e instanceof AddMemberError) {
        return c.json({ error: e.code, message: e.message, email, ownerEmail }, 400);
      }
      throw e;
    }

    const sub = await activeSubscriptionForAccount(deps.db, teamAccount.id);
    return c.json({
      ok: true,
      member: { user_id: member.id, email, role },
      account_id: teamAccount.id,
      seats: sub?.seats ?? null,
      active_members: headcount,
      over_subscribed: sub ? headcount > sub.seats : false,
    });
  });

  return r;
}
