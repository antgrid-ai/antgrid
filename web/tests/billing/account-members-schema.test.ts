import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { rejection } from "../helpers/rejection.js";
import { createTestUser, createTestSubscription } from "../helpers/fixtures.js";
import { seedPlans, PLAN_UUID, PLAN_SLUG_FREE } from "../../src/models/plan.js";

/**
 * The membership invariants live exclusively in raw migration SQL — a PARTIAL
 * unique index Prisma cannot model, and two column defaults. `migrate diff` is
 * provably blind to the partial one, so nothing else in the suite would notice
 * it silently failing to ship.
 */
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

async function ownedAccount(userId: string): Promise<string> {
  const account = await pg.db.productAccount.create({ data: { userId } });
  return account.id;
}

/**
 * Raw insert, so the assertion can name the index. Prisma normalizes a 23505
 * into "Unique constraint failed on the fields: (`user_id`)" and buries the
 * constraint name inside driver-adapter internals — and the index name is the
 * whole point here, since it is the only evidence the raw-SQL DDL shipped.
 */
async function insertMember(
  accountId: string,
  userId: string,
  role: string,
  status: string
): Promise<void> {
  await pg.db.$executeRawUnsafe(
    `INSERT INTO account_members (account_id, user_id, role, status) VALUES ($1::uuid, $2, $3, $4)`,
    accountId,
    userId,
    role,
    status
  );
}

describe("account_members constraints", () => {
  test("one active membership per user — a second is rejected", async () => {
    const owner = await createTestUser(pg.db);
    const joiner = await createTestUser(pg.db);
    const teamA = await ownedAccount(owner.id);
    const teamB = await ownedAccount(joiner.id);

    await pg.db.accountMember.create({
      data: { accountId: teamA, userId: joiner.id, role: "member", status: "active" },
    });

    // Not a caught-and-shrugged duplicate: this is the constraint behind "do not
    // allow multi-account membership". With two active rows a resolver's
    // findFirst picks by physical row order and the same user gets different
    // entitlements on different requests.
    expect(
      String(await rejection(insertMember(teamB, joiner.id, "member", "active")))
    ).toContain("account_members_one_active_per_user_idx");
  });

  test("a closed membership does not block joining another account", async () => {
    const owner = await createTestUser(pg.db);
    const joiner = await createTestUser(pg.db);
    const teamA = await ownedAccount(owner.id);
    const teamB = await ownedAccount(joiner.id);

    await pg.db.accountMember.create({
      data: {
        accountId: teamA,
        userId: joiner.id,
        role: "member",
        status: "left",
        endedAt: new Date(),
      },
    });
    const rejoined = await pg.db.accountMember.create({
      data: { accountId: teamB, userId: joiner.id, role: "owner", status: "active" },
    });

    expect(rejoined.status).toBe("active");
  });

  test("a user appears at most once per account, whatever the status", async () => {
    const owner = await createTestUser(pg.db);
    const team = await ownedAccount(owner.id);

    await pg.db.accountMember.create({
      data: { accountId: team, userId: owner.id, role: "owner", status: "active" },
    });
    expect(String(await rejection(insertMember(team, owner.id, "member", "left")))).toContain(
      "account_members_account_user_key"
    );
  });

  test("the fixture writes the owner membership, so suites exercise the member path", async () => {
    const user = await createTestUser(pg.db);
    await createTestSubscription(pg.db, user.id);

    const rows = await pg.db.accountMember.findMany({ where: { userId: user.id } });
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ role: "owner", status: "active", endedAt: null });

    // Callable twice for one user: the fixture upserts rather than inserting.
    await createTestSubscription(pg.db, user.id);
    expect(await pg.db.accountMember.count({ where: { userId: user.id } })).toBe(1);
  });
});

describe("seat columns", () => {
  test("a subscription created without seats lands on one", async () => {
    const user = await createTestUser(pg.db);
    const account = await ownedAccount(user.id);
    const sub = await pg.db.subscription.create({
      data: {
        accountId: account,
        planId: PLAN_UUID.pro_yearly,
        tier: "pro",
        status: "active",
        workerLimit: 10,
        appDeviceLimit: 10,
      },
    });

    expect(sub.seats).toBe(1);
  });

  test("the migration wrote the seat caps onto the live plan rows", async () => {
    const plans = await pg.db.plan.findMany({ select: { slug: true, maxSeats: true } });
    const bySlug = Object.fromEntries(plans.map((p) => [p.slug, p.maxSeats]));

    expect(bySlug[PLAN_SLUG_FREE]).toBe(1);
    expect(bySlug.trial).toBe(1);
    expect(bySlug.pro_yearly).toBe(25);
  });

  // Runs last: it empties the catalog. seedPlans' create branch is live, so a
  // plan row that ever goes missing is re-created from CATALOG_PLANS — and
  // max_seats is nullable, which makes it optional on create, so omitting it
  // there re-creates the row at unlimited seats instead of failing to compile.
  // Every seeded slug is named below rather than defaulted, so a new plan has to
  // declare which side of that it lands on.
  test("seedPlans re-creates plan rows carrying the same seat caps", async () => {
    const SEAT_CAPS: Record<string, number | null> = {
      free: 1,
      trial: 1,
      pro_yearly: 25,
      // The one row for which unlimited is the contracted value, not an omission.
      enterprise: null,
    };

    await pg.db.plan.deleteMany({});
    await seedPlans(pg.db);

    const plans = await pg.db.plan.findMany({ select: { slug: true, maxSeats: true } });
    expect(plans.length).toBeGreaterThan(0);
    for (const plan of plans) {
      expect(Object.keys(SEAT_CAPS)).toContain(plan.slug);
      expect({ slug: plan.slug, maxSeats: plan.maxSeats }).toEqual({
        slug: plan.slug,
        maxSeats: SEAT_CAPS[plan.slug] ?? null,
      });
    }
  });
});
