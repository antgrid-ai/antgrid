import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession } from "../helpers/fixtures.js";
import {
  isPendingCancellation,
  provisionProductAccountForUser,
} from "../../src/models/subscription.js";
import { applySubscriptionEvent } from "../../src/billing/reducer.js";
import { PLAN_UUID } from "../../src/models/plan.js";

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

describe("POST /billing/cancel-subscription", () => {
  test("dev pro yearly sets cancelledAt at period end and keeps pro access", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "cancel@example.com");
    const account = await provisionProductAccountForUser(pg.db, user.id);
    const { cookie } = await createTestSession(pg.db, user.id);
    const periodEnd = new Date("2027-06-08T00:00:00Z");

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "paddle",
        providerEventId: "evt_dev_yearly",
        type: "activated",
        accountId: account.id,
        planId: "pro_yearly",
        customerId: "ctm_dev",
        providerSubscriptionId: "sub_dev",
        currentPeriodEnd: periodEnd,
      },
      {}
    );
    await pg.db.subscription.updateMany({
      where: { accountId: account.id, providerSubscriptionId: "sub_dev" },
      data: { provider: "dev" },
    });

    const res = await app.request("/billing/cancel-subscription", {
      method: "POST",
      headers: { cookie },
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ effective: "end_of_period" });

    const active = await pg.db.subscription.findFirst({
      where: { accountId: account.id, providerSubscriptionId: "sub_dev" },
      include: { plan: true },
    });
    expect(active?.planId).toBe(PLAN_UUID.pro_yearly);
    expect(active?.status).toBe("active");
    expect(active?.cancelledAt?.toISOString()).toBe(periodEnd.toISOString());
    expect(active?.currentPeriodEnd?.toISOString()).toBe(periodEnd.toISOString());
    expect(active && isPendingCancellation(active)).toBe(true);
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(2);
  });

  test("dev trial cancels immediately and restores free", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "trial-cancel@example.com");
    const account = await provisionProductAccountForUser(pg.db, user.id);
    const { cookie } = await createTestSession(pg.db, user.id);

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "paddle",
        providerEventId: "evt_dev_trial",
        type: "activated",
        accountId: account.id,
        planId: "trial",
        customerId: "ctm_trial",
        providerSubscriptionId: "sub_trial_dev",
      },
      {}
    );
    await pg.db.subscription.updateMany({
      where: { accountId: account.id, providerSubscriptionId: "sub_trial_dev" },
      data: { provider: "dev" },
    });

    const res = await app.request("/billing/cancel-subscription", {
      method: "POST",
      headers: { cookie },
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ effective: "immediately" });

    const active = await pg.db.subscription.findFirst({
      where: { accountId: account.id, status: "active", cancelledAt: null },
      include: { plan: true },
    });
    expect(active?.planId).toBe(PLAN_UUID.free);
    // 3 rows: the canceled promotional grant from provisioning, the canceled
    // trial, and the freshly-created free row (no prior real free row exists
    // to reactivate, since provisioning now defaults to the promotional grant).
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(3);

    const freeBefore = await pg.db.subscription.findFirst({
      where: { accountId: account.id, planId: PLAN_UUID.free },
      orderBy: { createdAt: "asc" },
    });
    expect(active?.id).toBe(freeBefore?.id);
  });

  test("rejects cancel for a promotional grant (no providerSubscriptionId to cancel)", async () => {
    // The dashboard hides the cancel button for promotional subs (see
    // dashboard.tsx's canCancel gate); hitting the endpoint directly still
    // errors cleanly rather than mutating a promo row.
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "promo@example.com");
    await provisionProductAccountForUser(pg.db, user.id);
    const { cookie } = await createTestSession(pg.db, user.id);

    const res = await app.request("/billing/cancel-subscription", {
      method: "POST",
      headers: { cookie },
    });
    expect(res.status).toBe(400);
    expect((await res.json()).error).toBe("NO_PROVIDER_SUBSCRIPTION");
  });
});

describe("POST /billing/resume-subscription", () => {
  test("dev pro yearly resume clears cancelledAt", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "resume@example.com");
    const account = await provisionProductAccountForUser(pg.db, user.id);
    const { cookie } = await createTestSession(pg.db, user.id);
    const periodEnd = new Date("2027-06-08T00:00:00Z");

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "paddle",
        providerEventId: "evt_resume_yearly",
        type: "activated",
        accountId: account.id,
        planId: "pro_yearly",
        customerId: "ctm_resume",
        providerSubscriptionId: "sub_resume",
        currentPeriodEnd: periodEnd,
      },
      {}
    );
    await pg.db.subscription.updateMany({
      where: { accountId: account.id, providerSubscriptionId: "sub_resume" },
      data: { provider: "dev", cancelledAt: periodEnd },
    });

    const res = await app.request("/billing/resume-subscription", {
      method: "POST",
      headers: { cookie },
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ ok: true });

    const active = await pg.db.subscription.findFirst({
      where: { accountId: account.id, providerSubscriptionId: "sub_resume" },
    });
    expect(active?.status).toBe("active");
    expect(active?.cancelledAt).toBeNull();
    expect(active && isPendingCancellation(active)).toBe(false);
  });

  test("rejects resume when not pending cancellation", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "no-pending@example.com");
    const account = await provisionProductAccountForUser(pg.db, user.id);
    const { cookie } = await createTestSession(pg.db, user.id);

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "paddle",
        providerEventId: "evt_active_yearly",
        type: "activated",
        accountId: account.id,
        planId: "pro_yearly",
        customerId: "ctm_active",
        providerSubscriptionId: "sub_active",
      },
      {}
    );
    await pg.db.subscription.updateMany({
      where: { accountId: account.id, providerSubscriptionId: "sub_active" },
      data: { provider: "dev" },
    });

    const res = await app.request("/billing/resume-subscription", {
      method: "POST",
      headers: { cookie },
    });
    expect(res.status).toBe(400);
    expect((await res.json()).error).toBe("NOT_PENDING_CANCELLATION");
  });
});
