import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser } from "../helpers/fixtures.js";
import { seedPlans, PLAN_UUID, PLAN_SLUG_FREE } from "../../src/models/plan.js";

/**
 * The Enterprise catalog row exists only in raw migration SQL and in
 * CATALOG_PLANS, and the two are joined by nothing but this file: seedPlans
 * upserts with `update: {}`, so a value that drifts between them is invisible
 * until the day a plan row goes missing and the create branch re-materializes it
 * at the constant's values.
 */
const MIGRATION_SQL = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "prisma",
  "migrations",
  "20260815000000_enterprise_catalog",
  "migration.sql"
);

const ENTERPRISE_CAPABILITIES = { sso: true, audit: true, ipAllowlist: true };

/**
 * Pull the shipped re-sync out of the migration and hand it back for re-running.
 * The statement executes exactly once, against a database that has no fixtures
 * in it, so re-reading the file is the only way a test can exercise the guard
 * that is actually deployed rather than a copy of it that can drift.
 */
function capabilityResync(): string {
  const sql = readFileSync(MIGRATION_SQL, "utf8");
  const stmt = sql.match(/UPDATE "subscriptions"[^;]*"capabilities" = p\."capabilities"[^;]*/);
  if (!stmt) throw new Error("no capabilities re-sync statement in the migration");
  return stmt[0];
}

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});
beforeEach(async () => {
  await pg.truncate();
});

describe("the Enterprise plan row", () => {
  test("the migration seeded it with the contracted value on every axis", async () => {
    const row = await pg.db.plan.findUniqueOrThrow({
      where: { id: PLAN_UUID.enterprise },
    });

    expect({
      slug: row.slug,
      tier: row.tier,
      billingPeriod: row.billingPeriod,
      salesMotion: row.salesMotion,
      capabilities: row.capabilities,
      active: row.active,
    }).toEqual({
      slug: "enterprise",
      tier: "enterprise",
      billingPeriod: "contract",
      salesMotion: "contact_sales",
      capabilities: ENTERPRISE_CAPABILITIES,
      // Live in the catalog; `sales_motion` is what says it is not bought with
      // a card. The two are separate columns precisely so this can be true.
      active: true,
    });
  });

  test("carries no seat cap — NULL is how a contract says unlimited", async () => {
    const row = await pg.db.plan.findUniqueOrThrow({
      where: { id: PLAN_UUID.enterprise },
    });

    expect(row.maxSeats).toBeNull();
  });

  test("machines and app devices are Pro's list price, not a promise", async () => {
    const [enterprise, pro] = await Promise.all([
      pg.db.plan.findUniqueOrThrow({ where: { id: PLAN_UUID.enterprise } }),
      pg.db.plan.findUniqueOrThrow({ where: { id: PLAN_UUID.pro_yearly } }),
    ]);

    expect({
      workerLimit: enterprise.workerLimit,
      appDeviceLimit: enterprise.appDeviceLimit,
    }).toEqual({ workerLimit: pro.workerLimit, appDeviceLimit: pro.appDeviceLimit });
  });
});

describe("the new axes on the pre-existing catalog rows", () => {
  test("the migration wrote them onto every row rather than leaving the default", async () => {
    const plans = await pg.db.plan.findMany({
      select: {
        slug: true,
        billingPeriod: true,
        salesMotion: true,
        capabilities: true,
      },
    });
    const bySlug = Object.fromEntries(plans.map((p) => [p.slug, p]));

    expect(bySlug[PLAN_SLUG_FREE]).toMatchObject({
      billingPeriod: "none",
      salesMotion: "self_serve",
      capabilities: {},
    });
    expect(bySlug.trial).toMatchObject({
      billingPeriod: "yearly",
      salesMotion: "self_serve",
      capabilities: {},
    });
    expect(bySlug.pro_yearly).toMatchObject({
      billingPeriod: "yearly",
      salesMotion: "self_serve",
      capabilities: {},
    });
    // Retired, not deleted, and subscriptions still point at it — so its period
    // has to say what was sold rather than inherit the self-serve default.
    expect(bySlug.pro_lifetime).toMatchObject({ billingPeriod: "lifetime" });
  });
});

describe("the capabilities re-sync", () => {
  test("moves a subscription with no gateway and leaves a manual contract alone", async () => {
    const [gatewayless, contract] = await Promise.all([
      createTestUser(pg.db),
      createTestUser(pg.db),
    ]);
    const [accountA, accountB] = await Promise.all([
      pg.db.productAccount.create({ data: { userId: gatewayless.id } }),
      pg.db.productAccount.create({ data: { userId: contract.id } }),
    ]);

    // provider NULL is the whole fixture: `<>` evaluates to NULL for this row,
    // so a guard rewritten as a plain inequality skips it and leaves the
    // capabilities at `{}` — which is what the first assertion below catches.
    const listPrice = await pg.db.subscription.create({
      data: {
        accountId: accountA.id,
        planId: PLAN_UUID.enterprise,
        provider: null,
        tier: "enterprise",
        status: "active",
        workerLimit: 10,
        appDeviceLimit: 10,
      },
    });
    // A narrower set than the plan's, so "left alone" and "re-synced" cannot
    // look the same.
    const negotiated = { sso: true };
    const manual = await pg.db.subscription.create({
      data: {
        accountId: accountB.id,
        planId: PLAN_UUID.enterprise,
        provider: "manual",
        tier: "enterprise",
        status: "active",
        workerLimit: 40,
        appDeviceLimit: 40,
        capabilities: negotiated,
      },
    });

    await pg.db.$executeRawUnsafe(capabilityResync());

    const moved = await pg.db.subscription.findUniqueOrThrow({ where: { id: listPrice.id } });
    expect(moved.capabilities).toEqual(ENTERPRISE_CAPABILITIES);

    const untouched = await pg.db.subscription.findUniqueOrThrow({ where: { id: manual.id } });
    expect(untouched.capabilities).toEqual(negotiated);
  });

  test("a subscription created without capabilities lands on the empty set", async () => {
    const user = await createTestUser(pg.db);
    const account = await pg.db.productAccount.create({ data: { userId: user.id } });

    const sub = await pg.db.subscription.create({
      data: {
        accountId: account.id,
        planId: PLAN_UUID.pro_yearly,
        tier: "pro",
        status: "active",
        workerLimit: 10,
        appDeviceLimit: 10,
      },
    });

    expect(sub.capabilities).toEqual({});
  });
});

describe("seedPlans against the migrated catalog", () => {
  test("is idempotent — it neither downgrades a row nor revives a retired one", async () => {
    const before = await pg.db.plan.findMany({ orderBy: { slug: "asc" } });
    await seedPlans(pg.db);
    const after = await pg.db.plan.findMany({ orderBy: { slug: "asc" } });

    expect(after).toEqual(before);
    // Named on its own: `update: {}` is what makes the upsert harmless here, and
    // the create branch is the half that is live. pro_lifetime is deactivated
    // and absent from CATALOG_PLANS, so an upsert that ever started writing
    // updates would put it back on sale.
    expect(after.find((p) => p.slug === "pro_lifetime")?.active).toBe(false);
  });

  // Runs last: it empties the catalog. The create branch is live, so a plan row
  // that ever goes missing is re-created from CATALOG_PLANS — and four of its
  // fields are optional on create (max_seats is nullable; billing_period,
  // sales_motion and capabilities carry defaults), so a constant that has
  // drifted from this migration re-creates the row at the default instead of
  // failing to compile.
  test("re-creates a deleted row at the values the migration seeded", async () => {
    const migrated = await pg.db.plan.findUniqueOrThrow({
      where: { id: PLAN_UUID.enterprise },
    });

    await pg.db.plan.deleteMany({});
    await seedPlans(pg.db);

    const reseeded = await pg.db.plan.findUniqueOrThrow({
      where: { id: PLAN_UUID.enterprise },
    });
    expect(reseeded).toEqual(migrated);

    // pro_lifetime is deactivated rather than deleted precisely because this
    // branch would otherwise resurrect it; it is absent from CATALOG_PLANS, so
    // it must not come back at all.
    expect(await pg.db.plan.findFirst({ where: { slug: "pro_lifetime" } })).toBeNull();
  });
});
