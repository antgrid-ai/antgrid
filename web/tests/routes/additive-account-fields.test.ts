import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestSession, createTestSubscription, createTestUser } from "../helpers/fixtures.js";
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

/**
 * The response shapes as they stood before seats existed, frozen here on
 * purpose.
 *
 * These lists are the contract an app already in the field was compiled
 * against. Editing one to make a test pass is the whole failure mode they exist
 * to catch: a rename or a dropped field is a breaking change no matter how
 * additive the commit that made it looked.
 */
const LEGACY_SUBSCRIPTIONS_ME_KEYS = [
  "account_id",
  "subscription",
  "tier",
  "worker_limit",
  "session_limit",
  "app_device_limit",
  "promotional",
  "active_app_devices",
] as const;

const LEGACY_SUBSCRIPTION_KEYS = [
  "id",
  "account_id",
  "tier",
  "plan_id",
  "provider",
  "status",
  "worker_limit",
  "session_limit",
  "app_device_limit",
  "promotional",
  "trial_started_at",
  "trial_ends_at",
  "current_period_end",
  "cancelled_at",
] as const;

const LEGACY_ACCOUNT_ME_KEYS = [
  "userId",
  "email",
  "tier",
  "worker_limit",
  "session_limit",
  "app_device_limit",
  "promotional",
] as const;

const ADDED_KEYS = ["role", "seats", "seats_used", "capabilities"] as const;

function keysOf(value: unknown): string[] {
  return Object.keys(value as object).sort();
}

function sorted(keys: readonly string[]): string[] {
  return [...keys].sort();
}

type LegacySubscription = Record<(typeof LEGACY_SUBSCRIPTION_KEYS)[number], unknown>;

type SubscriptionsMeBody = {
  account_id: string;
  subscription: LegacySubscription & { seats: number };
  tier: string;
  worker_limit: number;
  session_limit: number;
  app_device_limit: number;
  promotional: boolean;
  active_app_devices: number;
  role: string | null;
  seats: number;
  seats_used: number;
  capabilities: Record<string, boolean>;
};

type AccountMeBody = {
  userId: string;
  email: string;
  tier: string;
  worker_limit: number;
  session_limit: number;
  app_device_limit: number;
  promotional: boolean;
  role: string | null;
  seats: number;
  seats_used: number;
  capabilities: Record<string, boolean>;
};

type TestApp = ReturnType<typeof buildTestApp>["app"];

function devApp(): TestApp {
  return buildTestApp(pg.db, pg.url, {
    envOverrides: { DEV_BILLING_ENABLED: true } as never,
  }).app;
}

async function devPost(app: TestApp, path: string, body: unknown): Promise<Response> {
  return app.request(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function read<T>(app: TestApp, path: string, cookie: string): Promise<T> {
  const res = await app.request(path, { headers: { cookie } });
  expect(res.status).toBe(200);
  return (await res.json()) as T;
}

describe("GET /subscriptions/me", () => {
  test("returns every field it returned before, unchanged, plus role/seats/seats_used/capabilities", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);
    const sub = await createTestSubscription(pg.db, user.id, {
      tier: "pro",
      workerLimit: 3,
      seats: 4,
    });
    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
    const { cookie } = await createTestSession(pg.db, user.id);

    const body = await read<SubscriptionsMeBody>(app, "/subscriptions/me", cookie);

    expect(keysOf(body)).toEqual(sorted([...LEGACY_SUBSCRIPTIONS_ME_KEYS, ...ADDED_KEYS]));
    expect(keysOf(body.subscription)).toEqual(sorted([...LEGACY_SUBSCRIPTION_KEYS, "seats"]));

    // The "unchanged" half, proved rather than asserted around: drop the new
    // keys and what remains is exactly what an older client read — every name,
    // type and value spelled out, so a rename or a re-meaning cannot slip
    // through as a passing test.
    const { role, seats, seats_used: seatsUsed, capabilities, ...legacy } = body;
    const { seats: subscriptionSeats, ...legacySubscription } = body.subscription;
    expect({ ...legacy, subscription: legacySubscription }).toEqual({
      account_id: account.id,
      subscription: {
        id: sub.id,
        account_id: account.id,
        tier: "pro",
        plan_id: PLAN_UUID.pro_yearly,
        provider: null,
        status: "active",
        worker_limit: 3,
        session_limit: 3,
        app_device_limit: 10,
        promotional: false,
        trial_started_at: null,
        trial_ends_at: null,
        current_period_end: null,
        cancelled_at: null,
      },
      tier: "pro",
      worker_limit: 3,
      session_limit: 3,
      app_device_limit: 10,
      promotional: false,
      active_app_devices: 0,
    });

    expect(role).toBe("owner");
    expect(seats).toBe(4);
    expect(subscriptionSeats).toBe(4);
    // Purchased four, occupying one: the two are separate questions.
    expect(seatsUsed).toBe(1);
    // A self-serve plan grants none, and the empty object is the answer rather
    // than an absent key — a client cannot tell "no capabilities" from "this
    // build does not report them" if the field only appears when non-empty.
    expect(capabilities).toEqual({});
  });
});

describe("GET /account/me", () => {
  test("returns every field it returned before, unchanged, plus role/seats/seats_used/capabilities", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db);
    await createTestSubscription(pg.db, user.id, { tier: "pro", workerLimit: 3, seats: 4 });
    const { cookie } = await createTestSession(pg.db, user.id);

    const body = await read<AccountMeBody>(app, "/account/me", cookie);

    expect(keysOf(body)).toEqual(sorted([...LEGACY_ACCOUNT_ME_KEYS, ...ADDED_KEYS]));

    const { role, seats, seats_used: seatsUsed, capabilities, ...legacy } = body;
    expect(legacy).toEqual({
      userId: user.id,
      email: user.email,
      tier: "pro",
      worker_limit: 3,
      session_limit: 3,
      app_device_limit: 10,
      promotional: false,
    });

    expect(role).toBe("owner");
    expect(seats).toBe(4);
    expect(seatsUsed).toBe(1);
    expect(capabilities).toEqual({});
  });
});

describe("seats_used and role over a real team", () => {
  test("seats_used moves when a member joins through the real membership path", async () => {
    const app = devApp();
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    expect((await devPost(app, "/dev/billing/subscription", {
      email: owner.email,
      planSlug: "pro_yearly",
      seats: 5,
    })).status).toBe(200);
    const { cookie: ownerCookie } = await createTestSession(pg.db, owner.id);

    const before = await read<SubscriptionsMeBody>(app, "/subscriptions/me", ownerCookie);
    expect(before.seats).toBe(5);
    expect(before.seats_used).toBe(1);

    expect((await devPost(app, "/dev/billing/member", {
      email: member.email,
      ownerEmail: owner.email,
    })).status).toBe(200);

    const after = await read<SubscriptionsMeBody>(app, "/subscriptions/me", ownerCookie);
    // The purchase did not change; the occupancy did.
    expect(after.seats).toBe(5);
    expect(after.seats_used).toBe(2);
    // Both routes count seat holders through the one definition, so they can
    // never quote a different headcount for the same team.
    expect((await read<AccountMeBody>(app, "/account/me", ownerCookie)).seats_used).toBe(2);
  });

  test("an owner reads role owner; a member of the same account reads role member", async () => {
    const app = devApp();
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    await devPost(app, "/dev/billing/subscription", {
      email: owner.email,
      planSlug: "pro_yearly",
      seats: 5,
    });
    await devPost(app, "/dev/billing/member", { email: member.email, ownerEmail: owner.email });
    const { cookie: ownerCookie } = await createTestSession(pg.db, owner.id);
    const { cookie: memberCookie } = await createTestSession(pg.db, member.id);

    const ownerBody = await read<SubscriptionsMeBody>(app, "/subscriptions/me", ownerCookie);
    const memberBody = await read<SubscriptionsMeBody>(app, "/subscriptions/me", memberCookie);

    expect(ownerBody.role).toBe("owner");
    expect(memberBody.role).toBe("member");
    expect((await read<AccountMeBody>(app, "/account/me", memberCookie)).role).toBe("member");

    // Role describes the caller's capacity on the account they bill against, so
    // both must be describing the same account for the pair to mean anything.
    expect(memberBody.subscription.account_id).toBe(ownerBody.subscription.account_id);
    expect(memberBody.seats).toBe(ownerBody.seats);
    expect(memberBody.seats_used).toBe(2);
  });
});
