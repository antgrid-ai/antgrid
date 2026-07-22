import { Hono } from "hono";
import type { DB } from "../db/index.js";
import type { RelayPushConfig } from "../relay/push.js";
import { logPaddlePaymentFailure, PaddleProvider } from "../billing/paddle.js";
import { logRazorpayPaymentFailure, RazorpayProvider } from "../billing/razorpay.js";
import { applySubscriptionEvent } from "../billing/reducer.js";

export function webhookRoutes(deps: {
  db: DB;
  relay: RelayPushConfig;
  paddleWebhookSecret?: string;
  razorpayWebhookSecret?: string;
}) {
  const r = new Hono();

  r.post("/webhooks/paddle", async (c) => {
    if (!deps.paddleWebhookSecret) return c.json({ error: "PADDLE_NOT_CONFIGURED" }, 503);

    const provider = new PaddleProvider({ webhookSecret: deps.paddleWebhookSecret });
    const raw = await c.req.text();
    const signature = c.req.header("paddle-signature");

    let event;
    try {
      event = await provider.verifyWebhook(raw, signature);
    } catch {
      return c.json({ error: "INVALID_SIGNATURE" }, 400);
    }

    if (!event) {
      logPaddlePaymentFailure(raw);
      return c.json({ ok: true, ignored: true });
    }

    const parsed = JSON.parse(raw) as unknown;
    await applySubscriptionEvent(deps.db, deps.relay, event, parsed);
    return c.json({ ok: true });
  });

  r.post("/webhooks/razorpay", async (c) => {
    if (!deps.razorpayWebhookSecret) return c.json({ error: "RAZORPAY_NOT_CONFIGURED" }, 503);

    const provider = new RazorpayProvider({ webhookSecret: deps.razorpayWebhookSecret });
    const raw = await c.req.text();
    const signature = c.req.header("x-razorpay-signature");

    let event;
    try {
      event = await provider.verifyWebhook(raw, signature);
    } catch {
      return c.json({ error: "INVALID_SIGNATURE" }, 400);
    }

    if (!event) {
      logRazorpayPaymentFailure(raw);
      return c.json({ ok: true, ignored: true });
    }

    const parsed = JSON.parse(raw) as unknown;
    await applySubscriptionEvent(deps.db, deps.relay, event, parsed);
    return c.json({ ok: true });
  });

  return r;
}
