import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession, addTestMember } from "../helpers/fixtures.js";
import { testBillingEnv } from "../helpers/billing-env.js";
import { provisionProductAccountForUser } from "../../src/models/subscription.js";
import { applySubscriptionEvent } from "../../src/billing/reducer.js";

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

type Team = {
  accountId: string;
  ownerCookie: string;
  memberCookie: string;
};

/**
 * An owner on a live dev-provider pro_yearly subscription plus one member who
 * bills against it. The subscription is real (not a fixture row) so the owner
 * control cases below take the same path a gate bug would open to the member.
 */
async function team(): Promise<Team> {
  const owner = await createTestUser(pg.db);
  const member = await createTestUser(pg.db);
  const account = await provisionProductAccountForUser(pg.db, owner.id);
  await provisionProductAccountForUser(pg.db, member.id);
  await addTestMember(pg.db, account.id, member.id);

  await applySubscriptionEvent(
    pg.db,
    {},
    {
      provider: "paddle",
      providerEventId: "evt_team_owner",
      type: "activated",
      accountId: account.id,
      planId: "pro_yearly",
      customerId: "ctm_team",
      providerSubscriptionId: "sub_team",
      currentPeriodEnd: new Date("2027-06-08T00:00:00Z"),
    },
    {}
  );
  await pg.db.subscription.updateMany({
    where: { accountId: account.id, providerSubscriptionId: "sub_team" },
    data: { provider: "dev" },
  });

  const { cookie: ownerCookie } = await createTestSession(pg.db, owner.id);
  const { cookie: memberCookie } = await createTestSession(pg.db, member.id);
  return { accountId: account.id, ownerCookie, memberCookie };
}

describe("owner-only billing routes", () => {
  test("a member cannot cancel the team's subscription", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const { accountId, memberCookie } = await team();

    const res = await app.request("/billing/cancel-subscription", {
      method: "POST",
      headers: { cookie: memberCookie },
    });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "NOT_ACCOUNT_OWNER" });

    // The status code alone would still pass if the gate ran after the effect.
    const sub = await pg.db.subscription.findFirstOrThrow({
      where: { accountId, providerSubscriptionId: "sub_team" },
    });
    expect(sub.status).toBe("active");
    expect(sub.cancelledAt).toBeNull();
  });

  test("the owner of the same team still cancels", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const { accountId, ownerCookie } = await team();

    const res = await app.request("/billing/cancel-subscription", {
      method: "POST",
      headers: { cookie: ownerCookie },
    });
    expect(res.status).toBe(200);
    const sub = await pg.db.subscription.findFirstOrThrow({
      where: { accountId, providerSubscriptionId: "sub_team" },
    });
    expect(sub.cancelledAt).not.toBeNull();
  });

  test("a member cannot resume the team's pending cancellation", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const { accountId, ownerCookie, memberCookie } = await team();
    await app.request("/billing/cancel-subscription", {
      method: "POST",
      headers: { cookie: ownerCookie },
    });

    const res = await app.request("/billing/resume-subscription", {
      method: "POST",
      headers: { cookie: memberCookie },
    });
    expect(res.status).toBe(403);
    const sub = await pg.db.subscription.findFirstOrThrow({
      where: { accountId, providerSubscriptionId: "sub_team" },
    });
    expect(sub.cancelledAt).not.toBeNull();
  });

  test("a member cannot resize the team's seats", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const { accountId, memberCookie } = await team();
    const before = await pg.db.subscription.findFirstOrThrow({
      where: { accountId, providerSubscriptionId: "sub_team" },
    });

    const res = await app.request("/billing/seats", {
      method: "POST",
      headers: { cookie: memberCookie, "content-type": "application/json" },
      body: JSON.stringify({ seats: 9 }),
    });
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "NOT_ACCOUNT_OWNER" });

    // The status code alone would still pass if the handler were registered
    // above the middleware loop, where Hono never runs the gate at all.
    const after = await pg.db.subscription.findFirstOrThrow({ where: { id: before.id } });
    expect(after.seats).toBe(before.seats);
  });

  test("a member cannot move the team's billing country", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const { accountId, memberCookie } = await team();
    await pg.db.productAccount.update({
      where: { id: accountId },
      data: { country: "DE", countrySource: "manual" },
    });

    const res = await app.request("/billing/confirm-country", {
      method: "POST",
      headers: { cookie: memberCookie, "content-type": "application/json" },
      body: JSON.stringify({ country: "IN" }),
    });
    expect(res.status).toBe(403);
    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { id: accountId } });
    expect(account.country).toBe("DE");
  });

  test("a member cannot lock the team's billing provider", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const { accountId, memberCookie } = await team();

    const intent = await app.request("/billing/checkout-intent", {
      headers: { cookie: memberCookie },
    });
    expect(intent.status).toBe(403);

    const session = await app.request("/billing/checkout-session", {
      method: "POST",
      headers: { cookie: memberCookie, "content-type": "application/json" },
      body: JSON.stringify({ planId: "pro_yearly", country: "IN" }),
    });
    expect(session.status).toBe(403);

    const redirect = await app.request("/billing/checkout", {
      method: "POST",
      headers: { cookie: memberCookie, "content-type": "application/json" },
      body: JSON.stringify({ planId: "pro_yearly" }),
    });
    expect(redirect.status).toBe(403);

    // lockBillingProvider early-returns on an existing value, so one member
    // reaching checkout would pin the team's gateway to their country for good.
    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { id: accountId } });
    expect(account.billingProvider).toBeNull();
  });

  test("GET /billing/plans stays open to members", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const { memberCookie } = await team();

    const res = await app.request("/billing/plans", { headers: { cookie: memberCookie } });
    expect(res.status).toBe(200);
  });
});

describe("owner-only HTMX twins", () => {
  test("a member's cancel/resume post redirects without touching the subscription", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const { accountId, memberCookie } = await team();

    const cancel = await app.request("/ui/subscription/cancel", {
      method: "POST",
      headers: { cookie: memberCookie },
    });
    expect(cancel.status).toBe(302);
    expect(cancel.headers.get("location")).toBe("/dashboard?cancel=failed");

    const resume = await app.request("/ui/subscription/resume", {
      method: "POST",
      headers: { cookie: memberCookie },
    });
    expect(resume.status).toBe(302);
    expect(resume.headers.get("location")).toBe("/dashboard?resume=failed");

    const sub = await pg.db.subscription.findFirstOrThrow({
      where: { accountId, providerSubscriptionId: "sub_team" },
    });
    expect(sub.status).toBe("active");
    expect(sub.cancelledAt).toBeNull();
  });

  test("GET /checkout redirects a member away before it can lock the provider", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const { accountId, memberCookie } = await team();

    const res = await app.request("/checkout?planId=pro_yearly", {
      headers: { cookie: memberCookie },
    });
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/dashboard");
    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { id: accountId } });
    expect(account.billingProvider).toBeNull();
  });
});
