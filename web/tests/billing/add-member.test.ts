import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser, createTestSubscription } from "../helpers/fixtures.js";
import { addAccountMember, AddMemberError } from "../../src/billing/add-member.js";
import {
  countActiveSeatHolders,
  resolveBillingAccountId,
} from "../../src/models/account-member.js";
import { ensureProductAccount } from "../../src/models/product-account.js";
import {
  activeSubscriptionForAccount,
  ensureDefaultSubscription,
  ensureFreeSubscription,
} from "../../src/models/subscription.js";
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

async function ownedAccountId(userId: string): Promise<string> {
  return (await pg.db.productAccount.findUniqueOrThrow({ where: { userId } })).id;
}

/** An account with a live contract, whose owner already occupies one of `seats`. */
async function team(seats: number): Promise<{ ownerId: string; accountId: string }> {
  const owner = await createTestUser(pg.db);
  await createTestSubscription(pg.db, owner.id, { seats });
  return { ownerId: owner.id, accountId: await ownedAccountId(owner.id) };
}

/** A user holding a personal account and its owner membership, and nothing else. */
async function invitee(): Promise<{ userId: string; personalId: string }> {
  const user = await createTestUser(pg.db);
  const account = await ensureProductAccount(pg.db, user.id);
  return { userId: user.id, personalId: account.id };
}

/** Asserting on `code` needs the instance, and a resolved call must fail the test
 *  rather than fall through to assertions on a value that was never thrown. */
async function refusal(p: Promise<unknown>): Promise<AddMemberError> {
  try {
    await p;
  } catch (e) {
    if (e instanceof AddMemberError) return e;
    throw e;
  }
  throw new Error("expected AddMemberError, but the call resolved");
}

describe("addAccountMember refusals", () => {
  test("a full team refuses the next member and names the seat count", async () => {
    const { accountId } = await team(1);
    const { userId } = await invitee();

    const err = await refusal(
      addAccountMember(pg.db, { accountId, userId, role: "member" })
    );
    expect(err.code).toBe("SEAT_CAP");
    expect(err.limit).toBe(1);
    expect(err.message).toContain("1/1");
    expect(await countActiveSeatHolders(pg.db, accountId)).toBe(1);
  });

  test("an invitee who pays for their own subscription is refused", async () => {
    const { accountId } = await team(3);
    const user = await createTestUser(pg.db);
    // Not promotional, plan pro_yearly, recurring — someone was charged.
    await createTestSubscription(pg.db, user.id);
    const personalId = await ownedAccountId(user.id);

    const err = await refusal(
      addAccountMember(pg.db, { accountId, userId: user.id, role: "member" })
    );
    expect(err.code).toBe("HAS_PAID_SUBSCRIPTION");

    // The whole point of refusing rather than cancelling: there is no refund path.
    expect(await activeSubscriptionForAccount(pg.db, personalId)).not.toBeNull();
    expect(await countActiveSeatHolders(pg.db, accountId)).toBe(1);
    expect(await resolveBillingAccountId(pg.db, user.id)).toBe(personalId);
  });

  test("an account with no live contract has no seat to give", async () => {
    const owner = await createTestUser(pg.db);
    const account = await pg.db.productAccount.create({ data: { userId: owner.id } });
    const { userId } = await invitee();

    const err = await refusal(
      addAccountMember(pg.db, { accountId: account.id, userId, role: "member" })
    );
    expect(err.code).toBe("NO_ACTIVE_SUBSCRIPTION");
  });

  test("joining the account you already bill against leaves that account's subscription alone", async () => {
    const { ownerId, accountId } = await team(3);

    const err = await refusal(
      addAccountMember(pg.db, { accountId, userId: ownerId, role: "member" })
    );
    expect(err.code).toBe("ALREADY_ON_THIS_ACCOUNT");
    // The cancel step is aimed at the joiner's personal account, which for a
    // self-join IS this one — a refusal that arrived late would have cancelled
    // the contract it was adding a seat to.
    expect(await activeSubscriptionForAccount(pg.db, accountId)).not.toBeNull();
    expect(await countActiveSeatHolders(pg.db, accountId)).toBe(1);
  });

  test("an existing member is refused rather than counted twice", async () => {
    const { accountId } = await team(3);
    const { userId } = await invitee();
    await addAccountMember(pg.db, { accountId, userId, role: "member" });

    const err = await refusal(
      addAccountMember(pg.db, { accountId, userId, role: "member" })
    );
    expect(err.code).toBe("ALREADY_ON_THIS_ACCOUNT");
    expect(await countActiveSeatHolders(pg.db, accountId)).toBe(2);
  });
});

describe("addAccountMember acceptance", () => {
  test("a promotional grant is spent, not orphaned", async () => {
    const { accountId } = await team(3);
    const { userId, personalId } = await invitee();
    const promo = await ensureDefaultSubscription(pg.db, personalId);
    expect(promo.promotional).toBe(true);
    expect(promo.tier).not.toBe("free");

    const { seatHolders } = await addAccountMember(pg.db, {
      accountId,
      userId,
      role: "member",
    });
    expect(seatHolders).toBe(2);

    // Grandfathered Pro is not a purchase, so it cannot refuse the invite — and
    // leaving it active would hand it back the moment they left the team.
    expect((await pg.db.subscription.findUniqueOrThrow({ where: { id: promo.id } })).status).toBe(
      "canceled"
    );
    expect(await activeSubscriptionForAccount(pg.db, personalId)).toBeNull();
    expect(await resolveBillingAccountId(pg.db, userId)).toBe(accountId);
  });

  test("a free row is cancelled on the way in", async () => {
    const { accountId } = await team(3);
    const { userId, personalId } = await invitee();
    const free = await ensureFreeSubscription(pg.db, personalId);
    expect(free.planId).toBe(PLAN_UUID.free);

    await addAccountMember(pg.db, { accountId, userId, role: "member" });

    expect((await pg.db.subscription.findUniqueOrThrow({ where: { id: free.id } })).status).toBe(
      "canceled"
    );
    expect(await activeSubscriptionForAccount(pg.db, personalId)).toBeNull();
  });

  test("the denormalized user.account_id follows the membership", async () => {
    const { accountId } = await team(3);
    const { userId, personalId } = await invitee();
    expect((await pg.db.user.findUniqueOrThrow({ where: { id: userId } })).accountId).toBe(
      personalId
    );

    await addAccountMember(pg.db, { accountId, userId, role: "member" });

    expect((await pg.db.user.findUniqueOrThrow({ where: { id: userId } })).accountId).toBe(
      accountId
    );
    expect(await resolveBillingAccountId(pg.db, userId)).toBe(accountId);
  });

  test("a member of another team is moved, not inserted alongside", async () => {
    const first = await team(3);
    const second = await team(3);
    const { userId } = await invitee();
    await addAccountMember(pg.db, { accountId: first.accountId, userId, role: "member" });

    // account_members_one_active_per_user_idx rejects a second active row, so
    // this call throwing is the regression.
    await addAccountMember(pg.db, { accountId: second.accountId, userId, role: "member" });

    expect(await pg.db.accountMember.count({ where: { userId, status: "active" } })).toBe(1);
    expect(await countActiveSeatHolders(pg.db, first.accountId)).toBe(1);
    expect(await countActiveSeatHolders(pg.db, second.accountId)).toBe(2);
    expect(await resolveBillingAccountId(pg.db, userId)).toBe(second.accountId);
  });

  test("rejoining a team you once left reuses the row the plain unique holds", async () => {
    const first = await team(3);
    const second = await team(3);
    const { userId } = await invitee();
    await addAccountMember(pg.db, { accountId: first.accountId, userId, role: "member" });
    await addAccountMember(pg.db, { accountId: second.accountId, userId, role: "member" });

    // account_members_account_user_key is a PLAIN unique on (account_id,
    // user_id): the `left` row from the first join is still there, so a create
    // would 23505 here.
    await addAccountMember(pg.db, { accountId: first.accountId, userId, role: "owner" });

    const rows = await pg.db.accountMember.findMany({
      where: { userId, accountId: first.accountId },
    });
    expect(rows).toHaveLength(1);
    expect(rows[0]!.status).toBe("active");
    expect(rows[0]!.role).toBe("owner");
    expect(rows[0]!.endedAt).toBeNull();
  });
});

describe("addAccountMember waivers", () => {
  test("the seat waiver builds the over-subscribed team no enforcing path can", async () => {
    const { accountId } = await team(1);
    const a = await invitee();
    const b = await invitee();

    await addAccountMember(pg.db, { accountId, userId: a.userId, role: "member" }, {
      seatCap: true,
    });
    const { seatHolders } = await addAccountMember(
      pg.db,
      { accountId, userId: b.userId, role: "member" },
      { seatCap: true }
    );

    expect(seatHolders).toBe(3);
    expect((await activeSubscriptionForAccount(pg.db, accountId))!.seats).toBe(1);
  });

  test("the paid-subscription waiver admits a dev-granted holder", async () => {
    const { accountId } = await team(3);
    const user = await createTestUser(pg.db);
    await createTestSubscription(pg.db, user.id);
    const personalId = await ownedAccountId(user.id);

    await addAccountMember(pg.db, { accountId, userId: user.id, role: "member" }, {
      paidSubscription: true,
    });

    expect(await activeSubscriptionForAccount(pg.db, personalId)).toBeNull();
    expect(await resolveBillingAccountId(pg.db, user.id)).toBe(accountId);
  });
});
