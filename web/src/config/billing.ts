export type BillingConfig = {
  yearlyOfferActive: boolean;
  paddle: {
    environment: "sandbox" | "production";
    clientToken: string;
    priceYearly: string;
    priceLifetime: string;
    discountIdYearlyOffer: string;
    webhookDestinationId: string;
  };
  razorpay: {
    planYearly: string;
    amountLifetime: number;
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
    priceLifetime: "pri_01ktzks8nyj0mw4s8as07jesx4",
    discountIdYearlyOffer: "dsc_01ktx8ean5ttvanhnfvjj7brz0",
    webhookDestinationId: "ntfset_01ktxnqqkwa0zmwjrkdcne65vq",
  },
  razorpay: {
    planYearly: "plan_T116LK54v4SZfL",
    amountLifetime: 9900,
  },
};

/** Live dev site (app.staging.antgrid.ai) — sandbox IDs; fill secrets on the VM .env. */
const STAGING: BillingConfig = {
  yearlyOfferActive: true,
  paddle: {
    environment: "sandbox",
    clientToken: "test_702c1651209f08cfcd237479b95",
    priceYearly: "pri_01ktx71cqeg9z71w0ef6ve6ccw",
    priceLifetime: "pri_01ktzks8nyj0mw4s8as07jesx4",
    discountIdYearlyOffer: "dsc_01ktx8ean5ttvanhnfvjj7brz0",
    webhookDestinationId: "ntfset_01ktxnqqkwa0zmwjrkdcne65vq",
  },
  razorpay: {
    planYearly: "plan_T116LK54v4SZfL",
    amountLifetime: 9900,
  },
};

const PRODUCTION: BillingConfig = {
  yearlyOfferActive: true,
  paddle: {
    environment: "production",
    clientToken: "",
    priceYearly: "",
    priceLifetime: "",
    discountIdYearlyOffer: "",
    webhookDestinationId: "",
  },
  razorpay: {
    planYearly: "",
    amountLifetime: 9900,
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
    PADDLE_PRICE_LIFETIME: opt(billing.paddle.priceLifetime),
    PADDLE_DISCOUNT_ID_YEARLY_OFFER: opt(billing.paddle.discountIdYearlyOffer),
    RAZORPAY_PLAN_YEARLY: opt(billing.razorpay.planYearly),
    RAZORPAY_AMOUNT_LIFETIME: billing.razorpay.amountLifetime,
  };
}
