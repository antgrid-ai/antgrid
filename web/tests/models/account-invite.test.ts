import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser } from "../helpers/fixtures.js";
import { ensureProductAccount } from "../../src/models/product-account.js";
import {
  checkInviteToken,
  countPendingInvites,
  createInvite,
  expireStalePendingInvites,
  findPendingInviteById,
  findPendingInviteByIdWithHash,
  generateInviteToken,
  listPendingInvites,
  markInviteAccepted,
  refreshInviteToken,
  revokeInvite,
} from "../../src/models/account-invite.js";

const SECRET = "invite-hmac-secret-for-tests";

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

type Team = { accountId: string; ownerId: string };

async function team(): Promise<Team> {
  const owner = await createTestUser(pg.db);
  const account = await ensureProductAccount(pg.db, owner.id);
  return { accountId: account.id, ownerId: owner.id };
}

async function invite(
  t: Team,
  email = "ada@test.local",
  token = generateInviteToken()
): Promise<{ id: string; token: string }> {
  const row = await createInvite(pg.db, {
    accountId: t.accountId,
    email,
    role: "member",
    createdBy: t.ownerId,
    token,
    secret: SECRET,
  });
  return { id: row.id, token };
}

async function backdate(id: string): Promise<void> {
  await pg.db.accountInvite.update({
    where: { id },
    data: { expiresAt: new Date(Date.now() - 1000) },
  });
}

describe("invite tokens", () => {
  test("only the HMAC is stored — the token itself never lands in a column", async () => {
    const t = await team();
    const { id, token } = await invite(t);

    const stored = await pg.db.accountInvite.findUniqueOrThrow({ where: { id } });
    expect(new TextDecoder().decode(stored.tokenHash)).not.toContain(token);
    expect(JSON.stringify(stored)).not.toContain(token);
    expect(stored.tokenHash).toHaveLength(32);
  });

  test("the presented token verifies, and nothing else does", async () => {
    const t = await team();
    const { id, token } = await invite(t);
    const row = await findPendingInviteByIdWithHash(pg.db, id);

    expect(checkInviteToken(row!.tokenHash, token, SECRET)).toBe(true);
    expect(checkInviteToken(row!.tokenHash, generateInviteToken(), SECRET)).toBe(false);
    // A rotated signing secret must invalidate outstanding links rather than
    // quietly keep accepting them.
    expect(checkInviteToken(row!.tokenHash, token, `${SECRET}-rotated`)).toBe(false);
  });

  test("the public projection carries no hash to leak", async () => {
    const t = await team();
    const { id } = await invite(t);
    const row = await findPendingInviteById(pg.db, id);
    expect(row).not.toBeNull();
    expect(row).not.toHaveProperty("tokenHash");
  });

  test("a resend retires the previous link", async () => {
    const t = await team();
    const { id, token } = await invite(t);
    const next = generateInviteToken();

    const refreshed = await refreshInviteToken(pg.db, {
      id,
      accountId: t.accountId,
      token: next,
      secret: SECRET,
    });
    expect(refreshed).not.toBeNull();

    const row = await findPendingInviteByIdWithHash(pg.db, id);
    expect(checkInviteToken(row!.tokenHash, next, SECRET)).toBe(true);
    expect(checkInviteToken(row!.tokenHash, token, SECRET)).toBe(false);
  });

  test("a resend cannot revive a revoked invite", async () => {
    const t = await team();
    const { id } = await invite(t);
    await revokeInvite(pg.db, t.accountId, id);

    expect(
      await refreshInviteToken(pg.db, {
        id,
        accountId: t.accountId,
        token: generateInviteToken(),
        secret: SECRET,
      })
    ).toBeNull();
  });

  test("a resend aimed at another team's invite id does nothing", async () => {
    const mine = await team();
    const theirs = await team();
    const { id, token } = await invite(theirs);

    expect(
      await refreshInviteToken(pg.db, {
        id,
        accountId: mine.accountId,
        token: generateInviteToken(),
        secret: SECRET,
      })
    ).toBeNull();
    const row = await findPendingInviteByIdWithHash(pg.db, id);
    expect(checkInviteToken(row!.tokenHash, token, SECRET)).toBe(true);
  });
});

describe("invite lifecycle", () => {
  test("acceptance is single-use", async () => {
    const t = await team();
    const { id } = await invite(t);

    expect(await markInviteAccepted(pg.db, id)).toBe(true);
    // The second click of the same link, or a second tab that read the invite
    // before the first one committed.
    expect(await markInviteAccepted(pg.db, id)).toBe(false);

    const row = await pg.db.accountInvite.findUniqueOrThrow({ where: { id } });
    expect(row.status).toBe("accepted");
    expect(row.resolvedAt).not.toBeNull();
  });

  test("an expired invite is neither readable nor acceptable", async () => {
    const t = await team();
    const { id } = await invite(t);
    await backdate(id);

    expect(await findPendingInviteById(pg.db, id)).toBeNull();
    expect(await findPendingInviteByIdWithHash(pg.db, id)).toBeNull();
    expect(await markInviteAccepted(pg.db, id)).toBe(false);
    expect(await listPendingInvites(pg.db, t.accountId)).toHaveLength(0);
    expect(await countPendingInvites(pg.db, t.accountId)).toBe(0);
  });

  test("revoking is account-scoped and one-way", async () => {
    const mine = await team();
    const theirs = await team();
    const { id } = await invite(theirs);

    expect(await revokeInvite(pg.db, mine.accountId, id)).toBe(false);
    expect(await revokeInvite(pg.db, theirs.accountId, id)).toBe(true);
    expect(await revokeInvite(pg.db, theirs.accountId, id)).toBe(false);
    expect(await markInviteAccepted(pg.db, id)).toBe(false);
    expect(await countPendingInvites(pg.db, theirs.accountId)).toBe(0);
  });

  test("outstanding invites are counted per account, terminal ones are not", async () => {
    const t = await team();
    const other = await team();
    const live = await invite(t, "live@test.local");
    const revoked = await invite(t, "revoked@test.local");
    const lapsed = await invite(t, "lapsed@test.local");
    await invite(other, "elsewhere@test.local");

    await revokeInvite(pg.db, t.accountId, revoked.id);
    await backdate(lapsed.id);

    expect(await countPendingInvites(pg.db, t.accountId)).toBe(1);
    const pending = await listPendingInvites(pg.db, t.accountId);
    expect(pending.map((r) => r.id)).toEqual([live.id]);
    expect(pending[0]!.role).toBe("member");
  });
});

describe("account_invites constraints", () => {
  test("a second outstanding invite to the same address is rejected, case-insensitively", async () => {
    const t = await team();
    await invite(t, "Ada@test.local");

    // CITEXT plus the partial unique: re-inviting the same human under a
    // different capitalisation must not buy a second seat's worth of pending.
    await expect(invite(t, "ada@TEST.local")).rejects.toThrow();
  });

  test("the rejection is the partial index, not a plain unique", async () => {
    const t = await team();
    await invite(t, "ada@test.local");

    // Raw insert so the assertion can name the index — Prisma normalizes a 23505
    // into a field list and buries the constraint name in adapter internals, and
    // the name is the only evidence the raw-SQL DDL shipped.
    const err = await pg.db
      .$executeRawUnsafe(
        `INSERT INTO account_invites (account_id, email, role, status, token_hash, created_by, expires_at)
         VALUES ($1::uuid, $2, 'member', 'pending', '\\x00'::bytea, $3, now() + interval '1 day')`,
        t.accountId,
        "ADA@test.local",
        t.ownerId
      )
      .then(
        () => null,
        (e: unknown) => e
      );
    expect(String(err)).toContain("account_invites_one_pending_per_email_idx");
  });

  test("a terminal invite frees the address again", async () => {
    const t = await team();
    const first = await invite(t, "ada@test.local");
    await revokeInvite(pg.db, t.accountId, first.id);

    // The index keys on status alone, so only a terminal status releases the slot.
    const second = await invite(t, "ada@test.local");
    expect(second.id).not.toBe(first.id);
    expect(await countPendingInvites(pg.db, t.accountId)).toBe(1);
  });

  test("sweeping lapsed invites releases the slot the index still holds", async () => {
    const t = await team();
    const stale = await invite(t, "ada@test.local");
    await backdate(stale.id);

    // A lapsed invite is invisible to every read and still owns the address:
    // the partial predicate cannot reference now(), so without the sweep the
    // re-invite an owner is entitled to send fails on 23505.
    await expect(invite(t, "ada@test.local")).rejects.toThrow();

    expect(await expireStalePendingInvites(pg.db, t.accountId)).toBe(1);
    expect(
      (await pg.db.accountInvite.findUniqueOrThrow({ where: { id: stale.id } })).status
    ).toBe("expired");

    const fresh = await invite(t, "ada@test.local");
    expect(fresh.id).not.toBe(stale.id);
  });

  test("the sweep leaves live invites and other accounts alone", async () => {
    const t = await team();
    const other = await team();
    await invite(t, "live@test.local");
    const theirStale = await invite(other, "stale@test.local");
    await backdate(theirStale.id);

    expect(await expireStalePendingInvites(pg.db, t.accountId)).toBe(0);
    expect(await countPendingInvites(pg.db, t.accountId)).toBe(1);
    expect(
      (await pg.db.accountInvite.findUniqueOrThrow({ where: { id: theirStale.id } })).status
    ).toBe("pending");
  });

  test("a role outside the schema reads as null rather than reaching a membership", async () => {
    const t = await team();
    const { id } = await invite(t);
    await pg.db.accountInvite.update({ where: { id }, data: { role: "superuser" } });

    expect((await findPendingInviteById(pg.db, id))!.role).toBeNull();
  });

  test("invites die with the account that issued them", async () => {
    const t = await team();
    await invite(t);

    await pg.db.productAccount.delete({ where: { id: t.accountId } });

    expect(await pg.db.accountInvite.count({ where: { accountId: t.accountId } })).toBe(0);
  });
});
