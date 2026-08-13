import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { decodeJwt } from "jose";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import {
  createTestUser,
  createTestSession,
  createTestSubscription,
  addTestMember,
} from "../helpers/fixtures.js";
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
      worker_limit: 10,
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

type TestApp = ReturnType<typeof buildTestApp>["app"];

async function mintAgentClaims(
  app: TestApp,
  cookie: string
): Promise<Record<string, unknown>> {
  const dev = await app.request("/account/devices", {
    method: "POST",
    headers: { cookie, "content-type": "application/json" },
    body: JSON.stringify({
      deviceUuid: crypto.randomUUID(),
      ed25519Pub: Buffer.alloc(32, 0x11).toString("base64"),
      x25519Pub: Buffer.alloc(32, 0x22).toString("base64"),
      platform: "linux",
      displayName: "member's box",
    }),
  });
  expect(dev.status).toBe(201);
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
  return decodeJwt((await tok.json()).access_token) as Record<string, unknown>;
}

/**
 * The team-entitlement story rests entirely on which subscription row
 * `activeSubscriptionForUser` returns: `resolveEntitlement` is a pure field
 * projection and the `tier` claim is minted straight off it, so nothing in the
 * bridge or the relay changes for a member. These two tests are the only place
 * that is proven end to end.
 */
describe("membership → entitlement", () => {
  test("a member's minted JWT carries the owner's tier", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    // Trial, not pro: every fallback the resolver could take lands on a pro row
    // (the promotional grant a mint would provision), so a pro-on-pro assertion
    // would pass whether or not the claim came from the team.
    await createTestSubscription(pg.db, owner.id, { tier: "trial" });
    const team = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: owner.id } });
    await addTestMember(pg.db, team.id, member.id);
    const { cookie } = await createTestSession(pg.db, member.id);

    const claims = await mintAgentClaims(app, cookie);
    expect(claims.tier).toBe("trial");
    expect(claims.uid).toBe(member.id);
  });

  test("minting a member's token grants nothing on their own account", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id, { tier: "trial" });
    const team = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: owner.id } });
    const personal = await provisionProductAccountForUser(pg.db, member.id);
    await addTestMember(pg.db, team.id, member.id);
    await pg.db.subscription.updateMany({
      where: { accountId: personal.id, status: "active" },
      data: { status: "canceled", cancelledAt: new Date() },
    });
    const { cookie } = await createTestSession(pg.db, member.id);

    // Token mints run provisioning too, and they run hourly per agent — a member
    // whose personal account keeps being re-granted would mask every seat bug in
    // dev, where that grant is the pro tier.
    expect((await mintAgentClaims(app, cookie)).tier).toBe("trial");
    expect(
      await pg.db.subscription.count({ where: { accountId: personal.id, status: "active" } })
    ).toBe(0);
  });

  test("a member's /subscriptions/me reports the team's account, not their own", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id, { tier: "pro", workerLimit: 4 });
    const team = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: owner.id } });
    const personal = await provisionProductAccountForUser(pg.db, member.id);
    await addTestMember(pg.db, team.id, member.id);
    const { cookie } = await createTestSession(pg.db, member.id);

    const body = (await (await app.request("/subscriptions/me", { headers: { cookie } })).json()) as {
      account_id: string;
      subscription: { account_id: string };
      worker_limit: number;
      promotional: boolean;
    };
    // Both keys come from separate lookups in the route; a member is the only
    // subject for which they can disagree.
    expect(body.account_id).toBe(team.id);
    expect(body.subscription.account_id).toBe(team.id);
    expect(body.account_id).not.toBe(personal.id);
    expect(body.worker_limit).toBe(4);
    // The member's own account still carries its promotional grant; reading it
    // instead would report `true` here.
    expect(body.promotional).toBe(false);
  });
});
