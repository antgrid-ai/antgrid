import { describe, test, expect } from "bun:test";
import {
  paddlePeriodEnd,
  paddleResumePendingCancellation,
} from "../../src/billing/paddle.js";
import { paddleUpdateSubscriptionQuantity } from "../../src/billing/paddle.js";
import {
  razorpayCancelSubscription,
  razorpayPeriodEnd,
  razorpayUpdateSubscriptionQuantity,
} from "../../src/billing/razorpay.js";

describe("provider subscription lifecycle helpers", () => {
  test("razorpay cancel uses cancel_at_cycle_end flag", async () => {
    const calls: Array<{ id: string; atEnd: boolean }> = [];
    const razorpay = {
      subscriptions: {
        cancel: async (id: string, atEnd: boolean) => {
          calls.push({ id, atEnd });
          return { current_end: 1893456000, status: "active" };
        },
      },
    };

    await razorpayCancelSubscription(razorpay as never, "sub_rzp", true);
    await razorpayCancelSubscription(razorpay as never, "sub_trial", false);

    expect(calls).toEqual([
      { id: "sub_rzp", atEnd: true },
      { id: "sub_trial", atEnd: false },
    ]);
    expect(razorpayPeriodEnd({ current_end: 1893456000 })?.toISOString()).toBe(
      "2030-01-01T00:00:00.000Z"
    );
  });

  test("paddle resume clears scheduledChange", async () => {
    const calls: Array<{ id: string; body: unknown }> = [];
    const paddle = {
      subscriptions: {
        update: async (id: string, body: unknown) => {
          calls.push({ id, body });
          return {
            scheduledChange: null,
            currentBillingPeriod: { endsAt: "2030-06-08T00:00:00Z" },
          };
        },
      },
    };

    const updated = await paddleResumePendingCancellation(paddle as never, "sub_pdl");
    expect(calls).toEqual([{ id: "sub_pdl", body: { scheduledChange: null } }]);
    expect(paddlePeriodEnd(updated)?.toISOString()).toBe("2030-06-08T00:00:00.000Z");
  });

  test("paddle period end prefers scheduledChange effectiveAt", () => {
    const end = paddlePeriodEnd({
      scheduledChange: { effectiveAt: "2030-12-01T00:00:00Z", action: "cancel", resumeAt: null },
      currentBillingPeriod: { endsAt: "2030-06-08T00:00:00Z" },
    } as never);
    expect(end?.toISOString()).toBe("2030-12-01T00:00:00.000Z");
  });
});

describe("provider seat-quantity updates", () => {
  function fakePaddle(items: unknown[]) {
    const calls: Array<{ id: string; body: unknown }> = [];
    return {
      calls,
      client: {
        subscriptions: {
          get: async (_id: string) => ({ items }),
          update: async (id: string, body: unknown) => {
            calls.push({ id, body });
            return { items };
          },
        },
      },
    };
  }

  test("paddle resubmits the subscription's own price id, not the catalog one", async () => {
    // pro_yearly rides a cloned non-catalog price, so PADDLE_PRICE_YEARLY is a
    // DIFFERENT price for exactly the plan people buy — sending it would move
    // the customer onto the catalog's trial period and amount.
    const paddle = fakePaddle([
      { status: "active", quantity: 1, price: { id: "pri_cloned_non_catalog" } },
    ]);

    await paddleUpdateSubscriptionQuantity(paddle.client as never, "sub_pdl", 4);

    expect(paddle.calls).toEqual([
      {
        id: "sub_pdl",
        body: {
          items: [{ priceId: "pri_cloned_non_catalog", quantity: 4 }],
          prorationBillingMode: "prorated_immediately",
        },
      },
    ]);
  });

  test("paddle ignores removed lines when picking the one to resize", async () => {
    const paddle = fakePaddle([
      { status: "inactive", quantity: 9, price: { id: "pri_old" } },
      { status: "trialing", quantity: 1, price: { id: "pri_live" } },
    ]);

    await paddleUpdateSubscriptionQuantity(paddle.client as never, "sub_pdl", 3);

    expect(paddle.calls[0]?.body).toMatchObject({
      items: [{ priceId: "pri_live", quantity: 3 }],
    });
  });

  test("paddle refuses a subscription with several live lines rather than guess", async () => {
    // `items` replaces the whole line set, so writing the seat count onto an
    // ambiguous set would silently resize an add-on or drop it entirely.
    const paddle = fakePaddle([
      { status: "active", quantity: 1, price: { id: "pri_seat" } },
      { status: "active", quantity: 1, price: { id: "pri_addon" } },
    ]);

    await expect(
      paddleUpdateSubscriptionQuantity(paddle.client as never, "sub_pdl", 3)
    ).rejects.toThrow("PADDLE_AMBIGUOUS_SUBSCRIPTION_ITEMS");
    expect(paddle.calls).toEqual([]);
  });

  test("razorpay sends the quantity and states when the change applies", async () => {
    const calls: Array<{ id: string; body: unknown }> = [];
    const razorpay = {
      subscriptions: {
        update: async (id: string, body: unknown) => {
          calls.push({ id, body });
          return { status: "active", current_end: 1893456000 };
        },
      },
    };

    await razorpayUpdateSubscriptionQuantity(razorpay as never, "sub_rzp", 6);

    // `cycle_end` would set has_scheduled_changes, which readRazorpayQuantity
    // treats as no seat information at all.
    expect(calls).toEqual([
      { id: "sub_rzp", body: { quantity: 6, schedule_change_at: "now" } },
    ]);
  });
});
