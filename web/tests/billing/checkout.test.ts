import { describe, test, expect } from "bun:test";
import {
  anyCheckoutReady,
  checkoutReadiness,
  findRazorpayCustomerIdByEmail,
  isPaddleCheckoutReady,
  isRazorpayCheckoutReady,
  isRazorpayCustomerExistsError,
  paddleSkipTrialForPlan,
} from "../../src/billing/checkout.js";
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
    expect(isPaddleCheckoutReady(base, "pro_lifetime")).toBe(true);
  });

  test("razorpay lifetime only needs keys; yearly and trial need env plan id", () => {
    const keys = {
      RAZORPAY_KEY_ID: "key",
      RAZORPAY_KEY_SECRET: "secret",
    };
    expect(isRazorpayCheckoutReady(keys, "pro_lifetime")).toBe(true);
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
    const planIds = ["trial", "pro_yearly", "pro_lifetime"] as const;
    const readiness = checkoutReadiness(testBillingEnv(), [...planIds]);
    expect(readiness.paddle.trial).toBe(true);
    expect(readiness.paddle.pro_yearly).toBe(true);
    expect(readiness.paddle.pro_lifetime).toBe(true);
    expect(readiness.razorpay.trial).toBe(true);
    expect(readiness.razorpay.pro_yearly).toBe(true);
    expect(readiness.razorpay.pro_lifetime).toBe(true);
    expect(anyCheckoutReady(readiness)).toBe(true);
    expect(anyCheckoutReady(checkoutReadiness({}, [...planIds]))).toBe(false);
  });

  test("pro_yearly uses no-trial Paddle item; trial keeps catalog price", () => {
    expect(paddleSkipTrialForPlan("pro_yearly")).toBe(true);
    expect(paddleSkipTrialForPlan("trial")).toBe(false);
    expect(paddleSkipTrialForPlan("pro_lifetime")).toBe(false);
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
