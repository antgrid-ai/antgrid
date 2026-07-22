import { describe, test, expect } from "bun:test";
import { resolveBillingConfig } from "../../src/config/billing.js";

describe("resolveBillingConfig", () => {
  test("production returns empty plan/price IDs and public keys", () => {
    const cfg = resolveBillingConfig("production");
    expect(cfg.paddle.environment).toBe("production");
    expect(cfg.paddle.clientToken).toBe("");
    expect(cfg.paddle.priceYearly).toBe("");
    expect(cfg.paddle.priceLifetime).toBe("");
    expect(cfg.paddle.discountIdYearlyOffer).toBe("");
    expect(cfg.razorpay.planYearly).toBe("");
    expect(cfg.razorpay.amountLifetime).toBe(9900);
  });

  test("development returns sandbox public keys and plan/price IDs", () => {
    const cfg = resolveBillingConfig("development");
    expect(cfg.paddle.environment).toBe("sandbox");
    expect(cfg.paddle.clientToken).toBe("test_702c1651209f08cfcd237479b95");
    expect(cfg.paddle.priceYearly).toBe("pri_01ktx71cqeg9z71w0ef6ve6ccw");
    expect(cfg.paddle.priceLifetime).toBe("pri_01ktzks8nyj0mw4s8as07jesx4");
    expect(cfg.paddle.discountIdYearlyOffer).toBe("dsc_01ktx8ean5ttvanhnfvjj7brz0");
    expect(cfg.razorpay.planYearly).toBe("plan_T116LK54v4SZfL");
  });

  test("staging uses sandbox config for the live dev site", () => {
    const cfg = resolveBillingConfig("staging");
    expect(cfg.paddle.environment).toBe("sandbox");
    expect(cfg.razorpay.planYearly).toBe("plan_T116LK54v4SZfL");
  });
});
