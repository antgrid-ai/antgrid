import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import {
  addTestMember,
  createTestSession,
  createTestSubscription,
  createTestUser,
} from "../helpers/fixtures.js";
import { provisionProductAccountForUser } from "../../src/models/subscription.js";
import type { SendEmail } from "../../src/auth/email.js";

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

type Sent = { to: string; subject: string; text: string; clientReference?: string };

/** Captures what the router mailed. The invite body carries exactly one URL, so
 *  `inviteLink` can take the first it finds. */
function capture(): { sent: Sent[]; sendEmail: SendEmail } {
  const sent: Sent[] = [];
  return {
    sent,
    sendEmail: async (args) => {
      sent.push(args);
    },
  };
}

function inviteLink(mail: Sent): { id: string; token: string } {
  const match = mail.text.match(/https?:\/\/\S+/);
  if (!match) throw new Error(`no invite URL in mail: ${mail.text}`);
  const url = new URL(match[0]);
  return { id: url.searchParams.get("id") ?? "", token: url.searchParams.get("t") ?? "" };
}

type TestApp = ReturnType<typeof buildTestApp>["app"];

async function post(
  app: TestApp,
  path: string,
  body: Record<string, string>,
  cookie?: string
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

/** An owner with a live contract of `seats` seats, signed in. */
async function ownerWithSeats(seats: number) {
  const owner = await createTestUser(pg.db, `owner+${crypto.randomUUID()}@example.com`);
  await createTestSubscription(pg.db, owner.id, { seats });
  const account = await pg.db.productAccount.findUniqueOrThrow({
    where: { userId: owner.id },
    select: { id: true },
  });
  const { cookie } = await createTestSession(pg.db, owner.id);
  return { owner, accountId: account.id, cookie };
}

describe("POST /ui/team/invite — who may invite", () => {
  test("a member of the account is refused", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { accountId } = await ownerWithSeats(5);
    const member = await createTestUser(pg.db, "member@example.com");
    await addTestMember(pg.db, accountId, member.id);
    const { cookie } = await createTestSession(pg.db, member.id);

    const res = await post(app, "/ui/team/invite", { email: "outsider@example.com" }, cookie);

    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/team?invite=forbidden");
    expect(await pg.db.accountInvite.count()).toBe(0);
    expect(sent).toHaveLength(0);
  });

  test("a cross-origin POST is refused before anything is written", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { cookie } = await ownerWithSeats(5);

    const res = await app.request("/ui/team/invite", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        origin: "https://evil.example",
        cookie,
      },
      body: new URLSearchParams({ email: "victim@example.com" }).toString(),
    });

    expect(res.status).toBe(403);
    expect(await pg.db.accountInvite.count()).toBe(0);
  });
});

describe("POST /ui/team/invite — seat arithmetic", () => {
  test("pending invites count against the cap, so the second one on a single free seat is refused", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    // Two seats, one of them the owner's: exactly one free.
    const { cookie } = await ownerWithSeats(2);

    const first = await post(app, "/ui/team/invite", { email: "first@example.com" }, cookie);
    expect(first.headers.get("location")).toBe("/team?invite=sent");

    const second = await post(app, "/ui/team/invite", { email: "second@example.com" }, cookie);
    expect(second.headers.get("location")).toBe("/team?invite=seat_cap");

    expect(await pg.db.accountInvite.count({ where: { status: "pending" } })).toBe(1);
    expect(sent).toHaveLength(1);
  });

  test("an over-subscribed account is refused a new invite", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    // One seat, two holders — legal (nobody is ever removed to fit a number) and
    // only reachable by seating a member the fixtures put there directly.
    const { accountId, cookie } = await ownerWithSeats(1);
    const member = await createTestUser(pg.db);
    await addTestMember(pg.db, accountId, member.id);

    const res = await post(app, "/ui/team/invite", { email: "third@example.com" }, cookie);

    expect(res.headers.get("location")).toBe("/team?invite=over_subscribed");
    expect(await pg.db.accountInvite.count()).toBe(0);
    expect(sent).toHaveLength(0);
  });

  test("an account with no live contract is refused", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const owner = await createTestUser(pg.db);
    await createTestSubscription(pg.db, owner.id, { status: "canceled" });
    const { cookie } = await createTestSession(pg.db, owner.id);

    const res = await post(app, "/ui/team/invite", { email: "nobody@example.com" }, cookie);

    // provisionProductAccountForUser heals a promotional grant onto an account
    // whose only subscription is canceled, so the refusal here is the seat cap on
    // that one-seat grant, not the missing contract. Either way: no invite.
    expect(res.headers.get("location")).toBe("/team?invite=seat_cap");
    expect(await pg.db.accountInvite.count()).toBe(0);
  });
});

describe("the invitation mail", () => {
  test("states the cost of accepting and is namespaced for the bounce webhook", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { cookie } = await ownerWithSeats(3);

    await post(app, "/ui/team/invite", { email: "Invitee@Example.com" }, cookie);

    expect(sent).toHaveLength(1);
    const mail = sent[0]!;
    // Address is normalized before it is stored and mailed.
    expect(mail.to).toBe("invitee@example.com");
    expect(mail.text).toContain("CANCELS the subscription you hold today");
    expect(mail.text).toContain("free Pro grant you were never charged for");
    expect(mail.text).toContain("Leaving the team later does not bring it back");
    const { id } = inviteLink(mail);
    expect(mail.clientReference).toBe(`invite:${id}`);
  });

  test("a hard bounce lands on the invite, not silently on nothing", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, {
      sendEmail,
      envOverrides: { ZEPTOMAIL_WEBHOOK_SECRET: "wh-secret" },
    });
    const { cookie } = await ownerWithSeats(3);
    await post(app, "/ui/team/invite", { email: "typo@exmaple.com" }, cookie);
    const { id } = inviteLink(sent[0]!);

    const res = await app.request("/webhooks/zeptomail/wh-secret", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        event_name: ["hardbounce"],
        event_message: [{ email_info: { client_reference: `invite:${id}` } }],
      }),
    });

    expect(res.status).toBe(200);
    const row = await pg.db.accountInvite.findUniqueOrThrow({ where: { id } });
    expect(row.deliveryStatus).toBe("bounced");
  });
});

describe("GET /invite", () => {
  test("a signed-out visitor is told to sign in and is offered no accept control", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { cookie } = await ownerWithSeats(3);
    await post(app, "/ui/team/invite", { email: "guest@example.com" }, cookie);
    const { id, token } = inviteLink(sent[0]!);

    const res = await app.request(`/invite?id=${id}&t=${encodeURIComponent(token)}`);

    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("Sign in as guest@example.com");
    expect(html).not.toContain('action="/ui/team/invite/accept"');
    // The same warning the mail carries — the screen must not be the quieter of
    // the two places a Pro grant can be spent.
    expect(html).toContain("including a free Pro grant you were never charged for");
    expect(html).toContain("Leaving the team later does not bring it back");
  });

  test("a garbage link renders the dead-link page, never the accept form", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request(`/invite?id=${crypto.randomUUID()}&t=nope`);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("no longer valid");
    expect(html).not.toContain('action="/ui/team/invite/accept"');
  });
});

describe("POST /ui/team/invite/accept — acceptance proves nothing about an address", () => {
  test("a signed-out POST is refused and leaves emailVerified alone", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { cookie } = await ownerWithSeats(3);
    // The squatter: an unverified account holding the invited address. Accepting
    // must never be the thing that proves it.
    const squatted = await pg.db.user.create({
      data: {
        id: crypto.randomUUID(),
        email: "unproven@example.com",
        name: "unproven@example.com",
        emailVerified: false,
      },
      select: { id: true },
    });
    await post(app, "/ui/team/invite", { email: "unproven@example.com" }, cookie);
    const { id, token } = inviteLink(sent[0]!);

    const res = await post(app, "/ui/team/invite/accept", { id, token });

    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/login");
    const after = await pg.db.user.findUniqueOrThrow({ where: { id: squatted.id } });
    expect(after.emailVerified).toBe(false);
    expect(await pg.db.accountMember.count({ where: { userId: squatted.id } })).toBe(0);
    const invite = await pg.db.accountInvite.findUniqueOrThrow({ where: { id } });
    expect(invite.status).toBe("pending");
  });

  test("a signed-in user whose address differs is refused", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { accountId, cookie } = await ownerWithSeats(3);
    await post(app, "/ui/team/invite", { email: "intended@example.com" }, cookie);
    const { id, token } = inviteLink(sent[0]!);

    const bystander = await createTestUser(pg.db, "bystander@example.com");
    const session = await createTestSession(pg.db, bystander.id);
    const res = await post(app, "/ui/team/invite/accept", { id, token }, session.cookie);

    expect(res.status).toBe(302);
    // Back to the link, which re-derives the address-conflict screen rather than
    // showing an alert above a button that can never work for this account.
    expect(res.headers.get("location")).toContain("/invite?id=");
    expect(
      await pg.db.accountMember.count({ where: { accountId, userId: bystander.id } })
    ).toBe(0);
    const invite = await pg.db.accountInvite.findUniqueOrThrow({ where: { id } });
    expect(invite.status).toBe("pending");

    // And the screen says so in as many words.
    const page = await app.request(`/invite?id=${id}&t=${encodeURIComponent(token)}`, {
      headers: { cookie: session.cookie },
    });
    const html = await page.text();
    expect(html).toContain("signed in as bystander@example.com");
    expect(html).not.toContain('action="/ui/team/invite/accept"');
  });
});

describe("POST /ui/team/invite/accept — the happy path", () => {
  test("produces exactly one membership and cancels the invitee's own subscription", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { accountId, cookie } = await ownerWithSeats(2);
    const invitee = await createTestUser(pg.db, "joiner@example.com");
    // The pre-activation cohort: a promotional Pro grant nobody was charged for,
    // which accepting spends.
    const personal = await provisionProductAccountForUser(pg.db, invitee.id);
    const session = await createTestSession(pg.db, invitee.id);

    await post(app, "/ui/team/invite", { email: "joiner@example.com" }, cookie);
    const { id, token } = inviteLink(sent[0]!);

    const res = await post(app, "/ui/team/invite/accept", { id, token }, session.cookie);

    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/team?invite=accepted");

    const memberships = await pg.db.accountMember.findMany({
      where: { userId: invitee.id, status: "active" },
    });
    expect(memberships).toHaveLength(1);
    expect(memberships[0]!.accountId).toBe(accountId);
    expect(memberships[0]!.role).toBe("member");

    const personalSubs = await pg.db.subscription.findMany({
      where: { accountId: personal.id },
    });
    expect(personalSubs.every((s) => s.status !== "active")).toBe(true);

    const invite = await pg.db.accountInvite.findUniqueOrThrow({ where: { id } });
    expect(invite.status).toBe("accepted");
    expect(invite.resolvedAt).not.toBeNull();

    // emailVerified was true before and is untouched; nothing on this path writes it.
    const after = await pg.db.user.findUniqueOrThrow({ where: { id: invitee.id } });
    expect(after.emailVerified).toBe(true);
  });

  test("a second accept on a consumed invite is refused and adds no second membership", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { accountId, cookie } = await ownerWithSeats(2);
    const invitee = await createTestUser(pg.db, "replay@example.com");
    const session = await createTestSession(pg.db, invitee.id);
    await post(app, "/ui/team/invite", { email: "replay@example.com" }, cookie);
    const { id, token } = inviteLink(sent[0]!);

    await post(app, "/ui/team/invite/accept", { id, token }, session.cookie);
    const again = await post(app, "/ui/team/invite/accept", { id, token }, session.cookie);

    expect(again.status).toBe(302);
    expect(again.headers.get("location")).toContain("/invite?id=");
    expect(
      await pg.db.accountMember.count({ where: { accountId, status: "active" } })
    ).toBe(2);
  });

  test("an expired invite is refused", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { accountId, cookie } = await ownerWithSeats(2);
    const invitee = await createTestUser(pg.db, "late@example.com");
    const session = await createTestSession(pg.db, invitee.id);
    await post(app, "/ui/team/invite", { email: "late@example.com" }, cookie);
    const { id, token } = inviteLink(sent[0]!);
    // The TTL is a week; wind the clock rather than the test.
    await pg.db.accountInvite.update({
      where: { id },
      data: { expiresAt: new Date(Date.now() - 1000) },
    });

    const res = await post(app, "/ui/team/invite/accept", { id, token }, session.cookie);

    expect(res.headers.get("location")).toContain("/invite?id=");
    expect(
      await pg.db.accountMember.count({ where: { accountId, userId: invitee.id, status: "active" } })
    ).toBe(0);

    const page = await app.request(`/invite?id=${id}&t=${encodeURIComponent(token)}`, {
      headers: { cookie: session.cookie },
    });
    expect(await page.text()).toContain("no longer valid");
  });

  test("an invitee already paying for their own subscription is refused, not silently cancelled", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { cookie } = await ownerWithSeats(2);
    const invitee = await createTestUser(pg.db, "payer@example.com");
    // Not promotional: a subscription somebody actually bought, and there is no
    // refund path anywhere in this codebase.
    await createTestSubscription(pg.db, invitee.id);
    const session = await createTestSession(pg.db, invitee.id);
    await post(app, "/ui/team/invite", { email: "payer@example.com" }, cookie);
    const { id, token } = inviteLink(sent[0]!);

    const res = await post(app, "/ui/team/invite/accept", { id, token }, session.cookie);

    expect(res.headers.get("location")).toContain("error=has_paid_subscription");
    const personal = await pg.db.productAccount.findUniqueOrThrow({
      where: { userId: invitee.id },
      select: { id: true },
    });
    expect(
      await pg.db.subscription.count({ where: { accountId: personal.id, status: "active" } })
    ).toBe(1);
    // A refusal must not burn the invitation — cancelling their own plan and
    // retrying has to work.
    const invite = await pg.db.accountInvite.findUniqueOrThrow({ where: { id } });
    expect(invite.status).toBe("pending");
  });
});

describe("revoke and resend", () => {
  test("revoking prevents a later accept", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { accountId, cookie } = await ownerWithSeats(2);
    const invitee = await createTestUser(pg.db, "withdrawn@example.com");
    const session = await createTestSession(pg.db, invitee.id);
    await post(app, "/ui/team/invite", { email: "withdrawn@example.com" }, cookie);
    const { id, token } = inviteLink(sent[0]!);

    const revoked = await post(app, `/ui/team/invite/${id}/revoke`, {}, cookie);
    expect(revoked.headers.get("location")).toBe("/team?invite=revoked");

    const res = await post(app, "/ui/team/invite/accept", { id, token }, session.cookie);
    expect(res.headers.get("location")).toContain("/invite?id=");
    expect(
      await pg.db.accountMember.count({ where: { accountId, userId: invitee.id, status: "active" } })
    ).toBe(0);
    expect((await pg.db.accountInvite.findUniqueOrThrow({ where: { id } })).status).toBe("revoked");
  });

  test("a member cannot revoke, and cannot resend", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { accountId, cookie } = await ownerWithSeats(4);
    await post(app, "/ui/team/invite", { email: "pending@example.com" }, cookie);
    const { id } = inviteLink(sent[0]!);

    const member = await createTestUser(pg.db);
    await addTestMember(pg.db, accountId, member.id);
    const session = await createTestSession(pg.db, member.id);

    const revoke = await post(app, `/ui/team/invite/${id}/revoke`, {}, session.cookie);
    const resend = await post(app, `/ui/team/invite/${id}/resend`, {}, session.cookie);

    expect(revoke.headers.get("location")).toBe("/team?invite=forbidden");
    expect(resend.headers.get("location")).toBe("/team?invite=forbidden");
    expect((await pg.db.accountInvite.findUniqueOrThrow({ where: { id } })).status).toBe("pending");
    expect(sent).toHaveLength(1);
  });

  test("resending invalidates the token already in the invitee's inbox", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { accountId, cookie } = await ownerWithSeats(2);
    const invitee = await createTestUser(pg.db, "resent@example.com");
    const session = await createTestSession(pg.db, invitee.id);
    await post(app, "/ui/team/invite", { email: "resent@example.com" }, cookie);
    const first = inviteLink(sent[0]!);

    const res = await post(app, `/ui/team/invite/${first.id}/resend`, {}, cookie);
    expect(res.headers.get("location")).toBe("/team?invite=resent");
    expect(sent).toHaveLength(2);
    const second = inviteLink(sent[1]!);
    expect(second.id).toBe(first.id);
    expect(second.token).not.toBe(first.token);

    // The old link is dead the moment the new one is minted — two live tokens for
    // one seat is two ways in.
    const stale = await post(
      app,
      "/ui/team/invite/accept",
      { id: first.id, token: first.token },
      session.cookie
    );
    expect(stale.headers.get("location")).toContain("/invite?id=");
    expect(
      await pg.db.accountMember.count({ where: { accountId, userId: invitee.id, status: "active" } })
    ).toBe(0);

    const fresh = await post(
      app,
      "/ui/team/invite/accept",
      { id: second.id, token: second.token },
      session.cookie
    );
    expect(fresh.headers.get("location")).toBe("/team?invite=accepted");
  });
});
