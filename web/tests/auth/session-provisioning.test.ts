import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSubscription, addTestMember } from "../helpers/fixtures.js";

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

const PASSWORD = "provisioning-password";

/**
 * Sign up and verify, then hand back the user id. Goes through Better-Auth
 * rather than a fixture on purpose: `databaseHooks.user.create.after` and
 * `session.create.after` are the only callers of `provisionBillingAccount`, and
 * nothing else in the suite runs them.
 */
async function signUpVerified(
  auth: ReturnType<typeof buildTestApp>["auth"],
  email: string
): Promise<string> {
  const res = await auth.api.signUpEmail({ body: { email, password: PASSWORD, name: email } });
  const userId = res.user.id;
  await pg.db.user.update({ where: { id: userId }, data: { emailVerified: true } });
  return userId;
}

async function signIn(
  auth: ReturnType<typeof buildTestApp>["auth"],
  email: string
): Promise<void> {
  await auth.api.signInEmail({ body: { email, password: PASSWORD } });
}

describe("provisioning on sign-in", () => {
  test("a member's sign-ins do not re-grant on their orphan personal account", async () => {
    const { auth } = buildTestApp(pg.db, pg.url);
    const owner = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id, { tier: "pro" });
    const team = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: owner.id } });

    const email = "joiner@example.com";
    const memberId = await signUpVerified(auth, email);
    const personal = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: memberId } });
    expect(personal.id).not.toBe(team.id);

    await addTestMember(pg.db, team.id, memberId);
    // What accepting an invite costs: the personal grant is spent on join. An
    // account that still holds an active row would make this test vacuous —
    // ensureDefaultSubscription early-returns on one and the bug would not fire.
    await pg.db.subscription.updateMany({
      where: { accountId: personal.id, status: "active" },
      data: { status: "canceled", cancelledAt: new Date() },
    });
    const teamSubsBefore = await pg.db.subscription.count({ where: { accountId: team.id } });

    await signIn(auth, email);
    await signIn(auth, email);

    expect(
      await pg.db.subscription.count({ where: { accountId: personal.id, status: "active" } })
    ).toBe(0);
    expect(await pg.db.subscription.count({ where: { accountId: personal.id } })).toBe(1);
    // Membership never mutates the bill in the other direction either.
    expect(await pg.db.subscription.count({ where: { accountId: team.id } })).toBe(teamSubsBefore);
    const memberRow = await pg.db.user.findUniqueOrThrow({ where: { id: memberId } });
    expect(memberRow.accountId).toBe(team.id);
  });

  test("a solo user's sign-ins still restore the promotional grant", async () => {
    const { auth } = buildTestApp(pg.db, pg.url);
    const email = "solo@example.com";
    const userId = await signUpVerified(auth, email);
    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId } });
    // Every account carries an owner membership, so a guard keyed on "has a
    // membership" rather than "bills against someone else's account" would stop
    // provisioning for every user alive. This is that regression.
    await pg.db.subscription.updateMany({
      where: { accountId: account.id, status: "active" },
      data: { status: "canceled", cancelledAt: new Date() },
    });

    await signIn(auth, email);

    const active = await pg.db.subscription.findMany({
      where: { accountId: account.id, status: "active" },
    });
    expect(active).toHaveLength(1);
    expect(active[0]!.tier).toBe("pro");
    expect(active[0]!.promotional).toBe(true);
  });
});
