import { describe, test, expect } from "bun:test";
import { createHmac } from "node:crypto";
import {
  RazorpayProvider,
  logRazorpayPaymentFailure,
  razorpayPeriodEnd,
  verifyRazorpayHmac,
} from "../../src/billing/razorpay.js";

const SECRET = "rzp_test_webhook_secret";

function razorpaySignature(rawBody: string, secret: string): string {
  return createHmac("sha256", secret).update(rawBody).digest("hex");
}

describe("verifyRazorpayHmac", () => {
  test("accepts webhook body signature", () => {
    const raw = '{"event":"test"}';
    const sig = createHmac("sha256", SECRET).update(raw).digest("hex");
    expect(verifyRazorpayHmac(raw, SECRET, sig)).toBe(true);
  });

  test("accepts order|payment payment-callback signature", () => {
    const payload = "order_1|pay_1";
    const sig = createHmac("sha256", SECRET).update(payload).digest("hex");
    expect(verifyRazorpayHmac(payload, SECRET, sig)).toBe(true);
  });
});

describe("RazorpayProvider.verifyWebhook", () => {
  const provider = new RazorpayProvider({ webhookSecret: SECRET });

  test("normalizes subscription.activated", async () => {
    const raw = JSON.stringify({
      event: "subscription.activated",
      payload: {
        payment: {
          entity: {
            id: "pay_yearly_1",
          },
        },
        subscription: {
          entity: {
            id: "sub_123",
            customer_id: "cust_123",
            status: "active",
            notes: { accountId: "acc-1", planId: "pro_yearly" },
            current_end: 1893456000,
          },
        },
      },
    });
    const ev = await provider.verifyWebhook(raw, razorpaySignature(raw, SECRET));
    expect(ev).toMatchObject({
      provider: "razorpay",
      type: "activated",
      accountId: "acc-1",
      planId: "pro_yearly",
      customerId: "cust_123",
      providerSubscriptionId: "sub_123",
      providerTransactionId: "pay_yearly_1",
    });
  });

  test("normalizes payment.captured for lifetime", async () => {
    const raw = JSON.stringify({
      event: "payment.captured",
      payload: {
        payment: {
          entity: {
            id: "pay_99",
            order_id: "order_99",
            customer_id: "cust_99",
            notes: { accountId: "acc-1", planId: "pro_lifetime" },
          },
        },
      },
    });
    const ev = await provider.verifyWebhook(raw, razorpaySignature(raw, SECRET));
    expect(ev).toMatchObject({
      type: "activated",
      planId: "pro_lifetime",
      customerId: "cust_99",
      providerTransactionId: "pay_99",
    });
  });

  test("rejects bad signature", async () => {
    const raw = JSON.stringify({ event: "subscription.activated", payload: {} });
    await expect(provider.verifyWebhook(raw, "bad")).rejects.toThrow();
  });

  test("normalizes subscription.activated for trial", async () => {
    const raw = JSON.stringify({
      event: "subscription.activated",
      payload: {
        subscription: {
          entity: {
            id: "sub_trial",
            customer_id: "cust_trial",
            status: "authenticated",
            notes: { accountId: "acc-1", planId: "trial" },
            current_end: 1893456000,
          },
        },
      },
    });
    const ev = await provider.verifyWebhook(raw, razorpaySignature(raw, SECRET));
    expect(ev).toMatchObject({
      type: "activated",
      planId: "trial",
      providerSubscriptionId: "sub_trial",
    });
  });

  test("normalizes subscription.authenticated for trial only", async () => {
    const raw = JSON.stringify({
      event: "subscription.authenticated",
      payload: {
        payment: {
          entity: {
            id: "pay_trial_auth",
          },
        },
        subscription: {
          entity: {
            id: "sub_trial",
            customer_id: "cust_trial",
            status: "authenticated",
            notes: { accountId: "acc-1", planId: "trial" },
          },
        },
      },
    });
    const ev = await provider.verifyWebhook(raw, razorpaySignature(raw, SECRET));
    expect(ev).toMatchObject({
      type: "activated",
      planId: "trial",
      providerSubscriptionId: "sub_trial",
      providerTransactionId: "pay_trial_auth",
    });
  });

  test("ignores subscription.authenticated for immediate-billing plans", async () => {
    const raw = JSON.stringify({
      event: "subscription.authenticated",
      payload: {
        subscription: {
          entity: {
            id: "sub_yearly",
            customer_id: "cust_yearly",
            status: "authenticated",
            notes: { accountId: "acc-1", planId: "pro_yearly" },
          },
        },
      },
    });
    const ev = await provider.verifyWebhook(raw, razorpaySignature(raw, SECRET));
    expect(ev).toBeNull();
  });

  test("normalizes subscription.charged as renewed (trial first charge)", async () => {
    const raw = JSON.stringify({
      event: "subscription.charged",
      payload: {
        payment: {
          entity: {
            id: "pay_trial_charge",
          },
        },
        subscription: {
          entity: {
            id: "sub_trial",
            customer_id: "cust_trial",
            status: "active",
            notes: { accountId: "acc-1", planId: "trial" },
            current_end: 1924992000,
          },
        },
      },
    });
    const ev = await provider.verifyWebhook(raw, razorpaySignature(raw, SECRET));
    expect(ev).toMatchObject({
      type: "renewed",
      planId: "trial",
      providerSubscriptionId: "sub_trial",
      providerTransactionId: "pay_trial_charge",
    });
  });
});

describe("logRazorpayPaymentFailure", () => {
  test("returns true and logs payment.failed", () => {
    const warn = console.warn;
    const logs: unknown[][] = [];
    console.warn = (...args: unknown[]) => {
      logs.push(args);
    };
    try {
      const raw = JSON.stringify({
        event: "payment.failed",
        payload: {
          payment: {
            entity: {
              id: "pay_fail",
              order_id: "order_fail",
              subscription_id: "sub_fail",
              customer_id: "cust_fail",
              notes: { accountId: "acc-1", planId: "pro_lifetime" },
              error_code: "BAD_REQUEST_ERROR",
              error_description: "Payment declined",
            },
          },
        },
      });
      expect(logRazorpayPaymentFailure(raw)).toBe(true);
      expect(logs[0]?.[0]).toBe("[billing] razorpay payment failed");
      expect(logs[0]?.[1]).toMatchObject({
        paymentId: "pay_fail",
        planId: "pro_lifetime",
        errorCode: "BAD_REQUEST_ERROR",
      });
    } finally {
      console.warn = warn;
    }
  });

  test("returns false for unrelated events", () => {
    expect(logRazorpayPaymentFailure(JSON.stringify({ event: "subscription.activated" }))).toBe(
      false
    );
  });
});

describe("razorpayPeriodEnd", () => {
  test("maps current_end unix seconds to Date", () => {
    const end = razorpayPeriodEnd({ current_end: 1893456000 });
    expect(end?.toISOString()).toBe("2030-01-01T00:00:00.000Z");
  });

  test("returns null when current_end missing", () => {
    expect(razorpayPeriodEnd({})).toBeNull();
  });
});
