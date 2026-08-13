import { describe, test, expect } from "bun:test";
import { isPaddleCheckoutReady } from "../../src/billing/checkout.js";
import {
  displayPriceCents,
  isPlanId,
  PRICING,
  resolveCheckoutSku,
  resolvePaddleDiscountId,
  TRIAL_DAYS,
  yearlyOfferActive,
} from "../../src/billing/plans.js";
import { TEST_BILLING_SKUS, testBillingEnv } from "../helpers/billing-env.js";

describe("plan catalog", () => {
  test("TRIAL_DAYS is 7", () => {
    expect(TRIAL_DAYS).toBe(7);
  });

  test("pro_yearly has no trial; trial plan exists", () => {
    expect(PRICING.pro_yearly).toMatchObject({
      listPriceCents: 9900,
      offerPriceCents: 4900,
      offerPercent: 50,
      recurring: true,
      trial: false,
    });
    expect(PRICING.trial).toMatchObject({ trial: true, recurring: true });
  });

  test("isPlanId narrows known ids only", () => {
    expect(isPlanId("trial")).toBe(true);
    expect(isPlanId("pro_yearly")).toBe(true);
    expect(isPlanId("free")).toBe(false);
    expect(isPlanId("pro_lifetime")).toBe(false);
  });

  test("displayPriceCents uses offer when YEARLY_OFFER_ACTIVE", () => {
    const env = { YEARLY_OFFER_ACTIVE: true };
    expect(yearlyOfferActive(env)).toBe(true);
    expect(displayPriceCents("pro_yearly", env)).toBe(4900);
    expect(displayPriceCents("trial", env)).toBe(4900);
  });

  test("paddle trial and pro_yearly share PADDLE_PRICE_YEARLY", () => {
    const env = { PADDLE_PRICE_YEARLY: TEST_BILLING_SKUS.paddle.priceYearly };
    expect(resolveCheckoutSku("trial", "paddle", env)).toBe(TEST_BILLING_SKUS.paddle.priceYearly);
    expect(resolveCheckoutSku("pro_yearly", "paddle", env)).toBe(
      TEST_BILLING_SKUS.paddle.priceYearly
    );
    expect(isPaddleCheckoutReady(testBillingEnv(), "trial")).toBe(true);
  });

  test("resolveCheckoutSku reads razorpay plan ids from env", () => {
    const env = {
      RAZORPAY_PLAN_TRIAL: TEST_BILLING_SKUS.razorpay.planTrial,
      RAZORPAY_PLAN_YEARLY: TEST_BILLING_SKUS.razorpay.planYearly,
    };
    expect(resolveCheckoutSku("trial", "razorpay", env)).toBe(TEST_BILLING_SKUS.razorpay.planTrial);
    expect(resolveCheckoutSku("pro_yearly", "razorpay", env)).toBe(
      TEST_BILLING_SKUS.razorpay.planYearly
    );
  });

  test("razorpay trial sku falls back to yearly plan when trial env unset", () => {
    const env = { RAZORPAY_PLAN_YEARLY: TEST_BILLING_SKUS.razorpay.planYearly };
    expect(resolveCheckoutSku("trial", "razorpay", env)).toBe(TEST_BILLING_SKUS.razorpay.planYearly);
  });

  test("paddle discount id comes from env when yearly offer active", () => {
    const env = {
      YEARLY_OFFER_ACTIVE: true,
      PADDLE_DISCOUNT_ID_YEARLY_OFFER: TEST_BILLING_SKUS.paddle.discountYearlyOffer,
    };
    expect(resolvePaddleDiscountId(env)).toBe(TEST_BILLING_SKUS.paddle.discountYearlyOffer);
  });
});
