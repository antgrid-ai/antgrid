import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession } from "../helpers/fixtures.js";
import { provisionProductAccountForUser } from "../../src/models/subscription.js";
import { MAX_CHECKOUT_SEATS } from "../../src/billing/checkout.js";
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

/**
 * A signed-in owner with a fixed billing country and no gateway credentials.
 *
 * The missing credentials are the assertion device: a seat count the route
 * accepts gets as far as the provider and comes back `503 *_NOT_CONFIGURED`,
 * which no refused count can produce. Testing acceptance any other way would
 * mean a live gateway call.
 */
async function buyer(country: string): Promise<{ accountId: string; cookie: string }> {
  const user = await createTestUser(pg.db);
  const account = await provisionProductAccountForUser(pg.db, user.id);
  await pg.db.productAccount.update({
    where: { id: account.id },
    data: { country, countrySource: "manual" },
  });
  const { cookie } = await createTestSession(pg.db, user.id);
  return { accountId: account.id, cookie };
}

type TestApp = ReturnType<typeof buildTestApp>["app"];

async function checkout(app: TestApp, cookie: string, body: unknown): Promise<Response> {
  return app.request("/billing/checkout-session", {
    method: "POST",
    headers: { cookie, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("POST /billing/checkout-session seat count", () => {
  test("five seats within the plan cap reach the paddle gateway", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { cookie } = await buyer("DE");

    const res = await checkout(app, cookie, { planId: "pro_yearly", country: "DE", seats: 5 });

    expect(res.status).toBe(503);
    expect((await res.json()).error).toBe("PADDLE_NOT_CONFIGURED");
  });

  test("five seats within the plan cap reach the razorpay gateway", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { cookie } = await buyer("IN");

    const res = await checkout(app, cookie, { planId: "pro_yearly", country: "IN", seats: 5 });

    expect(res.status).toBe(503);
    expect((await res.json()).error).toBe("RAZORPAY_NOT_CONFIGURED");
  });

  test("an absent seat count buys one seat, and still reaches the gateway", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { cookie } = await buyer("DE");

    const res = await checkout(app, cookie, { planId: "pro_yearly", country: "DE" });

    expect(res.status).toBe(503);
    expect((await res.json()).error).toBe("PADDLE_NOT_CONFIGURED");
  });

  test("above the plan's max_seats is refused, naming the cap", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { accountId, cookie } = await buyer("DE");

    const res = await checkout(app, cookie, { planId: "pro_yearly", country: "DE", seats: 26 });

    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "SEATS_ABOVE_PLAN_MAX", max_seats: 25 });
    // A refusal must leave nothing behind: lockBillingProvider early-returns on
    // an existing value, so reaching it would pin the gateway for good.
    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { id: accountId } });
    expect(account.billingProvider).toBeNull();
  });

  test("trial is a one-seat plan and refuses a second seat", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { cookie } = await buyer("DE");

    const res = await checkout(app, cookie, { planId: "trial", country: "DE", seats: 2 });

    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "SEATS_ABOVE_PLAN_MAX", max_seats: 1 });
  });

  test("a NULL max_seats is unlimited and takes a large count", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { cookie } = await buyer("DE");
    // `plans` survives truncate, so restore the catalog value for later files.
    await pg.db.plan.update({ where: { id: PLAN_UUID.pro_yearly }, data: { maxSeats: null } });
    try {
      const res = await checkout(app, cookie, {
        planId: "pro_yearly",
        country: "DE",
        seats: 500,
      });

      expect(res.status).toBe(503);
      expect((await res.json()).error).toBe("PADDLE_NOT_CONFIGURED");
    } finally {
      await pg.db.plan.update({ where: { id: PLAN_UUID.pro_yearly }, data: { maxSeats: 25 } });
    }
  });

  test("unlimited still stops at the request sanity bound", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { accountId, cookie } = await buyer("DE");
    await pg.db.plan.update({ where: { id: PLAN_UUID.pro_yearly }, data: { maxSeats: null } });
    try {
      const res = await checkout(app, cookie, {
        planId: "pro_yearly",
        country: "DE",
        seats: MAX_CHECKOUT_SEATS + 1,
      });

      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: "BAD_REQUEST" });
      const account = await pg.db.productAccount.findUniqueOrThrow({ where: { id: accountId } });
      expect(account.billingProvider).toBeNull();
    } finally {
      await pg.db.plan.update({ where: { id: PLAN_UUID.pro_yearly }, data: { maxSeats: 25 } });
    }
  });

  test.each([
    ["zero", 0],
    ["negative", -1],
    ["fractional", 2.5],
    ["a numeric string", "3"],
    ["a boolean", true],
    ["null", null],
  ])("rejects %s before anything is written", async (_label, seats) => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { accountId, cookie } = await buyer("DE");

    const res = await checkout(app, cookie, { planId: "pro_yearly", country: "DE", seats });

    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "BAD_REQUEST" });
    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { id: accountId } });
    expect(account.billingProvider).toBeNull();
  });
});
