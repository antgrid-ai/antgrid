import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { razorpaySignature, razorpaySubscriptionBody } from "../helpers/razorpay-sig.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser } from "../helpers/fixtures.js";
import { ensureProductAccount } from "../../src/models/product-account.js";
import { testBillingEnv } from "../helpers/billing-env.js";
import { PLAN_UUID } from "../../src/models/plan.js";

const SECRET = "rzp_route_webhook_secret";

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

function subscriptionBody(
  accountId: string,
  opts: { event?: string; quantity?: number } = {}
): string {
  return razorpaySubscriptionBody(opts.event ?? "subscription.activated", {
    id: "sub_route",
    customer_id: "cust_route",
    status: "active",
    notes: { accountId, planId: "pro_yearly" },
    current_end: 1893456000,
    ...(opts.quantity === undefined ? {} : { quantity: opts.quantity }),
  });
}

function activationBody(accountId: string): string {
  return subscriptionBody(accountId);
}

describe("POST /webhooks/razorpay", () => {
  test("valid activation creates subscription", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: testBillingEnv({ RAZORPAY_WEBHOOK_SECRET: SECRET }),
    });
    const user = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, user.id);
    const raw = activationBody(account.id);
    const res = await app.request("/webhooks/razorpay", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-razorpay-signature": razorpaySignature(raw, SECRET),
      },
      body: raw,
    });
    expect(res.status).toBe(200);
    const sub = await pg.db.subscription.findFirst({ where: { accountId: account.id } });
    expect(sub).toMatchObject({ tier: "pro", status: "active", planId: PLAN_UUID.pro_yearly });
  });

  test("replayed delivery is idempotent", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: testBillingEnv({ RAZORPAY_WEBHOOK_SECRET: SECRET }),
    });
    const user = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, user.id);
    const raw = activationBody(account.id);
    const headers = {
      "content-type": "application/json",
      "x-razorpay-signature": razorpaySignature(raw, SECRET),
    };
    await app.request("/webhooks/razorpay", { method: "POST", headers, body: raw });
    const res2 = await app.request("/webhooks/razorpay", { method: "POST", headers, body: raw });
    expect(res2.status).toBe(200);
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(1);
  });

  test("subscription.updated reaches the reducer and moves the seat count", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: testBillingEnv({ RAZORPAY_WEBHOOK_SECRET: SECRET }),
    });
    const user = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, user.id);

    const post = async (raw: string) =>
      app.request("/webhooks/razorpay", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-razorpay-signature": razorpaySignature(raw, SECRET),
        },
        body: raw,
      });

    await post(subscriptionBody(account.id, { quantity: 2 }));

    const raw = subscriptionBody(account.id, { event: "subscription.updated", quantity: 6 });
    const res = await post(raw);
    expect(res.status).toBe(200);
    // Before the subscription.updated branch existed this short-circuited to
    // {ok:true, ignored:true} without ever reaching the reducer.
    expect(await res.json()).toMatchObject({ ok: true, duplicate: false });

    const sub = await pg.db.subscription.findFirstOrThrow({
      where: { providerSubscriptionId: "sub_route" },
    });
    expect(sub.seats).toBe(6);
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(1);
  });

  test("unconfigured secret returns 503", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, user.id);
    const raw = activationBody(account.id);
    const res = await app.request("/webhooks/razorpay", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-razorpay-signature": razorpaySignature(raw, SECRET),
      },
      body: raw,
    });
    expect(res.status).toBe(503);
  });

  test("bad signature returns 400", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: testBillingEnv({ RAZORPAY_WEBHOOK_SECRET: SECRET }),
    });
    const user = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, user.id);
    const raw = activationBody(account.id);
    const res = await app.request("/webhooks/razorpay", {
      method: "POST",
      headers: { "content-type": "application/json", "x-razorpay-signature": "bad" },
      body: raw,
    });
    expect(res.status).toBe(400);
  });

  test("payment.failed is logged and does not provision", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: testBillingEnv({ RAZORPAY_WEBHOOK_SECRET: SECRET }),
    });
    const user = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, user.id);
    const raw = JSON.stringify({
      event: "payment.failed",
      payload: {
        payment: {
          entity: {
            id: "pay_route_fail",
            subscription_id: "sub_route",
            customer_id: "cust_route",
            notes: { accountId: account.id, planId: "trial" },
            error_code: "BAD_REQUEST_ERROR",
          },
        },
      },
    });
    const res = await app.request("/webhooks/razorpay", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-razorpay-signature": razorpaySignature(raw, SECRET),
      },
      body: raw,
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ ok: true, ignored: true });
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(0);
  });
});
