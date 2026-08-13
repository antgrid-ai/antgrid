import { Hono } from "hono";
import { getCookie } from "hono/cookie";
import { z } from "zod";
import { isAPIError } from "better-auth/api";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import type { Env } from "../env.js";
import type { RelayPushConfig } from "../relay/push.js";
import { findByIdWithHashes, findValidById, checkNonce } from "../models/pending-sign-in.js";
import { COOKIE_BROWSER_TOKEN, ERR_ALREADY_APPROVED } from "../auth/cross-device-plugin.js";
import { ApproveSignInPage } from "../ui/approve-sign-in.js";
import { ApprovedPage } from "../ui/approved.js";
import {
  requireUser,
  requireUserOrRedirect,
  type AuthVars,
} from "../auth/middleware.js";
import { listActiveDevices } from "../models/device.js";
import {
  activeSubscriptionForUser,
  isPendingCancellation,
  provisionProductAccountForUser,
  resolveEntitlement,
} from "../models/subscription.js";
import { revokeUserDevice } from "../services/device.js";
import { tokenBucket } from "../util/rate-limit.js";
import { LoginPage } from "../ui/login.js";
import { LoginPasswordPage } from "../ui/login-password.js";
import { ForgotPasswordPage } from "../ui/forgot-password.js";
import { ResetPasswordPage, ResetLinkInvalidPage } from "../ui/reset-password.js";
import { CheckEmailPage, VerifyEmailFailedPage } from "../ui/check-email.js";
import { SignUpPage } from "../ui/signup.js";
import { MAX_PASSWORD_LENGTH, MIN_PASSWORD_LENGTH } from "../auth/better-auth.js";
import {
  hasPasswordCredential,
  pruneDuplicatePasswordCredentials,
} from "../models/credential.js";
import { DashboardPage } from "../ui/dashboard.js";
import { DevicesPage } from "../ui/devices.js";
import { PricingPage } from "../ui/pricing.js";
import { CheckoutPage, type CheckoutPlan } from "../ui/checkout.js";
import {
  anyCheckoutReady,
  checkoutReadiness,
} from "../billing/checkout.js";
import { displayPriceCents, FREE_TIER, isPlanId } from "../billing/plans.js";
// import { type PlanId } from "../billing/plans.js"; // TEMP-PROMO: restore with the /pricing currentPlanSlug block below once IAP ships.
import { listActivePlans } from "../models/plan.js";
import {
  ensureProductAccount,
  ensureProductAccountCountry,
  isBillingProviderLocked,
  lockBillingProvider,
  previewBillingProvider,
} from "../models/product-account.js";
import { detectCountryFromIp } from "../billing/geo.js";
import type { ClientIpResolver } from "../util/client-ip.js";
import {
  cancelRecurringSubscription,
  resumeRecurringSubscription,
} from "../billing/cancel-subscription.js";
import { PendingPage, PollingIndicator } from "../ui/pending.js";
import { ConnectionsPage } from "../ui/connections.js";
import { fetchConnections } from "../relay/push.js";
import { listUserSessions, type UserSession } from "../services/sessions.js";
import { AccountPage, AccountDeletedPage } from "../ui/account.js";
import { deleteUserAccount, hasRenewingPaidSubscription } from "../services/account.js";

// Internal relay-connections view is restricted to named operators. Gate on
// email (lowercased) — Better-Auth verifies email ownership at sign-in, so it's
// a safe identity anchor here. Non-operators get 404, not 403: don't reveal the
// route exists.
const INTERNAL_OPERATOR_EMAILS = new Set(["bharathm@radhaai.com"]);

export function uiRoutes(deps: {
  db: DB;
  auth: Auth;
  env: Env;
  relay: RelayPushConfig;
  clientIp: ClientIpResolver;
}) {
  const r = new Hono<{ Variables: AuthVars }>();
  const startLimiter = tokenBucket(5, 0.2); // 5 burst, 1 per 5s, per IP
  const approveSignInLimiter = tokenBucket(10, 0.5); // 10 burst, 1 per 2s, per IP
  // Better-Auth's own customRules cover the same endpoints but only arm in
  // production (`rateLimit.enabled` defaults to `isProduction`), and they never
  // see these /ui/* paths anyway — the browser forms reach the endpoints via
  // `auth.api.*`, which is not routed and so never reaches the limiter. Every
  // form below must therefore carry its own bucket; there is no backstop.
  const passwordSignInLimiter = tokenBucket(10, 0.2); // 10 burst, 1 per 5s, per IP
  // Step 1 only decides where to go: no mail, no credential check, no lookup.
  // It can afford to be loose because every branch it hands off to spends its
  // own, tighter budget — this bucket exists so the router itself can't be the
  // cheap way to make the expensive branches run.
  const continueLimiter = tokenBucket(20, 1); // 20 burst, 1 per second, per IP
  const passwordEmailLimiter = tokenBucket(5, 1 / 60); // reset + resend sends
  // Sized to Better-Auth's own `/sign-up/email` rule (10/hour), which this form
  // never reaches: it calls the endpoint in-process. Each admitted request
  // scrypt-hashes a password, writes a user + billing account, and sends mail.
  const signUpLimiter = tokenBucket(10, 1 / 360); // 10 burst, 1 per 6min, per IP
  // Submitting the sign-up FORM, kept off the bucket above for the same reason
  // the reset form is: a mistyped confirmation or a too-short password is
  // rejected before any of that work happens, and must not spend an hour-long
  // budget — three fumbles from each of four people behind one NAT would
  // otherwise lock the address out of signing up at all.
  const signUpSubmitLimiter = tokenBucket(10, 0.2); // 10 burst, 1 per 5s, per IP
  // Submitting the reset FORM, kept off the send bucket above: a user fixing a
  // mismatched confirmation must not spend the budget for requesting a new link.
  const resetSubmitLimiter = tokenBucket(10, 0.2); // 10 burst, 1 per 5s, per IP
  // Keyed by USER, not IP: this one guards an authenticated form whose failure
  // mode is a current-password oracle, and changePassword scrypt-hashes the new
  // password before it verifies the old one — two hashes per wrong guess.
  const passwordWriteLimiter = tokenBucket(5, 1 / 20); // 5 burst, 1 per 20s

  function ipKey(c: import("hono").Context): string {
    return deps.clientIp(c) ?? "unknown";
  }

  const appOrigin = new URL(deps.env.BETTER_AUTH_URL).origin;

  /** Reject a state-changing form post that some other site initiated.
   *
   *  Better-Auth ships exactly this check (`formCsrfMiddleware` on
   *  /sign-in/email) but it is inert for the in-process `auth.api.*` calls
   *  these routes make: it opens `if (!ctx.request) return`, and there is no
   *  request object to hand it — forwarding an Origin header does not arm it
   *  either, since `validateOrigin` reads `ctx.request.headers`. Unguarded,
   *  evil.com can sign a victim's browser into an ATTACKER's account
   *  (/ui/login/password forwards the resulting Set-Cookie), and can plant a
   *  password on a signed-in victim (/ui/account/password takes no current
   *  password when the account has none yet).
   *
   *  A caller sending neither Origin nor Sec-Fetch-Site is not a browser and
   *  has no ambient credentials to abuse, so it passes; browsers always send at
   *  least one on a form POST. Origin is compared against the configured public
   *  origin rather than the request URL, which behind the reverse proxy is the
   *  internal one.
   *
   *  `Origin: null` is what a form POST from our OWN pages carries: app.ts sends
   *  Referrer-Policy: no-referrer, and Fetch serializes a non-CORS request's
   *  origin as `null` under that policy (fetch spec, "append a request Origin
   *  header"). A sandboxed iframe sends the same value, so `null` names no site
   *  either way and cannot be compared — such a request is decided on
   *  Sec-Fetch-Site alone, which is forbidden-header-name and so unforgeable by
   *  a page. Absent that header a stated-`null` origin is refused rather than
   *  waved through: an attacker page can put itself in exactly that state with
   *  its own no-referrer policy. */
  r.use("*", async (c, next) => {
    if (c.req.method === "GET" || c.req.method === "HEAD") return next();
    const origin = c.req.header("origin");
    const site = c.req.header("sec-fetch-site");
    const statedOrigin = origin && origin !== "null" ? origin : null;
    const sameOrigin = statedOrigin
      ? statedOrigin === appOrigin
      : site
        ? site === "same-origin" || site === "none"
        : origin === undefined;
    if (!sameOrigin) return c.text("Forbidden", 403);
    return next();
  });

  /** Headers for an `auth.api.*` call made on behalf of a browser form. Those
   *  endpoints have no socket, so hand them the ALREADY-resolved client IP as a
   *  single hop rather than the forgeable chain — their rate buckets key off it.
   *  Same contract as /ui/login/start. */
  function forwardedHeaders(c: import("hono").Context): Record<string, string> {
    return {
      "content-type": "application/json",
      "user-agent": c.req.header("user-agent") ?? "",
      "x-forwarded-for": deps.clientIp(c) ?? "",
      cookie: c.req.header("cookie") ?? "",
    };
  }

  /** With `asResponse`, Better-Auth serializes a thrown APIError into the
   *  response. Match on `code` (the stable BASE_ERROR_CODES key), never
   *  `message` — that one is prose and gets reworded upstream. */
  async function authErrorCode(res: Response): Promise<string | null> {
    try {
      const body = (await res.json()) as { code?: unknown };
      return typeof body.code === "string" ? body.code : null;
    } catch {
      return null;
    }
  }

  /** Headers for an `auth.api.*` call that must take its UNAUTHENTICATED
   *  branch. `sendVerificationEmail` looks up the session first and, when it
   *  finds one, throws EMAIL_MISMATCH/EMAIL_ALREADY_VERIFIED instead of
   *  reaching the enumeration-safe path the resend button relies on — so it
   *  must not see the browser's cookie. */
  function anonymousHeaders(c: import("hono").Context): Record<string, string> {
    const { cookie: _cookie, ...rest } = forwardedHeaders(c);
    return rest;
  }

  /** Both bounds, in one message. Better-Auth throws PASSWORD_TOO_LONG ahead of
   *  every other check and the code matches none of the handlers' cases, so an
   *  unenforced ceiling surfaces as a generic "try again" that never succeeds. */
  function passwordLengthError(password: string): string | null {
    if (password.length < MIN_PASSWORD_LENGTH) {
      return `Password must be at least ${MIN_PASSWORD_LENGTH} characters`;
    }
    if (password.length > MAX_PASSWORD_LENGTH) {
      return `Password must be at most ${MAX_PASSWORD_LENGTH} characters`;
    }
    return null;
  }

  function forwardSetCookies(c: import("hono").Context, res: Response): void {
    // One header per cookie — see the /logout comment below for why
    // `headers.get("set-cookie")` cannot be used here.
    for (const sc of res.headers.getSetCookie()) {
      c.header("set-cookie", sc, { append: true });
    }
  }

  function redirectWith(
    c: import("hono").Context,
    path: string,
    params: Record<string, string>
  ) {
    const qs = new URLSearchParams(params).toString();
    return c.redirect(qs ? `${path}?${qs}` : path);
  }

  r.get("/", (c) => c.redirect("/dashboard"));

  // Better-Auth's POST /api/auth/sign-out returns `{success:true}` JSON, not a
  // redirect — pointing a server-rendered form at it dumps JSON in the browser.
  // Drive sign-out through the server API and forward its cookie-clearing
  // Set-Cookie onto a 302 back to the app root (which bounces to /login when
  // signed out). No-op safe: signOut clears the cookie even without a session.
  r.post("/logout", async (c) => {
    const res = await deps.auth.api.signOut({
      headers: c.req.raw.headers,
      asResponse: true,
    });
    // Forward EACH Set-Cookie as its own header. signOut can clear more than
    // one cookie, and `headers.get("set-cookie")` would comma-join them — fatal
    // here because the clearing cookies carry `Expires=...GMT` (a comma the
    // browser can't disambiguate). Mirrors oauth-start.ts / the login handlers.
    for (const sc of res.headers.getSetCookie()) {
      c.header("set-cookie", sc, { append: true });
    }
    return c.redirect("/");
  });

  r.get("/login", (c) => {
    const error = c.req.query("error") ?? null;
    const notice = c.req.query("notice") ?? null;
    // Round-tripped by step 2's "change" link, so stepping back never costs the
    // user the address they already typed.
    const email = c.req.query("email") ?? null;
    return c.html(<LoginPage error={error} notice={notice} email={email} />);
  });

  /** Send a cross-device magic link and hand the browser its pending page.
   *
   *  Two entry points reach it: step 1's fall-through below, and the forms that
   *  post to /ui/login/start (step 2's "Email me a link instead", the pending
   *  page's resend).
   *
   *  Its `startLimiter` token is spent by the CALLER, not here — each entry
   *  point has to bucket ahead of its own body read (see /ui/login/continue),
   *  and a second charge here would halve the budget rather than protect
   *  anything. */
  async function startMagicLink(c: import("hono").Context, email: string) {
    const res = await deps.auth.api.crossDeviceStart({
      method: "POST",
      headers: {
        "content-type": "application/json",
        "user-agent": c.req.header("user-agent") ?? "",
        // The plugin has no socket access, so hand it the ALREADY-resolved
        // client IP as a single-hop header instead of the raw (forgeable)
        // chain — it reads the rightmost hop (see cross-device-plugin.ts).
        "x-forwarded-for": deps.clientIp(c) ?? "",
        cookie: c.req.header("cookie") ?? "",
      },
      body: { email },
      asResponse: true
    });
    if (!res.ok) {
      return c.redirect(`/login?error=${encodeURIComponent("Could not send link")}`);
    }
    forwardSetCookies(c, res);
    const { id } = (await res.json()) as { id: string };
    return c.redirect(`/login/pending/${id}?email=${encodeURIComponent(email)}`);
  }

  r.post("/ui/login/continue", async (c) => {
    // Bucket first, body second, and the same order everywhere below. Bun hands
    // the handler the request as soon as the headers land and streams the body
    // lazily, so returning before `formData()` costs nothing — reading it first
    // buffers an attacker-chosen body (128 MiB by default, ~4x that in RSS) for
    // a request already destined for 429.
    if (!continueLimiter(ipKey(c))) {
      return redirectWith(c, "/login", { error: "Too many requests" });
    }
    const form = await c.req.formData();
    const email = String(form.get("email") ?? "").trim();
    // What the BROWSER remembers about its own last sign-in (ui/auth-memory.ts),
    // never something this server looked up — no route here knows whether an
    // address has an account, a password, or a provider, and keeping it that way
    // is the whole design. So it is untrusted input like any other field.
    const method = String(form.get("method") ?? "");
    if (!email) return redirectWith(c, "/login", { error: "Email required" });

    // The link branch, reached two ways: asked for outright, or landed on
    // because nothing better is known. One body so both spend the same token —
    // /ui/login/start's budget is what stands between this and a mailer.
    const sendLink = async () => {
      if (!startLimiter(ipKey(c))) {
        return redirectWith(c, "/login", { error: "Too many requests" });
      }
      return startMagicLink(c, email);
    };

    // A submit button naming its own branch, read ahead of the switch: the hint
    // says what this browser did last time, the button says what the user wants
    // now, and the second outranks the first. `data-ab-recall` fills the hidden
    // `method` field on every submit of this form, so a stale hint always rides
    // along with the click trying to get away from it.
    //
    // `password` is the one step 1 renders — nothing else writes that hint but a
    // password sign-in and /account, so a browser that has watched neither could
    // never reach step 2 on its own, and a wrong provider hint would relaunch
    // itself on every Continue. Neither branch asks the server anything about
    // the address; step 2 is a form, not an answer.
    //
    // `link` is still honoured for a page cached before that button moved into
    // the method block, so it is not routed by the very hint it was posted to
    // escape.
    const fallback = String(form.get("fallback") ?? "");
    if (fallback === "password") {
      return redirectWith(c, "/login/password", { email });
    }
    if (fallback === "link") return sendLink();

    switch (method) {
      case "password":
        return redirectWith(c, "/login/password", { email });
      // Switched on the two literals rather than forwarded: `method` is
      // client-supplied, and a value it chose must never reach the `provider`
      // param.
      case "github":
        return c.redirect("/oauth/start?provider=github&callbackURL=/dashboard");
      case "google":
        return c.redirect("/oauth/start?provider=google&callbackURL=/dashboard");
      default:
        // Absent, unrecognised, or simply wrong about this address — one answer
        // for all three. The link is the only branch that needs no server-side
        // verdict on whether the account exists, and it resolves either case:
        // cross-device approve signs up on approve.
        return sendLink();
    }
  });

  r.get("/login/password", (c) => {
    const email = c.req.query("email") ?? "";
    // Never render step 2 without the address it belongs to: it has no email
    // field of its own, so an empty one is a dead end, and reaching it at all
    // means the client-side hint was lost — step 1 is where that is rebuilt.
    if (!email) return c.redirect("/login");
    return c.html(
      <LoginPasswordPage email={email} error={c.req.query("error") ?? null} />
    );
  });

  r.post("/ui/login/password", async (c) => {
    if (!passwordSignInLimiter(ipKey(c))) {
      // Back to step 1, not step 2 — the address only exists in the body, and
      // the bucket has to be spent before that is read (see /ui/login/continue).
      // Step 1
      // prefills the last-used address from the browser, so the round trip
      // costs a click rather than the address.
      return redirectWith(c, "/login", { error: "Too many requests" });
    }
    const form = await c.req.formData();
    const email = String(form.get("email") ?? "").trim().toLowerCase();
    const password = String(form.get("password") ?? "");
    // The checkbox is simply absent from the body when unchecked, so presence
    // IS the answer — never compare against its value.
    const rememberMe = form.has("rememberMe");

    if (!email || !password) {
      return redirectWith(c, "/login", { error: "Email and password required" });
    }

    const res = await deps.auth.api.signInEmail({
      method: "POST",
      headers: forwardedHeaders(c),
      body: { email, password, rememberMe },
      asResponse: true,
    });
    if (!res.ok) {
      if ((await authErrorCode(res)) === "EMAIL_NOT_VERIFIED") {
        // Reached only AFTER the password verified (api/routes/sign-in.mjs), so
        // naming this state discloses nothing a correct password didn't already.
        // Issue the resend here rather than via `sendOnSignIn`: the token is a
        // stateless JWT with no cooldown, so the send has to spend the same
        // per-IP email budget as the resend button or a self-registered,
        // never-verified address becomes a 700-mails-an-hour firehose.
        const sent = passwordEmailLimiter(ipKey(c));
        if (sent) {
          await deps.auth.api
            .sendVerificationEmail({
              method: "POST",
              headers: anonymousHeaders(c),
              body: { email },
              asResponse: true,
            })
            .catch(() => undefined);
        }
        // Report what actually happened. Claiming a fresh link on the throttled
        // branch leaves the user waiting on mail nobody sent, and their only
        // recourse — signing in again — spends the sign-in bucket instead.
        return redirectWith(c, "/login/check-email", {
          email,
          ...(sent ? { resent: "1" } : { throttled: "1" }),
        });
      }
      // Everything else collapses to one message deliberately: Better-Auth
      // returns the same INVALID_EMAIL_OR_PASSWORD for a wrong password, an
      // unknown address, AND an account that has no password at all
      // (magic-link/OAuth only). Wording that told them apart would be an
      // enumeration oracle — the standing hint under the form is what tells
      // that last user where to go instead.
      //
      // Back to step 2 with the address intact: it was settled a step ago, and
      // the "Email me a link instead" button this lands next to is the way out
      // for the user the collapse is hiding.
      return redirectWith(c, "/login/password", {
        email,
        error: "Invalid email or password",
      });
    }
    forwardSetCookies(c, res);
    return c.redirect("/dashboard");
  });

  r.get("/signup", (c) =>
    c.html(
      <SignUpPage
        email={c.req.query("email") ?? null}
        error={c.req.query("error") ?? null}
        minPasswordLength={MIN_PASSWORD_LENGTH}
        maxPasswordLength={MAX_PASSWORD_LENGTH}
      />
    )
  );

  r.post("/ui/signup", async (c) => {
    // Bucket ahead of the body read, as everywhere here — see
    // /ui/login/continue for why the order is load bearing. This is the cheap
    // one; the account write spends its own below, once the form is known good.
    if (!signUpSubmitLimiter(ipKey(c))) {
      return redirectWith(c, "/signup", { error: "Too many requests" });
    }
    const form = await c.req.formData();
    const email = String(form.get("email") ?? "").trim().toLowerCase();
    const password = String(form.get("password") ?? "");
    const confirm = String(form.get("confirmPassword") ?? "");
    // Carry the address back on every failure: this page has no step to return
    // to, so dropping it turns a mistyped password into a retyped everything.
    const fail = (message: string) =>
      redirectWith(c, "/signup", { ...(email ? { email } : {}), error: message });

    if (!email) return fail("Email required");
    if (password !== confirm) return fail("Passwords do not match");
    const lengthError = passwordLengthError(password);
    if (lengthError) return fail(lengthError);
    // Charged only now, so the expensive budget is spent by requests that
    // actually reach the scrypt hash + user/billing write + mail. Keyed on the
    // IP alone, so which address is being typed changes nothing here — the
    // reply stays as address-blind as the success path.
    if (!signUpLimiter(ipKey(c))) return fail("Too many requests");

    const res = await deps.auth.api.signUpEmail({
      method: "POST",
      headers: forwardedHeaders(c),
      // Named by address, matching the users the cross-device plugin creates —
      // an account looks the same whichever door made it, and asking for a
      // display name here would be a field with nothing riding on it.
      body: { email, password, name: email },
      asResponse: true,
    });
    if (!res.ok) {
      const code = await authErrorCode(res);
      if (code === "PASSWORD_TOO_SHORT" || code === "PASSWORD_TOO_LONG") {
        return fail(passwordLengthError(password) ?? "Choose a different password");
      }
      // Not USER_ALREADY_EXISTS — with requireEmailVerification on, Better-Auth
      // answers a duplicate with a synthetic success and sends nothing, which
      // is what keeps this endpoint from being an enumeration oracle. It lands
      // on the same page as a fresh sign-up, and that page says what a user in
      // that case should do instead.
      return fail("Could not create your account. Try again.");
    }
    // Deliberately NOT forwarding Set-Cookie. `autoSignIn` is off, so there is
    // none — and were that default ever to change under us, forwarding it would
    // hand the ProductAccount `user.create.after` just provisioned to whoever
    // typed the address rather than to whoever can read the mail.
    return redirectWith(c, "/login/check-email", { email, created: "1" });
  });

  r.get("/login/check-email", (c) => {
    const email = c.req.query("email") ?? null;
    const throttled = c.req.query("throttled");
    return c.html(
      <CheckEmailPage
        kind="verify"
        email={email}
        // Only the sign-up landing writes the hint. The other way in here is an
        // unverified password sign-in, whose browser already learned it.
        rememberPassword={Boolean(c.req.query("created"))}
        notice={
          c.req.query("resent")
            ? "Your email isn't verified yet — we've sent a fresh link."
            : null
        }
        error={
          throttled
            ? "Too many requests — no link was sent. Wait a minute, then use " +
              "the button below."
            : null
        }
      />
    );
  });

  r.post("/ui/verify-email/resend", async (c) => {
    // Address rides in the query, not the body, so the throttled reply can echo
    // it back without reading a body we are about to discard — the page needs it
    // to render the address AND the resend button, which is gated on having one.
    // Keeps the bucket ahead of any body read; see /ui/login/continue.
    const email = (c.req.query("email") ?? "").trim().toLowerCase();
    if (!email) return c.redirect("/login");
    if (!passwordEmailLimiter(ipKey(c))) {
      return redirectWith(c, "/login/check-email", { email, throttled: "1" });
    }
    // Enumeration-safe by construction: the endpoint reports success without
    // sending for an unknown or already-verified address, so the reply below is
    // the same either way. Errors are swallowed for that same reason. Sent
    // WITHOUT the cookie — a signed-in caller (back button after verifying)
    // would otherwise be answered from the session branch, which throws rather
    // than taking the path this comment describes.
    await deps.auth.api
      .sendVerificationEmail({
        method: "POST",
        headers: anonymousHeaders(c),
        body: { email },
        asResponse: true,
      })
      .catch(() => undefined);
    return redirectWith(c, "/login/check-email", { email, resent: "1" });
  });

  // Landing for the emailed verification link. Better-Auth redirects here bare
  // on success — with `autoSignInAfterVerification` the session cookie is
  // already set, so /dashboard just works — and with `?error=<CODE>` when the
  // token is expired or forged.
  r.get("/login/verified", async (c) => {
    if (c.req.query("error")) return c.html(<VerifyEmailFailedPage />);
    // Only the FIRST open of the link carries a session: Better-Auth
    // short-circuits an already-verified user before the
    // autoSignInAfterVerification block, so it redirects here bare. That is the
    // normal case whenever a mail scanner prefetches the link (SafeLinks,
    // Proofpoint) or the user opens it on a second device — bouncing them to
    // /dashboard would land them on an unexplained sign-in page instead.
    const session = await deps.auth.api.getSession({ headers: c.req.raw.headers });
    if (!session) {
      return redirectWith(c, "/login", {
        notice: "Email verified. Sign in to continue.",
      });
    }
    return c.redirect("/dashboard");
  });

  r.get("/forgot-password", (c) =>
    c.html(
      <ForgotPasswordPage
        error={c.req.query("error") ?? null}
        // Carried in from step 2's "Forgot your password?" link. A prefill only
        // — the page still sends to whatever is submitted, and still answers
        // identically for an address with no account.
        email={c.req.query("email") ?? null}
      />
    )
  );

  r.post("/ui/forgot-password", async (c) => {
    if (!passwordEmailLimiter(ipKey(c))) {
      return redirectWith(c, "/forgot-password", { error: "Too many requests" });
    }
    const form = await c.req.formData();
    const email = String(form.get("email") ?? "").trim().toLowerCase();
    if (!email) return redirectWith(c, "/forgot-password", { error: "Email required" });
    await deps.auth.api
      .requestPasswordReset({
        method: "POST",
        headers: forwardedHeaders(c),
        // Relative path: Better-Auth origin-checks redirectTo, and the token
        // callback appends `?token=` (or `?error=`) to it before we render.
        body: { email, redirectTo: "/reset-password" },
        asResponse: true,
      })
      .catch(() => undefined);
    // Always the same answer, whether or not that address has an account — the
    // endpoint is enumeration-safe and this page must not undo that. No email
    // is echoed back for the same reason, which is also why the redirect below
    // carries no params.
    //
    // Redirect rather than render: a rendered POST leaves the send in history,
    // so a refresh re-submits it and spends another token from a bucket the
    // user needs to request a replacement link.
    return c.redirect("/forgot-password/sent");
  });

  r.get("/forgot-password/sent", (c) => c.html(<CheckEmailPage kind="reset" />));

  r.get("/reset-password", (c) => {
    const token = c.req.query("token") ?? "";
    // No token means Better-Auth's `/reset-password/:token` callback rejected
    // it and bounced here with `?error=INVALID_TOKEN`; a bare visit lands the
    // same way. Never render the form without one.
    if (!token) return c.html(<ResetLinkInvalidPage />);
    return c.html(
      <ResetPasswordPage
        token={token}
        error={c.req.query("error") ?? null}
        minPasswordLength={MIN_PASSWORD_LENGTH}
        maxPasswordLength={MAX_PASSWORD_LENGTH}
      />
    );
  });

  r.post("/ui/reset-password", async (c) => {
    // The token is unguessable, so this bucket is not the security boundary —
    // it is what keeps an unauthenticated endpoint that does a DB lookup and a
    // scrypt hash per call from being a free CPU lever. Better-Auth's own
    // /reset-password rule cannot cover it (in-process call, no router).
    //
    // Its OWN bucket, not the send bucket: this form is submitted repeatedly by
    // a user fixing a mismatched confirmation, and every one of those attempts
    // would otherwise spend budget they need to request a NEW reset link if
    // this token lapses.
    if (!resetSubmitLimiter(ipKey(c))) {
      // Keep the token — dropping it strands a user holding a still-valid link
      // with no way back to the form.
      const throttledToken = c.req.query("token") ?? "";
      if (!throttledToken) return c.html(<ResetLinkInvalidPage />);
      return redirectWith(c, "/reset-password", {
        token: throttledToken,
        error: "Too many attempts. Wait a moment, then try again.",
      });
    }
    const form = await c.req.formData();
    const token = String(form.get("token") ?? "");
    const password = String(form.get("password") ?? "");
    const confirm = String(form.get("confirmPassword") ?? "");
    if (!token) return c.html(<ResetLinkInvalidPage />);
    const fail = (message: string) =>
      redirectWith(c, "/reset-password", { token, error: message });

    if (password !== confirm) return fail("Passwords do not match");
    const lengthError = passwordLengthError(password);
    if (lengthError) return fail(lengthError);

    const res = await deps.auth.api.resetPassword({
      method: "POST",
      headers: forwardedHeaders(c),
      body: { token, newPassword: password },
      asResponse: true,
    });
    if (!res.ok) {
      const code = await authErrorCode(res);
      if (code === "INVALID_TOKEN") return c.html(<ResetLinkInvalidPage />);
      return fail("Could not set your password. Try again.");
    }
    // revokeSessionsOnPasswordReset dropped every session for this user,
    // including any this browser held, so there is nothing to sign in to yet.
    return redirectWith(c, "/login", {
      notice: "Password updated. Sign in with your new password.",
    });
  });

  r.post("/ui/login/start", async (c) => {
    if (!startLimiter(ipKey(c))) {
      return c.redirect("/login?error=Too%20many%20requests");
    }
    const form = await c.req.formData();
    const email = String(form.get("email") ?? "").trim();
    if (!email) return c.redirect("/login?error=Email%20required");
    return startMagicLink(c, email);
  });

  r.get("/login/pending/:id", (c) => {
    const id = c.req.param("id");
    const email = c.req.query("email") ?? "";
    if (!z.uuid().safeParse(id).success) return c.redirect("/login");
    return c.html(<PendingPage email={email} pendingId={id} />);
  });

  /** Lowercased address this browser already holds a session for, if any. */
  async function signedInAs(c: import("hono").Context): Promise<string | null> {
    const session = await deps.auth.api.getSession({ headers: c.req.raw.headers });
    return session?.user.email?.toLowerCase() ?? null;
  }

  /** Whether the browser opening this link is the one that asked for it.
   *
   *  The bind cookie is the same secret /sign-in/cross-device/status demands
   *  before it hands out a session, so a match proves this browser started THIS
   *  row — the approval screen exists to warn a second party, and here there
   *  isn't one. It is httpOnly and written only by start, so no site can plant
   *  it, and an unattended fetch (SafeLinks, Proofpoint, a mail client
   *  prefetching URLs) carries no cookies at all and so still meets the screen.
   */
  function startedInThisBrowser(
    c: import("hono").Context,
    row: { id: string; browserTokenHash: Uint8Array }
  ): boolean {
    const cookie = getCookie(c, COOKIE_BROWSER_TOKEN);
    if (!cookie) return false;
    const dot = cookie.indexOf(".");
    if (dot < 0 || cookie.slice(0, dot) !== row.id) return false;
    return checkNonce(
      row.browserTokenHash,
      cookie.slice(dot + 1),
      deps.env.BETTER_AUTH_SECRET
    );
  }

  /** Turn an approved row into a session for the browser holding its bind
   *  cookie. True when that browser leaves signed in as `email` either way: the
   *  waiting tab may have claimed the row a poll earlier, which is the same
   *  outcome one tab sooner, not a failure to report. */
  async function claimApprovedSession(
    c: import("hono").Context,
    email: string
  ): Promise<boolean> {
    const res = await deps.auth.api.crossDeviceStatus({
      method: "GET",
      headers: { cookie: c.req.header("cookie") ?? "" },
      asResponse: true,
    });
    forwardSetCookies(c, res);
    const body = (await res.json()) as { status?: string };
    if (body.status === "ready") return true;
    return (await signedInAs(c)) === email.toLowerCase();
  }

  r.get("/ui/login/poll/:id", async (c) => {
    const id = c.req.param("id");
    if (!z.uuid().safeParse(id).success) return c.text("expired", 200);

    const res = await deps.auth.api.crossDeviceStatus({
      method: "GET",
      headers: { cookie: c.req.header("cookie") ?? "" },
      asResponse: true
    });
    // Forward Set-Cookie from the plugin response (status=ready sets the session cookie).
    for (const [k, v] of res.headers) {
      if (k.toLowerCase() === "set-cookie") c.header("Set-Cookie", v, { append: true });
    }
    const body = (await res.json()) as { status: string; delivery?: string | null };
    if (body.status === "ready") {
      c.header("HX-Redirect", "/dashboard");
      return c.text("");
    }
    if (body.status === "expired" || body.status === "consumed" || body.status === "unbound") {
      // The tab that opened the link may have claimed the session itself, which
      // consumes the row and clears the bind cookie — from here that is
      // indistinguishable from a dead link. Telling a signed-in user their link
      // expired is the one answer that is certainly wrong, so rule it out
      // before saying it. Matched on the row's own address: a browser signed in
      // as somebody else has not completed THIS flow.
      const row = await findValidById(deps.db, id);
      if (row && (await signedInAs(c)) === row.email.toLowerCase()) {
        c.header("HX-Redirect", "/dashboard");
        return c.text("");
      }
      c.header("HX-Redirect", "/login?error=Link%20expired");
      return c.text("");
    }
    if (body.delivery === "bounced") {
      // Hard bounce: the link will never arrive, so stop polling and tell the
      // user — parity with the app's bounced screen. delivery rides the pending
      // response; ZeptoMail sends no "delivered" event, so there is no success case.
      c.header(
        "HX-Redirect",
        `/login?error=${encodeURIComponent("We couldn't deliver the link — check the address and try again")}`
      );
      return c.text("");
    }
    // pending: re-render the same fragment so polling continues.
    return c.html(<PollingIndicator pendingId={id} />);
  });

  r.get("/login/approve", async (c) => {
    const id = c.req.query("id") ?? "";
    const token = c.req.query("t") ?? "";
    if (!z.uuid().safeParse(id).success || !token) {
      return c.redirect("/login?error=Invalid%20link");
    }
    const row = await findByIdWithHashes(deps.db, id);
    if (!row || row.expiresAt < new Date()) {
      return c.redirect("/login?error=Link%20expired");
    }
    if (!checkNonce(row.nonceHash, token, deps.env.BETTER_AUTH_SECRET)) {
      return c.redirect("/login?error=Invalid%20link");
    }
    // Both branches below are kept after the nonce check so neither the
    // approval state nor the interstitial is readable from the row id alone.
    const ownRequest = startedInThisBrowser(c, row);

    // Re-opening an approved link — back button, a second tap, a mail client
    // prefetching URLs — is a success the user already earned, not a reused
    // link. Whoever ends up signed in as the address on the row has nothing
    // left to do here, so send them where they were going.
    if (row.approvedAt) {
      const signedIn = ownRequest
        ? await claimApprovedSession(c, row.email)
        : (await signedInAs(c)) === row.email.toLowerCase();
      return c.redirect(signedIn ? "/dashboard" : "/login/approved");
    }

    // The link opened in the browser that asked for it: approving is a step
    // where the user confirms something to themselves, about a request they
    // made seconds ago, on the device they made it from. Skip it and finish the
    // sign-in here — the interstitial still stands for every other opener.
    if (ownRequest) {
      // Same budget the explicit approve spends: this path approves too.
      if (!approveSignInLimiter(ipKey(c))) {
        return c.redirect("/login?error=Too%20many%20requests");
      }
      try {
        await deps.auth.api.crossDeviceApprove({
          method: "POST",
          headers: { "content-type": "application/json" },
          body: { id: row.id, token },
        });
      } catch (err) {
        // A second open racing the first approved it already — that is this
        // request's own work landing, so carry on and claim the session.
        if (!(isAPIError(err) && err.body?.message === ERR_ALREADY_APPROVED)) {
          return c.redirect("/login?error=Could%20not%20approve");
        }
      }
      const signedIn = await claimApprovedSession(c, row.email);
      return c.redirect(signedIn ? "/dashboard" : "/login/approved");
    }
    // expiresAt = createdAt + 10m. Showing expiresAt as "requested at" is
    // imprecise but acceptable for the approver UI.
    return c.html(
      <ApproveSignInPage
        email={row.email}
        requesterUa={row.requesterUa}
        requesterIp={row.requesterIp}
        requestedAt={row.expiresAt}
        pendingId={row.id}
        token={token}
      />
    );
  });

  r.post("/ui/login/approve", async (c) => {
    if (!approveSignInLimiter(ipKey(c))) {
      return c.redirect("/login?error=Too%20many%20requests");
    }
    const form = await c.req.formData();
    const id = String(form.get("id") ?? "");
    const token = String(form.get("token") ?? "");
    try {
      await deps.auth.api.crossDeviceApprove({
        method: "POST",
        headers: { "content-type": "application/json" },
        body: { id, token },
      });
    } catch (err) {
      // A double-clicked button re-POSTs the same form. The first POST already
      // approved the row, so ALREADY_APPROVED means the approval landed — report
      // success rather than an error the approver cannot act on.
      if (isAPIError(err) && err.body?.message === ERR_ALREADY_APPROVED) {
        return c.redirect("/login/approved");
      }
      // Better-Auth APIError (bad token / expired / consumed) — surface a
      // generic message so we don't reveal which condition failed.
      return c.redirect("/login?error=Could%20not%20approve");
    }
    return c.redirect("/login/approved");
  });

  r.get("/login/approved", (c) => c.html(<ApprovedPage />));

  r.post("/ui/sign-out", async (c) => {
    const origin = new URL(c.req.url).origin;
    const res = await deps.auth.api.signOut({
      method: "POST",
      headers: {
        cookie: c.req.header("cookie") ?? "",
        origin,
        "content-type": "application/json",
      },
      asResponse: true,
    });
    for (const [k, v] of res.headers) {
      if (k.toLowerCase() === "set-cookie") c.header("Set-Cookie", v, { append: true });
    }
    if (!res.ok) return c.redirect("/dashboard?error=Could%20not%20sign%20out");
    return c.redirect("/login");
  });

  r.post("/ui/subscription/cancel", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    const sub = await activeSubscriptionForUser(deps.db, userId);
    if (!sub) return c.redirect("/dashboard?cancel=failed");

    const plan = await deps.db.plan.findUnique({ where: { id: sub.planId } });
    if (!plan?.recurring || sub.status !== "active" || isPendingCancellation(sub)) {
      return c.redirect("/dashboard?cancel=failed");
    }

    try {
      const { effective } = await cancelRecurringSubscription(deps.db, deps.relay, deps.env, {
        accountId: sub.accountId,
        subscription: { ...sub, plan },
      });
      if (effective === "immediately") return c.redirect("/dashboard?cancel=immediate");
      return c.redirect("/dashboard?cancel=pending");
    } catch {
      return c.redirect("/dashboard?cancel=failed");
    }
  });

  r.post("/ui/subscription/resume", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    const sub = await activeSubscriptionForUser(deps.db, userId);
    if (!sub) return c.redirect("/dashboard?resume=failed");

    const plan = await deps.db.plan.findUnique({ where: { id: sub.planId } });
    if (!plan?.recurring || !isPendingCancellation(sub)) {
      return c.redirect("/dashboard?resume=failed");
    }

    try {
      await resumeRecurringSubscription(deps.db, deps.env, {
        subscription: { ...sub, plan },
      });
      return c.redirect("/dashboard?resume=success");
    } catch {
      return c.redirect("/dashboard?resume=failed");
    }
  });

  r.get(
    "/internal/connections",
    requireUserOrRedirect({ auth: deps.auth }),
    async (c) => {
      const email = c.get("userEmail")?.toLowerCase() ?? "";
      if (!INTERNAL_OPERATOR_EMAILS.has(email)) {
        // Record denied probes too — for a surveillance endpoint, a non-operator
        // fishing for the route is exactly what the audit trail should capture.
        console.warn(
          JSON.stringify({
            evt: "internal.connections.denied",
            userId: c.get("userId"),
            email,
            at: new Date().toISOString(),
          }),
        );
        return c.notFound();
      }

      // Audit every access: a read of the live-connection map is a surveillance
      // capability the relay can't attribute (it only authenticates "web"), so
      // operator attribution must be logged here, at the gate.
      console.info(
        JSON.stringify({
          evt: "internal.connections.access",
          userId: c.get("userId"),
          email,
          at: new Date().toISOString(),
        }),
      );

      let connections: Awaited<ReturnType<typeof fetchConnections>> | null;
      try {
        connections = await fetchConnections(deps.relay);
      } catch (e) {
        console.warn("[internal.connections] relay fetch failed", e);
        connections = null;
      }
      return c.html(
        <ConnectionsPage
          user={{ email: c.get("userEmail") }}
          connections={connections}
          now={Date.now()}
        />,
      );
    },
  );

  r.get("/upgrade", (c) => c.redirect("/pricing"));

  r.get("/pricing", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    const plans = await listActivePlans(deps.db);
    // TEMP-PROMO: every plan renders as a disabled "Coming soon" card while
    // in-app purchases aren't live — grep "TEMP-PROMO" repo-wide for every
    // related spot (backend grant logic in web/src/models/subscription.ts
    // plus the matching disabled UI in web/src/ui/pricing.tsx).
    //
    // TO RESTORE ONCE PAYMENT INTEGRATION SHIPS: delete the `const plans =`
    // line above and the `c.html(...)` call below, then uncomment the two
    // blocks below (strip the leading "// ") — this re-adds the real
    // current-plan lookup that ui/pricing.tsx's restored version expects.
    //
    // const [plans, sub] = await Promise.all([
    //   listActivePlans(deps.db),
    //   activeSubscriptionForUser(deps.db, userId),
    // ]);
    // let currentPlanSlug: PlanId | null = null;
    // if (sub && sub.tier !== FREE_TIER) {
    //   const plan = await deps.db.plan.findUnique({ where: { id: sub.planId } });
    //   if (plan && isPlanId(plan.slug)) currentPlanSlug = plan.slug;
    // }
    return c.html(
      <PricingPage user={{ email: c.get("userEmail") }} plans={plans} env={deps.env} />
      // <PricingPage
      //   user={{ email: c.get("userEmail") }}
      //   plans={plans}
      //   env={deps.env}
      //   currentPlanSlug={currentPlanSlug}
      // />
    );
  });

  r.get("/checkout", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const rawPlanId = c.req.query("planId") ?? "trial";
    const selectedPlanId = isPlanId(rawPlanId) ? rawPlanId : "trial";

    const userId = c.get("userId");
    const { id: accountId } = await provisionProductAccountForUser(deps.db, userId);
    let account = await ensureProductAccount(deps.db, userId);
    const planRows = await listActivePlans(deps.db);
    if (planRows.length === 0) return c.redirect("/pricing");

    const detected =
      account.country ??
      (await detectCountryFromIp(deps.clientIp(c), deps.env.IPINFO_TOKEN));
    if (!account.country && detected) {
      account = await ensureProductAccountCountry(deps.db, accountId, detected, "ipinfo");
    }
    const country = account.country ?? detected;
    if (!isBillingProviderLocked(account) && country) {
      await lockBillingProvider(deps.db, accountId, country);
      account = await ensureProductAccount(deps.db, userId);
    }
    const gateway = previewBillingProvider(account, country);

    const planRow = planRows.find((row) => row.slug === selectedPlanId);
    if (!planRow || !isPlanId(planRow.slug)) return c.redirect("/pricing");

    const chargePrice = displayPriceCents(selectedPlanId, deps.env);
    const plan: CheckoutPlan = {
      id: planRow.slug,
      label: planRow.label,
      recurring: planRow.recurring,
      trial: planRow.trial,
      workerLimit: planRow.workerLimit,
      displayPrice: chargePrice,
      chargePrice,
    };

    const readiness = checkoutReadiness(deps.env, [selectedPlanId]);
    const checkoutAvailable = anyCheckoutReady(readiness);

    return c.html(
      <CheckoutPage
        user={{ email: c.get("userEmail") }}
        plan={plan}
        detectedCountry={country}
        gateway={gateway}
        readiness={readiness}
        checkoutAvailable={checkoutAvailable}
        isDev={deps.env.NODE_ENV === "development"}
      />
    );
  });

  r.get("/devices", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    const devices = await listActiveDevices(deps.db, userId);
    return c.html(<DevicesPage user={{ email: c.get("userEmail") }} devices={devices} />);
  });

  r.get("/dashboard", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    const [sub, devices] = await Promise.all([
      activeSubscriptionForUser(deps.db, userId),
      listActiveDevices(deps.db, userId),
    ]);
    if (!sub) return c.redirect("/login");
    // resolveEntitlement only needs sub; compute tier now so we can prefetch sessions.
    const { tier, deviceLimit, workerLimit } = resolveEntitlement(sub);
    // Run plan lookup and sessions fetch concurrently — they're independent.
    const [plan, sessions] = await Promise.all([
      deps.db.plan.findUnique({ where: { id: sub.planId } }),
      // Fetched on every tier: Free has remote control too. null = relay unreachable.
      listUserSessions(deps.relay, userId, devices),
    ]);
    if (!plan) return c.redirect("/login");
    const purchaseSuccess = c.req.query("purchase") === "success";
    const cancelRaw = c.req.query("cancel");
    const resumeRaw = c.req.query("resume");
    return c.html(
      <DashboardPage
        user={{ email: c.get("userEmail") }}
        subscription={sub}
        plan={plan}
        tier={tier}
        deviceLimit={deviceLimit}
        activeDevices={devices.length}
        workerLimit={workerLimit}
        // The worker cap counts agent rows only; the desktop app also registers
        // an `app` controller row for itself, which must not be metered here.
        activeWorkers={devices.filter((d) => d.kind === "agent").length}
        sessions={sessions}
        now={Date.now()}
        purchaseSuccess={purchaseSuccess}
        cancelNotice={
          cancelRaw === "immediate" || cancelRaw === "pending" || cancelRaw === "failed"
            ? cancelRaw
            : null
        }
        resumeNotice={resumeRaw === "success" || resumeRaw === "failed" ? resumeRaw : null}
      />
    );
  });

  // HTMX removes the row on success (empty body + hx-swap="outerHTML").
  r.delete("/ui/devices/:id", requireUser({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    const id = c.req.param("id");
    if (!z.uuid().safeParse(id).success) return c.text("not found", 404);
    // Thread request headers so deleteDeviceOAuthClient can use the session.
    // This is a session-authed HTMX route, so headers are always available.
    await revokeUserDevice(deps.db, deps.relay, deps.auth, {
      userId,
      deviceUuid: id,
      headers: c.req.raw.headers,
    });
    return c.text("");
  });

  r.get("/account", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    await provisionProductAccountForUser(deps.db, userId);
    // Same predicate the DELETE endpoint uses — one source of truth.
    const [blocked, hasPassword] = await Promise.all([
      hasRenewingPaidSubscription(deps.db, userId),
      hasPasswordCredential(deps.db, userId),
    ]);
    return c.html(
      <AccountPage
        user={{ email: c.get("userEmail") }}
        blockedBySubscription={blocked}
        hasPassword={hasPassword}
        minPasswordLength={MIN_PASSWORD_LENGTH}
        maxPasswordLength={MAX_PASSWORD_LENGTH}
        passwordNotice={c.req.query("passwordNotice") ?? null}
        passwordError={c.req.query("passwordError") ?? null}
      />
    );
  });

  r.post("/ui/account/password", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    const fail = (message: string) =>
      redirectWith(c, "/account", { passwordError: message });

    // Per-user, and ahead of the body read. A session holder can otherwise
    // grind `currentPassword` here without limit — the reply distinguishes a
    // wrong one — and each attempt costs two scrypt hashes, because
    // changePassword hashes the NEW password before verifying the old.
    if (!passwordWriteLimiter(userId)) return fail("Too many attempts. Try again shortly.");

    const form = await c.req.formData();
    const password = String(form.get("password") ?? "");
    const confirm = String(form.get("confirmPassword") ?? "");
    const currentPassword = String(form.get("currentPassword") ?? "");

    if (password !== confirm) return fail("Passwords do not match");
    const lengthError = passwordLengthError(password);
    if (lengthError) return fail(lengthError);

    // The two endpoints are not interchangeable: setPassword refuses a user who
    // already has one, changePassword refuses one who doesn't. Read the current
    // state rather than inferring it from which fields the form submitted.
    const hasPassword = await hasPasswordCredential(deps.db, userId);
    const res = hasPassword
      ? await deps.auth.api.changePassword({
          method: "POST",
          headers: forwardedHeaders(c),
          body: { currentPassword, newPassword: password, revokeOtherSessions: true },
          asResponse: true,
        })
      : await deps.auth.api.setPassword({
          method: "POST",
          headers: forwardedHeaders(c),
          body: { newPassword: password },
          asResponse: true,
        });

    if (!res.ok) {
      const code = await authErrorCode(res);
      if (code === "INVALID_PASSWORD") return fail("Current password is incorrect");
      return fail("Could not update your password");
    }
    // revokeOtherSessions kills EVERY session for the user and issues a fresh
    // one — dropping this cookie would sign the user out of the very tab they
    // just changed their password in.
    forwardSetCookies(c, res);

    if (!hasPassword) {
      // setPassword takes no `revokeOtherSessions` and sends no notification,
      // so on its own it lets whoever is holding a session mint a permanent way
      // back in that survives the owner signing out and revoking every device —
      // the credential lives on the account, not the session. Match what the
      // change branch above already does, and leave a line an operator can
      // alert on, next to auth.password.reset.
      // Forward its Set-Cookie for the same reason as above: revokeOtherSessions
      // rotates the surviving session's token, and the acting tab is that one.
      const revoked = await deps.auth.api
        .revokeOtherSessions({ headers: c.req.raw.headers, asResponse: true })
        .catch(() => undefined);
      if (revoked) forwardSetCookies(c, revoked);
      // setPassword is check-then-create with no unique index behind it; two
      // submits that interleave leave a second row whose hash outlives the next
      // change. Converge on one.
      await pruneDuplicatePasswordCredentials(deps.db, userId);
      console.info(
        JSON.stringify({ evt: "auth.password.set", userId, at: new Date().toISOString() })
      );
    }
    return redirectWith(c, "/account", {
      passwordNotice: hasPassword ? "Password changed." : "Password set.",
    });
  });

  r.post("/ui/account/delete", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    // Re-verify the type-to-confirm word server-side. The page disables the
    // submit button until "DELETE" is typed, but that's client-only — a direct
    // POST, autofill, or Enter-submit could otherwise trip an irreversible
    // deletion without confirmation. Must stay in lockstep with the input's
    // name= and the confirm word in account.tsx.
    const body = await c.req.parseBody();
    if (body.confirm !== "DELETE") {
      return c.redirect("/account");
    }
    const result = await deleteUserAccount(deps.db, deps.relay, deps.auth, {
      userId,
      headers: c.req.raw.headers,
    });
    if (result === "blocked_subscription") return c.redirect("/account");
    // Sessions are already deleted by the service; clear the browser cookie too.
    // Best-effort: the account is already gone, so a signOut hiccup must not turn
    // the success path into a 500 — fall through to the deleted page regardless.
    try {
      const res = await deps.auth.api.signOut({ headers: c.req.raw.headers, asResponse: true });
      for (const sc of res.headers.getSetCookie()) c.header("set-cookie", sc, { append: true });
    } catch (err) {
      console.error("[account] signOut after deletion failed; cookie persists until TTL", err);
    }
    return c.redirect("/account/deleted");
  });

  r.get("/account/deleted", (c) => c.html(<AccountDeletedPage />));

  return r;
}
