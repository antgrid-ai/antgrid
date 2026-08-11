import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { createTestUser, createTestSession } from "../helpers/fixtures.js";
import { CREDENTIAL_PROVIDER_ID } from "../../src/models/credential.js";

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

type TestApp = ReturnType<typeof buildTestApp>["app"];
type CapturedEmail = { to: string; subject: string; text: string; html?: string };

/** Above MIN_PASSWORD_LENGTH (12) — the forms reject anything shorter. */
const PASSWORD = "first-password-one";
const NEW_PASSWORD = "second-password-two";

function makeCapture() {
  const captured: CapturedEmail[] = [];
  return { captured, sendEmail: async (a: CapturedEmail) => void captured.push(a) };
}

/** Most recent link out of the email whose subject matches — the flows re-send
 *  (sendOnSignIn, the resend button), so the newest is the live one. */
function linkFrom(captured: CapturedEmail[], subjectFragment: string): string {
  const email = [...captured].reverse().find((e) => e.subject.includes(subjectFragment));
  expect(email, `no email with subject containing "${subjectFragment}"`).toBeDefined();
  return email!.text.match(/https?:\/\/[^\s]+/)![0];
}

/** The session cookie alone, ignoring a clearing `...=;` header. */
function sessionCookie(res: Response): string | null {
  for (const sc of res.headers.getSetCookie()) {
    const m = sc.match(/^better-auth\.session_token=[^;]+/);
    if (m) return m[0];
  }
  return null;
}

function post(
  app: TestApp,
  path: string,
  fields: Record<string, string>,
  cookie?: string
) {
  const headers: Record<string, string> = {
    "content-type": "application/x-www-form-urlencoded",
  };
  if (cookie) headers.cookie = cookie;
  return app.request(path, {
    method: "POST",
    headers,
    body: new URLSearchParams(fields).toString(),
    redirect: "manual",
  });
}

/** Redirect target as a parsed URL, so assertions read decoded query values
 *  rather than guessing at URLSearchParams' `+`-for-space encoding. */
function location(res: Response): URL {
  const loc = res.headers.get("location");
  expect(loc, "expected a redirect").not.toBeNull();
  return new URL(loc!, "http://localhost");
}

function signIn(app: TestApp, email: string, password: string) {
  return post(app, "/ui/login/password", { email, password });
}

/** Sign up, open the emailed link, return the session cookie
 *  `autoSignInAfterVerification` mints. */
async function signUpAndVerify(
  app: TestApp,
  captured: CapturedEmail[],
  email: string,
  password = PASSWORD
): Promise<string> {
  const res = await post(app, "/ui/signup", {
    email,
    password,
    confirmPassword: password,
  });
  expect(res.status).toBe(302);
  const verified = await app.request(linkFrom(captured, "Verify"), {
    redirect: "manual",
  });
  expect(verified.status).toBe(302);
  const cookie = sessionCookie(verified);
  expect(cookie).not.toBeNull();
  return cookie!;
}

describe("password sign-up", () => {
  test("creates no session until the emailed link is opened", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });

    const res = await post(app, "/ui/signup", {
      email: "Nina@Example.com",
      password: PASSWORD,
      confirmPassword: PASSWORD,
    });
    expect(res.status).toBe(302);
    const loc = location(res);
    expect(loc.pathname).toBe("/login/check-email");
    expect(loc.searchParams.get("email")).toBe("nina@example.com");
    // autoSignIn is off: signing up must not hand out a session for an address
    // nobody has proven they control.
    expect(sessionCookie(res)).toBeNull();

    const user = await pg.db.user.findUniqueOrThrow({
      where: { email: "nina@example.com" },
    });
    expect(user.emailVerified).toBe(false);
    // databaseHooks.user.create.after — the billing account exists from the
    // first row, so nothing downstream has to cope with a user without one.
    const account = await pg.db.productAccount.findUnique({ where: { userId: user.id } });
    expect(account).not.toBeNull();

    expect(cap.captured.length).toBe(1);
    expect(cap.captured[0].to).toBe("nina@example.com");
    expect(cap.captured[0].subject).toContain("Verify");
  });

  test("an unverified account cannot sign in, and gets a fresh link", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await post(app, "/ui/signup", {
      email: "omar@example.com",
      password: PASSWORD,
      confirmPassword: PASSWORD,
    });

    const res = await signIn(app, "omar@example.com", PASSWORD);
    expect(res.status).toBe(302);
    const loc = location(res);
    expect(loc.pathname).toBe("/login/check-email");
    expect(loc.searchParams.get("resent")).toBe("1");
    expect(sessionCookie(res)).toBeNull();
    // sendOnSignIn re-sent the link rather than dead-ending the user.
    expect(cap.captured.length).toBe(2);
  });

  test("opening the link verifies, signs in, and password sign-in then works", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    const cookie = await signUpAndVerify(app, cap.captured, "pia@example.com");

    const user = await pg.db.user.findUniqueOrThrow({
      where: { email: "pia@example.com" },
    });
    expect(user.emailVerified).toBe(true);
    expect(
      (await app.request("/dashboard", { headers: { cookie } })).status
    ).toBe(200);

    const res = await signIn(app, "pia@example.com", PASSWORD);
    expect(res.status).toBe(302);
    expect(location(res).pathname).toBe("/dashboard");
    const fresh = sessionCookie(res);
    expect(fresh).not.toBeNull();
    expect(
      (await app.request("/dashboard", { headers: { cookie: fresh! } })).status
    ).toBe(200);
  });

  test("a second sign-up for the same address neither leaks nor overwrites", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await signUpAndVerify(app, cap.captured, "quinn@example.com");

    // Better-Auth answers a duplicate with a synthetic success while
    // requireEmailVerification is on, so the reply must look like a fresh
    // sign-up — anything else turns the form into an enumeration oracle.
    const res = await post(app, "/ui/signup", {
      email: "quinn@example.com",
      password: NEW_PASSWORD,
      confirmPassword: NEW_PASSWORD,
    });
    expect(res.status).toBe(302);
    expect(location(res).pathname).toBe("/login/check-email");

    expect(await pg.db.user.count({ where: { email: "quinn@example.com" } })).toBe(1);
    // The credential is untouched: the attacker's password must not work, the
    // owner's must.
    expect(location(await signIn(app, "quinn@example.com", NEW_PASSWORD)).pathname).toBe("/login");
    expect(location(await signIn(app, "quinn@example.com", PASSWORD)).pathname).toBe("/dashboard");
  });

  test("rejects a mismatched or too-short password without creating a user", async () => {
    const { app } = buildTestApp(pg.db, pg.url);

    const mismatch = await post(app, "/ui/signup", {
      email: "rita@example.com",
      password: PASSWORD,
      confirmPassword: `${PASSWORD}x`,
    });
    expect(location(mismatch).searchParams.get("error")).toBe("Passwords do not match");

    const short = await post(app, "/ui/signup", {
      email: "rita@example.com",
      password: "short",
      confirmPassword: "short",
    });
    expect(location(short).searchParams.get("error")).toContain("at least 12");
    // The email is echoed back so the form can be re-rendered filled in; the
    // password never is.
    expect(location(short).searchParams.get("email")).toBe("rita@example.com");
    expect(location(short).search).not.toContain("short");

    expect(await pg.db.user.count()).toBe(0);
  });

  test("the sign-up form posts the field name the route reads", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const html = await (await app.request("/signup")).text();
    // `confirm` is the delete-account form's word on /account; a rename on
    // either side that silently stops matching would only show up as
    // "Passwords do not match" for every user.
    expect(html).toContain('name="confirmPassword"');
  });
});

describe("password sign-in failures", () => {
  test("wrong password, unknown address, and no-password account read alike", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await signUpAndVerify(app, cap.captured, "sara@example.com");
    // Magic-link/OAuth accounts have no credential row at all.
    await createTestUser(pg.db, "tess@example.com");

    const wrongPassword = await signIn(app, "sara@example.com", "wrong-password-here");
    const unknownUser = await signIn(app, "nobody@example.com", PASSWORD);
    const noCredential = await signIn(app, "tess@example.com", PASSWORD);

    for (const res of [wrongPassword, unknownUser, noCredential]) {
      expect(res.status).toBe(302);
      expect(location(res).pathname).toBe("/login");
      expect(location(res).searchParams.get("error")).toBe("Invalid email or password");
      expect(sessionCookie(res)).toBeNull();
    }
  });
});

describe("password reset", () => {
  test("round-trips, kills every existing session, and rotates the credential", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    const cookie = await signUpAndVerify(app, cap.captured, "uma@example.com");
    expect((await app.request("/account", { headers: { cookie } })).status).toBe(200);

    // POST/redirect/GET: a reload of the confirmation must not re-send.
    const requested = await post(app, "/ui/forgot-password", { email: "uma@example.com" });
    expect(requested.status).toBe(302);
    expect(location(requested).pathname).toBe("/forgot-password/sent");
    expect(
      (await app.request("/forgot-password/sent")).status,
      "the redirect target has to be a real page"
    ).toBe(200);

    // Better-Auth validates the token on the GET before the form is ever
    // rendered, so a live token is the only thing that reaches /reset-password.
    const opened = await app.request(linkFrom(cap.captured, "Reset"), { redirect: "manual" });
    expect(opened.status).toBe(302);
    const formUrl = location(opened);
    expect(formUrl.pathname).toBe("/reset-password");
    const token = formUrl.searchParams.get("token");
    expect(token).toBeTruthy();

    const formHtml = await (await app.request(`${formUrl.pathname}${formUrl.search}`)).text();
    expect(formHtml).toContain('name="confirmPassword"');

    const saved = await post(app, "/ui/reset-password", {
      token: token!,
      password: NEW_PASSWORD,
      confirmPassword: NEW_PASSWORD,
    });
    expect(saved.status).toBe(302);
    expect(location(saved).pathname).toBe("/login");
    expect(location(saved).searchParams.get("notice")).toContain("Password updated");

    // revokeSessionsOnPasswordReset: a reset is the takeover-recovery path, so
    // whatever the attacker was holding has to die with it.
    const afterReset = await app.request("/account", {
      headers: { cookie },
      redirect: "manual",
    });
    expect(location(afterReset).pathname).toBe("/login");

    expect(location(await signIn(app, "uma@example.com", PASSWORD)).pathname).toBe("/login");
    expect(location(await signIn(app, "uma@example.com", NEW_PASSWORD)).pathname).toBe("/dashboard");
  });

  test("mints a credential for an account that never had a password", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    // Verified, but magic-link/OAuth only — this is the recovery path the login
    // page points such a user at.
    const user = await createTestUser(pg.db, "vic@example.com");

    await post(app, "/ui/forgot-password", { email: "vic@example.com" });
    const opened = await app.request(linkFrom(cap.captured, "Reset"), { redirect: "manual" });
    const token = location(opened).searchParams.get("token")!;
    const saved = await post(app, "/ui/reset-password", {
      token,
      password: NEW_PASSWORD,
      confirmPassword: NEW_PASSWORD,
    });
    expect(location(saved).pathname).toBe("/login");

    const credential = await pg.db.account.findFirst({
      where: { userId: user.id, providerId: CREDENTIAL_PROVIDER_ID },
    });
    expect(credential?.password).toBeTruthy();
    expect(location(await signIn(app, "vic@example.com", NEW_PASSWORD)).pathname).toBe("/dashboard");
  });

  test("answers an unknown address exactly as it answers a real one", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await createTestUser(pg.db, "wes@example.com");

    const known = await post(app, "/ui/forgot-password", { email: "wes@example.com" });
    const unknown = await post(app, "/ui/forgot-password", { email: "ghost@example.com" });

    expect(unknown.status).toBe(known.status);
    // Byte-identical, not merely "both 302" — neither the redirect target nor
    // the page it lands on may carry the address back, or the reply itself
    // becomes the oracle the endpoint exists to avoid being.
    expect(unknown.headers.get("location")).toBe(known.headers.get("location"));
    const landing = await app.request(location(known).pathname);
    expect(await landing.text()).not.toContain("wes@example.com");
    expect(cap.captured.length).toBe(1);
    expect(cap.captured[0].to).toBe("wes@example.com");
  });

  test("a bare or dead token never renders the form", async () => {
    const { app } = buildTestApp(pg.db, pg.url);

    const bare = await (await app.request("/reset-password")).text();
    expect(bare).toContain("Reset link expired");
    expect(bare).not.toContain('name="password"');

    const dead = await post(app, "/ui/reset-password", {
      token: "not-a-real-token",
      password: NEW_PASSWORD,
      confirmPassword: NEW_PASSWORD,
    });
    expect(dead.status).toBe(200);
    expect(await dead.text()).toContain("Reset link expired");
  });
});

describe("POST /ui/account/password", () => {
  test("sets a first password for a magic-link account and keeps the tab signed in", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "xena@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);

    const before = await (await app.request("/account", { headers: { cookie } })).text();
    expect(before).toContain("Set a password");
    expect(before).toContain('name="confirmPassword"');

    const res = await post(
      app,
      "/ui/account/password",
      { password: PASSWORD, confirmPassword: PASSWORD },
      cookie
    );
    expect(res.status).toBe(302);
    expect(location(res).searchParams.get("passwordNotice")).toBe("Password set.");

    const after = await (await app.request("/account", { headers: { cookie } })).text();
    expect(after).toContain("Change password");
    expect(location(await signIn(app, "xena@example.com", PASSWORD)).pathname).toBe("/dashboard");
  });

  test("changing requires the current password and drops the other sessions", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    const cookie = await signUpAndVerify(app, cap.captured, "yuri@example.com");
    const user = await pg.db.user.findUniqueOrThrow({ where: { email: "yuri@example.com" } });
    const other = await createTestSession(pg.db, user.id);

    const wrong = await post(
      app,
      "/ui/account/password",
      { currentPassword: "not-the-password", password: NEW_PASSWORD, confirmPassword: NEW_PASSWORD },
      cookie
    );
    expect(location(wrong).searchParams.get("passwordError")).toBe(
      "Current password is incorrect"
    );
    expect(location(await signIn(app, "yuri@example.com", PASSWORD)).pathname).toBe("/dashboard");

    const res = await post(
      app,
      "/ui/account/password",
      { currentPassword: PASSWORD, password: NEW_PASSWORD, confirmPassword: NEW_PASSWORD },
      cookie
    );
    expect(location(res).searchParams.get("passwordNotice")).toBe("Password changed.");

    // revokeOtherSessions kills every session including this browser's, so the
    // replacement cookie has to be forwarded or the user is signed out of the
    // tab they just used.
    const replacement = sessionCookie(res);
    expect(replacement).not.toBeNull();
    expect(
      (await app.request("/account", { headers: { cookie: replacement! } })).status
    ).toBe(200);
    expect(
      location(
        await app.request("/account", { headers: { cookie: other.cookie }, redirect: "manual" })
      ).pathname
    ).toBe("/login");

    expect(location(await signIn(app, "yuri@example.com", PASSWORD)).pathname).toBe("/login");
    expect(location(await signIn(app, "yuri@example.com", NEW_PASSWORD)).pathname).toBe("/dashboard");
  });

  test("rejects a mismatched or too-short password before touching the credential", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "zola@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);

    const mismatch = await post(
      app,
      "/ui/account/password",
      { password: PASSWORD, confirmPassword: NEW_PASSWORD },
      cookie
    );
    expect(location(mismatch).searchParams.get("passwordError")).toBe("Passwords do not match");

    const short = await post(
      app,
      "/ui/account/password",
      { password: "short", confirmPassword: "short" },
      cookie
    );
    expect(location(short).searchParams.get("passwordError")).toContain("at least 12");

    expect(
      await pg.db.account.count({
        where: { userId: user.id, providerId: CREDENTIAL_PROVIDER_ID },
      })
    ).toBe(0);
  });

  test("redirects to /login without a session", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await post(app, "/ui/account/password", {
      password: PASSWORD,
      confirmPassword: PASSWORD,
    });
    expect([302, 307]).toContain(res.status);
    expect(location(res).pathname).toBe("/login");
  });
});

/** Drive the cross-device magic link end to end and return the session cookie
 *  it mints. Mirrors tests/routes/cross-device-flow.test.ts. */
async function signInByMagicLink(
  app: TestApp,
  captured: CapturedEmail[],
  email: string
): Promise<string> {
  const start = await post(app, "/ui/login/start", { email });
  expect(start.status).toBe(302);
  const bindCookie = (start.headers.get("set-cookie") ?? "").split(";")[0];
  const url = new URL(linkFrom(captured, "sign-in"));
  const approve = await post(app, "/ui/login/approve", {
    id: url.searchParams.get("id")!,
    token: url.searchParams.get("t")!,
  });
  expect(approve.status).toBe(302);
  const poll = await app.request(`/ui/login/poll/${url.searchParams.get("id")}`, {
    headers: { cookie: bindCookie },
  });
  expect(poll.headers.get("hx-redirect")).toBe("/dashboard");
  const cookie = sessionCookie(poll);
  expect(cookie).not.toBeNull();
  return cookie!;
}

describe("pre-registration hijack", () => {
  test("a password planted before the owner arrives dies when they sign in", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    const victim = "victim@example.com";

    // Attacker squats the address. Sign-up writes the credential row before the
    // address is proven; requireEmailVerification withholds only the session.
    const planted = await post(app, "/ui/signup", {
      email: victim,
      password: PASSWORD,
      confirmPassword: PASSWORD,
    });
    expect(sessionCookie(planted)).toBeNull();
    const user = await pg.db.user.findUniqueOrThrow({ where: { email: victim } });
    expect(user.emailVerified).toBe(false);
    expect(
      await pg.db.account.count({
        where: { userId: user.id, providerId: CREDENTIAL_PROVIDER_ID },
      })
    ).toBe(1);

    // The real owner shows up by magic link. This is what flips emailVerified,
    // and it must not arm a password they never chose.
    await signInByMagicLink(app, cap.captured, victim);
    expect(
      (await pg.db.user.findUniqueOrThrow({ where: { email: victim } })).emailVerified
    ).toBe(true);
    expect(
      await pg.db.account.count({
        where: { userId: user.id, providerId: CREDENTIAL_PROVIDER_ID },
      })
    ).toBe(0);

    const attempt = await signIn(app, victim, PASSWORD);
    expect(sessionCookie(attempt)).toBeNull();
    expect(location(attempt).searchParams.get("error")).toBe("Invalid email or password");
  });

  test("a planted password dies when the owner arrives by GitHub", async () => {
    const cap = makeCapture();
    const { app, auth } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    const victim = "oauth-victim@example.com";

    await post(app, "/ui/signup", {
      email: victim,
      password: PASSWORD,
      confirmPassword: PASSWORD,
    });
    const user = await pg.db.user.findUniqueOrThrow({ where: { email: victim } });
    expect(user.emailVerified).toBe(false);
    expect(
      await pg.db.account.count({
        where: { userId: user.id, providerId: CREDENTIAL_PROVIDER_ID },
      })
    ).toBe(1);

    // The OAuth callback's linking step without the provider round trip. This
    // is the exact call `handleOAuthUserInfo` makes for an existing user
    // (oauth2/link-account.mjs), and it makes it BEFORE flipping emailVerified
    // — which is the only window in which the hook can still tell a planted
    // password from a proven one.
    const ctx = await auth.$context;
    await ctx.internalAdapter.linkAccount({
      userId: user.id,
      providerId: "github",
      accountId: "gh-1",
      scope: "user:email",
    });

    expect(
      await pg.db.account.count({
        where: { userId: user.id, providerId: CREDENTIAL_PROVIDER_ID },
      })
    ).toBe(0);
  });

  test("linking to an already-verified user leaves their password alone", async () => {
    const cap = makeCapture();
    const { app, auth } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    const email = "oauth-owner@example.com";

    await signUpAndVerify(app, cap.captured, email);
    const user = await pg.db.user.findUniqueOrThrow({ where: { email } });

    const ctx = await auth.$context;
    await ctx.internalAdapter.linkAccount({
      userId: user.id,
      providerId: "github",
      accountId: "gh-2",
      scope: "user:email",
    });

    // Verified BEFORE the link, so the password is the user's own and adding a
    // second sign-in method must not take it away.
    const res = await signIn(app, email, PASSWORD);
    expect(sessionCookie(res)).not.toBeNull();
  });

  test("a password the owner set themselves survives their next sign-in", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    const email = "owner@example.com";

    // Verified through the emailed link, which IS the proof sign-up lacked.
    await signUpAndVerify(app, cap.captured, email);
    await signInByMagicLink(app, cap.captured, email);

    const res = await signIn(app, email, PASSWORD);
    expect(sessionCookie(res)).not.toBeNull();
    expect(location(res).pathname).toBe("/dashboard");
  });
});

describe("cross-site form posts", () => {
  test("a foreign origin cannot log the browser into someone else's account", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await signUpAndVerify(app, cap.captured, "attacker@example.com");

    const res = await app.request("/ui/login/password", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        origin: "https://evil.example",
        "sec-fetch-site": "cross-site",
        "sec-fetch-mode": "navigate",
      },
      body: new URLSearchParams({
        email: "attacker@example.com",
        password: PASSWORD,
      }).toString(),
      redirect: "manual",
    });
    expect(res.status).toBe(403);
    expect(sessionCookie(res)).toBeNull();
  });

  test("the app's own origin is still allowed", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await signUpAndVerify(app, cap.captured, "nina@example.com");

    const res = await app.request("/ui/login/password", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        origin: "http://localhost:8787",
        "sec-fetch-site": "same-origin",
      },
      body: new URLSearchParams({
        email: "nina@example.com",
        password: PASSWORD,
      }).toString(),
      redirect: "manual",
    });
    expect(res.status).toBe(302);
    expect(sessionCookie(res)).not.toBeNull();
  });
});

describe("password reset", () => {
  test("completing a reset records the address as verified", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    const email = "lost@example.com";

    // Signed up but never opened the verification link.
    await post(app, "/ui/signup", {
      email,
      password: PASSWORD,
      confirmPassword: PASSWORD,
    });
    expect(
      (await pg.db.user.findUniqueOrThrow({ where: { email } })).emailVerified
    ).toBe(false);

    await post(app, "/ui/forgot-password", { email });
    const token = new URL(linkFrom(cap.captured, "Reset")).pathname.split("/").pop()!;
    const reset = await app.request(`/api/auth/reset-password/${token}?callbackURL=/reset-password`, {
      redirect: "manual",
    });
    const formToken = new URL(reset.headers.get("location")!, "http://localhost")
      .searchParams.get("token")!;
    const saved = await post(app, "/ui/reset-password", {
      token: formToken,
      password: NEW_PASSWORD,
      confirmPassword: NEW_PASSWORD,
    });
    expect(location(saved).pathname).toBe("/login");

    // Opening the emailed link is the same proof the verification link asks
    // for. Without recording it, this sign-in bounces to /login/check-email.
    const res = await signIn(app, email, NEW_PASSWORD);
    expect(location(res).pathname).toBe("/dashboard");
    expect(sessionCookie(res)).not.toBeNull();
  });
});

describe("password length", () => {
  test("names the ceiling instead of a generic failure", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const tooLong = "x".repeat(129);
    const res = await post(app, "/ui/signup", {
      email: "long@example.com",
      password: tooLong,
      confirmPassword: tooLong,
    });
    expect(location(res).searchParams.get("error")).toContain("at most 128");
    expect(await pg.db.user.count({ where: { email: "long@example.com" } })).toBe(0);
  });
});

describe("GET /login/verified", () => {
  test("a link opened without a session lands somewhere that explains itself", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    // What a mail scanner's prefetch leaves behind: Better-Auth short-circuits
    // an already-verified user before autoSignInAfterVerification, so the human
    // arrives here with no cookie.
    const res = await app.request("/login/verified", { redirect: "manual" });
    expect(res.status).toBe(302);
    const loc = location(res);
    expect(loc.pathname).toBe("/login");
    expect(loc.searchParams.get("notice")).toContain("verified");
  });
});
