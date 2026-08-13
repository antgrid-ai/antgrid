import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import {
  addTestMember,
  createTestSession,
  createTestSubscription,
  createTestUser,
} from "../helpers/fixtures.js";
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

function capture(): { sent: Sent[]; sendEmail: SendEmail } {
  const sent: Sent[] = [];
  return {
    sent,
    sendEmail: async (args) => {
      sent.push(args);
    },
  };
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

async function getTeam(app: TestApp, cookie?: string): Promise<Response> {
  return app.request("/team", { headers: cookie ? { cookie } : {} });
}

/** The page as a reader sees it. Numbers on this page are split across a stat
 *  value and its unit span, so asserting on markup would pass while showing the
 *  reader nothing — compare the rendered words instead. */
function readable(html: string): string {
  return html
    .replace(/<[^>]*>/g, " ")
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ")
    .trim();
}

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

describe("GET /team — the owner's view", () => {
  test("reports seats, the people holding them, and the invitations that promise the rest", async () => {
    const { sendEmail } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { owner, accountId, cookie } = await ownerWithSeats(4);
    const member = await createTestUser(pg.db, "seated@example.com");
    await addTestMember(pg.db, accountId, member.id);
    await post(app, "/ui/team/invite", { email: "waiting@example.com" }, cookie);

    const res = await getTeam(app, cookie);

    expect(res.status).toBe(200);
    const html = await res.text();
    const text = readable(html);

    // The meter counts seat HOLDERS — owner plus member — and never folds the
    // pending invitation into the same number, which is why it is reported
    // beside it rather than added to it.
    expect(text).toContain("Seats used 2 / 4");
    expect(text).toContain("Pending invites 1");

    expect(text).toContain(owner.email);
    expect(text).toContain("seated@example.com");
    expect(text).toContain("waiting@example.com");
    // The owner reading their own row must be able to tell which one is theirs.
    expect(text).toContain("(you)");
    // Both per-invite verbs are reachable, or a mistyped address is unfixable.
    expect(html).toContain('action="/ui/team/invite"');
    expect(html).toContain("/revoke");
    expect(html).toContain("/resend");
  });

  test("an over-subscribed account is told both numbers and handed a disabled form", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    // One seat, two holders: legal, and nobody is removed to make it fit.
    const { accountId, cookie } = await ownerWithSeats(1);
    const member = await createTestUser(pg.db);
    await addTestMember(pg.db, accountId, member.id);

    const text = readable(await (await getTeam(app, cookie)).text());

    expect(text).toContain("This account has 2 members on 1 seat.");
    expect(text).toContain("Seats used 2 / 1");
    // The form stays on the page so the reason sits with the control it blocks;
    // the fieldset is what refuses. The POST refuses again regardless.
    const html = await (await getTeam(app, cookie)).text();
    expect(html).toContain('<fieldset class="fieldset" disabled="">');
  });

  test("a notice the query string invents is not rendered", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const { cookie } = await ownerWithSeats(3);

    const res = await app.request("/team?invite=Your+password+has+expired", {
      headers: { cookie },
    });

    const text = readable(await res.text());
    expect(text).not.toContain("Your password has expired");
    // A known code still renders, so the guard above is the enum and not a
    // disabled banner.
    const ok = await app.request("/team?invite=sent", { headers: { cookie } });
    expect(readable(await ok.text())).toContain("Invitation sent.");
  });
});

describe("GET /team — a member's view", () => {
  test("names whose bill they are on and their own role, and nothing about the contract", async () => {
    const { sendEmail } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { owner, accountId, cookie: ownerCookie } = await ownerWithSeats(5);
    await post(app, "/ui/team/invite", { email: "pending@example.com" }, ownerCookie);
    const member = await createTestUser(pg.db, "member@example.com");
    await addTestMember(pg.db, accountId, member.id);
    const { cookie } = await createTestSession(pg.db, member.id);

    const res = await getTeam(app, cookie);

    expect(res.status).toBe(200);
    const html = await res.text();
    const text = readable(html);

    expect(text).toContain(owner.email);
    expect(text).toContain("Your role");
    expect(text).toContain("member");

    // No invite form, and no per-invite verb either: every one of these POSTs
    // answers a member with `forbidden`, so rendering them would be an offer the
    // server refuses.
    expect(html).not.toContain('action="/ui/team/invite"');
    expect(html).not.toContain("/revoke");
    expect(html).not.toContain("/resend");
    // Nothing about someone else's contract: not the meter, not the roster, not
    // who has been invited to it.
    expect(text).not.toContain("Seats used");
    expect(text).not.toContain("Pending invites");
    expect(text).not.toContain("pending@example.com");
  });
});

describe("GET /team — sign-in", () => {
  test("a signed-out request is sent to the login page", async () => {
    const { app } = buildTestApp(pg.db, pg.url);

    const res = await getTeam(app);

    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/login");
  });
});

describe("the team forms carry their own rate limits", () => {
  test("the send bucket refuses a loop, and is not shared with another owner", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { cookie } = await ownerWithSeats(20);

    for (let i = 0; i < 10; i++) {
      const res = await post(app, "/ui/team/invite", { email: `t${i}@example.com` }, cookie);
      expect(res.headers.get("location")).toBe("/team?invite=sent");
    }
    const refused = await post(app, "/ui/team/invite", { email: "eleventh@example.com" }, cookie);

    expect(refused.headers.get("location")).toBe("/team?invite=throttled");
    expect(sent).toHaveLength(10);
    expect(await pg.db.accountInvite.count({ where: { status: "pending" } })).toBe(10);

    // Keyed by owner: one team onboarding in a hurry must not silence another's.
    const other = await ownerWithSeats(5);
    const theirs = await post(app, "/ui/team/invite", { email: "fresh@example.com" }, other.cookie);
    expect(theirs.headers.get("location")).toBe("/team?invite=sent");
  });

  test("withdrawing is on its own budget, so an exhausted sender can still take an invite back", async () => {
    const { sendEmail } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { accountId, cookie } = await ownerWithSeats(3);
    await post(app, "/ui/team/invite", { email: "typo@exmaple.com" }, cookie);
    const invite = await pg.db.accountInvite.findFirstOrThrow({ where: { accountId } });

    // Nine more sends drain what the first one left.
    for (let i = 0; i < 9; i++) {
      await post(app, "/ui/team/invite", { email: `drain${i}@example.com` }, cookie);
    }
    const send = await post(app, "/ui/team/invite", { email: "late@example.com" }, cookie);
    const resend = await post(app, `/ui/team/invite/${invite.id}/resend`, {}, cookie);
    const revoke = await post(app, `/ui/team/invite/${invite.id}/revoke`, {}, cookie);

    expect(send.headers.get("location")).toBe("/team?invite=throttled");
    // Resending mails a third party on the same say-so, so it draws on the same
    // budget deliberately.
    expect(resend.headers.get("location")).toBe("/team?invite=throttled");
    expect(revoke.headers.get("location")).toBe("/team?invite=revoked");
    expect((await pg.db.accountInvite.findUniqueOrThrow({ where: { id: invite.id } })).status).toBe(
      "revoked"
    );
  });

  test("the withdraw bucket refuses a loop without spending the sender's", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { cookie } = await ownerWithSeats(3);

    for (let i = 0; i < 30; i++) {
      const res = await post(app, `/ui/team/invite/${crypto.randomUUID()}/revoke`, {}, cookie);
      expect(res.headers.get("location")).toBe("/team?invite=failed");
    }
    const refused = await post(app, `/ui/team/invite/${crypto.randomUUID()}/revoke`, {}, cookie);
    expect(refused.headers.get("location")).toBe("/team?invite=throttled");

    const send = await post(app, "/ui/team/invite", { email: "unaffected@example.com" }, cookie);
    expect(send.headers.get("location")).toBe("/team?invite=sent");
    expect(sent).toHaveLength(1);
  });
});

describe("the team forms are same-origin only", () => {
  test("a cross-origin withdraw is refused and the invitation survives", async () => {
    const { sendEmail } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { accountId, cookie } = await ownerWithSeats(3);
    await post(app, "/ui/team/invite", { email: "target@example.com" }, cookie);
    const invite = await pg.db.accountInvite.findFirstOrThrow({ where: { accountId } });

    const res = await app.request(`/ui/team/invite/${invite.id}/revoke`, {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        origin: "https://evil.example",
        cookie,
      },
      body: "",
    });

    expect(res.status).toBe(403);
    expect((await pg.db.accountInvite.findUniqueOrThrow({ where: { id: invite.id } })).status).toBe(
      "pending"
    );
  });

  test("a cross-origin resend is refused before any mail is sent", async () => {
    const { sendEmail, sent } = capture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail });
    const { accountId, cookie } = await ownerWithSeats(3);
    await post(app, "/ui/team/invite", { email: "target@example.com" }, cookie);
    const invite = await pg.db.accountInvite.findFirstOrThrow({ where: { accountId } });

    const res = await app.request(`/ui/team/invite/${invite.id}/resend`, {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        "sec-fetch-site": "cross-site",
        cookie,
      },
      body: "",
    });

    expect(res.status).toBe(403);
    expect(sent).toHaveLength(1);
  });
});
