import { describe, test, expect } from "bun:test";
import { createHmac } from "node:crypto";
import { PaddleProvider, logPaddlePaymentFailure, paddleCustomerCheckoutAuth } from "../../src/billing/paddle.js";
import { paddleSignature } from "../helpers/paddle-sig.js";

const SECRET = "pdl_ntfset_test_secret";

function body(eventType: string, data: Record<string, unknown>, eventId = "evt_abc"): string {
  return JSON.stringify({
    event_id: eventId,
    notification_id: "ntf_abc",
    event_type: eventType,
    occurred_at: "2026-06-08T00:00:00Z",
    data,
  });
}

describe("PaddleProvider.verifyWebhook", () => {
  const provider = new PaddleProvider({ webhookSecret: SECRET });

  test("normalizes subscription.activated", async () => {
    const raw = body("subscription.activated", {
      id: "sub_77",
      status: "active",
      customer_id: "ctm_9",
      custom_data: { accountId: "acc-1", planId: "pro_yearly" },
      current_billing_period: { starts_at: "2026-06-08T00:00:00Z", ends_at: "2027-06-08T00:00:00Z" },
    });
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev).toMatchObject({
      provider: "paddle",
      type: "activated",
      accountId: "acc-1",
      planId: "pro_yearly",
      customerId: "ctm_9",
      providerSubscriptionId: "sub_77",
      providerEventId: "evt_abc",
    });
    expect(ev?.currentPeriodEnd?.toISOString()).toBe("2027-06-08T00:00:00.000Z");
  });

  test("normalizes subscription.canceled", async () => {
    const raw = body(
      "subscription.canceled",
      {
        id: "sub_77",
        status: "canceled",
        customer_id: "ctm_9",
        custom_data: { accountId: "acc-1", planId: "pro_yearly" },
      },
      "evt_cancel"
    );
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev).toMatchObject({ type: "canceled", providerSubscriptionId: "sub_77" });
  });

  test("subscription.canceled without custom_data still normalizes", async () => {
    const raw = body(
      "subscription.canceled",
      {
        id: "sub_no_cd",
        status: "canceled",
        customer_id: "ctm_9",
      },
      "evt_cancel_no_cd"
    );
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev).toMatchObject({
      type: "canceled",
      providerSubscriptionId: "sub_no_cd",
      customerId: "ctm_9",
    });
  });

  test("transaction.completed for a retired plan normalizes to nothing", async () => {
    // There is no one-time-payment branch left: a transaction with no
    // subscription_id has no surviving plan it could activate.
    const raw = body(
      "transaction.completed",
      {
        id: "txn_5",
        customer_id: "ctm_9",
        custom_data: { accountId: "acc-1", planId: "pro_lifetime" },
      },
      "evt_ltd"
    );
    expect(await provider.verifyWebhook(raw, paddleSignature(raw, SECRET))).toBeNull();
  });

  test("transaction.completed for trial start ($0) activates with subscription", async () => {
    const raw = body(
      "transaction.completed",
      {
        id: "txn_trial",
        customer_id: "ctm_9",
        subscription_id: "sub_trial",
        custom_data: { accountId: "acc-1", planId: "trial" },
        billing_period: {
          starts_at: "2026-06-12T12:55:31.782Z",
          ends_at: "2026-06-19T12:55:31.782Z",
        },
        details: { totals: { grand_total: "0" } },
      },
      "evt_trial_txn"
    );
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev).toMatchObject({
      type: "activated",
      planId: "trial",
      providerSubscriptionId: "sub_trial",
      providerTransactionId: "txn_trial",
    });
    expect(ev?.currentPeriodEnd?.toISOString()).toBe("2026-06-19T12:55:31.782Z");
  });

  test("transaction.completed for trial renewal converts via renewed", async () => {
    const raw = body(
      "transaction.completed",
      {
        id: "txn_trial_paid",
        customer_id: "ctm_9",
        subscription_id: "sub_trial",
        custom_data: { accountId: "acc-1", planId: "trial" },
        billing_period: {
          starts_at: "2026-06-19T12:55:31.782Z",
          ends_at: "2027-06-19T12:55:31.782Z",
        },
        details: { totals: { grand_total: "9900" } },
      },
      "evt_trial_paid"
    );
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev).toMatchObject({
      type: "renewed",
      planId: "trial",
      providerSubscriptionId: "sub_trial",
    });
    expect(ev?.currentPeriodEnd?.toISOString()).toBe("2027-06-19T12:55:31.782Z");
  });

  test("transaction.completed for yearly plan activates when paid", async () => {
    const raw = body(
      "transaction.completed",
      {
        id: "txn_6",
        customer_id: "ctm_9",
        subscription_id: "sub_yearly",
        custom_data: { accountId: "acc-1", planId: "pro_yearly" },
        billing_period: {
          starts_at: "2026-06-08T00:00:00Z",
          ends_at: "2027-06-08T00:00:00Z",
        },
        details: { totals: { grand_total: "9900" } },
      },
      "evt_yearly_txn"
    );
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev).toMatchObject({
      type: "activated",
      planId: "pro_yearly",
      providerSubscriptionId: "sub_yearly",
    });
  });

  test("reads the seat count from items[].quantity on a subscription payload", async () => {
    const raw = body("subscription.updated", {
      id: "sub_77",
      status: "active",
      customer_id: "ctm_9",
      custom_data: { accountId: "acc-1", planId: "pro_yearly" },
      items: [{ status: "active", quantity: 5, price: { id: "pri_x", product_id: "pro_x" } }],
    });
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev).toMatchObject({ type: "activated", providerSubscriptionId: "sub_77", quantity: 5 });
  });

  test("reads the seat count from a transaction payload too", async () => {
    const raw = body(
      "transaction.completed",
      {
        id: "txn_seats",
        customer_id: "ctm_9",
        subscription_id: "sub_yearly",
        custom_data: { accountId: "acc-1", planId: "pro_yearly" },
        items: [{ quantity: 3, price: { id: "pri_x", product_id: "pro_x" } }],
        details: { totals: { grand_total: "29700" } },
      },
      "evt_txn_seats"
    );
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev).toMatchObject({ type: "activated", quantity: 3 });
  });

  test("a cloned non-catalog price still yields its quantity", async () => {
    // pro_yearly checks out on a cloned inline price, so the item carries no
    // catalog price id at all — matching on one would read nothing for exactly
    // the plan that is sold.
    const raw = body("subscription.updated", {
      id: "sub_clone",
      status: "active",
      customer_id: "ctm_9",
      custom_data: { accountId: "acc-1", planId: "pro_yearly" },
      items: [
        {
          status: "active",
          quantity: 8,
          price: { product_id: "pro_x", description: "Pro Yearly", unit_price: { amount: "9900" } },
        },
      ],
    });
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev?.quantity).toBe(8);
  });

  test("an inactive item is skipped", async () => {
    const raw = body("subscription.updated", {
      id: "sub_77",
      status: "active",
      customer_id: "ctm_9",
      custom_data: { accountId: "acc-1", planId: "pro_yearly" },
      items: [
        { status: "inactive", quantity: 9, price: { product_id: "pro_old" } },
        { status: "active", quantity: 2, price: { product_id: "pro_x" } },
      ],
    });
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev?.quantity).toBe(2);
  });

  test("price.quantity is an allowed range, never the seat count", async () => {
    const raw = body("subscription.updated", {
      id: "sub_77",
      status: "active",
      customer_id: "ctm_9",
      custom_data: { accountId: "acc-1", planId: "pro_yearly" },
      items: [{ status: "active", price: { product_id: "pro_x", quantity: { minimum: 1, maximum: 100 } } }],
    });
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev).not.toBeNull();
    expect(ev?.quantity).toBeUndefined();
  });

  test("a payload with no items yields no quantity rather than one seat", async () => {
    const raw = body("subscription.updated", {
      id: "sub_77",
      status: "active",
      customer_id: "ctm_9",
      custom_data: { accountId: "acc-1", planId: "pro_yearly" },
    });
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev).not.toBeNull();
    expect(ev?.quantity).toBeUndefined();
  });

  test("several live items are ambiguous, so no seat count is reported", async () => {
    const raw = body("subscription.updated", {
      id: "sub_77",
      status: "active",
      customer_id: "ctm_9",
      custom_data: { accountId: "acc-1", planId: "pro_yearly" },
      items: [
        { status: "active", quantity: 4, price: { product_id: "pro_x" } },
        { status: "trialing", quantity: 1, price: { product_id: "pro_y" } },
      ],
    });
    const ev = await provider.verifyWebhook(raw, paddleSignature(raw, SECRET));
    expect(ev?.quantity).toBeUndefined();
  });

  test("ignores unrelated events", async () => {
    const raw = body("address.created", { id: "add_1" });
    expect(await provider.verifyWebhook(raw, paddleSignature(raw, SECRET))).toBeNull();
  });

  test("rejects tampered body", async () => {
    const raw = body("subscription.activated", {
      id: "sub_77",
      status: "active",
      customer_id: "ctm_9",
      custom_data: { accountId: "acc-1", planId: "pro_yearly" },
    });
    const sig = paddleSignature(raw, SECRET);
    await expect(provider.verifyWebhook(raw + " ", sig)).rejects.toThrow();
  });

  test("accepts a signature 3 minutes old (within 5-minute window)", async () => {
    const raw = body("subscription.activated", {
      id: "sub_recent",
      status: "active",
      customer_id: "ctm_9",
      custom_data: { accountId: "acc-1", planId: "pro_yearly" },
    });
    const ts = Math.floor(Date.now() / 1000) - 3 * 60;
    const h1 = createHmac("sha256", SECRET).update(`${ts}:${raw}`).digest("hex");
    const ev = await provider.verifyWebhook(raw, `ts=${ts};h1=${h1}`);
    expect(ev).not.toBeNull();
  });

  test("rejects a signature older than 5 minutes", async () => {
    const raw = body("subscription.activated", {
      id: "sub_stale",
      status: "active",
      customer_id: "ctm_9",
      custom_data: { accountId: "acc-1", planId: "pro_yearly" },
    });
    const staleTs = Math.floor(Date.now() / 1000) - 6 * 60;
    const h1 = createHmac("sha256", SECRET).update(`${staleTs}:${raw}`).digest("hex");
    await expect(provider.verifyWebhook(raw, `ts=${staleTs};h1=${h1}`)).rejects.toThrow(
      "invalid paddle signature"
    );
  });

  test("rejects a signature more than 5 minutes in the future", async () => {
    const raw = body("subscription.activated", {
      id: "sub_future",
      status: "active",
      customer_id: "ctm_9",
      custom_data: { accountId: "acc-1", planId: "pro_yearly" },
    });
    const futureTs = Math.floor(Date.now() / 1000) + 6 * 60;
    const h1 = createHmac("sha256", SECRET).update(`${futureTs}:${raw}`).digest("hex");
    await expect(provider.verifyWebhook(raw, `ts=${futureTs};h1=${h1}`)).rejects.toThrow(
      "invalid paddle signature"
    );
  });
});

describe("logPaddlePaymentFailure", () => {
  test("returns true and logs transaction.payment_failed", () => {
    const warn = console.warn;
    const logs: unknown[][] = [];
    console.warn = (...args: unknown[]) => {
      logs.push(args);
    };
    try {
      const raw = body("transaction.payment_failed", {
        id: "txn_fail",
        customer_id: "ctm_fail",
        subscription_id: "sub_fail",
        custom_data: { accountId: "acc-1", planId: "trial" },
        payments: [{ status: "error", error_code: "declined" }],
      });
      expect(logPaddlePaymentFailure(raw)).toBe(true);
      expect(logs[0]?.[0]).toBe("[billing] paddle payment failed");
      expect(logs[0]?.[1]).toMatchObject({
        transactionId: "txn_fail",
        planId: "trial",
        errorCode: "declined",
      });
    } finally {
      console.warn = warn;
    }
  });

  test("returns false for unrelated events", () => {
    expect(logPaddlePaymentFailure(body("subscription.activated", { id: "sub_1" }))).toBe(false);
  });
});

describe("paddleCustomerCheckoutAuth", () => {
  test("returns customerAuthToken from Paddle API", async () => {
    const paddle = {
      customers: {
        generateAuthToken: async () => ({ customerAuthToken: "pca_test_token" }),
      },
    };
    await expect(
      paddleCustomerCheckoutAuth(paddle as never, "ctm_returning")
    ).resolves.toEqual({ customerAuthToken: "pca_test_token" });
  });

  test("returns null when auth token generation fails", async () => {
    const paddle = {
      customers: {
        generateAuthToken: async () => {
          throw new Error("customer not found");
        },
      },
    };
    await expect(paddleCustomerCheckoutAuth(paddle as never, "ctm_missing")).resolves.toBeNull();
  });
});
