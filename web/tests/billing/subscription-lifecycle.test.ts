import { describe, test, expect } from "bun:test";
import {
  paddlePeriodEnd,
  paddleResumePendingCancellation,
} from "../../src/billing/paddle.js";
import {
  razorpayCancelSubscription,
  razorpayPeriodEnd,
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
