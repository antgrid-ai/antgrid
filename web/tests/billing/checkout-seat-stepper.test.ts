import { describe, test, expect, beforeAll, afterAll, beforeEach, afterEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { testBillingEnv } from "../helpers/billing-env.js";
import { createTestSession, createTestUser } from "../helpers/fixtures.js";
import { provisionProductAccountForUser } from "../../src/models/subscription.js";
import { formatMoneyMinor } from "../../src/billing/checkout.js";
import { displayPriceCents, formatUsd } from "../../src/billing/plans.js";
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

const ORIGIN = "http://localhost:8787";
const NOW = "2026-01-01T00:00:00.000Z";

/**
 * A price id unique to this file.
 *
 * `paddleCatalogPriceCache` is module-level and keyed by price id, so a shared
 * fixture id would let another suite's cached snapshot answer instead of this
 * file's stub — and the caching is invisible from here.
 */
const PRICE_ID = "pri_seat_stepper";
const UNIT_MINOR = 4900;

/**
 * A tax only the gateway knows about.
 *
 * The point of the whole fixture: the grand total Paddle reports is NOT seats ×
 * unit price, so a page that showed its own arithmetic would show a different
 * number and the assertions below would catch it. Real checkouts differ from
 * that product for exactly this reason — tax, discounts, proration.
 */
const GATEWAY_TAX_MINOR = 731;

/** Routed and asserted on the path: the SDK builds `${base}${url}` with the
 *  query string always appended, so a POST arrives as `/transactions?`. */
type PaddleCall = { path: string; body: unknown };

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function priceBody() {
  return {
    data: {
      id: PRICE_ID,
      product_id: "pro_seat_stepper_product",
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
  const lineTotal = UNIT_MINOR * quantity;
  const grandTotal = lineTotal + GATEWAY_TAX_MINOR;
  return {
    data: {
      id: "txn_seat_stepper",
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
          subtotal: String(lineTotal),
          discount: "0",
          tax: String(GATEWAY_TAX_MINOR),
          total: String(grandTotal),
          credit: "0",
          credit_to_balance: "0",
          balance: String(grandTotal),
          grand_total: String(grandTotal),
          grand_total_tax: String(GATEWAY_TAX_MINOR),
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
 * An app whose Paddle answers from this process.
 *
 * `quoted` records what the gateway itself said, and it is the ONE source every
 * total assertion below compares against — never a literal repeated beside the
 * one the fixture used.
 */
function armedApp() {
  const calls: PaddleCall[] = [];
  const quoted: { quantity: number | null; grandTotal: string | null; currency: string | null } = {
    quantity: null,
    grandTotal: null,
    currency: null,
  };

  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    if (!url.includes("paddle.com")) return realFetch(input as RequestInfo, init);

    const body = init?.body ? JSON.parse(String(init.body)) : null;
    const path = new URL(url).pathname;
    calls.push({ path, body });

    if (path.includes("/prices/")) return Response.json(priceBody());
    if (path.endsWith("/transactions")) {
      const items = (body as { items?: { quantity?: number }[] } | null)?.items ?? [];
      const quantity = items[0]?.quantity ?? 0;
      const payload = transactionBody(quantity);
      quoted.quantity = quantity;
      quoted.grandTotal = payload.data.details.totals.grand_total;
      quoted.currency = payload.data.details.totals.currency_code;
      return Response.json(payload);
    }
    return Response.json({ error: { code: "unexpected", detail: url } }, { status: 500 });
  }) as typeof fetch;

  const { app, env } = buildTestApp(pg.db, pg.url, {
    envOverrides: testBillingEnv({ PADDLE_PRICE_YEARLY: PRICE_ID }),
  });
  return { app, env, calls, quoted };
}

type TestApp = ReturnType<typeof buildTestApp>["app"];

/** A signed-in owner whose billing country routes to Paddle. */
async function buyer(country = "DE"): Promise<{ accountId: string; cookie: string }> {
  const user = await createTestUser(pg.db);
  const account = await provisionProductAccountForUser(pg.db, user.id);
  await pg.db.productAccount.update({
    where: { id: account.id },
    data: { country, countrySource: "manual" },
  });
  const { cookie } = await createTestSession(pg.db, user.id);
  return { accountId: account.id, cookie };
}

async function orderRequest(
  app: TestApp,
  cookie: string,
  fields: Record<string, string>,
  opts: { planId?: string; origin?: string } = {}
): Promise<Response> {
  return app.request(`/ui/checkout/seats?planId=${opts.planId ?? "pro_yearly"}`, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      origin: opts.origin ?? ORIGIN,
      cookie,
    },
    body: new URLSearchParams(fields).toString(),
  });
}

/** The page as a reader sees it — markup can carry a number the reader never
 *  gets shown, and the claim under test is about what is displayed. */
function readable(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/g, " ")
    .replace(/<[^>]*>/g, " ")
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ")
    .trim();
}

function jsonBlock<T>(html: string, id: string): T | null {
  const m = html.match(new RegExp(`id="${id}"[^>]*>([\\s\\S]*?)</script>`));
  return m ? (JSON.parse(m[1] as string) as T) : null;
}

type EmbeddedSession = {
  provider: string;
  seats: number;
  transactionId: string;
  total: { amount: number; currency: string; display: string } | null;
};

describe("POST /ui/checkout/seats", () => {
  test("shows the total the transaction-creating call returned, not one of its own", async () => {
    const { app, env, quoted } = armedApp();
    const { cookie } = await buyer();

    const res = await orderRequest(app, cookie, { seats: "7", country: "DE" });
    expect(res.status).toBe(200);
    const html = await res.text();

    // The seat count reached the gateway, so the total below is a quote for the
    // order that was actually placed.
    expect(quoted.quantity).toBe(7);
    expect(quoted.grandTotal).not.toBeNull();

    // One source, compared three ways: the gateway's own number, the session
    // handed to the pay button, and the number on the page.
    const gatewayTotal = Number(quoted.grandTotal);
    const session = jsonBlock<EmbeddedSession>(html, "checkout-session-data");
    expect(session?.total?.amount).toBe(gatewayTotal);
    expect(session?.seats).toBe(7);
    expect(readable(html)).toContain(formatMoneyMinor(gatewayTotal, quoted.currency as string));

    // And emphatically not the number the page could have worked out alone.
    const ownArithmetic = formatUsd(displayPriceCents("pro_yearly", env) * 7);
    expect(formatMoneyMinor(gatewayTotal, "USD")).not.toBe(ownArithmetic);
    expect(readable(html)).not.toContain(ownArithmetic);
  });

  test("quotes nothing before an order is placed", async () => {
    const { app, calls } = armedApp();
    const { cookie } = await buyer();

    const res = await app.request("/checkout?planId=pro_yearly", { headers: { cookie } });
    expect(res.status).toBe(200);
    const html = await res.text();

    // A page GET must not create a transaction, and with no transaction there
    // is no total it is entitled to print.
    expect(calls).toEqual([]);
    expect(jsonBlock(html, "checkout-session-data")).toBeNull();
    expect(readable(html)).toContain("Your total is quoted when you review the order.");
  });

  test("refuses a seat count above the plan's max_seats without calling the gateway", async () => {
    const { app, calls } = armedApp();
    const { accountId, cookie } = await buyer();

    const res = await orderRequest(app, cookie, { seats: "26", country: "DE" });

    expect(res.status).toBe(400);
    expect(readable(await res.text())).toContain("This plan covers at most 25 seats");
    expect(calls).toEqual([]);
    // A refusal must leave nothing behind: the gateway lock is immutable once set.
    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { id: accountId } });
    expect(account.billingProvider).toBeNull();
  });

  test("a NULL max_seats plan takes a large count and quotes it", async () => {
    const { app, quoted } = armedApp();
    const { cookie } = await buyer();
    // `plans` survives truncate, so restore the catalog value for later files.
    await pg.db.plan.update({ where: { id: PLAN_UUID.pro_yearly }, data: { maxSeats: null } });
    try {
      const res = await orderRequest(app, cookie, { seats: "500", country: "DE" });

      expect(res.status).toBe(200);
      expect(quoted.quantity).toBe(500);
      const html = await res.text();
      expect(readable(html)).toContain(
        formatMoneyMinor(Number(quoted.grandTotal), quoted.currency as string)
      );
      expect(readable(html)).toContain("Add as many seats as you need.");
    } finally {
      await pg.db.plan.update({ where: { id: PLAN_UUID.pro_yearly }, data: { maxSeats: 25 } });
    }
  });

  test("refuses a count below one", async () => {
    const { app, calls } = armedApp();
    const { cookie } = await buyer();

    const res = await orderRequest(app, cookie, { seats: "0", country: "DE" });

    expect(res.status).toBe(400);
    expect(readable(await res.text())).toContain("Choose between 1 and 25 seats.");
    expect(calls).toEqual([]);
  });

  test("has its own rate-limit bucket, and drives to a refusal", async () => {
    const { app, calls } = armedApp();
    const { cookie } = await buyer();

    const statuses: number[] = [];
    for (let i = 0; i < 8; i++) {
      const res = await orderRequest(app, cookie, { seats: "2", country: "DE" });
      statuses.push(res.status);
      if (res.status === 302) {
        expect(res.headers.get("location")).toBe("/checkout?planId=pro_yearly&notice=throttled");
        break;
      }
    }

    expect(statuses).toContain(302);
    // The bucket is the only thing that stopped it: every attempt before the
    // refusal was accepted, and the gateway saw exactly those.
    const accepted = statuses.filter((s) => s === 200).length;
    expect(accepted).toBeGreaterThan(0);
    expect(calls.filter((call) => call.path.endsWith("/transactions"))).toHaveLength(accepted);

    // The redirect target renders the refusal rather than swallowing it.
    const page = await app.request("/checkout?planId=pro_yearly&notice=throttled", {
      headers: { cookie },
    });
    expect(readable(await page.text())).toContain("Too many order updates.");
  });

  test("rejects a cross-origin post before anything is created", async () => {
    const { app, calls } = armedApp();
    const { accountId, cookie } = await buyer();

    const res = await orderRequest(
      app,
      cookie,
      { seats: "3", country: "DE" },
      { origin: "https://evil.example" }
    );

    expect(res.status).toBe(403);
    expect(await res.text()).toBe("Forbidden");
    expect(calls).toEqual([]);
    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { id: accountId } });
    expect(account.billingProvider).toBeNull();
  });

  test("a member cannot order seats on the account they belong to", async () => {
    const { app, calls } = armedApp();
    const { accountId } = await buyer();
    const member = await createTestUser(pg.db);
    await provisionProductAccountForUser(pg.db, member.id);
    await pg.db.accountMember.updateMany({
      where: { userId: member.id, status: "active" },
      data: { status: "left", endedAt: new Date() },
    });
    await pg.db.accountMember.create({
      data: { accountId, userId: member.id, role: "member", status: "active" },
    });
    const { cookie } = await createTestSession(pg.db, member.id);

    const res = await orderRequest(app, cookie, { seats: "3", country: "DE" });

    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/dashboard");
    expect(calls).toEqual([]);
  });
});
