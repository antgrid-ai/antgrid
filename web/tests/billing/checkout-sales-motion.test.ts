import { describe, test, expect, beforeAll, afterAll, beforeEach, afterEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { testBillingEnv } from "../helpers/billing-env.js";
import { createTestSession, createTestUser } from "../helpers/fixtures.js";
import { provisionProductAccountForUser } from "../../src/models/subscription.js";
import { PLAN_UUID } from "../../src/models/plan.js";

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

const NOW = "2026-01-01T00:00:00.000Z";

/** Unique to this file: `paddleCatalogPriceCache` is module-level and keyed by
 *  price id, so a shared fixture id would let another suite's snapshot answer. */
const PRICE_ID = "pri_sales_motion";
const UNIT_MINOR = 4900;

type PaddleCall = { path: string; body: unknown };

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function priceBody() {
  return {
    data: {
      id: PRICE_ID,
      product_id: "pro_sales_motion_product",
      description: "Pro Yearly",
      name: "Pro Yearly",
      type: "standard",
      billing_cycle: { interval: "year", frequency: 1 },
      trial_period: null,
      tax_mode: "account_setting",
      unit_price: { amount: String(UNIT_MINOR), currency_code: "USD" },
      unit_price_overrides: [],
      quantity: { minimum: 1, maximum: 1000 },
      status: "active",
      custom_data: null,
      import_meta: null,
      created_at: NOW,
      updated_at: NOW,
    },
    meta: { request_id: "req_price" },
  };
}

function transactionBody(quantity: number) {
  const total = String(UNIT_MINOR * quantity);
  return {
    data: {
      id: "txn_sales_motion",
      status: "ready",
      customer_id: null,
      address_id: null,
      business_id: null,
      custom_data: null,
      currency_code: "USD",
      origin: "api",
      subscription_id: null,
      invoice_id: null,
      invoice_number: null,
      collection_mode: "automatic",
      discount_id: null,
      billing_details: null,
      billing_period: null,
      items: [],
      payments: [],
      details: {
        tax_rates_used: [],
        line_items: [],
        totals: {
          subtotal: total,
          discount: "0",
          tax: "0",
          total,
          credit: "0",
          credit_to_balance: "0",
          balance: total,
          grand_total: total,
          grand_total_tax: "0",
          fee: null,
          earnings: null,
          currency_code: "USD",
        },
      },
      checkout: null,
      created_at: NOW,
      updated_at: NOW,
      billed_at: null,
      revised_at: null,
    },
    meta: { request_id: "req_txn" },
  };
}

/**
 * An app with a working Paddle behind it.
 *
 * Working is the point: with no credentials every checkout dies at the client
 * getter, so a refusal and an acceptance would look alike. Here an accepted
 * order really does create a transaction, which is what makes an empty `calls`
 * evidence that the refusal happened before the gateway rather than at it.
 */
function armedApp() {
  const calls: PaddleCall[] = [];

  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    if (!url.includes("paddle.com")) return realFetch(input as RequestInfo, init);

    const body = init?.body ? JSON.parse(String(init.body)) : null;
    const path = new URL(url).pathname;
    calls.push({ path, body });

    if (path.includes("/prices/")) return Response.json(priceBody());
    if (path.endsWith("/transactions")) {
      const items = (body as { items?: { quantity?: number }[] } | null)?.items ?? [];
      return Response.json(transactionBody(items[0]?.quantity ?? 0));
    }
    return Response.json({ error: { code: "unexpected", detail: url } }, { status: 500 });
  }) as typeof fetch;

  const { app } = buildTestApp(pg.db, pg.url, {
    envOverrides: testBillingEnv({ PADDLE_PRICE_YEARLY: PRICE_ID }),
  });
  return { app, calls };
}

type TestApp = ReturnType<typeof buildTestApp>["app"];

async function buyer(): Promise<{ accountId: string; cookie: string }> {
  const user = await createTestUser(pg.db);
  const account = await provisionProductAccountForUser(pg.db, user.id);
  await pg.db.productAccount.update({
    where: { id: account.id },
    data: { country: "DE", countrySource: "manual" },
  });
  const { cookie } = await createTestSession(pg.db, user.id);
  return { accountId: account.id, cookie };
}

/**
 * Sell pro_yearly the way Enterprise is sold, for the duration of one test.
 *
 * The catalog's own contact-sales row cannot reach `startCheckout` today —
 * `isPlanId` refuses "enterprise" at both entry points first — so the only way
 * to exercise the gate is to move the motion onto a slug that gets that far.
 * That is also the shape the gate exists for: the day `PlanId` widens, this is
 * what the money path sees. `plans` survives truncate, hence the restore.
 */
async function withContactSales<T>(run: () => Promise<T>): Promise<T> {
  await pg.db.plan.update({
    where: { id: PLAN_UUID.pro_yearly },
    data: { salesMotion: "contact_sales" },
  });
  try {
    return await run();
  } finally {
    await pg.db.plan.update({
      where: { id: PLAN_UUID.pro_yearly },
      data: { salesMotion: "self_serve" },
    });
  }
}

async function checkoutSession(app: TestApp, cookie: string): Promise<Response> {
  return app.request("/billing/checkout-session", {
    method: "POST",
    headers: { cookie, "content-type": "application/json" },
    body: JSON.stringify({ planId: "pro_yearly", country: "DE", seats: 3 }),
  });
}

describe("POST /billing/checkout-session against a contact-sales plan", () => {
  test("is refused before the gateway is called or the provider locked", async () => {
    const { app, calls } = armedApp();
    const { accountId, cookie } = await buyer();

    const res = await withContactSales(() => checkoutSession(app, cookie));

    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "PLAN_NOT_SELF_SERVE" });
    expect(calls).toEqual([]);
    // The refusal must leave nothing behind: lockBillingProvider early-returns
    // on an existing value, so reaching it would pin the gateway for good.
    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { id: accountId } });
    expect(account.billingProvider).toBeNull();
  });

  test("the same request against the self-serve plan reaches the gateway", async () => {
    const { app, calls } = armedApp();
    const { cookie } = await buyer();

    const res = await checkoutSession(app, cookie);

    expect(res.status).toBe(200);
    expect((await res.json()).transactionId).toBe("txn_sales_motion");
    expect(calls.filter((call) => call.path.endsWith("/transactions"))).toHaveLength(1);
  });
});

describe("the checkout page against a contact-sales plan", () => {
  test("sends the buyer back to pricing rather than locking their gateway", async () => {
    const { app, calls } = armedApp();
    const { accountId, cookie } = await buyer();

    const res = await withContactSales(async () =>
      app.request("/checkout?planId=pro_yearly", { headers: { cookie } })
    );

    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/pricing");
    expect(calls).toEqual([]);
    // This GET is the page that locks the provider, and the lock is immutable
    // once written — a plan nobody can buy here must not cost the account one.
    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { id: accountId } });
    expect(account.billingProvider).toBeNull();
  });

  test("the order form creates no transaction for it either", async () => {
    const { app, calls } = armedApp();
    const { cookie } = await buyer();

    const res = await withContactSales(async () =>
      app.request("/ui/checkout/seats?planId=pro_yearly", {
        method: "POST",
        headers: {
          cookie,
          origin: "http://localhost:8787",
          "content-type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({ seats: "3", country: "DE" }).toString(),
      })
    );

    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/pricing");
    expect(calls).toEqual([]);
  });
});
