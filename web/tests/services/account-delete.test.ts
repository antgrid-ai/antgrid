import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession, createTestSubscription, createTestDevice, addTestMember } from "../helpers/fixtures.js";
import { createAuth } from "../../src/auth/better-auth.js";
import { createEmailSender } from "../../src/auth/email.js";
import { deleteUserAccount } from "../../src/services/account.js";
import { ensureFreeSubscription, provisionProductAccountForUser } from "../../src/models/subscription.js";
import { ensureProductAccount } from "../../src/models/product-account.js";
import { applySubscriptionEvent } from "../../src/billing/reducer.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

function authFor(db: typeof pg.db, url: string) {
  return createAuth({
    env: { BETTER_AUTH_SECRET: "antgrid-test-better-auth-secret-for-tests-only-not-prod",
           BETTER_AUTH_URL: "http://localhost:8787", PG_DATABASE_URL: url,
           GITHUB_CLIENT_ID: "gh", GITHUB_CLIENT_SECRET: "ghs",
           GOOGLE_CLIENT_ID: "gl", GOOGLE_CLIENT_SECRET: "gls",
           EMAIL_FROM: "Antgrid <no-reply@radhaai.org>", NODE_ENV: "test" } as never,
    db,
    sendEmail: createEmailSender({ zeptoToken: undefined, from: "x@y.z" }),
  });
}

describe("deleteUserAccount", () => {
  test("tombstones the user, deletes sessions, retains billing", async () => {
    const auth = authFor(pg.db, pg.url);
    const fakeRelay = { baseUrl: undefined, secret: undefined };

    const user = await createTestUser(pg.db, "alice@example.com");
    await createTestSession(pg.db, user.id);
    const account = await ensureProductAccount(pg.db, user.id);
    await ensureFreeSubscription(pg.db, account.id);
    await createTestDevice(pg.db, { userId: user.id, deviceId: "dev-alice-1" });

    // Seed the most sensitive credential rows directly (no fixture helper exists)
    // so their hard-delete is asserted — a regression dropping account/oauthClient
    // deleteMany would otherwise pass green.
    await pg.db.account.create({ data: {
      id: "acct-alice-1", accountId: "google-uid-1", providerId: "google", userId: user.id,
    }});
    await pg.db.oauthClient.create({ data: {
      id: "oc-alice-1", clientId: "client-alice-1", userId: user.id,
      scopes: [], redirectUris: [], postLogoutRedirectUris: [], contacts: [],
      grantTypes: [], responseTypes: [],
    }});
    await pg.db.oauthAccessToken.create({ data: {
      id: "oat-alice-1", token: "tok-alice-1", clientId: "client-alice-1",
      scopes: [], expiresAt: new Date(Date.now() + 3600_000), createdAt: new Date(),
    }});

    const result = await deleteUserAccount(pg.db, fakeRelay, auth, {
      userId: user.id, headers: new Headers(),
    });
    expect(result).toBe("deleted");

    const after = await pg.db.user.findUniqueOrThrow({ where: { id: user.id } });
    expect(after.email).toBe(`deleted+${user.id}@deleted.antgrid.invalid`);
    expect(after.name).toBe("Deleted user");

    expect(await pg.db.session.count({ where: { userId: user.id } })).toBe(0);

    // Credential rows hard-deleted (the most sensitive PII links).
    expect(await pg.db.account.count({ where: { userId: user.id } })).toBe(0);
    expect(await pg.db.oauthClient.count({ where: { userId: user.id } })).toBe(0);
    // OauthClient deletion cascades to its access tokens (schema onDelete: Cascade).
    expect(await pg.db.oauthAccessToken.count({ where: { clientId: "client-alice-1" } })).toBe(0);

    const acct = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
    expect(acct.deletedAt).not.toBeNull();
    // Billing rows retained but anonymized: subscription cancelled + provider ids nulled.
    expect(await pg.db.subscription.count({ where: { accountId: acct.id } })).toBeGreaterThan(0);
    const residual = await pg.db.subscription.findFirstOrThrow({ where: { accountId: acct.id } });
    expect(residual.status).toBe("canceled");
    expect(residual.providerSubscriptionId).toBeNull();
    expect(residual.providerTransactionId).toBeNull();
    // Device rows hard-deleted (the revoke loop ran + the tx delete fired).
    expect(await pg.db.device.count({ where: { userId: user.id } })).toBe(0);
  });

  test("blocks when a renewing paid subscription exists", async () => {
    const auth = authFor(pg.db, pg.url);
    const user = await createTestUser(pg.db, "bob@example.com");
    await createTestSubscription(pg.db, user.id, { tier: "pro" });

    const result = await deleteUserAccount(pg.db, { baseUrl: undefined, secret: undefined }, auth, {
      userId: user.id, headers: new Headers(),
    });
    expect(result).toBe("blocked_subscription");
    // User untouched
    const u = await pg.db.user.findUniqueOrThrow({ where: { id: user.id } });
    expect(u.email).toBe("bob@example.com");
  });

  test("the promotional grant every new account gets does not block deletion", async () => {
    const auth = authFor(pg.db, pg.url);
    const user = await createTestUser(pg.db, "promo@example.com");
    // The production path, not a hand-built row: this is what provisioning
    // hands every new user while checkout is disabled.
    const account = await provisionProductAccountForUser(pg.db, user.id);

    // Non-vacuity guard. The grant rides a PAID plan, which is the only reason
    // this case is interesting — were it ever switched to the free plan, the
    // slug test would carry it and this test would prove nothing.
    const granted = await pg.db.subscription.findFirstOrThrow({
      where: { accountId: account.id, status: "active" },
    });
    expect(granted.promotional).toBe(true);
    expect(granted.tier).toBe("pro");

    const result = await deleteUserAccount(pg.db, { baseUrl: undefined, secret: undefined }, auth, {
      userId: user.id, headers: new Headers(),
    });
    expect(result).toBe("deleted");
  });

  test("pending-cancel paid sub is fully cancelled and provider ids nulled on deletion", async () => {
    const auth = authFor(pg.db, pg.url);
    const fakeRelay = { baseUrl: undefined, secret: undefined };

    const user = await createTestUser(pg.db, "grace@example.com");
    // Seed a paid subscription that is pending-cancel: status active, cancelledAt in the future.
    // isPendingCancellation returns true → hasRenewingPaidSubscription returns false → deletion allowed.
    const sub = await createTestSubscription(pg.db, user.id, { tier: "pro" });
    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
    // Set cancelledAt to a future date and attach provider ids — simulating a pending-cancel paid sub.
    await pg.db.subscription.update({
      where: { id: sub.id },
      data: {
        cancelledAt: new Date(Date.now() + 30 * 24 * 3600 * 1000),
        providerSubscriptionId: "sub_pending_1",
        providerTransactionId: "txn_pending_1",
      },
    });

    const result = await deleteUserAccount(pg.db, fakeRelay, auth, {
      userId: user.id, headers: new Headers(),
    });
    // (a) Deletion succeeds.
    expect(result).toBe("deleted");
    const acct = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
    expect(acct.deletedAt).not.toBeNull();

    // (b) The residual subscription is fully cancelled with provider ids detached.
    const residual = await pg.db.subscription.findUniqueOrThrow({ where: { id: sub.id } });
    expect(residual.status).toBe("canceled");
    expect(residual.providerSubscriptionId).toBeNull();
    expect(residual.providerTransactionId).toBeNull();

    // (c) Zero active subscriptions remain for the account.
    const activeCount = await pg.db.subscription.count({
      where: { accountId: account.id, status: "active" },
    });
    expect(activeCount).toBe(0);
  });

  test("a provider-canceled paid sub (status canceled, provider ids still set) is fully detached on deletion", async () => {
    const auth = authFor(pg.db, pg.url);
    const fakeRelay = { baseUrl: undefined, secret: undefined };

    const user = await createTestUser(pg.db, "heidi@example.com");
    // Seed a paid sub, then move it to the terminal "canceled" state WITH provider
    // ids still attached — exactly what the billing reducer's cancel path leaves
    // behind (it sets status but does not null provider ids). Deletion is allowed
    // because no active paid sub remains; the residual row must still be detached.
    const sub = await createTestSubscription(pg.db, user.id, { tier: "pro" });
    await pg.db.subscription.update({
      where: { id: sub.id },
      data: {
        status: "canceled",
        cancelledAt: new Date(),
        providerSubscriptionId: "sub_canceled_1",
        providerTransactionId: "txn_canceled_1",
      },
    });

    const result = await deleteUserAccount(pg.db, fakeRelay, auth, {
      userId: user.id, headers: new Headers(),
    });
    expect(result).toBe("deleted");

    const residual = await pg.db.subscription.findUniqueOrThrow({ where: { id: sub.id } });
    expect(residual.status).toBe("canceled");
    expect(residual.providerSubscriptionId).toBeNull();
    expect(residual.providerTransactionId).toBeNull();
  });

  test("idempotent: second call on a tombstoned account returns deleted", async () => {
    const auth = authFor(pg.db, pg.url);
    const user = await createTestUser(pg.db, "carol@example.com");
    const account = await ensureProductAccount(pg.db, user.id);
    await ensureFreeSubscription(pg.db, account.id);

    const cfg = { baseUrl: undefined, secret: undefined };
    expect(await deleteUserAccount(pg.db, cfg, auth, { userId: user.id, headers: new Headers() })).toBe("deleted");
    expect(await deleteUserAccount(pg.db, cfg, auth, { userId: user.id, headers: new Headers() })).toBe("deleted");
  });

  test("a user with no ProductAccount is still tombstoned (deletedAt set), not just scrubbed", async () => {
    const auth = authFor(pg.db, pg.url);
    const user = await createTestUser(pg.db, "ivan@example.com");
    // No ensureProductAccount/subscription: simulate a user whose post-signup
    // provisioning never created a billing account.
    expect(await pg.db.productAccount.findUnique({ where: { userId: user.id } })).toBeNull();

    const result = await deleteUserAccount(pg.db, { baseUrl: undefined, secret: undefined }, auth, {
      userId: user.id, headers: new Headers(),
    });
    expect(result).toBe("deleted");

    const u = await pg.db.user.findUniqueOrThrow({ where: { id: user.id } });
    expect(u.email).toBe(`deleted+${user.id}@deleted.antgrid.invalid`);
    // A tombstoned account row now anchors the deletion (resurrection guard armed).
    const acct = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
    expect(acct.deletedAt).not.toBeNull();
  });
});

describe("deleteUserAccount by role", () => {
  const cfg = { baseUrl: undefined, secret: undefined };

  async function team(): Promise<{ ownerId: string; memberId: string; teamId: string }> {
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id, { tier: "pro" });
    // The member's own account is free — the paid, renewing row lives on the
    // team. That asymmetry is the whole point: it is what a delete guard
    // resolved through membership would wrongly read as the member's.
    const memberAccount = await ensureProductAccount(pg.db, member.id);
    await ensureFreeSubscription(pg.db, memberAccount.id);
    const teamAccount = await pg.db.productAccount.findUniqueOrThrow({
      where: { userId: owner.id },
    });
    await addTestMember(pg.db, teamAccount.id, member.id);
    return { ownerId: owner.id, memberId: member.id, teamId: teamAccount.id };
  }

  test("a member deletes their own user; the team is untouched and the seat is freed", async () => {
    const auth = authFor(pg.db, pg.url);
    const { ownerId, memberId, teamId } = await team();
    const personal = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: memberId } });
    const teamSubsBefore = await pg.db.subscription.findMany({ where: { accountId: teamId } });

    // The owner's renewing paid subscription is the one the member inherits;
    // resolving the block through membership would 409 them out for good.
    expect(
      await deleteUserAccount(pg.db, cfg, auth, { userId: memberId, headers: new Headers() })
    ).toBe("deleted");

    expect(
      (await pg.db.productAccount.findUniqueOrThrow({ where: { id: personal.id } })).deletedAt
    ).not.toBeNull();
    expect(
      (await pg.db.productAccount.findUniqueOrThrow({ where: { id: teamId } })).deletedAt
    ).toBeNull();
    const teamSubsAfter = await pg.db.subscription.findMany({ where: { accountId: teamId } });
    expect(teamSubsAfter).toEqual(teamSubsBefore);

    // Seat freed: nothing may still count a tombstoned user against the owner's
    // purchased cap, and the User row survives so the FK cascade never fires.
    expect(
      await pg.db.accountMember.count({ where: { userId: memberId, status: "active" } })
    ).toBe(0);
    const closed = await pg.db.accountMember.findFirstOrThrow({
      where: { userId: memberId, accountId: teamId },
    });
    expect(closed.status).toBe("left");
    expect(closed.endedAt).not.toBeNull();
    // Left set, it would point a scrubbed user at a live team forever.
    expect((await pg.db.user.findUniqueOrThrow({ where: { id: memberId } })).accountId).toBeNull();
    expect(
      await pg.db.accountMember.count({ where: { accountId: teamId, userId: ownerId, status: "active" } })
    ).toBe(1);
  });

  test("an owner with an active member is refused before anything is mutated", async () => {
    const auth = authFor(pg.db, pg.url);
    const { ownerId, teamId } = await team();

    expect(
      await deleteUserAccount(pg.db, cfg, auth, { userId: ownerId, headers: new Headers() })
    ).toBe("blocked_team");

    const account = await pg.db.productAccount.findUniqueOrThrow({ where: { id: teamId } });
    expect(account.deletedAt).toBeNull();
    expect(await pg.db.subscription.count({ where: { accountId: teamId, status: "active" } })).toBe(1);
    const owner = await pg.db.user.findUniqueOrThrow({ where: { id: ownerId } });
    expect(owner.email).not.toContain("deleted+");
  });

  // The block is keyed on the account being tombstoned, not on the one the
  // deleting user bills against — resolving it through membership would hand
  // this user a way to delete a team out from under its members.
  test("an owner who has since joined another team is still refused", async () => {
    const auth = authFor(pg.db, pg.url);
    const { ownerId, teamId } = await team();
    const otherOwner = await createTestUser(pg.db);
    await createTestSubscription(pg.db, otherOwner.id, { tier: "pro" });
    const otherTeam = await pg.db.productAccount.findUniqueOrThrow({
      where: { userId: otherOwner.id },
    });
    await addTestMember(pg.db, otherTeam.id, ownerId);

    expect(
      await deleteUserAccount(pg.db, cfg, auth, { userId: ownerId, headers: new Headers() })
    ).toBe("blocked_team");
    expect(
      (await pg.db.productAccount.findUniqueOrThrow({ where: { id: teamId } })).deletedAt
    ).toBeNull();
  });

  // The guard counts OTHER members. Counting the owner's own backfilled row and
  // testing `> 0` would refuse every solo owner while looking exactly right.
  test("an owner with no other members still deletes", async () => {
    const auth = authFor(pg.db, pg.url);
    const solo = await createTestUser(pg.db);
    const account = await ensureProductAccount(pg.db, solo.id);
    await ensureFreeSubscription(pg.db, account.id);
    expect(
      await pg.db.accountMember.count({ where: { accountId: account.id, status: "active" } })
    ).toBe(1);

    expect(
      await deleteUserAccount(pg.db, cfg, auth, { userId: solo.id, headers: new Headers() })
    ).toBe("deleted");
    expect(
      (await pg.db.productAccount.findUniqueOrThrow({ where: { id: account.id } })).deletedAt
    ).not.toBeNull();
    // Nothing holds an active membership on a tombstoned account — and a second
    // (idempotent) call must not heal one back into existence.
    expect(
      await pg.db.accountMember.count({ where: { accountId: account.id, status: "active" } })
    ).toBe(0);
    expect(
      await deleteUserAccount(pg.db, cfg, auth, { userId: solo.id, headers: new Headers() })
    ).toBe("deleted");
    expect(
      await pg.db.accountMember.count({ where: { accountId: account.id, status: "active" } })
    ).toBe(0);
  });
});

describe("DELETE /account/me", () => {
  test("200 deletes; session cookie is dead afterward", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "dave@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    const account = await ensureProductAccount(pg.db, user.id);
    await ensureFreeSubscription(pg.db, account.id);

    const res = await app.request("/account/me", { method: "DELETE", headers: { cookie } });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });

    // Cookie now invalid (session row deleted) → gate 401 on re-call.
    const again = await app.request("/account/me", { method: "DELETE", headers: { cookie } });
    expect(again.status).toBe(401);
  });

  test("409 when a renewing paid subscription exists", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "erin@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    await createTestSubscription(pg.db, user.id, { tier: "pro" });

    const res = await app.request("/account/me", { method: "DELETE", headers: { cookie } });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "SUBSCRIPTION_ACTIVE" });
  });

  test("409 TEAM_HAS_MEMBERS for an owner whose team still has a member", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    const { cookie } = await createTestSession(pg.db, owner.id);
    await createTestSubscription(pg.db, owner.id, { tier: "pro" });
    const teamAccount = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: owner.id } });
    await addTestMember(pg.db, teamAccount.id, member.id);

    const res = await app.request("/account/me", { method: "DELETE", headers: { cookie } });
    expect(res.status).toBe(409);
    // Distinct from SUBSCRIPTION_ACTIVE: the owner cannot clear this one by
    // cancelling, so the client must be able to tell the two refusals apart.
    expect(await res.json()).toEqual({ error: "TEAM_HAS_MEMBERS" });
  });

  test("a member's own DELETE /account/me succeeds while the team bills on", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const owner = await createTestUser(pg.db);
    const member = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id, { tier: "pro" });
    const teamAccount = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: owner.id } });
    const memberAccount = await ensureProductAccount(pg.db, member.id);
    await ensureFreeSubscription(pg.db, memberAccount.id);
    await addTestMember(pg.db, teamAccount.id, member.id);
    const { cookie } = await createTestSession(pg.db, member.id);

    const res = await app.request("/account/me", { method: "DELETE", headers: { cookie } });
    expect(res.status).toBe(200);
    expect(
      (await pg.db.productAccount.findUniqueOrThrow({ where: { id: teamAccount.id } })).deletedAt
    ).toBeNull();
    expect(
      await pg.db.subscription.count({ where: { accountId: teamAccount.id, status: "active" } })
    ).toBe(1);
  });

  test("401 without a session", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/account/me", { method: "DELETE" });
    expect(res.status).toBe(401);
  });
});

describe("webhook after deletion", () => {
  test("no-ops on a tombstoned account (no free-sub resurrection)", async () => {
    const auth = authFor(pg.db, pg.url);
    const user = await createTestUser(pg.db, "frank@example.com");
    // Use a free-tier account so deleteUserAccount succeeds without needing
    // a pending-cancel paid sub. After deletion, cancelActiveSubscriptions
    // marks the free sub as canceled (cancelledAt: null gate is met), leaving
    // zero active subscriptions.
    const account = await ensureProductAccount(pg.db, user.id);
    await ensureFreeSubscription(pg.db, account.id);
    await deleteUserAccount(pg.db, { baseUrl: undefined, secret: undefined }, auth, {
      userId: user.id, headers: new Headers(),
    });

    const before = await pg.db.subscription.count({
      where: { accountId: account.id, status: "active" },
    });
    // Expect 0 active subs after tombstone.
    expect(before).toBe(0);

    // A late "canceled" webhook arrives referencing this account by id/planId.
    // Without the guard, ensureFreeSubscription reactivates the canceled free sub.
    await applySubscriptionEvent(
      pg.db, { baseUrl: undefined, secret: undefined },
      { provider: "razorpay", type: "canceled", providerEventId: "evt_late_1",
        accountId: account.id, planId: "pro_yearly", customerId: "cust_1",
        providerSubscriptionId: "sub_late_1" } as never,
      {},
    );

    const afterActive = await pg.db.subscription.count({
      where: { accountId: account.id, status: "active" },
    });
    expect(afterActive).toBe(before); // unchanged — no free sub reactivated
  });

  test("ensureFreeSubscription refuses to resurrect a tombstoned account", async () => {
    const auth = authFor(pg.db, pg.url);
    const user = await createTestUser(pg.db, "judy@example.com");
    const account = await ensureProductAccount(pg.db, user.id);
    await ensureFreeSubscription(pg.db, account.id);
    await deleteUserAccount(pg.db, { baseUrl: undefined, secret: undefined }, auth, {
      userId: user.id, headers: new Headers(),
    });

    // A direct call to the shared provisioning helper must NOT reactivate/create.
    const sub = await ensureFreeSubscription(pg.db, account.id);
    expect(sub.status).toBe("canceled");
    expect(await pg.db.subscription.count({
      where: { accountId: account.id, status: "active" },
    })).toBe(0);
  });

  test("a late webhook for a deleted account is recorded so provider retries dedup", async () => {
    const auth = authFor(pg.db, pg.url);
    const user = await createTestUser(pg.db, "mallory@example.com");
    const account = await ensureProductAccount(pg.db, user.id);
    await ensureFreeSubscription(pg.db, account.id);
    await deleteUserAccount(pg.db, { baseUrl: undefined, secret: undefined }, auth, {
      userId: user.id, headers: new Headers(),
    });

    const cfg = { baseUrl: undefined, secret: undefined };
    const evt = { provider: "razorpay", type: "canceled", providerEventId: "evt_dedup_1",
      accountId: account.id, planId: "pro_yearly", customerId: "cust_1",
      providerSubscriptionId: "sub_dedup_1" } as never;
    const first = await applySubscriptionEvent(pg.db, cfg, evt, {});
    const second = await applySubscriptionEvent(pg.db, cfg, evt, {});
    expect(first.duplicate).toBe(false);
    expect(second.duplicate).toBe(true); // recorded on first → deduped on retry
  });
});
