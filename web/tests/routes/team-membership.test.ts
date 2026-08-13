import { describe, test, expect, beforeAll, afterAll, beforeEach, afterEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import {
  addTestMember,
  createTestDevice,
  createTestSession,
  createTestSubscription,
  createTestUser,
} from "../helpers/fixtures.js";
import { resolveBillingAccountId } from "../../src/models/account-member.js";

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

const ORIGIN = "http://localhost:8787";

type TestApp = ReturnType<typeof buildTestApp>["app"];

async function post(
  app: TestApp,
  path: string,
  cookie?: string,
  body: Record<string, string> = {}
): Promise<Response> {
  return app.request(path, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      origin: ORIGIN,
      ...(cookie ? { cookie } : {}),
    },
    body: new URLSearchParams(body).toString(),
  });
}

/** An account with a live contract, its holder, and a signed-in cookie for them.
 *  The holder owns the ProductAccount, which is the fact every ACCOUNT_OWNER
 *  refusal below turns on. */
async function ownerWithSeats(seats: number) {
  const owner = await createTestUser(pg.db, `owner+${crypto.randomUUID()}@example.com`);
  const sub = await createTestSubscription(pg.db, owner.id, { seats });
  const account = await pg.db.productAccount.findUniqueOrThrow({
    where: { userId: owner.id },
    select: { id: true },
  });
  const { cookie } = await createTestSession(pg.db, owner.id);
  return { owner, accountId: account.id, subId: sub.id, cookie };
}

async function joinAs(accountId: string, role: "owner" | "member" = "member") {
  const user = await createTestUser(pg.db, `m+${crypto.randomUUID()}@example.com`);
  await addTestMember(pg.db, accountId, user.id, role);
  const { cookie } = await createTestSession(pg.db, user.id);
  return { user, cookie };
}

async function membershipOn(accountId: string, userId: string) {
  return pg.db.accountMember.findUniqueOrThrow({
    where: { accountId_userId: { accountId, userId } },
    select: { status: true, endedAt: true },
  });
}

/** Their own account — where `resolveBillingAccountId` must land them once the
 *  membership is closed. */
async function personalAccountOf(userId: string): Promise<string> {
  const row = await pg.db.productAccount.findUniqueOrThrow({
    where: { userId },
    select: { id: true },
  });
  return row.id;
}

describe("removing a member", () => {
  test("an owner removes someone, and that person bills against their own account again", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { accountId, cookie } = await ownerWithSeats(4);
    const { user: member } = await joinAs(accountId);
    expect(await resolveBillingAccountId(pg.db, member.id)).toBe(accountId);

    const res = await post(app, `/ui/team/members/${member.id}/remove`, cookie);

    expect(res.headers.get("location")).toBe("/team?invite=removed");
    const row = await membershipOn(accountId, member.id);
    expect(row.status).toBe("removed");
    expect(row.endedAt).not.toBeNull();
    // The point of the whole verb: entitlement resolves to them, not the team.
    expect(await resolveBillingAccountId(pg.db, member.id)).toBe(
      await personalAccountOf(member.id)
    );
    // And the denormalized pointer moved with it, or the next provisioning pass
    // reads a user still attached to an account they are not on.
    const user = await pg.db.user.findUniqueOrThrow({
      where: { id: member.id },
      select: { accountId: true },
    });
    expect(user.accountId).toBe(await personalAccountOf(member.id));
  });

  test("a member leaves under their own power, and lands in the same place", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { accountId } = await ownerWithSeats(4);
    const { user: member, cookie } = await joinAs(accountId);

    const res = await post(app, "/ui/team/leave", cookie);

    expect(res.headers.get("location")).toBe("/team?invite=left");
    // "left", not "removed": the status column is the only record of which of
    // the two happened.
    expect((await membershipOn(accountId, member.id)).status).toBe("left");
    expect(await resolveBillingAccountId(pg.db, member.id)).toBe(
      await personalAccountOf(member.id)
    );
  });

  test("a member cannot remove another member", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { accountId } = await ownerWithSeats(5);
    const { cookie } = await joinAs(accountId);
    const { user: victim } = await joinAs(accountId);

    const res = await post(app, `/ui/team/members/${victim.id}/remove`, cookie);

    expect(res.headers.get("location")).toBe("/team?invite=forbidden");
    expect((await membershipOn(accountId, victim.id)).status).toBe("active");
    expect(await resolveBillingAccountId(pg.db, victim.id)).toBe(accountId);
  });

  test("an owner cannot name a member of a team they are not on", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { cookie } = await ownerWithSeats(3);
    const stranger = await ownerWithSeats(3);
    const { user: theirs } = await joinAs(stranger.accountId);

    const res = await post(app, `/ui/team/members/${theirs.id}/remove`, cookie);

    // Scoped to the caller's own account, so a valid id from elsewhere is simply
    // not a member here — the parameter reaches across nothing.
    expect(res.headers.get("location")).toBe("/team?invite=not_a_member");
    expect((await membershipOn(stranger.accountId, theirs.id)).status).toBe("active");
  });
});

describe("the last owner", () => {
  test("cannot leave", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { owner, accountId, cookie } = await ownerWithSeats(3);
    await joinAs(accountId);

    const res = await post(app, "/ui/team/leave", cookie);

    expect(res.headers.get("location")).toBe("/team?invite=account_owner");
    expect((await membershipOn(accountId, owner.id)).status).toBe("active");
    expect(await resolveBillingAccountId(pg.db, owner.id)).toBe(accountId);
  });

  test("cannot be removed, not even by a second owner", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { owner, accountId } = await ownerWithSeats(3);
    const second = await joinAs(accountId, "owner");

    const res = await post(app, `/ui/team/members/${owner.id}/remove`, second.cookie);

    expect(res.headers.get("location")).toBe("/team?invite=account_owner");
    expect((await membershipOn(accountId, owner.id)).status).toBe("active");
  });

  test("cannot leave even when the account holder is elsewhere", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    // The holder joined someone else's team, which closed their owner row here —
    // the one reachable state in which this account's last owner is not its
    // holder, and the only one in which the guard is not the ACCOUNT_OWNER one.
    const { accountId } = await ownerWithSeats(3);
    const elsewhere = await ownerWithSeats(3);
    const holder = await pg.db.productAccount.findUniqueOrThrow({
      where: { id: accountId },
      select: { userId: true },
    });
    await addTestMember(pg.db, elsewhere.accountId, holder.userId);
    const only = await joinAs(accountId, "owner");

    const res = await post(app, "/ui/team/leave", only.cookie);

    expect(res.headers.get("location")).toBe("/team?invite=last_owner");
    expect((await membershipOn(accountId, only.user.id)).status).toBe("active");
  });

  test("two of them leaving at once produces one departure and one refusal", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { accountId } = await ownerWithSeats(5);
    const elsewhere = await ownerWithSeats(3);
    const holder = await pg.db.productAccount.findUniqueOrThrow({
      where: { id: accountId },
      select: { userId: true },
    });
    await addTestMember(pg.db, elsewhere.accountId, holder.userId);
    const a = await joinAs(accountId, "owner");
    const b = await joinAs(accountId, "owner");

    const [first, second] = await Promise.all([
      post(app, "/ui/team/leave", a.cookie),
      post(app, "/ui/team/leave", b.cookie),
    ]);

    // Either may win; both winning is the unrecoverable account the guard exists
    // to prevent, and the advisory lock is what makes the loser's owner count
    // include the winner's committed departure.
    expect([first, second].map((r) => r.headers.get("location")).sort()).toEqual([
      "/team?invite=last_owner",
      "/team?invite=left",
    ]);
    const stillOwners = await pg.db.accountMember.count({
      where: { accountId, status: "active", role: "owner" },
    });
    expect(stillOwners).toBe(1);
  });

  test("a second owner may leave while another remains", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { owner, accountId } = await ownerWithSeats(4);
    const second = await joinAs(accountId, "owner");

    const res = await post(app, "/ui/team/leave", second.cookie);

    expect(res.headers.get("location")).toBe("/team?invite=left");
    expect((await membershipOn(accountId, second.user.id)).status).toBe("left");
    expect((await membershipOn(accountId, owner.id)).status).toBe("active");
    expect(await resolveBillingAccountId(pg.db, second.user.id)).toBe(
      await personalAccountOf(second.user.id)
    );
  });
});

describe("membership never mutates the bill", () => {
  test("removing someone frees a seat and leaves the subscription exactly as it was", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { accountId, subId, cookie } = await ownerWithSeats(3);
    const { user: member } = await joinAs(accountId);
    const before = await pg.db.subscription.findUniqueOrThrow({ where: { id: subId } });

    await post(app, `/ui/team/members/${member.id}/remove`, cookie);

    const after = await pg.db.subscription.findUniqueOrThrow({ where: { id: subId } });
    // The provider is the source of truth for what is billed. A helpful
    // `seats--` here would be a refund with no path to issue it, and it is the
    // single easiest thing to add by accident.
    expect(after.seats).toBe(3);
    expect(after.seats).toBe(before.seats);
    expect(after.status).toBe(before.status);
    expect(after.cancelledAt).toBe(before.cancelledAt);
    // The seat is free in the only sense that matters: the headcount dropped.
    expect(await pg.db.accountMember.count({ where: { accountId, status: "active" } })).toBe(1);
  });
});

describe("a departing member's devices", () => {
  const realFetch = globalThis.fetch;
  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  const RELAY_URL = "http://relay.test.local:9999";
  const RELAY_SECRET = "relay-internal-secret-for-tests";

  function armedApp() {
    const calls: { url: string; body: unknown }[] = [];
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input.toString();
      if (!url.startsWith(RELAY_URL)) return realFetch(input as RequestInfo, init);
      calls.push({ url, body: JSON.parse(String(init?.body ?? "{}")) });
      return new Response("{}", { status: 200 });
    }) as typeof fetch;
    const { app } = buildTestApp(pg.db, pg.url, {
      envOverrides: { RELAY_INTERNAL_URL: RELAY_URL, RELAY_INTERNAL_SECRET: RELAY_SECRET },
    });
    return { app, calls };
  }

  test("are revoked one by one, not expired, and stay registered to them", async () => {
    const { app, calls } = armedApp();
    const { accountId, cookie } = await ownerWithSeats(4);
    const { user: member } = await joinAs(accountId);
    await createTestDevice(pg.db, { userId: member.id, deviceId: "laptop", kind: "agent" });
    await createTestDevice(pg.db, { userId: member.id, deviceId: "phone", kind: "app" });

    const res = await post(app, `/ui/team/members/${member.id}/remove`, cookie);

    expect(res.headers.get("location")).toBe("/team?invite=removed");
    // Revoke, per device. Expiring drops the license cache and closes the
    // sockets, but the device re-mints seconds later — fine for a downgrade,
    // useless for a removal.
    expect(calls.map((c) => c.url)).toEqual([
      `${RELAY_URL}/internal/revoke`,
      `${RELAY_URL}/internal/revoke`,
    ]);
    expect(calls.some((c) => c.url.endsWith("/internal/expire"))).toBe(false);
    // Account-scoped: the same deviceId legitimately exists under two accounts,
    // and an unscoped revoke would sign the other one out.
    for (const call of calls) {
      expect(call.body).toMatchObject({ userId: member.id });
    }
    expect(calls.map((c) => (c.body as { deviceId: string }).deviceId).sort()).toEqual([
      "laptop",
      "phone",
    ]);

    // Their own registrations follow them to their own account. Marking the rows
    // revoked would make leaving a team cost someone their machines.
    const rows = await pg.db.device.findMany({
      where: { userId: member.id },
      select: { revokedAt: true },
    });
    expect(rows).toHaveLength(2);
    expect(rows.every((d) => d.revokedAt === null)).toBe(true);
  });

  test("a refused removal pushes nothing", async () => {
    const { app, calls } = armedApp();
    const { owner, accountId } = await ownerWithSeats(3);
    await createTestDevice(pg.db, { userId: owner.id, deviceId: "holder-laptop" });
    const second = await joinAs(accountId, "owner");

    const res = await post(app, `/ui/team/members/${owner.id}/remove`, second.cookie);

    expect(res.headers.get("location")).toBe("/team?invite=account_owner");
    expect(calls).toHaveLength(0);
  });
});

describe("the membership forms are same-origin only", () => {
  test("a cross-origin removal is refused and the membership survives", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { accountId, cookie } = await ownerWithSeats(4);
    const { user: member } = await joinAs(accountId);

    const res = await app.request(`/ui/team/members/${member.id}/remove`, {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        origin: "https://evil.example",
        cookie,
      },
      body: "",
    });

    expect(res.status).toBe(403);
    expect((await membershipOn(accountId, member.id)).status).toBe("active");
  });

  test("a cross-origin leave is refused", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { accountId } = await ownerWithSeats(4);
    const { user: member, cookie } = await joinAs(accountId);

    const res = await app.request("/ui/team/leave", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        "sec-fetch-site": "cross-site",
        cookie,
      },
      body: "",
    });

    expect(res.status).toBe(403);
    expect((await membershipOn(accountId, member.id)).status).toBe("active");
  });
});

describe("the team page offers only the departures the server will honour", () => {
  test("the owner's roster offers Remove for a member and not for the account holder", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { owner, accountId, cookie } = await ownerWithSeats(4);
    const { user: member } = await joinAs(accountId);

    const html = await (await app.request("/team", { headers: { cookie } })).text();

    expect(html).toContain(`/ui/team/members/${member.id}/remove`);
    expect(html).not.toContain(`/ui/team/members/${owner.id}/remove`);
    // The holder can never leave, so the card that offers it is absent too.
    expect(html).not.toContain('action="/ui/team/leave"');
  });

  test("a member is offered the way out", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { accountId } = await ownerWithSeats(4);
    const { cookie } = await joinAs(accountId);

    const html = await (await app.request("/team", { headers: { cookie } })).text();

    expect(html).toContain('action="/ui/team/leave"');
    // A member manages nobody, so no roster and no remove verb reaches them.
    expect(html).not.toContain("/remove");
  });

  test("a second owner is offered it too", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { accountId } = await ownerWithSeats(4);
    const second = await joinAs(accountId, "owner");

    const html = await (await app.request("/team", { headers: { cookie: second.cookie } })).text();

    expect(html).toContain('action="/ui/team/leave"');
  });
});
