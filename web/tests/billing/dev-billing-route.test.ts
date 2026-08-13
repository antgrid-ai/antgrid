import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser } from "../helpers/fixtures.js";
import { activeSubscriptionForUser } from "../../src/models/subscription.js";

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

type TestApp = ReturnType<typeof buildTestApp>["app"];

function post(app: TestApp, body: unknown) {
  return app.request("/dev/billing/subscription", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("POST /dev/billing/subscription", () => {
  test("when enabled, grants a subscription for the given email", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { DEV_BILLING_ENABLED: true } as never,
    });
    const user = await createTestUser(pg.db);

    const res = await post(app, { email: user.email, planSlug: "pro_yearly" });
    expect(res.status).toBe(200);
    const json = (await res.json()) as { ok: boolean; subscription: { tier: string; provider: string } };
    expect(json.ok).toBe(true);
    expect(json.subscription.provider).toBe("dev");
    expect(json.subscription.tier).not.toBe("free");
  });

  test("unknown email returns 404 USER_NOT_FOUND", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { DEV_BILLING_ENABLED: true } as never,
    });
    const res = await post(app, { email: "nobody@test.local" });
    expect(res.status).toBe(404);
    expect((await res.json()) as { error: string; email: string }).toEqual({
      error: "USER_NOT_FOUND",
      email: "nobody@test.local",
    });
  });

  test("invalid body returns 400", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { DEV_BILLING_ENABLED: true } as never,
    });
    const res = await post(app, { email: "not-an-email" });
    expect(res.status).toBe(400);
  });

  test("route is absent when the flag is unset (default)", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);
    const res = await post(app, { email: user.email });
    expect(res.status).toBe(404);
    // Hono's default 404 (route unmounted) is plain text, not our handler's JSON.
    expect(await res.text()).not.toContain("USER_NOT_FOUND");
  });

  test("route is absent in production even if the flag is set", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { NODE_ENV: "production", DEV_BILLING_ENABLED: true } as never,
    });
    const user = await createTestUser(pg.db);
    const res = await post(app, { email: user.email });
    expect(res.status).toBe(404);
  });
});

function postMember(app: TestApp, body: unknown) {
  return app.request("/dev/billing/member", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function devApp() {
  return buildTestApp(pg.db, pg.url, {
    envOverrides: { DEV_BILLING_ENABLED: true } as never,
  }).app;
}

describe("POST /dev/billing/member", () => {
  test("builds a team whose members resolve the owner's subscription", async () => {
    const app = devApp();
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    await post(app, { email: owner.email, planSlug: "pro_yearly", seats: 3 });

    const res = await postMember(app, { email: member.email, ownerEmail: owner.email });
    expect(res.status).toBe(200);
    const json = (await res.json()) as {
      account_id: string;
      seats: number;
      active_members: number;
      over_subscribed: boolean;
    };
    expect(json.seats).toBe(3);
    expect(json.active_members).toBe(2);
    expect(json.over_subscribed).toBe(false);

    const ownerSub = await activeSubscriptionForUser(pg.db, owner.id);
    const memberSub = await activeSubscriptionForUser(pg.db, member.id);
    expect(memberSub?.id).toBe(ownerSub!.id);
    expect(memberSub?.accountId).toBe(json.account_id);
  });

  test("the member's own subscription is cancelled, not left to resurface", async () => {
    const app = devApp();
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    await post(app, { email: owner.email, planSlug: "pro_yearly" });
    // Every signed-in user already holds a promotional grant on their personal
    // account; leaving it active would orphan it behind the membership.
    await post(app, { email: member.email, planSlug: "pro_yearly" });

    await postMember(app, { email: member.email, ownerEmail: owner.email });

    const personal = await pg.db.productAccount.findUniqueOrThrow({
      where: { userId: member.id },
    });
    const stillActive = await pg.db.subscription.count({
      where: { accountId: personal.id, status: "active" },
    });
    expect(stillActive).toBe(0);
    expect((await pg.db.user.findUniqueOrThrow({ where: { id: member.id } })).accountId).not.toBe(
      personal.id
    );
  });

  test("joining a user who already holds an active owner membership succeeds", async () => {
    const app = devApp();
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    // ensureProductAccount gives every user an active owner row, so a bare
    // create here would 23505 on account_members_one_active_per_user_idx.
    await post(app, { email: member.email, planSlug: "pro_yearly" });

    const res = await postMember(app, { email: member.email, ownerEmail: owner.email });
    expect(res.status).toBe(200);
    expect(
      await pg.db.accountMember.count({ where: { userId: member.id, status: "active" } })
    ).toBe(1);
  });

  test("a team can be built past its seat count — over-subscription is legal", async () => {
    const app = devApp();
    const owner = await createTestUser(pg.db);
    const first = await createTestUser(pg.db);
    const second = await createTestUser(pg.db);
    await post(app, { email: owner.email, planSlug: "pro_yearly", seats: 1 });

    await postMember(app, { email: first.email, ownerEmail: owner.email });
    const res = await postMember(app, { email: second.email, ownerEmail: owner.email });
    const json = (await res.json()) as { active_members: number; over_subscribed: boolean };
    expect(json.active_members).toBe(3);
    expect(json.over_subscribed).toBe(true);
  });

  test("an unknown email is 404 and names which one", async () => {
    const app = devApp();
    const owner = await createTestUser(pg.db);
    const res = await postMember(app, { email: "ghost@test.local", ownerEmail: owner.email });
    expect(res.status).toBe(404);
    expect((await res.json()) as { error: string; email: string }).toEqual({
      error: "USER_NOT_FOUND",
      email: "ghost@test.local",
    });
  });

  test("a user cannot join the account they already bill against", async () => {
    const app = devApp();
    const user = await createTestUser(pg.db);
    await post(app, { email: user.email, planSlug: "pro_yearly" });
    const res = await postMember(app, { email: user.email, ownerEmail: user.email });
    expect(res.status).toBe(400);
    expect((await res.json()) as { error: string }).toMatchObject({
      error: "ALREADY_ON_THIS_ACCOUNT",
    });
  });

  test("route is absent when the flag is unset (default)", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    const res = await postMember(app, { email: member.email, ownerEmail: owner.email });
    expect(res.status).toBe(404);
    expect(await res.text()).not.toContain("USER_NOT_FOUND");
  });

  test("route is absent in production even if the flag is set", async () => {
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { NODE_ENV: "production", DEV_BILLING_ENABLED: true } as never,
    });
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    const res = await postMember(app, { email: member.email, ownerEmail: owner.email });
    expect(res.status).toBe(404);
    expect(
      await pg.db.accountMember.count({ where: { userId: member.id, status: "active" } })
    ).toBe(0);
  });
});
