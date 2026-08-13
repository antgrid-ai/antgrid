import { describe, test, expect } from "bun:test";
import {
  anyCheckoutReady,
  buildPaddleTransactionItems,
  buildRazorpaySubscriptionRequest,
  checkoutReadiness,
  findRazorpayCustomerIdByEmail,
  isPaddleCheckoutReady,
  isRazorpayCheckoutReady,
  isRazorpayCustomerExistsError,
  paddleSkipTrialForPlan,
} from "../../src/billing/checkout.js";
import { TRIAL_DAYS } from "../../src/billing/plans.js";
import { testBillingEnv, TEST_BILLING_SKUS } from "../helpers/billing-env.js";

describe("checkout readiness", () => {
  test("paddle requires api key, client token, and env price ids", () => {
    const base = testBillingEnv();
    expect(isPaddleCheckoutReady(base, "trial")).toBe(true);
    expect(isPaddleCheckoutReady(base, "pro_yearly")).toBe(true);
    expect(isPaddleCheckoutReady({ ...base, PADDLE_PRICE_YEARLY: undefined }, "pro_yearly")).toBe(
      false
    );
    expect(isPaddleCheckoutReady({ ...base, PADDLE_CLIENT_TOKEN: undefined }, "pro_yearly")).toBe(
      false
    );
  });

  test("razorpay needs keys AND an env plan id for every plan", () => {
    const keys = {
      RAZORPAY_KEY_ID: "key",
      RAZORPAY_KEY_SECRET: "secret",
    };
    expect(isRazorpayCheckoutReady(keys, "pro_yearly")).toBe(false);
    expect(isRazorpayCheckoutReady(keys, "trial")).toBe(false);
    expect(
      isRazorpayCheckoutReady(
        { ...keys, RAZORPAY_PLAN_YEARLY: TEST_BILLING_SKUS.razorpay.planYearly },
        "pro_yearly"
      )
    ).toBe(true);
    expect(
      isRazorpayCheckoutReady(
        { ...keys, RAZORPAY_PLAN_YEARLY: TEST_BILLING_SKUS.razorpay.planYearly },
        "trial"
      )
    ).toBe(true);
  });

  test("checkoutReadiness uses env skus only", () => {
    const planIds = ["trial", "pro_yearly"] as const;
    const readiness = checkoutReadiness(testBillingEnv(), [...planIds]);
    expect(readiness.paddle.trial).toBe(true);
    expect(readiness.paddle.pro_yearly).toBe(true);
    expect(readiness.razorpay.trial).toBe(true);
    expect(readiness.razorpay.pro_yearly).toBe(true);
    expect(anyCheckoutReady(readiness)).toBe(true);
    expect(anyCheckoutReady(checkoutReadiness({}, [...planIds]))).toBe(false);
  });

  test("pro_yearly uses no-trial Paddle item; trial keeps catalog price", () => {
    expect(paddleSkipTrialForPlan("pro_yearly")).toBe(true);
    expect(paddleSkipTrialForPlan("trial")).toBe(false);
  });
});

describe("isRazorpayCustomerExistsError", () => {
  test("matches the duplicate-customer rejection", () => {
    expect(
      isRazorpayCustomerExistsError({
        error: { code: "BAD_REQUEST_ERROR", description: "Customer already exists for the merchant" },
      })
    ).toBe(true);
  });

  test("matches a flattened description and is case-insensitive", () => {
    expect(isRazorpayCustomerExistsError({ description: "CUSTOMER ALREADY EXISTS" })).toBe(true);
  });

  test("matches reworded variants via stable tokens", () => {
    expect(
      isRazorpayCustomerExistsError({
        error: { code: "BAD_REQUEST_ERROR", description: "Customer with this email already exists" },
      })
    ).toBe(true);
  });

  test("ignores unrelated errors and non-objects", () => {
    expect(
      isRazorpayCustomerExistsError({
        error: { code: "BAD_REQUEST_ERROR", description: "The email field is invalid" },
      })
    ).toBe(false);
    expect(isRazorpayCustomerExistsError(new Error("network down"))).toBe(false);
    expect(isRazorpayCustomerExistsError(null)).toBe(false);
    expect(isRazorpayCustomerExistsError("boom")).toBe(false);
  });
});

describe("findRazorpayCustomerIdByEmail", () => {
  const customersStub = (
    pages: Array<Array<{ id: string; email: string }>>
  ): { calls: Array<{ count: number; skip: number }>; customers: { all: (p: { count: number; skip: number }) => Promise<{ items: Array<{ id: string; email: string }> }> } } => {
    const calls: Array<{ count: number; skip: number }> = [];
    return {
      calls,
      customers: {
        all: async ({ count, skip }: { count: number; skip: number }) => {
          calls.push({ count, skip });
          return { items: pages[skip / count] ?? [] };
        },
      },
    };
  };

  test("returns the id of the email match (case/space-insensitive)", async () => {
    const stub = customersStub([[{ id: "cust_1", email: "a@x.io" }, { id: "cust_2", email: "Match@X.io" }]]);
    const id = await findRazorpayCustomerIdByEmail(stub as never, "  match@x.io ");
    expect(id).toBe("cust_2");
  });

  test("returns null and stops on a short page when no match", async () => {
    const stub = customersStub([[{ id: "cust_1", email: "a@x.io" }]]);
    const id = await findRazorpayCustomerIdByEmail(stub as never, "missing@x.io");
    expect(id).toBeNull();
    expect(stub.calls).toHaveLength(1); // short first page → no second request
  });

  test("pages forward across a full page until the match", async () => {
    const full = Array.from({ length: 100 }, (_, i) => ({ id: `c${i}`, email: `u${i}@x.io` }));
    const stub = customersStub([full, [{ id: "cust_target", email: "target@x.io" }]]);
    const id = await findRazorpayCustomerIdByEmail(stub as never, "target@x.io");
    expect(id).toBe("cust_target");
    expect(stub.calls).toEqual([
      { count: 100, skip: 0 },
      { count: 100, skip: 100 },
    ]);
  });
});

describe("seat quantity reaches the gateway request", () => {
  // The catalog snapshot is cached per price id for the process lifetime, so
  // every case names its own price id rather than sharing one.
  const paddleStub = (priceId: string) => {
    const calls: string[] = [];
    return {
      calls,
      paddle: {
        prices: {
          get: async (id: string) => {
            calls.push(id);
            return {
              productId: "pro_test",
              description: "Pro Yearly",
              unitPrice: { amount: "9900", currencyCode: "USD" },
              billingCycle: { interval: "year", frequency: 1 },
              taxMode: "account_setting",
            };
          },
        },
      },
    };
  };

  test("paddle trial keeps the catalog price and carries the seat count", async () => {
    const stub = paddleStub("pri_trial_seats");
    const items = await buildPaddleTransactionItems(
      stub.paddle as never,
      "trial",
      "pri_trial_seats",
      5
    );

    expect(items).toEqual([{ priceId: "pri_trial_seats", quantity: 5 }]);
    expect(stub.calls).toHaveLength(0); // trial never clones the price
  });

  test("paddle pro_yearly puts the seat count on the cloned no-trial price", async () => {
    const stub = paddleStub("pri_yearly_seats");
    const items = await buildPaddleTransactionItems(
      stub.paddle as never,
      "pro_yearly",
      "pri_yearly_seats",
      5
    );

    expect(items).toHaveLength(1);
    expect(items[0]!.quantity).toBe(5);
    expect(items[0]).toMatchObject({
      price: {
        productId: "pro_test",
        unitPrice: { amount: "9900", currencyCode: "USD" },
        trialPeriod: null,
      },
    });
    expect(stub.calls).toEqual(["pri_yearly_seats"]);
  });

  test("a one-seat checkout is unchanged on both paddle branches", async () => {
    const trial = await buildPaddleTransactionItems(
      paddleStub("pri_trial_one").paddle as never,
      "trial",
      "pri_trial_one",
      1
    );
    const yearly = await buildPaddleTransactionItems(
      paddleStub("pri_yearly_one").paddle as never,
      "pro_yearly",
      "pri_yearly_one",
      1
    );
    expect(trial[0]!.quantity).toBe(1);
    expect(yearly[0]!.quantity).toBe(1);
  });

  test("razorpay sends quantity and leaves total_count alone", () => {
    const req = buildRazorpaySubscriptionRequest({
      planId: "pro_yearly",
      razorpayPlanId: "plan_test_yearly",
      totalCount: 1,
      seats: 5,
      customerId: "cust_1",
      notes: { accountId: "acct_1", planId: "pro_yearly" },
    });

    expect(req).toEqual({
      plan_id: "plan_test_yearly",
      total_count: 1,
      quantity: 5,
      customer_notify: 1,
      customer_id: "cust_1",
      notes: { accountId: "acct_1", planId: "pro_yearly" },
    });
  });

  test("razorpay trial keeps its deferred start_at alongside the seat count", () => {
    const nowMs = Date.UTC(2030, 0, 1);
    const req = buildRazorpaySubscriptionRequest({
      planId: "trial",
      razorpayPlanId: "plan_test_trial",
      totalCount: 12,
      seats: 3,
      customerId: "cust_2",
      notes: { accountId: "acct_2", planId: "trial" },
      nowMs,
    });

    expect(req.quantity).toBe(3);
    expect(req.total_count).toBe(12);
    expect(req.start_at).toBe(Math.floor(nowMs / 1000) + TRIAL_DAYS * 24 * 60 * 60);
  });
});
