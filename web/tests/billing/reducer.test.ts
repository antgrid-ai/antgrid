import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser } from "../helpers/fixtures.js";
import { applySubscriptionEvent } from "../../src/billing/reducer.js";
import type { NormalizedEvent } from "../../src/billing/events.js";
import { provisionProductAccountForUser, activeSubscriptionForAccount } from "../../src/models/subscription.js";
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

function activatedYearly(accountId: string, over: Partial<NormalizedEvent> = {}): NormalizedEvent {
  return {
    provider: "paddle",
    providerEventId: "evt_1",
    type: "activated",
    accountId,
    planId: "pro_yearly",
    customerId: "ctm_1",
    providerSubscriptionId: "sub_1",
    currentPeriodEnd: new Date("2027-06-08T00:00:00Z"),
    ...over,
  };
}

describe("applySubscriptionEvent", () => {
  test("activation cancels the promotional grant and creates new paid row + billing customer", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);
    const userRow = await pg.db.user.findUnique({ where: { id: user.id } });
    expect(userRow?.accountId).toBe(account.id);
    const promoBefore = await pg.db.subscription.findFirst({
      where: { accountId: account.id, promotional: true },
    });

    const res = await applySubscriptionEvent(pg.db, {}, activatedYearly(account.id), {});
    expect(res.duplicate).toBe(false);

    const subs = await pg.db.subscription.findMany({
      where: { accountId: account.id },
      orderBy: { createdAt: "asc" },
    });
    expect(subs).toHaveLength(2);
    expect(subs[0]).toMatchObject({
      id: promoBefore!.id,
      status: "canceled",
      planId: PLAN_UUID.pro_yearly,
      promotional: true,
      cancelledAt: expect.any(Date),
    });
    expect(subs[1]).toMatchObject({
      accountId: account.id,
      tier: "pro",
      status: "active",
      planId: PLAN_UUID.pro_yearly,
      provider: "paddle",
      sessionLimit: 10,
      promotional: false,
      cancelledAt: null,
    });

    const cust = await pg.db.billingCustomer.findUnique({
      where: { accountId_provider: { accountId: account.id, provider: "paddle" } },
    });
    expect(cust?.providerCustomerId).toBe("ctm_1");
  });

  test("is idempotent on replay", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);
    await applySubscriptionEvent(pg.db, {}, activatedYearly(account.id), {});
    const second = await applySubscriptionEvent(pg.db, {}, activatedYearly(account.id), {});
    expect(second.duplicate).toBe(true);
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(2);
  });

  test("cancellation marks subscription canceled with cancelled_at and pushes expire", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);
    await applySubscriptionEvent(pg.db, {}, activatedYearly(account.id), {});

    const calls: string[] = [];
    const fakeFetch = (async (url: string) => {
      calls.push(String(url));
      return new Response("ok");
    }) as unknown as typeof fetch;
    await applySubscriptionEvent(
      pg.db,
      { baseUrl: "http://relay.test", secret: "s".repeat(16) },
      activatedYearly(account.id, { providerEventId: "evt_2", type: "canceled" }),
      {},
      fakeFetch
    );

    const sub = await pg.db.subscription.findFirst({
      where: { accountId: account.id, providerSubscriptionId: "sub_1" },
    });
    expect(sub?.status).toBe("canceled");
    expect(sub?.cancelledAt).not.toBeNull();
    expect(calls.some((u) => u.includes("/internal/expire"))).toBe(true);
  });

  test("non-activation without providerSubscriptionId leaves subscription unchanged", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);
    await applySubscriptionEvent(pg.db, {}, activatedYearly(account.id), {});

    const before = await pg.db.subscription.findFirst({ where: { accountId: account.id } });

    await applySubscriptionEvent(
      pg.db,
      {},
      activatedYearly(account.id, {
        providerEventId: "evt_no_sub",
        type: "canceled",
        providerSubscriptionId: undefined,
      }),
      {}
    );

    const after = await pg.db.subscription.findFirst({ where: { accountId: account.id } });
    expect(after?.status).toBe(before?.status);
    expect(after?.tier).toBe("pro");
  });

  test("trial activation cancels the promotional grant and sets trial dates", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "paddle",
        providerEventId: "evt_trial",
        type: "activated",
        accountId: account.id,
        planId: "trial",
        customerId: "ctm_trial",
        providerSubscriptionId: "sub_trial",
      },
      {}
    );

    const active = await pg.db.subscription.findFirst({
      where: { accountId: account.id, status: "active" },
      include: { plan: true },
    });
    expect(active?.plan.slug).toBe("trial");
    expect(active?.tier).toBe("trial");
    expect(active?.trialStartedAt).not.toBeNull();
    expect(active?.trialEndsAt).not.toBeNull();

    const promo = await pg.db.subscription.findFirst({
      where: { accountId: account.id, promotional: true },
    });
    expect(promo?.status).toBe("canceled");
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(2);
  });

  test("renewed event converts trial subscription to pro yearly", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "razorpay",
        providerEventId: "evt_trial_on",
        type: "activated",
        accountId: account.id,
        planId: "trial",
        customerId: "cust_1",
        providerSubscriptionId: "sub_trial",
      },
      {}
    );

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "razorpay",
        providerEventId: "evt_trial_charge",
        type: "renewed",
        accountId: account.id,
        planId: "trial",
        customerId: "cust_1",
        providerSubscriptionId: "sub_trial",
        currentPeriodEnd: new Date("2027-06-08T00:00:00Z"),
      },
      {}
    );

    const sub = await pg.db.subscription.findFirst({
      where: { accountId: account.id, status: "active" },
      include: { plan: true },
    });
    expect(sub?.plan.slug).toBe("pro_yearly");
    expect(sub?.tier).toBe("pro");
    expect(sub?.trialEndsAt).toBeNull();
    expect(sub?.providerSubscriptionId).toBe("sub_trial");

    const trial = await pg.db.subscription.findFirst({
      where: { accountId: account.id, planId: PLAN_UUID.trial },
    });
    expect(trial?.status).toBe("canceled");
    expect(trial?.providerSubscriptionId).toBeNull();
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(3);
  });

  test("canceled trial restores free subscription", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "paddle",
        providerEventId: "evt_trial_on",
        type: "activated",
        accountId: account.id,
        planId: "trial",
        customerId: "ctm_trial",
        providerSubscriptionId: "sub_trial",
        currentPeriodEnd: new Date("2026-06-19T12:55:31.782Z"),
      },
      {}
    );

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "paddle",
        providerEventId: "evt_trial_cancel",
        type: "canceled",
        accountId: account.id,
        planId: "trial",
        customerId: "ctm_trial",
        providerSubscriptionId: "sub_trial",
      },
      {}
    );

    const active = await pg.db.subscription.findFirst({
      where: { accountId: account.id, status: "active", cancelledAt: null },
      include: { plan: true },
    });
    expect(active?.plan.slug).toBe("free");
    expect(active?.tier).toBe("free");

    const trial = await pg.db.subscription.findFirst({
      where: { accountId: account.id, providerSubscriptionId: "sub_trial" },
    });
    expect(trial?.status).toBe("canceled");
    // 3 rows: the canceled promotional grant from provisioning, the canceled
    // trial, and the freshly-created free row (no prior real free row exists
    // to reactivate, since provisioning now defaults to the promotional grant).
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(3);

    const freeBefore = await pg.db.subscription.findFirst({
      where: { accountId: account.id, planId: PLAN_UUID.free },
      orderBy: { createdAt: "asc" },
    });
    expect(active?.id).toBe(freeBefore?.id);
    expect(active?.cancelledAt).toBeNull();
  });

  test("subscription.canceled without custom_data resolves from DB and restores free", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);

    await applySubscriptionEvent(
      pg.db,
      {},
      activatedYearly(account.id, { providerSubscriptionId: "sub_yearly_cd" }),
      {}
    );

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "paddle",
        providerEventId: "evt_cancel_no_cd",
        type: "canceled",
        accountId: "",
        planId: "pro_yearly",
        customerId: "ctm_1",
        providerSubscriptionId: "sub_yearly_cd",
      },
      {}
    );

    const active = await pg.db.subscription.findFirst({
      where: { accountId: account.id, status: "active", cancelledAt: null },
      include: { plan: true },
    });
    expect(active?.plan.slug).toBe("free");
    // 3 rows: the canceled promotional grant from provisioning, the canceled
    // real pro_yearly sub, and the freshly-created free row (no prior real
    // free row exists to reactivate).
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(3);

    const freeBefore = await pg.db.subscription.findFirst({
      where: { accountId: account.id, planId: PLAN_UUID.free },
      orderBy: { createdAt: "asc" },
    });
    expect(active?.id).toBe(freeBefore?.id);
    expect(active?.cancelledAt).toBeNull();
  });

  test("lifetime cancels prior paid sub and creates new row", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);
    await applySubscriptionEvent(pg.db, {}, activatedYearly(account.id), {});

    const yearlyBefore = await pg.db.subscription.findFirst({
      where: { accountId: account.id, status: "active" },
    });

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "paddle",
        providerEventId: "evt_ltd",
        type: "activated",
        accountId: account.id,
        planId: "pro_lifetime",
        customerId: "ctm_1",
        providerTransactionId: "txn_1",
      },
      {}
    );

    const subs = await pg.db.subscription.findMany({
      where: { accountId: account.id },
      orderBy: { createdAt: "asc" },
    });
    expect(subs).toHaveLength(3);
    expect(subs[1]).toMatchObject({
      id: yearlyBefore!.id,
      status: "canceled",
      planId: PLAN_UUID.pro_yearly,
    });

    const lifetime = subs[2];
    expect(lifetime).toMatchObject({
      status: "active",
      tier: "pro",
      planId: PLAN_UUID.pro_lifetime,
      providerTransactionId: "txn_1",
    });
    expect(lifetime?.currentPeriodEnd).toBeNull();
  });

  test("razorpay pro yearly lifecycle does not create duplicate rows", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);
    const subId = "sub_yearly_rp";
    const periodEnd = new Date("2027-06-08T00:00:00Z");

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "razorpay",
        providerEventId: "evt_yearly_charged",
        type: "renewed",
        accountId: account.id,
        planId: "pro_yearly",
        customerId: "cust_yearly",
        providerSubscriptionId: subId,
        currentPeriodEnd: periodEnd,
      },
      {}
    );

    const second = await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "razorpay",
        providerEventId: "evt_yearly_activated",
        type: "activated",
        accountId: account.id,
        planId: "pro_yearly",
        customerId: "cust_yearly",
        providerSubscriptionId: subId,
        currentPeriodEnd: periodEnd,
      },
      {}
    );
    expect(second.duplicate).toBe(true);

    const active = await pg.db.subscription.findMany({
      where: { accountId: account.id, status: "active", tier: "pro" },
    });
    expect(active).toHaveLength(1);
    expect(active[0]?.providerSubscriptionId).toBe(subId);
    expect(await pg.db.webhookEvent.count()).toBe(1);
  });

  test("razorpay renewal updates providerTransactionId", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);
    const subId = "sub_yearly_txn";
    const periodEnd = new Date("2027-06-08T00:00:00Z");

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "razorpay",
        providerEventId: "evt_yearly_activated_txn",
        type: "activated",
        accountId: account.id,
        planId: "pro_yearly",
        customerId: "cust_yearly",
        providerSubscriptionId: subId,
        providerTransactionId: "pay_initial",
        currentPeriodEnd: periodEnd,
      },
      {}
    );

    await applySubscriptionEvent(
      pg.db,
      {},
      {
        provider: "razorpay",
        providerEventId: "evt_yearly_renewed_txn",
        type: "renewed",
        accountId: account.id,
        planId: "pro_yearly",
        customerId: "cust_yearly",
        providerSubscriptionId: subId,
        providerTransactionId: "pay_renewal",
        currentPeriodEnd: new Date("2028-06-08T00:00:00Z"),
      },
      {}
    );

    const active = await activeSubscriptionForAccount(pg.db, account.id);
    expect(active?.providerTransactionId).toBe("pay_renewal");
  });

  test("duplicate activation by providerSubscriptionId skips webhook row", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);

    await applySubscriptionEvent(
      pg.db,
      {},
      activatedYearly(account.id, { provider: "razorpay", providerSubscriptionId: "sub_dup" }),
      {}
    );

    const dup = await applySubscriptionEvent(
      pg.db,
      {},
      activatedYearly(account.id, {
        provider: "razorpay",
        providerEventId: "evt_dup_2",
        providerSubscriptionId: "sub_dup",
      }),
      {}
    );
    expect(dup.duplicate).toBe(true);
    expect(await pg.db.webhookEvent.count()).toBe(1);
    expect(
      await pg.db.subscription.count({
        where: { accountId: account.id, tier: "pro", status: "active" },
      })
    ).toBe(1);
  });
});
