export type BillingConfig = {
  yearlyOfferActive: boolean;
  paddle: {
    environment: "sandbox" | "production";
    clientToken: string;
    priceYearly: string;
    discountIdYearlyOffer: string;
    webhookDestinationId: string;
  };
  razorpay: {
    planYearly: string;
  };
};

export type BillingNodeEnv = "development" | "staging" | "production";

/** Local machine — sandbox dashboard IDs + public keys. Secrets stay in web/.env. */
const DEVELOPMENT: BillingConfig = {
  yearlyOfferActive: true,
  paddle: {
    environment: "sandbox",
    clientToken: "test_702c1651209f08cfcd237479b95",
    priceYearly: "pri_01ktx71cqeg9z71w0ef6ve6ccw",
    discountIdYearlyOffer: "dsc_01ktx8ean5ttvanhnfvjj7brz0",
    webhookDestinationId: "ntfset_01ktxnqqkwa0zmwjrkdcne65vq",
  },
  razorpay: {
    planYearly: "plan_T116LK54v4SZfL",
  },
};

/** Live dev site (app.staging.antgrid.ai) — sandbox IDs; fill secrets on the VM .env. */
const STAGING: BillingConfig = {
  yearlyOfferActive: true,
  paddle: {
    environment: "sandbox",
    clientToken: "test_702c1651209f08cfcd237479b95",
    priceYearly: "pri_01ktx71cqeg9z71w0ef6ve6ccw",
    discountIdYearlyOffer: "dsc_01ktx8ean5ttvanhnfvjj7brz0",
    webhookDestinationId: "ntfset_01ktxnqqkwa0zmwjrkdcne65vq",
  },
  razorpay: {
    planYearly: "plan_T116LK54v4SZfL",
  },
};

const PRODUCTION: BillingConfig = {
  yearlyOfferActive: true,
  paddle: {
    environment: "production",
    clientToken: "",
    priceYearly: "",
    discountIdYearlyOffer: "",
    webhookDestinationId: "",
  },
  razorpay: {
    planYearly: "",
  },
};

export function resolveBillingConfig(nodeEnv: BillingNodeEnv): BillingConfig {
  switch (nodeEnv) {
    case "development":
      return DEVELOPMENT;
    case "staging":
      return STAGING;
    case "production":
      return PRODUCTION;
  }
}

/** Map billing config onto the flat Env fields consumed by billing code. */
export function billingToEnvFields(billing: BillingConfig) {
  const opt = (s: string) => (s.length > 0 ? s : undefined);
  return {
    YEARLY_OFFER_ACTIVE: billing.yearlyOfferActive,
    PADDLE_CLIENT_TOKEN: opt(billing.paddle.clientToken),
    PADDLE_ENVIRONMENT: billing.paddle.environment,
    PADDLE_PRICE_YEARLY: opt(billing.paddle.priceYearly),
    PADDLE_DISCOUNT_ID_YEARLY_OFFER: opt(billing.paddle.discountIdYearlyOffer),
    RAZORPAY_PLAN_YEARLY: opt(billing.razorpay.planYearly),
  };
}
