import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser } from "../helpers/fixtures.js";
import { paddleSignature } from "../helpers/paddle-sig.js";
import { testBillingEnv } from "../helpers/billing-env.js";
import { ensureProductAccount } from "../../src/models/product-account.js";
import { PLAN_UUID } from "../../src/models/plan.js";

const SECRET = "pdl_ntfset_route_secret";

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});
beforeEach(async () => {
  await pg.truncate();
});

function activationBody(
  accountId: string,
  eventId = "evt_route_1",
  opts: { eventType?: string; quantity?: number } = {}
): string {
  return JSON.stringify({
    event_id: eventId,
    notification_id: "ntf_1",
    event_type: opts.eventType ?? "subscription.activated",
    occurred_at: "2026-06-08T00:00:00Z",
    data: {
      id: "sub_route",
      status: "active",
      customer_id: "ctm_route",
      custom_data: { accountId, planId: "pro_yearly" },
      current_billing_period: { starts_at: "2026-06-08T00:00:00Z", ends_at: "2027-06-08T00:00:00Z" },
      ...(opts.quantity === undefined
        ? {}
        : { items: [{ status: "active", quantity: opts.quantity, price: { product_id: "pro_x" } }] }),
    },
  });
}

type TestApp = { request: (path: string, init: RequestInit) => Response | Promise<Response> };

async function post(app: TestApp, raw: string): Promise<Response> {
  return app.request("/webhooks/paddle", {
    method: "POST",
    headers: { "content-type": "application/json", "paddle-signature": paddleSignature(raw, SECRET) },
    body: raw,
  });
}

describe("POST /webhooks/paddle", () => {
  test("valid activation creates subscription", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: testBillingEnv({ PADDLE_WEBHOOK_SECRET: SECRET }),
    });
    const user = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, user.id);
    const raw = activationBody(account.id);
    const res = await app.request("/webhooks/paddle", {
      method: "POST",
      headers: { "content-type": "application/json", "paddle-signature": paddleSignature(raw, SECRET) },
      body: raw,
    });
    expect(res.status).toBe(200);
    const sub = await pg.db.subscription.findFirst({ where: { accountId: account.id } });
    expect(sub).toMatchObject({ tier: "pro", status: "active", planId: PLAN_UUID.pro_yearly });
  });

  test("replayed delivery is idempotent", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: testBillingEnv({ PADDLE_WEBHOOK_SECRET: SECRET }),
    });
    const user = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, user.id);
    const raw = activationBody(account.id);
    await app.request("/webhooks/paddle", {
      method: "POST",
      headers: { "content-type": "application/json", "paddle-signature": paddleSignature(raw, SECRET) },
      body: raw,
    });
    const res2 = await app.request("/webhooks/paddle", {
      method: "POST",
      headers: { "content-type": "application/json", "paddle-signature": paddleSignature(raw, SECRET) },
      body: raw,
    });
    expect(res2.status).toBe(200);
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(1);
  });

  test("a portal seat change reaches the database", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: testBillingEnv({ PADDLE_WEBHOOK_SECRET: SECRET }),
    });
    const user = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, user.id);
    await post(app, activationBody(account.id, "evt_seat_activate", { quantity: 3 }));

    const raw = activationBody(account.id, "evt_seat_change", {
      eventType: "subscription.updated",
      quantity: 5,
    });
    const res = await post(app, raw);
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ ok: true, duplicate: false });
    // The route cannot tell a silent no-op from a write, so assert the row.
    const sub = await pg.db.subscription.findFirstOrThrow({
      where: { providerSubscriptionId: "sub_route" },
    });
    expect(sub.seats).toBe(5);

    // A byte-identical redelivery must not write again.
    const replay = await post(app, raw);
    expect(replay.status).toBe(200);
    expect(await replay.json()).toMatchObject({ ok: true, duplicate: true });
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(1);
  });

  test("unconfigured secret returns 503", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, user.id);
    const raw = activationBody(account.id);
    const res = await app.request("/webhooks/paddle", {
      method: "POST",
      headers: { "content-type": "application/json", "paddle-signature": paddleSignature(raw, SECRET) },
      body: raw,
    });
    expect(res.status).toBe(503);
  });

  test("bad signature returns 400", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: testBillingEnv({ PADDLE_WEBHOOK_SECRET: SECRET }),
    });
    const user = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, user.id);
    const raw = activationBody(account.id);
    const res = await app.request("/webhooks/paddle", {
      method: "POST",
      headers: { "content-type": "application/json", "paddle-signature": paddleSignature(raw, "wrong") },
      body: raw,
    });
    expect(res.status).toBe(400);
  });

  test("transaction.payment_failed is logged and does not provision", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: testBillingEnv({ PADDLE_WEBHOOK_SECRET: SECRET }),
    });
    const user = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, user.id);
    const raw = JSON.stringify({
      event_id: "evt_fail",
      notification_id: "ntf_fail",
      event_type: "transaction.payment_failed",
      occurred_at: "2026-06-08T00:00:00Z",
      data: {
        id: "txn_fail",
        customer_id: "ctm_fail",
        subscription_id: "sub_fail",
        custom_data: { accountId: account.id, planId: "trial" },
        payments: [{ status: "error", error_code: "declined" }],
      },
    });
    const res = await app.request("/webhooks/paddle", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "paddle-signature": paddleSignature(raw, SECRET),
      },
      body: raw,
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ ok: true, ignored: true });
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(0);
  });
});
