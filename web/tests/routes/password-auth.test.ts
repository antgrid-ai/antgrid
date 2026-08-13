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

/** The session cookie WITH its attributes. `sessionCookie` deliberately drops
 *  them (it builds a request header), but whether the cookie outlives the
 *  browser window is exactly what "Keep me signed in" buys. */
function sessionSetCookie(res: Response): string | null {
  return (
    res.headers
      .getSetCookie()
      .find((sc) => /^better-auth\.session_token=[^;]/.test(sc)) ?? null
  );
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

/** Better-Auth's own sign-up endpoint, underneath the page. /api/auth/* is
 *  publicly routed, so this is a live surface with or without a form in front
 *  of it — the hijack cases below are about exactly that. */
function signUp(app: TestApp, email: string, password = PASSWORD) {
  return app.request("/api/auth/sign-up/email", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, password, name: email }),
    redirect: "manual",
  });
}

/** The sign-up page's form. Confirmation defaults to matching, so a caller only
 *  states it when the mismatch is the thing under test. */
function signUpForm(
  app: TestApp,
  email: string,
  password = PASSWORD,
  confirmPassword = password
) {
  return post(app, "/ui/signup", { email, password, confirmPassword });
}

/** Sign up, open the emailed link, return the session cookie
 *  `autoSignInAfterVerification` mints. */
async function signUpAndVerify(
  app: TestApp,
  captured: CapturedEmail[],
  email: string,
  password = PASSWORD
): Promise<string> {
  const res = await signUp(app, email, password);
  expect(res.ok).toBe(true);
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

    const res = await signUp(app, "Nina@Example.com");
    expect(res.ok).toBe(true);
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
    await signUp(app, "omar@example.com");

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
    // sign-up — anything else turns the endpoint into an enumeration oracle.
    const res = await signUp(app, "quinn@example.com", NEW_PASSWORD);
    expect(res.ok).toBe(true);

    expect(await pg.db.user.count({ where: { email: "quinn@example.com" } })).toBe(1);
    // The credential is untouched: the attacker's password must not work, the
    // owner's must.
    const rejected = await signIn(app, "quinn@example.com", NEW_PASSWORD);
    expect(location(rejected).pathname).toBe("/login/password");
    expect(location(await signIn(app, "quinn@example.com", PASSWORD)).pathname).toBe("/dashboard");
  });

  test("rejects a too-short password without creating a user", async () => {
    const { app } = buildTestApp(pg.db, pg.url);

    // MIN_PASSWORD_LENGTH is handed to Better-Auth itself, not just enforced by
    // the form — /api/auth/* is publicly routed, so the endpoint's own floor is
    // the only one an attacker has to clear.
    const res = await signUp(app, "rita@example.com", "short");
    expect(res.ok).toBe(false);
    expect(await pg.db.user.count()).toBe(0);
  });
});

describe("the sign-up page", () => {
  test("creates the account, sends the link, and hands out no session", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });

    const res = await signUpForm(app, "Tomas@Example.com");
    const loc = location(res);
    expect(loc.pathname).toBe("/login/check-email");
    expect(loc.searchParams.get("email")).toBe("tomas@example.com");
    expect(sessionCookie(res)).toBeNull();

    const user = await pg.db.user.findUniqueOrThrow({
      where: { email: "tomas@example.com" },
    });
    expect(user.emailVerified).toBe(false);
    expect(cap.captured.length).toBe(1);
    expect(cap.captured[0].subject).toContain("Verify");

    // The link is the proof sign-up lacked, so opening it is what signs them
    // in — and it must leave the password they just chose alone, unlike the
    // magic link, which purges an unproven credential at the same flip.
    const verified = await app.request(linkFrom(cap.captured, "Verify"), {
      redirect: "manual",
    });
    expect(sessionCookie(verified)).not.toBeNull();
    expect(location(await signIn(app, "tomas@example.com", PASSWORD)).pathname).toBe(
      "/dashboard"
    );
  });

  test("an address that already has an account is answered identically", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await signUpAndVerify(app, cap.captured, "ulla@example.com");
    const sentSoFar = cap.captured.length;

    // Byte-for-byte the reply a fresh address gets. Anything else here — a
    // distinct error, a distinct page, even a distinct query string — turns the
    // form into the account-lookup oracle the whole flow is built to withhold.
    const res = await signUpForm(app, "ulla@example.com", NEW_PASSWORD);
    expect(res.headers.get("location")).toBe(
      "/login/check-email?email=ulla%40example.com&created=1"
    );
    expect(sessionCookie(res)).toBeNull();
    // Silent on the wire and silent in the inbox: no second mail to tell the
    // address's owner apart from a stranger probing it.
    expect(cap.captured.length).toBe(sentSoFar);

    expect(await pg.db.user.count({ where: { email: "ulla@example.com" } })).toBe(1);
    const rejected = await signIn(app, "ulla@example.com", NEW_PASSWORD);
    expect(location(rejected).pathname).toBe("/login/password");
    expect(location(await signIn(app, "ulla@example.com", PASSWORD)).pathname).toBe(
      "/dashboard"
    );
  });

  test("a mismatched confirmation never reaches the account write", async () => {
    const { app } = buildTestApp(pg.db, pg.url);

    const res = await signUpForm(app, "vera@example.com", PASSWORD, NEW_PASSWORD);
    const loc = location(res);
    expect(loc.pathname).toBe("/signup");
    expect(loc.searchParams.get("error")).toBe("Passwords do not match");
    // The address rides back: this page has no earlier step to return to, so
    // dropping it makes a mistyped confirmation cost the whole form.
    expect(loc.searchParams.get("email")).toBe("vera@example.com");
    expect(await pg.db.user.count()).toBe(0);
  });

  test("states both password bounds rather than failing generically", async () => {
    const { app } = buildTestApp(pg.db, pg.url);

    expect(location(await signUpForm(app, "wim@example.com", "short")).searchParams.get("error")).toContain(
      "at least"
    );
    // PASSWORD_TOO_LONG is thrown ahead of every other check, so a ceiling left
    // to Better-Auth surfaces as a generic "try again" that can never succeed.
    expect(
      location(await signUpForm(app, "wim@example.com", "x".repeat(200))).searchParams.get("error")
    ).toContain("at most");
    expect(await pg.db.user.count()).toBe(0);
  });

  test("the landing teaches this browser that the address has a password", async () => {
    const { app } = buildTestApp(pg.db, pg.url);

    // Nothing else can write this hint for a new password: step 1 routes on
    // what the browser has watched an address do, and this user has never been
    // watched signing in at all.
    const created = await (
      await app.request("/login/check-email?email=yara%40example.com&created=1")
    ).text();
    expect(created).toContain('data-ab-remember-now="password"');
    expect(created).toContain('data-ab-email="yara@example.com"');

    // The other way onto this page is an unverified password sign-in, whose
    // browser learned the hint when it submitted step 2.
    const resent = await (
      await app.request("/login/check-email?email=yara%40example.com&resent=1")
    ).text();
    expect(resent).not.toContain('data-ab-remember-now="password"');
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
      // Step 2, not step 1: the address was settled a step ago, and this is the
      // page carrying "Email me a link instead" — the way out for the
      // no-credential user the collapsed message is deliberately hiding.
      expect(location(res).pathname).toBe("/login/password");
      expect(location(res).searchParams.get("error")).toBe("Invalid email or password");
      expect(sessionCookie(res)).toBeNull();
    }
    // Step 2 has no email field of its own, so an address that doesn't survive
    // the round trip leaves a mistyped password on a page it cannot re-render.
    expect(location(wrongPassword).searchParams.get("email")).toBe("sara@example.com");
    expect(location(unknownUser).searchParams.get("email")).toBe("nobody@example.com");
    expect(location(noCredential).searchParams.get("email")).toBe("tess@example.com");
  });

  test("the address it hands back renders step 2 rather than bouncing", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await signUpAndVerify(app, cap.captured, "step2@example.com");

    const rejected = await signIn(app, "step2@example.com", "wrong-password-here");
    const loc = location(rejected);
    const page = await app.request(`${loc.pathname}${loc.search}`, { redirect: "manual" });
    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).toContain("step2@example.com");
    expect(html).toContain("Invalid email or password");
    // The escape hatch for a browser whose hint was simply wrong.
    expect(html).toContain('action="/ui/login/start"');
  });

  test("step 2 without an address is a dead end, so it goes back to step 1", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const res = await app.request("/login/password", { redirect: "manual" });
    expect(res.status).toBe(302);
    expect(location(res).pathname).toBe("/login");
  });
});

/** Everything about a reply that the caller did not supply themselves. The
 *  address is their own input and the pending id / bind cookie are freshly
 *  random per request; ANY other difference between a real address and an
 *  invented one is the enumeration oracle this flow exists not to be. */
async function replyShape(res: Response, email: string) {
  const redact = (v: string) =>
    v
      .replaceAll(email, "<email>")
      .replaceAll(encodeURIComponent(email), "<email>")
      .replace(
        /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi,
        "<id>"
      );
  const loc = res.headers.get("location");
  return {
    status: res.status,
    location: loc === null ? null : redact(loc),
    // Names only: the bind cookie's value is a per-request secret.
    headerNames: [...new Set(res.headers.keys())].sort(),
    cookieNames: res.headers
      .getSetCookie()
      .map((c) => c.split("=")[0])
      .sort(),
    body: redact(await res.text()),
  };
}

/** The `<form>` blocks of a rendered page. These attributes have to be checked
 *  per form rather than per page: `data-ab-once` and `data-ab-cooldown` are each
 *  fine somewhere on a page and only wrong together on one form — and the shared
 *  inline script names both, so a whole-page substring match finds them whatever
 *  the markup says. */
function forms(html: string): string[] {
  return html.match(/<form\b[\s\S]*?<\/form>/g) ?? [];
}

function formWithAction(html: string, action: string): string {
  const hit = forms(html).find((f) => f.includes(`action="${action}"`));
  expect(hit, `no form posting to ${action}`).toBeDefined();
  return hit!;
}

describe("POST /ui/login/continue", () => {
  test("a remembered password routes to step 2 with the address intact", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });

    const res = await post(app, "/ui/login/continue", {
      email: "abe@example.com",
      method: "password",
    });
    expect(res.status).toBe(302);
    const loc = location(res);
    expect(loc.pathname).toBe("/login/password");
    expect(loc.searchParams.get("email")).toBe("abe@example.com");
    // Routing on a hint must not be a reason to touch the account or the inbox:
    // this step decides where to go and nothing else.
    expect(cap.captured.length).toBe(0);
  });

  test("link, no hint, and a junk hint all fall through to the magic link", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });

    const link = await post(app, "/ui/login/continue", {
      email: "bea@example.com",
      method: "link",
    });
    // With JS off the hidden field is never filled, so this is the no-hint case.
    const absent = await post(app, "/ui/login/continue", { email: "cyd@example.com" });
    // A hint is client-supplied, so it can be anything at all.
    const junk = await post(app, "/ui/login/continue", {
      email: "dot@example.com",
      method: "../../etc/passwd",
    });

    for (const res of [link, absent, junk]) {
      expect(res.status).toBe(302);
      const loc = location(res);
      expect(loc.pathname).toMatch(/^\/login\/pending\/[0-9a-f-]{36}$/);
      // Never a provider redirect on the fall-through — that is the branch a
      // junk hint would have to reach to smuggle a `provider` value.
      expect(loc.pathname).not.toBe("/oauth/start");
    }
    expect(cap.captured.map((e) => e.to)).toEqual([
      "bea@example.com",
      "cyd@example.com",
      "dot@example.com",
    ]);
    for (const mail of cap.captured) expect(mail.subject).toContain("sign-in");
  });

  test("the fallback button outranks whatever the browser remembers", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });

    // `data-ab-recall` fills the hidden field on EVERY submit of step 1's form,
    // the escape's included, so a stale hint always rides along with the click
    // trying to get away from it. The provider hints are what make this
    // load-bearing: they relaunch the provider, and step 2 — the only other
    // place the magic link is offered — is a page they can never reach.
    const bodies = [
      // With JS off the hidden field is never filled and the button posts alone.
      { email: "jo@example.com", method: "", fallback: "link" },
      { email: "kit@example.com", method: "password", fallback: "link" },
      { email: "lou@example.com", method: "github", fallback: "link" },
      { email: "mel@example.com", method: "google", fallback: "link" },
    ];

    for (const body of bodies) {
      const res = await post(app, "/ui/login/continue", body);
      expect(res.status).toBe(302);
      const loc = location(res);
      expect(loc.pathname).toMatch(/^\/login\/pending\/[0-9a-f-]{36}$/);
      // The two branches the hint would otherwise have taken, named so a
      // regression reads as itself rather than as a malformed pending id.
      expect(loc.pathname).not.toBe("/login/password");
      expect(loc.pathname).not.toBe("/oauth/start");
      expect(loc.searchParams.get("email")).toBe(body.email);
    }

    // Landing on the pending page proves only the branch. An escape that says
    // "check your inbox" without reaching a mailer is worse than no escape.
    expect(cap.captured.map((e) => e.to)).toEqual(bodies.map((b) => b.email));
    for (const mail of cap.captured) expect(mail.subject).toContain("sign-in");
  });

  test("only the two known providers reach /oauth/start, and never verbatim", async () => {
    const { app } = buildTestApp(pg.db, pg.url);

    for (const provider of ["github", "google"]) {
      const res = await post(app, "/ui/login/continue", {
        email: "eve@example.com",
        method: provider,
      });
      expect(res.status).toBe(302);
      const loc = location(res);
      expect(loc.pathname).toBe("/oauth/start");
      expect(loc.searchParams.get("provider")).toBe(provider);
      expect(loc.searchParams.get("callbackURL")).toBe("/dashboard");
    }

    // The switch matches literals rather than forwarding `method`, so a value
    // the client chose can never land in the `provider` param.
    for (const method of ["gitlab", "github ", "GitHub", "github&callbackURL=//evil"]) {
      const res = await post(app, "/ui/login/continue", {
        email: "eve@example.com",
        method,
      });
      const loc = location(res);
      expect(loc.pathname).not.toBe("/oauth/start");
      expect(loc.search).not.toContain("provider=");
    }
  });

  test("an empty address never leaves step 1", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });

    const res = await post(app, "/ui/login/continue", { email: "  ", method: "link" });
    expect(location(res).pathname).toBe("/login");
    expect(location(res).searchParams.get("error")).toBe("Email required");
    expect(cap.captured.length).toBe(0);
  });

  test("answers an address with an account exactly as it answers one without", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await createTestUser(pg.db, "real@example.com");

    const known = await post(app, "/ui/login/continue", {
      email: "real@example.com",
      method: "link",
    });
    const unknown = await post(app, "/ui/login/continue", {
      email: "ghost@example.com",
      method: "link",
    });

    // The load-bearing property of the whole design: step 1 does no account
    // lookup, so its reply cannot differ on whether the account exists. Once
    // the caller's own address and the per-request randomness are redacted,
    // the two replies must be indistinguishable.
    expect(await replyShape(unknown, "ghost@example.com")).toEqual(
      await replyShape(known, "real@example.com")
    );

    // Both really did send — identical replies mean nothing if neither branch
    // did any work.
    expect(cap.captured.map((e) => e.to)).toEqual([
      "real@example.com",
      "ghost@example.com",
    ]);

    // And the page each one lands on says the same thing too.
    const knownPage = await app.request(
      `${location(known).pathname}${location(known).search}`
    );
    const unknownPage = await app.request(
      `${location(unknown).pathname}${location(unknown).search}`
    );
    expect(await replyShape(unknownPage, "ghost@example.com")).toEqual(
      await replyShape(knownPage, "real@example.com")
    );
  });

  test("the escape hatch is no more of an oracle than the fall-through", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await createTestUser(pg.db, "nat@example.com");

    // Carrying the stale hint, because that is the body the escape is pressed
    // with. It reaches the mailer on input the caller controls end to end, so it
    // is the shortest path to an oracle the moment this branch grows a lookup.
    const known = await post(app, "/ui/login/continue", {
      email: "nat@example.com",
      method: "password",
      fallback: "link",
    });
    const unknown = await post(app, "/ui/login/continue", {
      email: "ghost@example.com",
      method: "password",
      fallback: "link",
    });

    expect(await replyShape(unknown, "ghost@example.com")).toEqual(
      await replyShape(known, "nat@example.com")
    );
    expect(cap.captured.map((e) => e.to)).toEqual([
      "nat@example.com",
      "ghost@example.com",
    ]);
  });

  test("the step-1 form posts the fields the route reads", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const html = await (await app.request("/login")).text();

    expect(html).toContain('action="/ui/login/continue"');
    // The hidden field the client script fills in. A rename on either side
    // silently demotes every returning user to the magic link.
    expect(html).toContain('name="method"');
    expect(html).toContain('name="email"');
    // No password field on step 1 — asking for one before the address is
    // settled is exactly what the restructure removed.
    expect(html).not.toContain('type="password"');
  });

  test("step 1 ships the hint plumbing and the way out of it", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const form = formWithAction(
      await (await app.request("/login")).text(),
      "/ui/login/continue"
    );

    // The hidden field and the hook that fills it from the browser's memory.
    expect(form).toContain('name="method"');
    expect(form).toContain("data-ab-recall");

    // Continue is the only control inside the form, and the only one that reads
    // the hint. Everything else names its own method, which is what keeps a
    // wrong hint costing a click rather than the account.
    expect((form.match(/<button[^>]*>/g) ?? []).length).toBe(1);
  });

  test("the address survives the trip back from step 2", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const html = await (
      await app.request("/login?email=fay%40example.com")
    ).text();
    expect(html).toContain('value="fay@example.com"');
  });

  test("step 2 is the only place that offers to create an account", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const step2 = await (
      await app.request("/login/password?email=gita%40example.com")
    ).text();
    // A password is the one method a browser cannot reach on its own — step 1
    // routes on what it has WATCHED an address do — so the page that asks for
    // one has to be the page that offers to create one, with the address it
    // already holds.
    expect(step2).toContain("/signup?email=gita%40example.com");

    const page = await app.request("/signup?email=gita%40example.com");
    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).toContain('action="/ui/signup"');
    // Handed over rather than retyped, and the field is filled from that alone —
    // `data-ab-prefill` would restore the last address this browser remembered,
    // which is the one address a new account is guaranteed not to be. Asserted
    // on the input, not the page: the shared script names the attribute in a
    // selector, so the bare string is present wherever that script ships.
    const field = html.match(/<input[^>]*id="signup-email"[^>]*>/)?.[0];
    expect(field).toBeDefined();
    expect(field!).toContain('value="gita@example.com"');
    expect(field!).not.toContain("data-ab-prefill");

    // Step 1 stays a single decision: enter your address. A sign-up link there
    // re-opens the sign-in/sign-up choice the email-first flow removes.
    expect(await (await app.request("/login")).text()).not.toContain("/signup");
  });

  test("the password escape carries the address to step 2 and remembers nothing", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const html = await (await app.request("/login")).text();
    const escape = html.match(/<button[^>]*value="password"[^>]*>/)?.[0];
    expect(escape, "step 1 has no way into the password step").toBeDefined();
    // Outside the form it submits, because it belongs to the method block
    // visually and forms cannot be nested. Without the association it posts
    // nothing and step 2 has no address to render.
    expect(escape!).toContain('form="login-form"');
    expect(html).toContain('id="login-form"');
    // No `data-ab-remember`: nothing here knows the address HAS a password —
    // the server refuses to say — so a hint written on the guess would pin this
    // browser to a step that can never work for it.
    expect(escape!).not.toContain("data-ab-remember");

    const res = await post(app, "/ui/login/continue", {
      email: "hana@example.com",
      fallback: "password",
    });
    expect(res.status).toBe(302);
    const loc = location(res);
    expect(loc.pathname).toBe("/login/password");
    // Step 2 has no email field, so the address has to survive the redirect or
    // it renders nothing and bounces straight back here.
    expect(loc.searchParams.get("email")).toBe("hana@example.com");
  });

  test("the escape outranks a hint pointing somewhere else, and reaches the link", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    // `data-ab-recall` fills the hidden field on every submit of step 1's form,
    // this button's included, so the stale hint always rides along with the
    // click trying to get away from it.
    const res = await post(app, "/ui/login/continue", {
      email: "ines@example.com",
      method: "github",
      fallback: "password",
    });
    const loc = location(res);
    expect(loc.pathname).toBe("/login/password");

    // Step 1 offers no link of its own, so this is the whole route out of a
    // provider hint that relaunches itself on every Continue: the password
    // button ignores the hint, and the step it reaches is where the link lives.
    const page = await (
      await app.request(`${loc.pathname}${loc.search}`, { redirect: "manual" })
    ).text();
    const link = formWithAction(page, "/ui/login/start");
    expect(link).toContain('value="ines@example.com"');
    // And taking it retires the hint that caused the trap, so the next Continue
    // does not walk back into it. Nothing else writes `link` on this path.
    expect(link).toContain('data-ab-remember="link"');
    expect(link).toContain('data-ab-email="ines@example.com"');
  });

  test("a password sign-up nobody asked for cannot be posted from step 1", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    // The escape is a page change, not a credential write: taking it must not
    // create the account, or step 1 would be a way to squat any address.
    await post(app, "/ui/login/continue", { email: "jess@example.com", fallback: "password" });
    expect(await pg.db.user.count()).toBe(0);
    expect(cap.captured.length).toBe(0);
  });
});

describe("double-submit guards", () => {
  test("every button that can send a link from step 1 disables itself", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const html = await (await app.request("/login")).text();
    const form = formWithAction(html, "/ui/login/continue");

    // Continue reaches the mailer on the fall-through, and the send is awaited
    // server-side, so an unguarded click stays live for a whole mail round trip.
    // A second one mints a second pending row and the bind cookie follows THAT
    // one, leaving the user watching a page the mail they open can no longer
    // satisfy.
    const buttons = form.match(/<button[^>]*>/g) ?? [];
    expect(buttons.length).toBe(1);
    for (const button of buttons) expect(button).toContain("data-ab-once");

    // The password button submits the same form and is deliberately exempt: it
    // sends nothing and only swaps the page, so a busy label would be a lie and
    // the disable would survive a browser Back into a step 1 with no way out.
    const escape = html.match(/<button[^>]*value="password"[^>]*>/)?.[0];
    expect(escape!).not.toContain("data-ab-once");
  });

  test("step 2's link form is guarded the same way", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const form = formWithAction(
      await (await app.request("/login/password?email=orla%40example.com")).text(),
      "/ui/login/start"
    );
    const button = form.match(/<button[^>]*>/)?.[0];
    expect(button, "step 2's link form has no submit button").toBeDefined();
    // On the button rather than the form: the script disables whichever element
    // carries the attribute, so a form-level one would disable nothing.
    expect(button!).toContain("data-ab-once");
  });

  test("a form with a cooldown is never also armed with the once guard", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });

    // The page a real send lands on, rather than a hand-built URL: the resend
    // form only has to hold up where the flow actually arrives.
    const sent = await post(app, "/ui/login/continue", { email: "pru@example.com" });
    const pending = await (
      await app.request(`${location(sent).pathname}${location(sent).search}`)
    ).text();
    const checkEmail = await (
      await app.request("/login/check-email?email=pru%40example.com")
    ).text();

    const cooling = [...forms(pending), ...forms(checkEmail)].filter((f) =>
      f.includes("data-ab-cooldown=")
    );
    // The magic-link resend and the verification resend — without both, the
    // sweep below passes on an empty list.
    expect(cooling.length).toBe(2);
    for (const form of cooling) {
      // Two owners of `disabled` fight over the re-enable: the once guard never
      // lifts, so it would outlast the countdown and kill the button for good.
      expect(form).not.toContain("data-ab-once");
    }
  });
});

describe("POST /ui/login/password rememberMe", () => {
  test("signs in whether the box is checked or absent", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await signUpAndVerify(app, cap.captured, "remy@example.com");

    const checked = await post(app, "/ui/login/password", {
      email: "remy@example.com",
      password: PASSWORD,
      rememberMe: "1",
    });
    expect(location(checked).pathname).toBe("/dashboard");
    const remembered = sessionCookie(checked);
    expect(remembered).not.toBeNull();
    expect(
      (await app.request("/dashboard", { headers: { cookie: remembered! } })).status
    ).toBe(200);

    // An unchecked box is simply absent from the body — the route reads
    // presence, so the absent case must still be a successful sign-in.
    const unchecked = await signIn(app, "remy@example.com", PASSWORD);
    expect(location(unchecked).pathname).toBe("/dashboard");
    const notRemembered = sessionCookie(unchecked);
    expect(notRemembered).not.toBeNull();
    expect(
      (await app.request("/dashboard", { headers: { cookie: notRemembered! } })).status
    ).toBe(200);

    // Both branches signing in proves only that neither is broken — a route
    // that dropped `rememberMe` on the floor passes everything above. What the
    // checkbox actually buys is a cookie that survives the browser closing, so
    // the persistence is the assertion: Max-Age on the remembered one, none on
    // the other (plus Better-Auth's own `dont_remember` marker).
    expect(sessionSetCookie(checked)).toContain("Max-Age=");
    expect(sessionSetCookie(unchecked)).not.toContain("Max-Age=");
    expect(unchecked.headers.getSetCookie().join("\n")).toContain(
      "better-auth.dont_remember="
    );
    expect(checked.headers.getSetCookie().join("\n")).not.toContain(
      "better-auth.dont_remember="
    );
  });

  test("step 2 ships the checkbox the route looks for", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const html = await (
      await app.request("/login/password?email=gus%40example.com")
    ).text();
    expect(html).toContain('name="rememberMe"');
    expect(html).toContain('name="password"');
    // The address is carried in a hidden field, not re-typed.
    expect(html).toContain('value="gus@example.com"');
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

    expect(location(await signIn(app, "uma@example.com", PASSWORD)).pathname).toBe(
      "/login/password"
    );
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

  test("a password set here teaches this browser to offer it at step 1", async () => {
    const { app } = buildTestApp(pg.db, pg.url);
    const user = await createTestUser(pg.db, "hint@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    const render = async (res: Response) => {
      const loc = location(res);
      return (
        await app.request(`${loc.pathname}${loc.search}`, { headers: { cookie } })
      ).text();
    };

    // The rejected save first: the hint hangs off the rendered OUTCOME, so a
    // failure must leave the browser believing nothing. Written on the submit
    // instead, this would claim a password the account does not have and route
    // every later sign-in to a step that can only fail.
    const failed = await render(
      await post(
        app,
        "/ui/account/password",
        { password: "short", confirmPassword: "short" },
        cookie
      )
    );
    // The attribute with its value, not the bare name: the inline script that
    // reads it names the same attribute in a selector, so a substring match on
    // the name alone passes on every page that ships the script.
    expect(failed).not.toContain('data-ab-remember-now="password"');

    const saved = await render(
      await post(
        app,
        "/ui/account/password",
        { password: PASSWORD, confirmPassword: PASSWORD },
        cookie
      )
    );
    // The one place a password is acquired without passing through the sign-in
    // flow. Nothing else writes this hint, so leaving it out strands the user
    // who just asked for a password on a step they can never reach.
    expect(saved).toContain('data-ab-remember-now="password"');
    // The address comes from the session, not from a form field this page does
    // not have.
    expect(saved).toContain('data-ab-email="hint@example.com"');
    // Inert markup unless the page also ships the script that reads it.
    expect(saved).toContain("antgrid.auth.methods.v1");
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

    expect(location(await signIn(app, "yuri@example.com", PASSWORD)).pathname).toBe(
      "/login/password"
    );
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
    const planted = await signUp(app, victim);
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

    await signUp(app, victim);
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

  // What a real browser sends from our own pages. app.ts sets Referrer-Policy:
  // no-referrer, and under that policy Fetch serializes a form POST's origin as
  // `null` — so every /ui form was 403ing in the browser while the two tests
  // either side of this one passed, because neither sends what Chrome sends.
  test("our own pages post with Origin: null and are still allowed", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await signUpAndVerify(app, cap.captured, "nell@example.com");

    const res = await app.request("/ui/login/password", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        origin: "null",
        "sec-fetch-site": "same-origin",
        "sec-fetch-mode": "navigate",
      },
      body: new URLSearchParams({
        email: "nell@example.com",
        password: PASSWORD,
      }).toString(),
      redirect: "manual",
    });
    expect(res.status).toBe(302);
    expect(sessionCookie(res)).not.toBeNull();
  });

  // A sandboxed frame gets `Origin: null` too, which is why the value alone
  // decides nothing and Sec-Fetch-Site — unforgeable by a page — decides it.
  test("a sandboxed foreign frame cannot borrow the null origin", async () => {
    const cap = makeCapture();
    const { app } = buildTestApp(pg.db, pg.url, { sendEmail: cap.sendEmail });
    await signUpAndVerify(app, cap.captured, "mallory@example.com");

    const extras: Record<string, string>[] = [{ "sec-fetch-site": "cross-site" }, {}];
    for (const extra of extras) {
      const res = await app.request("/ui/login/password", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          origin: "null",
          ...extra,
        },
        body: new URLSearchParams({
          email: "mallory@example.com",
          password: PASSWORD,
        }).toString(),
        redirect: "manual",
      });
      expect(res.status).toBe(403);
      expect(sessionCookie(res)).toBeNull();
    }
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
    await signUp(app, email);
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
    const user = await createTestUser(pg.db, "long@example.com");
    const { cookie } = await createTestSession(pg.db, user.id);
    const tooLong = "x".repeat(129);

    const res = await post(
      app,
      "/ui/account/password",
      { password: tooLong, confirmPassword: tooLong },
      cookie
    );
    expect(location(res).searchParams.get("passwordError")).toContain("at most 128");
    // A ceiling nobody enforces is the scrypt cost of whatever the caller sent.
    expect(
      await pg.db.account.count({
        where: { userId: user.id, providerId: CREDENTIAL_PROVIDER_ID },
      })
    ).toBe(0);
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
