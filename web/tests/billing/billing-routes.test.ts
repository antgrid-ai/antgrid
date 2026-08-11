import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession } from "../helpers/fixtures.js";
import { testBillingEnv } from "../helpers/billing-env.js";
import { ensureProductAccount } from "../../src/models/product-account.js";
import { provisionProductAccountForUser } from "../../src/models/subscription.js";
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

describe("GET /billing/checkout-intent", () => {
  test("returns provider routing for signed-in user", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const user = await createTestUser(pg.db, "alice@example.com");
    const account = await provisionProductAccountForUser(pg.db, user.id);
    await pg.db.productAccount.update({
      where: { id: account.id },
      data: { country: "IN", countrySource: "manual" },
    });
    const { cookie } = await createTestSession(pg.db, user.id);

    const res = await app.request("/billing/checkout-intent", { headers: { cookie } });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({
      detected_country: "IN",
      provider: "razorpay",
      provider_locked: false,
      country_locked: false,
      yearly_offer_active: true,
    });
  });

  test("requires auth", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/billing/checkout-intent");
    expect(res.status).toBe(401);
  });
});

describe("GET /billing/plans", () => {
  test("returns plan metadata without gateway sku fields", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const user = await createTestUser(pg.db, "plans@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);

    const res = await app.request("/billing/plans", { headers: { cookie } });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      yearly_offer_active: boolean;
      plans: Record<string, unknown>[];
    };
    expect(body.yearly_offer_active).toBe(true);
    expect(body.plans.length).toBeGreaterThanOrEqual(3);

    for (const plan of body.plans) {
      expect(plan).toMatchObject({
        slug: expect.any(String),
        label: expect.any(String),
        worker_limit: expect.any(Number),
        // Compatibility mirror for app builds already in the field.
        session_limit: expect.any(Number),
      });
      expect(plan).not.toHaveProperty("paddle_price_id");
      expect(plan).not.toHaveProperty("razorpay_plan_id");
    }

    expect(body.plans.map((p) => p.id)).toEqual(
      expect.arrayContaining(["trial", "pro_yearly", "pro_lifetime"])
    );
    const trial = body.plans.find((p) => p.id === "trial");
    expect(trial).toMatchObject({ slug: "trial", trial: true, tier: "trial" });
    const yearly = body.plans.find((p) => p.id === "pro_yearly");
    expect(yearly).toMatchObject({
      slug: "pro_yearly",
      trial: false,
      tier: "pro",
      price_cents: 4900,
      offer_percent: 50,
      list_price_cents: 9900,
    });
  });
});

describe("POST /billing/checkout-session", () => {
  test("returns 503 when paddle env skus are not configured", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "checkout@example.com");
    await provisionProductAccountForUser(pg.db, user.id);
    await pg.db.productAccount.update({
      where: { userId: user.id },
      data: { country: "DE", countrySource: "manual" },
    });
    const { cookie } = await createTestSession(pg.db, user.id);

    const res = await app.request("/billing/checkout-session", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({ planId: "pro_yearly", country: "DE" }),
    });
    expect(res.status).toBe(503);
    expect((await res.json()).error).toBe("PADDLE_NOT_CONFIGURED");
  });

  test("locks billing provider on checkout session", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const user = await createTestUser(pg.db, "lock@example.com");
    const account = await provisionProductAccountForUser(pg.db, user.id);
    const { cookie } = await createTestSession(pg.db, user.id);

    await app.request("/billing/confirm-country", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({ country: "IN" }),
    });

    await app.request("/billing/checkout-session", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({ planId: "pro_yearly", country: "IN" }),
    });

    const locked = await pg.db.productAccount.findUnique({ where: { id: account.id } });
    expect(locked?.billingProvider).toBe("razorpay");

    const preview = await app.request("/billing/confirm-country", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({ country: "DE" }),
    });
    expect(preview.status).toBe(200);
    expect(await preview.json()).toMatchObject({ country: "DE", provider: "razorpay" });
  });

  test("requires auth", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const res = await app.request("/billing/checkout-session", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ planId: "pro_yearly", country: "DE" }),
    });
    expect(res.status).toBe(401);
  });
});

describe("POST /billing/confirm-country", () => {
  test("updates country but keeps provider when billing provider is locked", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "bob@example.com");
    const account = await ensureProductAccount(pg.db, user.id);
    await pg.db.productAccount.update({
      where: { id: account.id },
      data: { billingProvider: "paddle", country: "US", countrySource: "manual" },
    });
    const { cookie } = await createTestSession(pg.db, user.id);

    const res = await app.request("/billing/confirm-country", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({ country: "GB" }),
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ country: "GB", provider: "paddle" });

    const row = await pg.db.productAccount.findUnique({ where: { id: account.id } });
    expect(row?.country).toBe("GB");
    expect(row?.billingProvider).toBe("paddle");
  });

  test("previews provider without persisting billing lock", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "carol@example.com");
    const account = await provisionProductAccountForUser(pg.db, user.id);
    const { cookie } = await createTestSession(pg.db, user.id);

    const first = await app.request("/billing/confirm-country", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({ country: "DE" }),
    });
    expect(first.status).toBe(200);
    expect(await first.json()).toMatchObject({ country: "DE", provider: "paddle" });

    const second = await app.request("/billing/confirm-country", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({ country: "IN" }),
    });
    expect(second.status).toBe(200);
    expect(await second.json()).toMatchObject({ country: "IN", provider: "razorpay" });

    const row = await pg.db.productAccount.findUnique({ where: { id: account.id } });
    expect(row?.billingProvider).toBeNull();
  });
});
