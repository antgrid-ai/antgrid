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

type Owner = { userId: string; accountId: string; cookie: string };

/**
 * An owner on a live pro_yearly subscription moved to `provider: "dev"`, the
 * pattern every billing route test uses so the handler runs its real path
 * without a gateway. The subscription is provisioned through the reducer rather
 * than inserted, so the row under test is the one production writes.
 */
async function owner(seats = 1): Promise<Owner> {
  const user = await createTestUser(pg.db);
  const account = await provisionProductAccountForUser(pg.db, user.id);
  await applySubscriptionEvent(
    pg.db,
    {},
    {
      provider: "paddle",
      providerEventId: `evt_${account.id}`,
      type: "activated",
      accountId: account.id,
      planId: "pro_yearly",
      customerId: "ctm_seats",
      providerSubscriptionId: `sub_${account.id}`,
      currentPeriodEnd: new Date("2027-06-08T00:00:00Z"),
      quantity: seats,
    },
    {}
  );
  await pg.db.subscription.updateMany({
    where: { accountId: account.id, providerSubscriptionId: `sub_${account.id}` },
    data: { provider: "dev" },
  });
  const { cookie } = await createTestSession(pg.db, user.id);
  return { userId: user.id, accountId: account.id, cookie };
}

function seatsOf(accountId: string) {
  return pg.db.subscription
    .findFirstOrThrow({ where: { accountId, providerSubscriptionId: `sub_${accountId}` } })
    .then((s) => s.seats);
}

function post(
  app: ReturnType<typeof buildTestApp>["app"],
  body: unknown,
  cookie?: string
) {
  return app.request("/billing/seats", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(cookie ? { cookie } : {}),
    },
    body: JSON.stringify(body),
  });
}

describe("POST /billing/seats", () => {
  test("the owner resizes and the subscription follows", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const o = await owner(1);

    const res = await post(app, { seats: 5 }, o.cookie);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, seats: 5, headcount: 1 });
    expect(await seatsOf(o.accountId)).toBe(5);
  });

  test("a count below active headcount is refused, and nothing moves", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const o = await owner(3);
    for (let i = 0; i < 2; i++) {
      const extra = await createTestUser(pg.db);
      await addTestMember(pg.db, o.accountId, extra.id);
    }

    const res = await post(app, { seats: 2 }, o.cookie);
    expect(res.status).toBe(409);
    const body = (await res.json()) as { error: string; message: string; headcount: number };
    expect(body.error).toBe("SEATS_BELOW_HEADCOUNT");
    // The number has to be in the refusal: an owner told only "too low" cannot
    // tell how many people to remove.
    expect(body.headcount).toBe(3);
    expect(body.message).toContain("3");

    // Re-read rather than trust the status: the write happens before the
    // gateway call, so a clamp in the wrong place would still answer 409.
    expect(await seatsOf(o.accountId)).toBe(3);
    expect(
      await pg.db.accountMember.count({
        where: { accountId: o.accountId, status: "active" },
      })
    ).toBe(3);
  });

  test("seats exactly equal to headcount are accepted", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const o = await owner(5);
    const second = await createTestUser(pg.db);
    await addTestMember(pg.db, o.accountId, second.id);

    const res = await post(app, { seats: 2 }, o.cookie);
    expect(res.status).toBe(200);
    expect(await seatsOf(o.accountId)).toBe(2);
  });

  test("a solo owner cannot drop below the seat they occupy", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const o = await owner(2);

    // Rejected at the schema, not the clamp — zero seats is not a team size.
    const zero = await post(app, { seats: 0 }, o.cookie);
    expect(zero.status).toBe(400);
    expect(await zero.json()).toEqual({ error: "BAD_REQUEST" });
    expect(await seatsOf(o.accountId)).toBe(2);
  });

  test("above the plan's max_seats is refused with the cap", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const o = await owner(1);

    const res = await post(app, { seats: 26 }, o.cookie);
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string; max_seats: number };
    expect(body.error).toBe("SEATS_ABOVE_PLAN_MAX");
    expect(body.max_seats).toBe(25);
    expect(await seatsOf(o.accountId)).toBe(1);
  });

  test("a malformed body is BAD_REQUEST and carries no zod issues", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const o = await owner(1);

    for (const body of [{}, { seats: "3" }, { seats: 2.5 }, { seats: true }]) {
      const res = await post(app, body, o.cookie);
      expect(res.status).toBe(400);
      // billing.ts never leaks zod issues, unlike devices.ts and dev-billing.ts.
      expect(await res.json()).toEqual({ error: "BAD_REQUEST" });
    }
    expect(await seatsOf(o.accountId)).toBe(1);
  });

  test("unauthenticated is 401", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const res = await post(app, { seats: 3 });
    expect(res.status).toBe(401);
  });

  test("an unpurchased promotional grant has no gateway seats, and the row is put back", async () => {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: testBillingEnv() });
    const user = await createTestUser(pg.db);
    const account = await provisionProductAccountForUser(pg.db, user.id);
    const { cookie } = await createTestSession(pg.db, user.id);

    const res = await post(app, { seats: 3 }, cookie);
    expect(res.status).toBe(400);
    expect((await res.json()) as { error: string }).toMatchObject({
      error: "NO_PROVIDER_SUBSCRIPTION",
    });

    // The row is written before the gateway is reached, so a refusal after that
    // point has to undo it or the account is billed for a seat it never bought.
    const sub = await pg.db.subscription.findFirstOrThrow({
      where: { accountId: account.id, status: "active" },
    });
    expect(sub.promotional).toBe(true);
    expect(sub.seats).toBe(1);
  });
});
