import type { CheckoutEnv } from "../../src/billing/checkout.js";
import type { Env } from "../../src/env.js";

type TestBillingEnv = Partial<CheckoutEnv> & {
  PADDLE_API_KEY?: string;
  PADDLE_WEBHOOK_SECRET?: string;
  RAZORPAY_WEBHOOK_SECRET?: string;
};

/**
 * Gateway SKU fixture — mirrors production env shape. Production reads the same values
 * from environment variables, not the plans table.
 */
export const TEST_BILLING_SKUS = {
  paddle: {
    priceYearly: "pri_test_yearly",
    priceLifetime: "pri_test_lifetime",
    discountYearlyOffer: "dsc_test_yearly",
    /** Sandbox notification destination "subscription" — subscription.canceled, transaction.completed */
    webhookDestinationId: "ntfset_01ktxnqqkwa0zmwjrkdcne65vq",
  },
  razorpay: {
    planTrial: "plan_test_trial",
    planYearly: "plan_test_yearly",
    amountLifetime: 9900,
  },
} as const;

/** Full billing env for tests — pass to buildTestApp({ envOverrides: testBillingEnv() }). */
export function testBillingEnv(overrides: TestBillingEnv = {}): Partial<Env> {
  return {
    YEARLY_OFFER_ACTIVE: true,
    PADDLE_API_KEY: "test_paddle_api",
    PADDLE_CLIENT_TOKEN: "test_paddle_client",
    PADDLE_ENVIRONMENT: "sandbox",
    PADDLE_WEBHOOK_SECRET: "test_paddle_webhook",
    PADDLE_PRICE_YEARLY: TEST_BILLING_SKUS.paddle.priceYearly,
    PADDLE_PRICE_LIFETIME: TEST_BILLING_SKUS.paddle.priceLifetime,
    PADDLE_DISCOUNT_ID_YEARLY_OFFER: TEST_BILLING_SKUS.paddle.discountYearlyOffer,
    RAZORPAY_KEY_ID: "rzp_test_key",
    RAZORPAY_KEY_SECRET: "rzp_test_secret",
    RAZORPAY_WEBHOOK_SECRET: "rzp_test_webhook",
    RAZORPAY_PLAN_YEARLY: TEST_BILLING_SKUS.razorpay.planYearly,
    RAZORPAY_AMOUNT_LIFETIME: TEST_BILLING_SKUS.razorpay.amountLifetime,
    ...overrides,
  } as Partial<Env>;
}
