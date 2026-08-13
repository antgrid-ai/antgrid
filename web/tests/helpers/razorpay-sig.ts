import { createHmac } from "node:crypto";

export function razorpaySignature(rawBody: string, secret: string): string {
  return createHmac("sha256", secret).update(rawBody).digest("hex");
}

/** Razorpay wraps the interesting entity two levels deep, which is enough
 *  boilerplate that hand-written payloads drift between suites. */
export function razorpaySubscriptionBody(
  event: string,
  entity: Record<string, unknown>,
  paymentEntity?: Record<string, unknown>
): string {
  return JSON.stringify({
    event,
    payload: {
      ...(paymentEntity ? { payment: { entity: paymentEntity } } : {}),
      subscription: { entity },
    },
  });
}
