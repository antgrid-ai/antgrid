import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { decodeJwt } from "jose";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession } from "../helpers/fixtures.js";
import { paddleSignature } from "../helpers/paddle-sig.js";
import { testBillingEnv } from "../helpers/billing-env.js";
import { provisionProductAccountForUser } from "../../src/models/subscription.js";
import { PLAN_UUID } from "../../src/models/plan.js";

const SECRET = "pdl_ntfset_flow_secret";
const AGENT_RESOURCE = "http://localhost:8787/api/auth";

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

describe("paddle webhook → entitlement", () => {
  test("after activation, minted JWT carries tier: pro", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: testBillingEnv({ PADDLE_WEBHOOK_SECRET: SECRET }),
    });
    const user = await createTestUser(pg.db, "dave@example.com");
    const account = await provisionProductAccountForUser(pg.db, user.id);
    const { cookie } = await createTestSession(pg.db, user.id);

    const before = await app.request("/subscriptions/me", { headers: { cookie } });
    expect((await before.json()).subscription).toMatchObject({
      tier: "pro",
      account_id: account.id,
      worker_limit: 3,
      promotional: true,
    });

    const raw = JSON.stringify({
      event_id: "evt_flow",
      notification_id: "ntf_flow",
      event_type: "subscription.activated",
      occurred_at: "2026-06-08T00:00:00Z",
      data: {
        id: "sub_flow",
        status: "active",
        customer_id: "ctm_flow",
        custom_data: { accountId: account.id, planId: "pro_yearly" },
        current_billing_period: {
          starts_at: "2026-06-08T00:00:00Z",
          ends_at: "2027-06-08T00:00:00Z",
        },
      },
    });
    const hook = await app.request("/webhooks/paddle", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "paddle-signature": paddleSignature(raw, SECRET),
      },
      body: raw,
    });
    expect(hook.status).toBe(200);

    const after = await app.request("/subscriptions/me", { headers: { cookie } });
    const body = await after.json();
    expect(body.subscription).toMatchObject({
      tier: "pro",
      account_id: account.id,
      plan_id: PLAN_UUID.pro_yearly,
      status: "active",
      cancelled_at: null,
      promotional: false,
    });

    const pub = Buffer.alloc(32, 0xab).toString("base64");
    const dev = await app.request("/account/devices", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({
        deviceUuid: crypto.randomUUID(),
        ed25519Pub: pub,
        x25519Pub: Buffer.alloc(32, 0xcd).toString("base64"),
        platform: "macos",
        displayName: "dave's mac",
      }),
    });
    const creds = (await dev.json()) as { clientId: string; clientSecret: string };
    const tok = await app.request("/api/auth/oauth2/token", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        authorization:
          "Basic " + Buffer.from(`${creds.clientId}:${creds.clientSecret}`).toString("base64"),
      },
      body: `grant_type=client_credentials&scope=agent&resource=${encodeURIComponent(AGENT_RESOURCE)}`,
    });
    const claims = decodeJwt((await tok.json()).access_token) as Record<string, unknown>;
    expect(claims.tier).toBe("pro");
    expect(claims.uid).toBe(user.id);
  });
});
