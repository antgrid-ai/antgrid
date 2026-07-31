import type { Plan } from "../generated/prisma/client.js";
import type { Tx } from "../db/index.js";
import type { PlanId } from "../billing/plans.js";

export type PlanRow = Plan;

export const PLAN_SLUG_FREE = "free";

/** Fixed UUIDs seeded in the billing migration — stable for tests and dev grants. */
export const PLAN_UUID = {
  free: "00000000-0000-4000-8000-000000000001",
  trial: "00000000-0000-4000-8000-000000000004",
  pro_yearly: "00000000-0000-4000-8000-000000000002",
  pro_lifetime: "00000000-0000-4000-8000-000000000003",
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

const CATALOG_PLANS = [
  {
    id: PLAN_UUID.free,
    slug: PLAN_SLUG_FREE,
    label: "Free",
    tier: "free",
    // Free ships at 2 workers and drops to 1 on launch day — keep in lockstep
    // with FREE_WORKER_LIMIT and the plans migration.
    workerLimit: 2,
    deviceLimit: 10,
    recurring: false,
    trial: false,
    sortOrder: 0,
  },
  {
    id: PLAN_UUID.trial,
    slug: "trial",
    label: "Trial",
    tier: "trial",
    workerLimit: 2,
    deviceLimit: 10,
    recurring: true,
    trial: true,
    sortOrder: 1,
  },
  {
    id: PLAN_UUID.pro_yearly,
    slug: "pro_yearly",
    label: "Pro Yearly",
    tier: "pro",
    workerLimit: 3,
    deviceLimit: 10,
    recurring: true,
    trial: false,
    sortOrder: 2,
  },
  {
    id: PLAN_UUID.pro_lifetime,
    slug: "pro_lifetime",
    label: "Pro Lifetime",
    tier: "pro",
    workerLimit: 3,
    deviceLimit: 10,
    recurring: false,
    trial: false,
    sortOrder: 3,
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
