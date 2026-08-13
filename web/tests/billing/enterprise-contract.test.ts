import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestSession, createTestUser } from "../helpers/fixtures.js";
import { findPlanBySlug, PLAN_UUID, type PlanRow } from "../../src/models/plan.js";
import {
  applyPlanToAccountSubscription,
  grantManualContract,
  MANUAL_PROVIDER,
  provisionProductAccountForUser,
  resolveEntitlement,
} from "../../src/models/subscription.js";

const LIST_PRICE_CAPABILITIES = { sso: true, audit: true, ipAllowlist: true };

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

async function planBySlug(slug: string): Promise<PlanRow> {
  const plan = await findPlanBySlug(pg.db, slug);
  if (!plan) throw new Error(`${slug} not seeded`);
  return plan;
}

async function account(): Promise<{ userId: string; accountId: string }> {
  const user = await createTestUser(pg.db);
  const { id } = await provisionProductAccountForUser(pg.db, user.id);
  return { userId: user.id, accountId: id };
}

describe("the capabilities snapshot", () => {
  test("a subscription created from a plan carries that plan's capabilities", async () => {
    const { accountId } = await account();
    const plan = await planBySlug("enterprise");

    const sub = await applyPlanToAccountSubscription(pg.db, accountId, plan, {
      provider: MANUAL_PROVIDER,
    });

    expect(sub.capabilities).toEqual(LIST_PRICE_CAPABILITIES);
    expect(sub.capabilities).toEqual(plan.capabilities);
  });

  test("a self-serve plan grants none, so the set is not merely inherited", async () => {
    const { accountId } = await account();

    const sub = await applyPlanToAccountSubscription(
      pg.db,
      accountId,
      await planBySlug("pro_yearly"),
      { provider: "paddle" }
    );

    expect(sub.capabilities).toEqual({});
  });

  test("an omitted override leaves an existing row's capabilities alone", async () => {
    const { accountId } = await account();
    const plan = await planBySlug("pro_yearly");
    const providerSubscriptionId = "sub_omitted_override";
    const negotiated = { audit: true };

    const first = await applyPlanToAccountSubscription(pg.db, accountId, plan, {
      provider: "paddle",
      providerSubscriptionId,
      capabilities: negotiated,
    });
    // A pending cancellation is what carries a provider id through the apply
    // path's cancel sweep, and so what routes the next apply into the update
    // branch — the renewal and resume webhooks both land there.
    await pg.db.subscription.update({
      where: { id: first.id },
      data: { cancelledAt: new Date(Date.now() + 30 * 24 * 3600 * 1000) },
    });

    const again = await applyPlanToAccountSubscription(pg.db, accountId, plan, {
      provider: "paddle",
      providerSubscriptionId,
    });

    // Same row, so the update branch really ran — a create would have made the
    // assertion below true for the wrong reason.
    expect(again.id).toBe(first.id);
    expect(again.capabilities).toEqual(negotiated);
    // And the plan's own set is empty, so "left alone" and "re-snapshotted from
    // the plan" cannot look the same here.
    expect(plan.capabilities).toEqual({});
  });

  test("an override present on that same row is what does change it", async () => {
    const { accountId } = await account();
    const plan = await planBySlug("pro_yearly");
    const providerSubscriptionId = "sub_present_override";

    const first = await applyPlanToAccountSubscription(pg.db, accountId, plan, {
      provider: "paddle",
      providerSubscriptionId,
      capabilities: { audit: true },
    });
    await pg.db.subscription.update({
      where: { id: first.id },
      data: { cancelledAt: new Date(Date.now() + 30 * 24 * 3600 * 1000) },
    });

    const again = await applyPlanToAccountSubscription(pg.db, accountId, plan, {
      provider: "paddle",
      providerSubscriptionId,
      capabilities: { sso: true },
    });

    expect(again.id).toBe(first.id);
    expect(again.capabilities).toEqual({ sso: true });
  });
});

describe("resolveEntitlement over a negotiated contract", () => {
  test("reports the contract's values, not the plan's list price", async () => {
    const { userId } = await account();
    const plan = await planBySlug("enterprise");
    const negotiated = { sso: true };

    const sub = await grantManualContract(pg.db, userId, {
      workerLimit: 40,
      appDeviceLimit: 40,
      seats: 100,
      capabilities: negotiated,
    });

    const entitlement = resolveEntitlement(sub);
    // The plan still carries the full set and Pro's ceilings; every value below
    // came off the subscription instead, which is the whole claim.
    expect(plan.capabilities).toEqual(LIST_PRICE_CAPABILITIES);
    expect(entitlement.capabilities).toEqual(negotiated);
    expect(entitlement.workerLimit).toBe(40);
    expect(entitlement.appDeviceLimit).toBe(40);
    expect(plan.workerLimit).not.toBe(40);
    expect(sub.seats).toBe(100);
    expect(sub.tier).toBe("enterprise");
  });

  test("a blob it cannot account for grants nothing", async () => {
    const { userId } = await account();
    const sub = await grantManualContract(pg.db, userId, { capabilities: { sso: true } });

    // Whatever wrote this — an older release, a hand-typed admin UPDATE — the
    // only safe reading of a set we cannot fully parse is "no".
    const damaged = await pg.db.subscription.update({
      where: { id: sub.id },
      data: { capabilities: { sso: "yes" } },
    });

    expect(resolveEntitlement(damaged).capabilities).toEqual({});
  });
});

/**
 * The migration guards its re-sync with a provider literal, and the contract
 * writer writes one. Nothing but this joins them: if the two ever disagree,
 * every negotiated row is quietly reset to the list price by the next catalog
 * migration, and no test that only reads either half would notice.
 */
describe("'manual' means the same thing to the writer and to the re-sync", () => {
  const MIGRATION_SQL = resolve(
    dirname(fileURLToPath(import.meta.url)),
    "..",
    "..",
    "prisma",
    "migrations",
    "20260815000000_enterprise_catalog",
    "migration.sql"
  );

  function resync(): string {
    const sql = readFileSync(MIGRATION_SQL, "utf8");
    const stmt = sql.match(/UPDATE "subscriptions"[^;]*"capabilities" = p\."capabilities"[^;]*/);
    if (!stmt) throw new Error("no capabilities re-sync statement in the migration");
    return stmt[0];
  }

  test("the shipped guard names exactly the provider the writer uses", () => {
    expect(resync()).toContain(`IS DISTINCT FROM '${MANUAL_PROVIDER}'`);
  });

  test("a contract survives the re-sync while a gateway-less row is moved", async () => {
    const contract = await account();
    const other = await account();
    const negotiated = { sso: true };

    const kept = await grantManualContract(pg.db, contract.userId, {
      capabilities: negotiated,
    });
    // provider NULL, which is what a dev grant and a free row look like: `<>`
    // evaluates to NULL for this row, so a guard weakened to a plain inequality
    // would skip it and the first assertion below would catch that too.
    const moved = await applyPlanToAccountSubscription(
      pg.db,
      other.accountId,
      await planBySlug("enterprise"),
      { provider: "" }
    );
    await pg.db.subscription.update({
      where: { id: moved.id },
      data: { provider: null, capabilities: {} },
    });

    await pg.db.$executeRawUnsafe(resync());

    expect(
      (await pg.db.subscription.findUniqueOrThrow({ where: { id: moved.id } })).capabilities
    ).toEqual(LIST_PRICE_CAPABILITIES);
    expect(
      (await pg.db.subscription.findUniqueOrThrow({ where: { id: kept.id } })).capabilities
    ).toEqual(negotiated);
  });
});

type TestApp = ReturnType<typeof buildTestApp>["app"];

function devApp(): TestApp {
  return buildTestApp(pg.db, pg.url, {
    envOverrides: { DEV_BILLING_ENABLED: true } as never,
  }).app;
}

async function postContract(app: TestApp, body: unknown): Promise<Response> {
  return app.request("/dev/billing/contract", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("POST /dev/billing/contract", () => {
  test("builds an Enterprise contract the entitlement API then reports", async () => {
    const app = devApp();
    const user = await createTestUser(pg.db);

    const res = await postContract(app, {
      email: user.email,
      workerLimit: 40,
      appDeviceLimit: 30,
      seats: 100,
      capabilities: { sso: true, audit: true },
    });
    expect(res.status).toBe(200);
    const created = (await res.json()) as {
      subscription: { provider: string; tier: string; plan_id: string; capabilities: unknown };
    };
    expect(created.subscription.provider).toBe(MANUAL_PROVIDER);
    expect(created.subscription.plan_id).toBe(PLAN_UUID.enterprise);

    const { cookie } = await createTestSession(pg.db, user.id);
    const me = (await (
      await app.request("/subscriptions/me", { headers: { cookie } })
    ).json()) as {
      tier: string;
      worker_limit: number;
      app_device_limit: number;
      seats: number;
      capabilities: Record<string, boolean>;
    };

    // The route the app actually reads, answering with the negotiated numbers
    // rather than the Enterprise row's list price.
    expect(me).toMatchObject({
      tier: "enterprise",
      worker_limit: 40,
      app_device_limit: 30,
      seats: 100,
      capabilities: { sso: true, audit: true },
    });
  });

  test("omitted values fall back to the plan, so an email alone is a valid contract", async () => {
    const app = devApp();
    const user = await createTestUser(pg.db);
    const plan = await planBySlug("enterprise");

    const res = await postContract(app, { email: user.email });

    expect(res.status).toBe(200);
    expect((await res.json()).subscription).toMatchObject({
      worker_limit: plan.workerLimit,
      app_device_limit: plan.appDeviceLimit,
      seats: 1,
      capabilities: LIST_PRICE_CAPABILITIES,
    });
  });

  test("a capability name this build does not know is refused, not dropped", async () => {
    const app = devApp();
    const user = await createTestUser(pg.db);

    const res = await postContract(app, {
      email: user.email,
      capabilities: { sso: true, telepathy: true },
    });

    // Stripping it would answer ok:true having granted nothing, which is the
    // one outcome a fixture must never produce.
    expect(res.status).toBe(400);
    expect((await res.json()).error).toBe("INVALID_REQUEST");
    expect(await pg.db.subscription.count({ where: { provider: MANUAL_PROVIDER } })).toBe(0);
  });

  test("unknown email returns 404 USER_NOT_FOUND", async () => {
    const res = await postContract(devApp(), { email: "nobody@test.local" });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "USER_NOT_FOUND", email: "nobody@test.local" });
  });

  test("route is absent when the flag is unset (default)", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);

    const res = await postContract(app, { email: user.email });

    expect(res.status).toBe(404);
    expect(await pg.db.subscription.count({ where: { provider: MANUAL_PROVIDER } })).toBe(0);
  });

  test("route is absent in production even if the flag is set", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { NODE_ENV: "production", DEV_BILLING_ENABLED: true } as never,
    });
    const user = await createTestUser(pg.db);

    const res = await postContract(app, { email: user.email });

    expect(res.status).toBe(404);
    expect(await pg.db.subscription.count({ where: { provider: MANUAL_PROVIDER } })).toBe(0);
  });
});
