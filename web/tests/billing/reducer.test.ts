import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser, addTestMember } from "../helpers/fixtures.js";
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
      workerLimit: 10,
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

  test("expire reaches every active member of the account, and nobody who left", async () => {
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    const formerMember = await createTestUser(pg.db);
    const stranger = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, owner.id);
    await provisionProductAccountForUser(pg.db, member.id);
    await provisionProductAccountForUser(pg.db, stranger.id);
    await addTestMember(pg.db, account.id, member.id);
    await addTestMember(pg.db, account.id, formerMember.id);
    await pg.db.accountMember.updateMany({
      where: { accountId: account.id, userId: formerMember.id },
      data: { status: "removed", endedAt: new Date() },
    });
    await applySubscriptionEvent(pg.db, {}, activatedYearly(account.id), {});

    const expired: string[] = [];
    const fakeFetch = (async (url: string, init: RequestInit) => {
      if (String(url).includes("/internal/expire")) {
        expired.push(JSON.parse(String(init.body)).userId);
      }
      return new Response("ok");
    }) as unknown as typeof fetch;
    await applySubscriptionEvent(
      pg.db,
      { baseUrl: "http://relay.test", secret: "s".repeat(16) },
      activatedYearly(account.id, { providerEventId: "evt_fanout", type: "canceled" }),
      {},
      fakeFetch
    );

    // The owner is not a member row's business: they must be expired whether or
    // not the account carries one, since the resolver falls back to ownership.
    expect([...expired].sort()).toEqual([owner.id, member.id].sort());
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

  test("a second activation on a new subscription id cancels the prior paid row", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);
    await applySubscriptionEvent(
      pg.db,
      {},
      activatedYearly(account.id, {
        providerEventId: "evt_trial",
        planId: "trial",
        providerSubscriptionId: "sub_trial",
      }),
      {}
    );

    const trialBefore = await pg.db.subscription.findFirst({
      where: { accountId: account.id, status: "active" },
    });

    await applySubscriptionEvent(
      pg.db,
      {},
      activatedYearly(account.id, {
        providerEventId: "evt_yearly",
        providerSubscriptionId: "sub_yearly",
      }),
      {}
    );

    const subs = await pg.db.subscription.findMany({
      where: { accountId: account.id },
      orderBy: { createdAt: "asc" },
    });
    expect(subs).toHaveLength(3);
    expect(subs[1]).toMatchObject({
      id: trialBefore!.id,
      status: "canceled",
      planId: PLAN_UUID.trial,
      // cancelActiveSubscriptions frees the unique provider-id slot.
      providerSubscriptionId: null,
    });
    expect(subs[2]).toMatchObject({
      status: "active",
      tier: "pro",
      planId: PLAN_UUID.pro_yearly,
      providerSubscriptionId: "sub_yearly",
    });
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

describe("applySubscriptionEvent — seats", () => {
  async function activatedWithSeats(seats?: number) {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);
    await applySubscriptionEvent(
      pg.db,
      {},
      activatedYearly(account.id, { quantity: seats }),
      {}
    );
    const sub = await pg.db.subscription.findFirstOrThrow({
      where: { accountId: account.id, providerSubscriptionId: "sub_1" },
    });
    return { user, account, sub };
  }

  test("a first activation carrying several seats does not land on the default of one", async () => {
    const { sub } = await activatedWithSeats(4);
    expect(sub.seats).toBe(4);
  });

  test("an activation carrying no quantity leaves the column default alone", async () => {
    const { sub } = await activatedWithSeats();
    expect(sub.seats).toBe(1);
  });

  test("a portal seat change is written in place on the same row, with an audit trail", async () => {
    const { account, sub } = await activatedWithSeats(3);

    const res = await applySubscriptionEvent(
      pg.db,
      {},
      activatedYearly(account.id, { providerEventId: "evt_seats_up", quantity: 5 }),
      {}
    );
    expect(res.duplicate).toBe(false);

    const after = await pg.db.subscription.findFirstOrThrow({
      where: { providerSubscriptionId: "sub_1" },
    });
    expect(after.seats).toBe(5);
    // Same row: routing a seat edit through provisioning would mint a new one
    // per edit and re-snapshot its limits from the current plan.
    expect(after.id).toBe(sub.id);
    expect(after.createdAt.getTime()).toBe(sub.createdAt.getTime());
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(2);
    // The early return used to skip even this, leaving the delivery no trace.
    expect(await pg.db.webhookEvent.count()).toBe(2);
  });

  test("a replayed activation at the same seat count is still a duplicate", async () => {
    const { account } = await activatedWithSeats(3);

    const dup = await applySubscriptionEvent(
      pg.db,
      {},
      activatedYearly(account.id, { providerEventId: "evt_same_seats", quantity: 3 }),
      {}
    );
    expect(dup.duplicate).toBe(true);
    expect(await pg.db.webhookEvent.count()).toBe(1);
    expect(await pg.db.subscription.count({ where: { accountId: account.id } })).toBe(2);
  });

  test("an event with no quantity leaves the stored seat count untouched", async () => {
    const { account } = await activatedWithSeats(6);

    await applySubscriptionEvent(
      pg.db,
      {},
      activatedYearly(account.id, { providerEventId: "evt_no_seats", type: "renewed" }),
      {}
    );

    const after = await pg.db.subscription.findFirstOrThrow({
      where: { providerSubscriptionId: "sub_1" },
    });
    expect(after.seats).toBe(6);
  });

  test("a renewal writes the seat count — the razorpay cycle-end catch-up", async () => {
    const { account } = await activatedWithSeats(2);

    await applySubscriptionEvent(
      pg.db,
      {},
      activatedYearly(account.id, {
        providerEventId: "evt_charged",
        type: "renewed",
        quantity: 7,
      }),
      {}
    );

    const after = await pg.db.subscription.findFirstOrThrow({
      where: { providerSubscriptionId: "sub_1" },
    });
    expect(after.seats).toBe(7);
  });

  test("a seat count below active headcount is written, and removes nobody", async () => {
    const { account } = await activatedWithSeats(3);
    const second = await createTestUser(pg.db);
    const third = await createTestUser(pg.db);
    await addTestMember(pg.db, account.id, second.id);
    await addTestMember(pg.db, account.id, third.id);
    expect(
      await pg.db.accountMember.count({ where: { accountId: account.id, status: "active" } })
    ).toBe(3);

    // The provider already made the change, so the row has to agree with the
    // invoice. Over-subscribed blocks new invites; it evicts no one.
    await applySubscriptionEvent(
      pg.db,
      {},
      activatedYearly(account.id, { providerEventId: "evt_seats_down", quantity: 1 }),
      {}
    );

    const after = await pg.db.subscription.findFirstOrThrow({
      where: { providerSubscriptionId: "sub_1" },
    });
    expect(after.seats).toBe(1);
    expect(
      await pg.db.accountMember.count({ where: { accountId: account.id, status: "active" } })
    ).toBe(3);
  });

  test("stale trial metadata on a converted subscription changes seats, not the plan", async () => {
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);
    const base = {
      provider: "razorpay" as const,
      accountId: account.id,
      planId: "trial" as const,
      customerId: "cust_1",
      providerSubscriptionId: "sub_conv",
    };
    await applySubscriptionEvent(
      pg.db,
      {},
      { ...base, providerEventId: "evt_conv_trial", type: "activated" },
      {}
    );
    await applySubscriptionEvent(
      pg.db,
      {},
      {
        ...base,
        providerEventId: "evt_conv_charge",
        type: "renewed",
        currentPeriodEnd: new Date("2027-06-08T00:00:00Z"),
      },
      {}
    );

    // checkout writes notes.planId once and never rewrites it, so every later
    // event on this subscription still claims "trial".
    await applySubscriptionEvent(
      pg.db,
      {},
      { ...base, providerEventId: "evt_conv_seats", type: "activated", quantity: 5 },
      {}
    );

    const active = await pg.db.subscription.findFirstOrThrow({
      where: { accountId: account.id, status: "active", cancelledAt: null },
      include: { plan: true },
    });
    expect(active.plan.slug).toBe("pro_yearly");
    expect(active.seats).toBe(5);
    expect(active.trialEndsAt).toBeNull();
  });
});
