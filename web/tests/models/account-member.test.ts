import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser, createTestSubscription, addTestMember } from "../helpers/fixtures.js";
import {
  countOtherActiveMembers,
  findActiveMembership,
  isBillingAccountOwner,
  listBillingAccountUserIds,
  resolveBillingAccountId,
} from "../../src/models/account-member.js";
import { activeSubscriptionForUser } from "../../src/models/subscription.js";
import { ensureProductAccount } from "../../src/models/product-account.js";

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

async function ownedAccountId(userId: string): Promise<string> {
  const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId } });
  return account.id;
}

describe("resolveBillingAccountId", () => {
  test("an active membership beats the account the user owns", async () => {
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id, { tier: "pro" });
    await createTestSubscription(pg.db, member.id, { tier: "pro" });
    const team = await ownedAccountId(owner.id);
    const personal = await ownedAccountId(member.id);
    expect(team).not.toBe(personal);

    await addTestMember(pg.db, team, member.id);

    expect(await resolveBillingAccountId(pg.db, member.id)).toBe(team);
  });

  test("a user with no membership row resolves the account they own", async () => {
    const solo = await createTestUser(pg.db);
    const account = await pg.db.productAccount.create({ data: { userId: solo.id } });
    expect(await pg.db.accountMember.count({ where: { userId: solo.id } })).toBe(0);

    expect(await resolveBillingAccountId(pg.db, solo.id)).toBe(account.id);
  });

  test("a membership that is not active falls back rather than resolving the team", async () => {
    const owner = await createTestUser(pg.db);
    const leaver = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id);
    await createTestSubscription(pg.db, leaver.id);
    const team = await ownedAccountId(owner.id);
    const personal = await ownedAccountId(leaver.id);

    await addTestMember(pg.db, team, leaver.id);
    await pg.db.accountMember.update({
      where: { accountId_userId: { accountId: team, userId: leaver.id } },
      data: { status: "left", endedAt: new Date() },
    });

    expect(await resolveBillingAccountId(pg.db, leaver.id)).toBe(personal);
  });

  // The resolver's where-clause pins the literal `active`, and Postgres compares
  // it case-sensitively — so a row written outside the Zod vocabulary is not a
  // near-match, it is invisible. It degrades to the user's own entitlement with
  // nothing logged, which is the whole reason status is written through a schema.
  test("a non-canonical status does not resolve the team", async () => {
    const owner = await createTestUser(pg.db);
    const stranger = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id);
    await createTestSubscription(pg.db, stranger.id);
    const team = await ownedAccountId(owner.id);
    const personal = await ownedAccountId(stranger.id);

    await pg.db.accountMember.updateMany({
      where: { userId: stranger.id },
      data: { status: "left" },
    });
    await pg.db.$executeRawUnsafe(
      `INSERT INTO account_members (account_id, user_id, role, status) VALUES ($1::uuid, $2, 'member', 'ACTIVE')`,
      team,
      stranger.id
    );

    expect(await resolveBillingAccountId(pg.db, stranger.id)).toBe(personal);
  });

  test("returns null for a user who owns nothing and belongs to nothing", async () => {
    const ghost = await createTestUser(pg.db);
    expect(await resolveBillingAccountId(pg.db, ghost.id)).toBeNull();
  });
});

describe("findActiveMembership", () => {
  test("a role outside the schema reads back as null, never as owner", async () => {
    const owner = await createTestUser(pg.db);
    const odd = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id);
    const team = await ownedAccountId(owner.id);

    await pg.db.$executeRawUnsafe(
      `INSERT INTO account_members (account_id, user_id, role, status) VALUES ($1::uuid, $2, 'admin', 'active')`,
      team,
      odd.id
    );

    const membership = await findActiveMembership(pg.db, odd.id);
    expect(membership).toEqual({ accountId: team, role: null });
    // The unparseable role must not cost the user their entitlement — which
    // account they bill against does not depend on their capacity on it.
    expect(await resolveBillingAccountId(pg.db, odd.id)).toBe(team);
  });
});

describe("isBillingAccountOwner", () => {
  test("owner true, member false, and an out-of-schema role fails closed", async () => {
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    const odd = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id);
    const team = await ownedAccountId(owner.id);
    await addTestMember(pg.db, team, member.id);
    await pg.db.$executeRawUnsafe(
      `INSERT INTO account_members (account_id, user_id, role, status) VALUES ($1::uuid, $2, 'admin', 'active')`,
      team,
      odd.id
    );

    expect(await isBillingAccountOwner(pg.db, owner.id)).toBe(true);
    expect(await isBillingAccountOwner(pg.db, member.id)).toBe(false);
    expect(await isBillingAccountOwner(pg.db, odd.id)).toBe(false);
  });

  // Every account carries an owner row today, but a user who predates the
  // backfill (or whose row was closed) still owns their own contract — refusing
  // them would lock a solo user out of cancelling their own subscription.
  test("a user with no membership row at all is an owner", async () => {
    const solo = await createTestUser(pg.db);
    await pg.db.productAccount.create({ data: { userId: solo.id } });
    expect(await pg.db.accountMember.count({ where: { userId: solo.id } })).toBe(0);

    expect(await isBillingAccountOwner(pg.db, solo.id)).toBe(true);
  });
});

describe("countOtherActiveMembers / listBillingAccountUserIds", () => {
  test("count excludes the asking owner and anyone who left", async () => {
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    const leaver = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id);
    const team = await ownedAccountId(owner.id);
    expect(await countOtherActiveMembers(pg.db, team, owner.id)).toBe(0);

    await addTestMember(pg.db, team, member.id);
    await addTestMember(pg.db, team, leaver.id);
    expect(await countOtherActiveMembers(pg.db, team, owner.id)).toBe(2);

    await pg.db.accountMember.updateMany({
      where: { accountId: team, userId: leaver.id },
      data: { status: "left", endedAt: new Date() },
    });
    expect(await countOtherActiveMembers(pg.db, team, owner.id)).toBe(1);
  });

  test("the fan-out set carries the owner even with no membership row of their own", async () => {
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id);
    const team = await ownedAccountId(owner.id);
    await addTestMember(pg.db, team, member.id);
    // An account provisioned before the owner-membership backfill: entitlement
    // still resolves to it by ownership, so the fan-out must still reach them.
    await pg.db.accountMember.deleteMany({ where: { accountId: team, userId: owner.id } });

    const ids = await listBillingAccountUserIds(pg.db, team);
    expect([...ids].sort()).toEqual([owner.id, member.id].sort());
  });

  test("no duplicate when the owner also holds a membership row", async () => {
    const owner = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id);
    const team = await ownedAccountId(owner.id);

    expect(await listBillingAccountUserIds(pg.db, team)).toEqual([owner.id]);
  });
});

describe("ensureOwnerMembership", () => {
  test("ensureProductAccount heals a missing owner row without stealing a member back", async () => {
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id);
    const team = await ownedAccountId(owner.id);
    const personal = await ensureProductAccount(pg.db, member.id);
    await addTestMember(pg.db, team, member.id);
    await pg.db.accountMember.deleteMany({ where: { accountId: team, userId: owner.id } });

    await ensureProductAccount(pg.db, owner.id);
    expect(
      await pg.db.accountMember.count({
        where: { accountId: team, userId: owner.id, status: "active", role: "owner" },
      })
    ).toBe(1);

    // Touching the member's own account is routine (every sign-in does it) and
    // must not resurrect an owner row that would win over their team seat.
    await ensureProductAccount(pg.db, member.id);
    expect(await resolveBillingAccountId(pg.db, member.id)).toBe(team);
    expect(
      await pg.db.accountMember.count({
        where: { accountId: personal.id, userId: member.id, status: "active" },
      })
    ).toBe(0);
  });
});

describe("activeSubscriptionForUser through membership", () => {
  test("a member reads the owner's subscription, not their own", async () => {
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    const ownerSub = await createTestSubscription(pg.db, owner.id, {
      tier: "pro",
      workerLimit: 7,
    });
    const memberSub = await createTestSubscription(pg.db, member.id, {
      tier: "trial",
      workerLimit: 2,
    });
    await addTestMember(pg.db, await ownedAccountId(owner.id), member.id);

    const resolved = await activeSubscriptionForUser(pg.db, member.id);
    expect(resolved?.id).toBe(ownerSub.id);
    expect(resolved?.id).not.toBe(memberSub.id);
    expect(resolved?.tier).toBe("pro");
    expect(resolved?.workerLimit).toBe(7);
  });

  test("a solo user still reads their own — Phase 2 is dark", async () => {
    const solo = await createTestUser(pg.db);
    const sub = await createTestSubscription(pg.db, solo.id, { tier: "trial", workerLimit: 3 });

    const resolved = await activeSubscriptionForUser(pg.db, solo.id);
    expect(resolved?.id).toBe(sub.id);
    expect(resolved?.workerLimit).toBe(3);
  });

  test("a member whose team has no active subscription does not fall back to their own", async () => {
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id, { status: "canceled" });
    await createTestSubscription(pg.db, member.id, { tier: "pro" });
    await addTestMember(pg.db, await ownedAccountId(owner.id), member.id);

    expect(await activeSubscriptionForUser(pg.db, member.id)).toBeNull();
  });
});
