import type { Plan } from "../generated/prisma/client.js";
import type { Tx } from "../db/index.js";
import type { PlanId } from "../billing/plans.js";
import type { Capabilities } from "../billing/capabilities.js";

export type PlanRow = Plan;

export const PLAN_SLUG_FREE = "free";

/** Fixed UUIDs seeded in the billing migration — stable for tests and dev grants.
 *  `…0003` is retired (pro_lifetime): the row is deactivated rather than deleted,
 *  so that id must never be reused for a new plan. */
export const PLAN_UUID = {
  free: "00000000-0000-4000-8000-000000000001",
  trial: "00000000-0000-4000-8000-000000000004",
  pro_yearly: "00000000-0000-4000-8000-000000000002",
  enterprise: "00000000-0000-4000-8000-000000000005",
} as const;

export async function listActivePlans(db: Tx): Promise<PlanRow[]> {
  return db.plan.findMany({
    where: { active: true, slug: { not: PLAN_SLUG_FREE } },
    orderBy: { sortOrder: "asc" },
  });
}

export async function findPlanById(db: Tx, id: string): Promise<PlanRow | null> {
  return db.plan.findUnique({ where: { id } });
}

export async function findPlanBySlug(db: Tx, slug: string): Promise<PlanRow | null> {
  return db.plan.findUnique({ where: { slug } });
}

export async function findPlanBySlugOrId(db: Tx, slugOrId: string): Promise<PlanRow | null> {
  const bySlug = await findPlanBySlug(db, slugOrId);
  if (bySlug) return bySlug;
  return findPlanById(db, slugOrId);
}

export function planSlug(row: PlanRow): PlanId | typeof PLAN_SLUG_FREE | string {
  return row.slug;
}

/** The only `plans.sales_motion` a card can buy. */
const SALES_MOTION_SELF_SERVE = "self_serve";

/** Whether this row can be bought without a human in the loop. Written as "is
 *  it self-serve" rather than "is it not contact_sales" so a motion a build does
 *  not recognise refuses the sale instead of defaulting into it. */
export function isSelfServe(plan: PlanRow): boolean {
  return plan.salesMotion === SALES_MOTION_SELF_SERVE;
}

/** List-price capabilities for the Enterprise row; a contract may narrow them on
 *  the customer's own subscription. `satisfies` rather than a bare literal, so a
 *  name outside the registry fails to compile here instead of parsing to the
 *  empty set at read time. */
const ENTERPRISE_CAPABILITIES = {
  sso: true,
  audit: true,
  ipAllowlist: true,
} satisfies Capabilities;

// Four fields below are optional on `plan.create` — maxSeats because it is
// nullable, billingPeriod/salesMotion/capabilities because they carry column
// defaults — so omitting one from an entry is not a compile error: the row
// silently lands on the default, which for maxSeats means unlimited seats. Every
// entry states all four, and every value has a matching explicit UPDATE in the
// migration that introduced the column, since seedPlans upserts with
// `update: {}` and a change here alone never reaches an existing database.
const CATALOG_PLANS = [
  {
    id: PLAN_UUID.free,
    slug: PLAN_SLUG_FREE,
    label: "Free",
    tier: "free",
    // The machine wall, and the only server-enforced paywall there is — keep in
    // lockstep with FREE_WORKER_LIMIT and the plans migration.
    workerLimit: 1,
    appDeviceLimit: 10,
    maxSeats: 1,
    recurring: false,
    trial: false,
    billingPeriod: "none",
    salesMotion: "self_serve",
    capabilities: {},
    sortOrder: 0,
  },
  {
    id: PLAN_UUID.trial,
    slug: "trial",
    label: "Trial",
    tier: "trial",
    // Trial is a Pro preview, so it tracks Pro's machines — at one seat.
    workerLimit: 10,
    appDeviceLimit: 10,
    maxSeats: 1,
    recurring: true,
    trial: true,
    billingPeriod: "yearly",
    salesMotion: "self_serve",
    capabilities: {},
    sortOrder: 1,
  },
  {
    id: PLAN_UUID.pro_yearly,
    slug: "pro_yearly",
    label: "Pro",
    tier: "pro",
    // Fair use, not a pricing lever — the paid axis is seats.
    workerLimit: 10,
    appDeviceLimit: 10,
    maxSeats: 25,
    recurring: true,
    trial: false,
    billingPeriod: "yearly",
    salesMotion: "self_serve",
    capabilities: {},
    sortOrder: 2,
  },
  {
    id: PLAN_UUID.enterprise,
    slug: "enterprise",
    label: "Enterprise",
    tier: "enterprise",
    // A list price, not a promise: the real machine and app ceilings are
    // negotiated onto the customer's subscription, so the row carries Pro's.
    workerLimit: 10,
    appDeviceLimit: 10,
    // NULL is how a contract says "unlimited".
    maxSeats: null,
    recurring: true,
    trial: false,
    billingPeriod: "contract",
    salesMotion: "contact_sales",
    capabilities: ENTERPRISE_CAPABILITIES,
    // 3 belongs to the retired pro_lifetime row — absent here, still present in
    // every migrated database, and a tie would leave listActivePlans' ORDER BY
    // to pick by physical row order.
    sortOrder: 4,
  },
] as const;

/** Idempotent catalog seed — heals DBs migrated before plan INSERT was added. */
export async function seedPlans(db: Tx): Promise<void> {
  for (const plan of CATALOG_PLANS) {
    await db.plan.upsert({
      where: { id: plan.id },
      create: { ...plan, active: true },
      update: {},
    });
  }
}
