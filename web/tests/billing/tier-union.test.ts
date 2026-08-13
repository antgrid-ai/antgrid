import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { seedPlans } from "../../src/models/plan.js";
import { FREE_TIER } from "../../src/billing/plans.js";

/**
 * Hand-mirrors `DEVICE_TIERS` in `relay/src/license/verify.ts`. It cannot be
 * imported: web's tsconfig confines `rootDir` to this workspace, and the relay
 * predicate is module-private. A tier web mints but the relay does not know is
 * a terminal `LICENSE_INVALID` — `retryable: false`, which fires the bridge's
 * `onAuthRevoked` and stops it reconnecting on its own. Widen the relay first.
 */
const RELAY_DEVICE_TIERS = new Set(["free", "trial", "pro", "enterprise"]);

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});

// `subscriptions.tier` — which `resolveEntitlement` hands to oauth-provider.ts
// to mint — is written from exactly two sources: FREE_TIER, and the plan row's
// own tier. Both are covered below, so together they bound what can be minted.
describe("minted tier stays inside the relay's union", () => {
  test("FREE_TIER is a tier the relay admits", () => {
    expect(RELAY_DEVICE_TIERS.has(FREE_TIER)).toBe(true);
  });

  // seedPlans first: the migration INSERT and the private CATALOG_PLANS array
  // are independent sources of plan rows, and a new tier is likeliest to land
  // in the catalog constant, which a migrate-only database never sees.
  test("every seeded plan carries a tier the relay admits", async () => {
    await seedPlans(pg.db);

    const plans = await pg.db.plan.findMany({ select: { slug: true, tier: true } });
    expect(plans.length).toBeGreaterThan(0);
    for (const plan of plans) {
      expect({ slug: plan.slug, known: RELAY_DEVICE_TIERS.has(plan.tier) }).toEqual({
        slug: plan.slug,
        known: true,
      });
    }
  });
});
