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
  activeSubscriptionForAccount,
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
import {
  CheckoutPage,
  seatCeiling,
  type CheckoutOrder,
  type CheckoutPlan,
} from "../ui/checkout.js";
import {
  anyCheckoutReady,
  checkoutReadiness,
  MAX_CHECKOUT_SEATS,
  type CheckoutReadiness,
} from "../billing/checkout.js";
import { startCheckout, type StartCheckoutResult } from "../billing/start-checkout.js";
import { displayPriceCents, FREE_TIER, isPlanId, type PlanId } from "../billing/plans.js";
import { isSelfServe, listActivePlans } from "../models/plan.js";
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
import {
  deleteUserAccount,
  hasRenewingPaidSubscription,
  isBlockedByTeamMembers,
} from "../services/account.js";
import {
  AccountMemberRoleSchema,
  countActiveSeatHolders,
  countOtherActiveOwners,
  findActiveMembership,
  isBillingAccountOwner,
  listActiveMembers,
  resolveBillingAccountId,
} from "../models/account-member.js";
import type { SendEmail } from "../auth/email.js";
import {
  acceptAccountInvite,
  createAccountInvite,
  InviteError,
  normalizeInviteEmail,
  resendAccountInvite,
  sendInviteEmail,
} from "../billing/invite.js";
import { removeAccountMember, RemoveMemberError } from "../billing/remove-member.js";
import {
  checkInviteToken,
  findPendingInviteByIdWithHash,
  listPendingInvites,
  revokeInvite,
} from "../models/account-invite.js";
import {
  InvitePage,
  InviteInvalidPage,
  parseInviteNotice,
  type InviteNotice,
} from "../ui/invite.js";
import { TeamPage } from "../ui/team.js";
import { parseTeamNotice, type TeamNotice } from "../ui/team-notice.js";

// Internal relay-connections view is restricted to named operators. Gate on
// email (lowercased) — Better-Auth verifies email ownership at sign-in, so it's
// a safe identity anchor here. Non-operators get 404, not 403: don't reveal the
// route exists.
const INTERNAL_OPERATOR_EMAILS = new Set(["bharathm@radhaai.com"]);

type UiContext = import("hono").Context<{ Variables: AuthVars }>;

/**
 * A seat count as a form field: digits, then the same request bound the JSON
 * API applies.
 *
 * Deliberately not `z.coerce.number()` — coercion reads "" as 0, " 2 " as 2 and
 * "2.5" as 2.5, so a mistyped box would quietly buy a count nobody chose. The
 * product cap (`plans.max_seats`) is NOT checked here; `startCheckout` owns it,
 * and a second copy is a second answer.
 */
const SeatsField = z
  .string()
  .regex(/^\d+$/)
  .transform((raw) => Number.parseInt(raw, 10))
  .pipe(z.number().int().min(1).max(MAX_CHECKOUT_SEATS));

/** Notices the checkout page may be redirected back with. A fixed set, so
 *  nothing in a query string reaches the page as prose. */
const CHECKOUT_NOTICE: Record<string, string> = {
  throttled: "Too many order updates. Wait a moment and try again.",
};

function checkoutFailureNotice(failure: Extract<StartCheckoutResult, { ok: false }>): string {
  if (failure.error === "SEATS_ABOVE_PLAN_MAX") {
    const max = failure.maxSeats;
    return `This plan covers at most ${max} seat${max === 1 ? "" : "s"}.`;
  }
  if (failure.error === "COUNTRY_REQUIRED") {
    return "Select your billing country to continue.";
  }
  return "Checkout is temporarily unavailable. Try again shortly.";
}

export function uiRoutes(deps: {
  db: DB;
  auth: Auth;
  env: Env;
  relay: RelayPushConfig;
  clientIp: ClientIpResolver;
  sendEmail: SendEmail;
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
  // Keyed by USER, not IP: both verbs mail a third party on one owner's say-so,
  // so the budget that has to hold is per owner. An owner onboarding a team in
  // one sitting stays under it; a loop pointed at someone else's inbox does not.
  const inviteSendLimiter = tokenBucket(10, 1 / 30); // 10 burst, 1 per 30s
  // Keyed by IP and covering the GET too. The id+token pair is the only thing
  // between a stranger and an invitee's address, and the accept POST is reached
  // with a session that is not the account under attack, so a per-user bucket
  // would bound the wrong principal.
  const inviteLinkLimiter = tokenBucket(20, 0.2); // 20 burst, 1 per 5s
  // Keyed by USER, and kept off the send bucket above: withdrawing a mistyped
  // invitation must not spend the budget the owner needs to send the corrected
  // one — the same split `resetSubmitLimiter` makes against the reset sends.
  // Wider because it is a loop bound and not an abuse budget: these verbs are
  // owner-gated or self-service, write one row and mail nobody.
  const teamWriteLimiter = tokenBucket(30, 0.5); // 30 burst, 1 per 2s
  // Keyed by USER, and the tightest bucket here for a form nobody submits in a
  // loop by hand: every accepted post creates a real object at a payment gateway
  // (a Paddle transaction, a Razorpay subscription). What this bounds is junk in
  // the merchant account, not work on this box.
  const checkoutOrderLimiter = tokenBucket(6, 0.1); // 6 burst, 1 per 10s

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
    // A non-JSON body (a plugin 5xx, a proxy error page) must not 500 the
    // approval screen: the session-cookie fallback below still answers, and
    // this is the browser that just clicked its own link.
    const body = (await res.json().catch(() => ({}))) as { status?: string };
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
    // The HTMX twin of POST /billing/cancel-subscription, and equally unguarded
    // by requireUserOrRedirect: a member resolves the owner's subscription and
    // would cancel the team's contract at the gateway.
    if (!(await isBillingAccountOwner(deps.db, userId))) {
      return c.redirect("/dashboard?cancel=failed");
    }
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
    if (!(await isBillingAccountOwner(deps.db, userId))) {
      return c.redirect("/dashboard?resume=failed");
    }
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

  /** Every team verb reports through the team page as a closed code, so the
   *  wording stays server-side and out of a parameter anyone can hand a signed-in
   *  owner — the same contract `?cancel=` already uses on the dashboard. */
  function teamRedirect(c: import("hono").Context, invite: TeamNotice) {
    return redirectWith(c, "/team", { invite });
  }

  /** Refusals `createAccountInvite` raises, in the owner's words. Anything not
   *  listed is a bug rather than a decision, and reports as `failed`. */
  const CREATE_NOTICE: Partial<Record<InviteError["code"], TeamNotice>> = {
    INVALID_EMAIL: "invalid_email",
    ALREADY_MEMBER: "already_member",
    ALREADY_INVITED: "already_invited",
    NO_ACTIVE_SUBSCRIPTION: "no_subscription",
    OVER_SUBSCRIBED: "over_subscribed",
    SEAT_CAP: "seat_cap",
  };

  /** The refusals an invitee can act on: buy nothing, wait for a seat, or cancel
   *  their own paid plan. `INVALID_LINK` and `EMAIL_MISMATCH` are not here — see
   *  the accept handler. */
  const ACCEPT_NOTICE: Partial<Record<InviteError["code"], InviteNotice>> = {
    SEAT_CAP: "seat_cap",
    NO_ACTIVE_SUBSCRIPTION: "no_subscription",
    HAS_PAID_SUBSCRIPTION: "has_paid_subscription",
  };

  /**
   * The team page. One route, two renderings, chosen by the same predicate the
   * invite verbs gate on — so a member is never shown a control the POST behind
   * it would refuse, and never shown the numbers on someone else's contract.
   */
  r.get("/team", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    // Ahead of every read, as on /account and /dashboard: this page reports an
    // account's entitlement, and provisioning is what guarantees there is one.
    await provisionProductAccountForUser(deps.db, userId);
    const [accountId, isOwner] = await Promise.all([
      resolveBillingAccountId(deps.db, userId),
      isBillingAccountOwner(deps.db, userId),
    ]);
    if (!accountId) return c.redirect("/login");
    const user = { email: c.get("userEmail") };
    const notice = parseTeamNotice(c.req.query("invite"));

    if (!isOwner) {
      const [membership, account, otherOwners] = await Promise.all([
        findActiveMembership(deps.db, userId),
        deps.db.productAccount.findUnique({
          where: { id: accountId },
          select: { userId: true, user: { select: { email: true } } },
        }),
        countOtherActiveOwners(deps.db, accountId, userId),
      ]);
      return c.html(
        <TeamPage
          user={user}
          notice={notice}
          view={{
            kind: "member",
            ownerEmail: account?.user.email ?? null,
            role: membership?.role ?? null,
            // The same two conditions `removeAccountMember` refuses on, asked of
            // the viewer. Offering a button the POST behind it answers with
            // `account_owner` teaches nothing; withholding it says the account
            // has nowhere to put them.
            canLeave: membership !== null && account?.userId !== userId && otherOwners > 0,
          }}
        />
      );
    }

    const [sub, seatsUsed, members, invites, account] = await Promise.all([
      activeSubscriptionForAccount(deps.db, accountId),
      countActiveSeatHolders(deps.db, accountId),
      listActiveMembers(deps.db, accountId),
      listPendingInvites(deps.db, accountId),
      deps.db.productAccount.findUnique({ where: { id: accountId }, select: { userId: true } }),
    ]);
    // Derived from the roster already fetched rather than a query per row, and
    // it must stay the arithmetic `removeAccountMember` does under the lock: a
    // departing owner is not among the owners left behind, a departing member
    // always was. Any row this predicts wrongly is a button whose POST refuses.
    const owners = members.filter((m) => m.role === AccountMemberRoleSchema.enum.owner).length;
    const mayExit = (m: (typeof members)[number]) =>
      m.userId !== account?.userId &&
      owners - (m.role === AccountMemberRoleSchema.enum.owner ? 1 : 0) > 0;
    return c.html(
      <TeamPage
        user={user}
        notice={notice}
        view={{
          kind: "owner",
          seatsPurchased: sub?.seats ?? null,
          seatsUsed,
          canLeave: members.some((m) => m.userId === userId && mayExit(m)),
          members: members.map((m) => ({
            userId: m.userId,
            email: m.email,
            role: m.role,
            joinedAt: m.joinedAt,
            isSelf: m.userId === userId,
            // Never on your own row: leaving and being removed are different
            // records of the same departure, and the Leave control below says
            // which one this is.
            removable: m.userId !== userId && mayExit(m),
          })),
          invites: invites.map((i) => ({
            id: i.id,
            email: i.email,
            role: i.role,
            expiresAt: i.expiresAt,
            bounced: i.deliveryStatus !== null,
          })),
        }}
      />
    );
  });

  r.use("/ui/team/*", requireUserOrRedirect({ auth: deps.auth }));

  /**
   * Owner-only invite verbs, listed in one place for the same reason
   * `OWNER_ONLY_PATHS` exists in billing.ts: the session carries no role, so each
   * of these costs a DB read and a forgotten one fails silently.
   *
   * Accepting is deliberately absent. The invitee is by definition not an owner
   * of the account they are joining, and gating accept here would refuse every
   * invitation the feature exists to deliver.
   *
   * Every handler named here must be registered BELOW this loop. Hono runs a
   * path-scoped `use` only for handlers registered after it, so one placed above
   * keeps its entry in this list, reads as gated, and is not.
   */
  const OWNER_ONLY_TEAM_PATHS = [
    "/ui/team/invite",
    "/ui/team/invite/:id/revoke",
    "/ui/team/invite/:id/resend",
    "/ui/team/members/:userId/remove",
  ];
  for (const path of OWNER_ONLY_TEAM_PATHS) {
    r.use(path, async (c, next) => {
      if (!(await isBillingAccountOwner(deps.db, c.get("userId")))) {
        return teamRedirect(c, "forbidden");
      }
      await next();
    });
  }

  r.post("/ui/team/invite", async (c) => {
    const userId = c.get("userId");
    // Ahead of the body read, like every other bucket here: a request already
    // destined for a refusal must not buffer an attacker-chosen form first.
    if (!inviteSendLimiter(userId)) return teamRedirect(c, "throttled");

    const form = await c.req.formData();
    const email = String(form.get("email") ?? "");
    const rawRole = form.get("role");
    // Absent means the ordinary case. Present-but-unparseable is refused rather
    // than coerced: the value lands in the membership row, and defaulting an
    // unknown string to `member` would quietly demote an owner invitation.
    const role = rawRole === null
      ? AccountMemberRoleSchema.enum.member
      : AccountMemberRoleSchema.safeParse(String(rawRole)).data;
    if (!role) return teamRedirect(c, "failed");

    await provisionProductAccountForUser(deps.db, userId);
    const accountId = await resolveBillingAccountId(deps.db, userId);
    if (!accountId) return teamRedirect(c, "failed");

    let created;
    try {
      created = await createAccountInvite(deps.db, {
        accountId,
        email,
        role,
        createdBy: userId,
        secret: deps.env.BETTER_AUTH_SECRET,
      });
    } catch (e) {
      if (e instanceof InviteError) return teamRedirect(c, CREATE_NOTICE[e.code] ?? "failed");
      throw e;
    }

    try {
      await sendInviteEmail(deps.sendEmail, {
        to: created.invite.email,
        inviteId: created.invite.id,
        token: created.token,
        invitedBy: c.get("userEmail") ?? "A team owner",
        baseUrl: deps.env.BETTER_AUTH_URL,
      });
    } catch (err) {
      // The invitation exists and holds a seat; only the mail failed. Say so —
      // reporting a plain failure would leave the owner re-inviting an address
      // that now answers ALREADY_INVITED, with resend as the verb they need.
      console.error("[team] invite mail send failed", err);
      return teamRedirect(c, "send_failed");
    }
    return teamRedirect(c, "sent");
  });

  r.post("/ui/team/invite/:id/resend", async (c) => {
    const userId = c.get("userId");
    if (!inviteSendLimiter(userId)) return teamRedirect(c, "throttled");
    const id = c.req.param("id");
    if (!z.uuid().safeParse(id).success) return teamRedirect(c, "failed");

    const accountId = await resolveBillingAccountId(deps.db, userId);
    if (!accountId) return teamRedirect(c, "failed");

    // Mints a new token and invalidates the one already in the invitee's inbox.
    // Two live tokens for one seat is two ways in, and the older mail is the one
    // an attacker who saw it would still be holding.
    const resent = await resendAccountInvite(deps.db, {
      id,
      accountId,
      secret: deps.env.BETTER_AUTH_SECRET,
    });
    if (!resent) return teamRedirect(c, "failed");

    try {
      await sendInviteEmail(deps.sendEmail, {
        to: resent.invite.email,
        inviteId: resent.invite.id,
        token: resent.token,
        invitedBy: c.get("userEmail") ?? "A team owner",
        baseUrl: deps.env.BETTER_AUTH_URL,
      });
    } catch (err) {
      console.error("[team] invite resend mail failed", err);
      return teamRedirect(c, "send_failed");
    }
    return teamRedirect(c, "resent");
  });

  r.post("/ui/team/invite/:id/revoke", async (c) => {
    const userId = c.get("userId");
    if (!teamWriteLimiter(userId)) return teamRedirect(c, "throttled");
    const id = c.req.param("id");
    if (!z.uuid().safeParse(id).success) return teamRedirect(c, "failed");
    const accountId = await resolveBillingAccountId(deps.db, userId);
    if (!accountId) return teamRedirect(c, "failed");
    // Account-scoped in the WHERE, so an owner cannot revoke another team's
    // invite by guessing an id.
    const revoked = await revokeInvite(deps.db, accountId, id);
    return teamRedirect(c, revoked ? "revoked" : "failed");
  });

  /** Refusals `removeAccountMember` raises. A full Record and not a Partial: a
   *  new refusal must be a type error here, because the alternative is a
   *  departure that silently reports as `failed`. */
  const EXIT_NOTICE: Record<RemoveMemberError["code"], TeamNotice> = {
    NOT_A_MEMBER: "not_a_member",
    ACCOUNT_OWNER: "account_owner",
    LAST_OWNER: "last_owner",
  };

  /**
   * Take someone off this team. Owner-gated by `OWNER_ONLY_TEAM_PATHS` above; a
   * member reaching it is redirected with `forbidden` before any read.
   *
   * The named user is scoped to the OWNER's own account, so an id from another
   * team resolves to no membership and reports `not_a_member` rather than
   * reaching across accounts. That scoping is the whole authorization story for
   * the parameter — do not relax it into a global user lookup.
   *
   * Nothing here touches the subscription. Freeing a seat never lowers the bill.
   */
  r.post("/ui/team/members/:userId/remove", async (c) => {
    const actorId = c.get("userId");
    if (!teamWriteLimiter(actorId)) return teamRedirect(c, "throttled");
    const target = c.req.param("userId");
    const accountId = await resolveBillingAccountId(deps.db, actorId);
    if (!accountId) return teamRedirect(c, "failed");

    // Removing yourself is leaving, whichever button got you here. The status
    // column is the only record of how a membership ended, and writing
    // "removed" for someone who walked out would misreport it; every guard
    // applies identically either way.
    const self = target === actorId;
    try {
      await removeAccountMember(deps.db, deps.relay, {
        accountId,
        userId: target,
        as: self ? "left" : "removed",
      });
    } catch (e) {
      if (e instanceof RemoveMemberError) return teamRedirect(c, EXIT_NOTICE[e.code]);
      throw e;
    }
    return teamRedirect(c, self ? "left" : "removed");
  });

  /**
   * Leave the team you are on. Deliberately NOT owner-gated: a second owner may
   * leave while another remains, and the guard that stops the last one is in
   * `removeAccountMember` under the lock, where two of them leaving at once is
   * still one refusal.
   *
   * The account comes from the membership row, never from
   * `resolveBillingAccountId` — that falls back to the account a user OWNS, so a
   * user on no team would be asking to leave their own account and be told they
   * are its owner, which is true and not an answer to what they clicked.
   */
  r.post("/ui/team/leave", async (c) => {
    const userId = c.get("userId");
    if (!teamWriteLimiter(userId)) return teamRedirect(c, "throttled");
    const membership = await findActiveMembership(deps.db, userId);
    if (!membership) return teamRedirect(c, "not_a_member");

    try {
      await removeAccountMember(deps.db, deps.relay, {
        accountId: membership.accountId,
        userId,
        as: "left",
      });
    } catch (e) {
      if (e instanceof RemoveMemberError) return teamRedirect(c, EXIT_NOTICE[e.code]);
      throw e;
    }
    return teamRedirect(c, "left");
  });

  r.post("/ui/team/invite/accept", async (c) => {
    const userId = c.get("userId");
    const form = await c.req.formData();
    const id = String(form.get("id") ?? "");
    const token = String(form.get("token") ?? "");
    // Back to the link, not to /team: a refusal the invitee can act on must
    // leave them holding a URL that still works once they have acted.
    const back = (notice: InviteNotice) =>
      redirectWith(c, "/invite", { id, t: token, error: notice });

    if (!inviteLinkLimiter(ipKey(c))) return back("throttled");
    if (!z.uuid().safeParse(id).success || !token) return c.redirect("/invite");

    try {
      await acceptAccountInvite(deps.db, {
        inviteId: id,
        token,
        userId,
        secret: deps.env.BETTER_AUTH_SECRET,
      });
    } catch (e) {
      if (!(e instanceof InviteError)) throw e;
      // These two are about the link or about who is holding it, and no alert
      // above the button explains either as well as the GET does — it re-derives
      // the dead-link page or the address-conflict screen from the same inputs.
      if (e.code === "INVALID_LINK" || e.code === "EMAIL_MISMATCH") {
        return redirectWith(c, "/invite", { id, t: token });
      }
      return back(ACCEPT_NOTICE[e.code] ?? "failed");
    }
    return teamRedirect(c, "accepted");
  });

  /**
   * The invitation screen.
   *
   * Ungated on purpose, and it is the one route here that must stay that way:
   * `requireUserOrRedirect` drops the query string on its way to /login, which
   * would destroy the token the invitee just clicked. Signing in is asked for on
   * the page instead, with the address it has to be.
   *
   * Nothing here proves an address. A signed-out visitor is told to sign in, a
   * signed-in one whose address differs is refused, and `emailVerified` is never
   * written on any path out of this screen.
   */
  r.get("/invite", async (c) => {
    const id = c.req.query("id") ?? "";
    const token = c.req.query("t") ?? "";
    const session = await deps.auth.api.getSession({ headers: c.req.raw.headers });
    const user = session?.user ? { email: session.user.email } : null;

    // Honest 429 rather than the invalid-link page: telling a rate-limited
    // invitee their invitation is dead is the one answer they cannot recover
    // from, and they would ask the owner to burn a seat re-sending it.
    if (!inviteLinkLimiter(ipKey(c))) return c.text("Too many requests", 429);
    if (!z.uuid().safeParse(id).success || !token) {
      return c.html(<InviteInvalidPage user={user} />);
    }

    const invite = await findPendingInviteByIdWithHash(deps.db, id);
    if (!invite || !checkInviteToken(invite.tokenHash, token, deps.env.BETTER_AUTH_SECRET)) {
      return c.html(<InviteInvalidPage user={user} />);
    }

    const inviter = await deps.db.user.findUnique({
      where: { id: invite.createdBy },
      select: { email: true },
    });
    const signedInAs = user?.email ?? null;
    const state = !signedInAs
      ? "signed-out"
      : normalizeInviteEmail(signedInAs) === normalizeInviteEmail(invite.email)
        ? "ready"
        : "mismatch";

    return c.html(
      <InvitePage
        user={user}
        invitedEmail={invite.email}
        invitedBy={inviter?.email ?? "A team owner"}
        inviteId={invite.id}
        token={token}
        state={state}
        signedInAs={signedInAs}
        notice={parseInviteNotice(c.req.query("error"))}
      />
    );
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
    // TEMP-PROMO: no plan can be bought while in-app purchases aren't live, so
    // the Pro card takes waitlist signups instead of running a checkout — grep
    // "TEMP-PROMO" repo-wide for every related spot (backend grant logic in
    // web/src/models/subscription.ts plus the static UI in web/src/ui/pricing.tsx).
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
      <PricingPage user={{ email: c.get("userEmail") }} plans={plans} />
      // <PricingPage
      //   user={{ email: c.get("userEmail") }}
      //   plans={plans}
      //   env={deps.env}
      //   currentPlanSlug={currentPlanSlug}
      // />
    );
  });

  type CheckoutContext = {
    plan: CheckoutPlan;
    /** `plans.max_seats` verbatim — NULL stays NULL, which is unlimited. */
    maxSeats: number | null;
    country: string | null;
    gateway: "paddle" | "razorpay";
    readiness: CheckoutReadiness;
    checkoutAvailable: boolean;
  };

  /**
   * Everything the checkout page shows that does not depend on an order.
   *
   * `lock` belongs to the page GET and to nothing else. Locking the account's
   * gateway is irreversible, so the order form leaves it to `startCheckout`,
   * which settles the seat cap before it writes anything — a seat count we are
   * about to refuse must not cost the buyer their choice of gateway.
   */
  async function loadCheckoutContext(
    c: UiContext,
    planId: PlanId,
    opts: { lock: boolean }
  ): Promise<CheckoutContext | null> {
    const userId = c.get("userId");
    const { id: accountId } = await provisionProductAccountForUser(deps.db, userId);
    let account = await ensureProductAccount(deps.db, userId);
    const planRows = await listActivePlans(deps.db);
    const planRow = planRows.find((row) => row.slug === planId);
    // A contact-sales row is refused here as well as in `startCheckout`, because
    // this page GET locks the account's gateway before any order exists — the
    // one write a refusal further down the order path can no longer take back.
    if (!planRow || !isPlanId(planRow.slug) || !isSelfServe(planRow)) return null;

    const detected =
      account.country ??
      (await detectCountryFromIp(deps.clientIp(c), deps.env.IPINFO_TOKEN));
    if (!account.country && detected) {
      account = await ensureProductAccountCountry(deps.db, accountId, detected, "ipinfo");
    }
    const country = account.country ?? detected;
    if (opts.lock && !isBillingProviderLocked(account) && country) {
      await lockBillingProvider(deps.db, accountId, country);
      account = await ensureProductAccount(deps.db, userId);
    }

    const chargePrice = displayPriceCents(planId, deps.env);
    const readiness = checkoutReadiness(deps.env, [planId]);
    return {
      plan: {
        id: planRow.slug,
        label: planRow.label,
        recurring: planRow.recurring,
        trial: planRow.trial,
        workerLimit: planRow.workerLimit,
        displayPrice: chargePrice,
        chargePrice,
      },
      maxSeats: planRow.maxSeats,
      country,
      gateway: previewBillingProvider(account, country),
      readiness,
      checkoutAvailable: anyCheckoutReady(readiness),
    };
  }

  function renderCheckout(
    c: UiContext,
    ctx: CheckoutContext,
    order: { seats: number; order: CheckoutOrder | null; notice: string | null },
    status?: 400 | 503
  ) {
    const page = (
      <CheckoutPage
        user={{ email: c.get("userEmail") }}
        plan={ctx.plan}
        detectedCountry={ctx.country}
        gateway={ctx.gateway}
        readiness={ctx.readiness}
        checkoutAvailable={ctx.checkoutAvailable}
        isDev={deps.env.NODE_ENV === "development"}
        seats={order.seats}
        maxSeats={ctx.maxSeats}
        order={order.order}
        notice={order.notice}
      />
    );
    return status ? c.html(page, status) : c.html(page);
  }

  function requestedPlanId(raw: string | undefined): PlanId {
    return raw && isPlanId(raw) ? raw : "trial";
  }

  r.get("/checkout", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const selectedPlanId = requestedPlanId(c.req.query("planId"));

    const userId = c.get("userId");
    // Gated on a page GET because the page itself writes: it locks the billing
    // provider below, and that lock is immutable once set.
    if (!(await isBillingAccountOwner(deps.db, userId))) return c.redirect("/dashboard");

    const ctx = await loadCheckoutContext(c, selectedPlanId, { lock: true });
    if (!ctx) return c.redirect("/pricing");

    const requested = SeatsField.safeParse(c.req.query("seats") ?? "1");
    const seats = Math.min(requested.success ? requested.data : 1, seatCeiling(ctx.maxSeats));

    return renderCheckout(c, ctx, {
      seats,
      // A page GET quotes nothing. The only total this page ever shows comes
      // from the order POST below, which is the call that creates the charge.
      order: null,
      notice: CHECKOUT_NOTICE[c.req.query("notice") ?? ""] ?? null,
    });
  });

  /**
   * Size the order and create the transaction, in one call.
   *
   * Rendered rather than redirected — the one place these forms depart from
   * POST/redirect/GET — because the total this page shows is read off the
   * gateway response `startCheckout` has just produced. A redirect would have to
   * either carry that number through a query string, where anyone could rewrite
   * it, or re-create the transaction on the GET, and a second transaction is a
   * second price. The plan travels in the query string so a refusal can render
   * the right page without first buffering the body.
   */
  r.post("/ui/checkout/seats", requireUserOrRedirect({ auth: deps.auth }), async (c) => {
    const userId = c.get("userId");
    const planId = requestedPlanId(c.req.query("planId"));
    if (!(await isBillingAccountOwner(deps.db, userId))) return c.redirect("/dashboard");

    // Ahead of the body read, like every other bucket here: a request already
    // destined for a refusal must not buffer an attacker-chosen form first.
    if (!checkoutOrderLimiter(userId)) {
      return redirectWith(c, "/checkout", { planId, notice: "throttled" });
    }

    const ctx = await loadCheckoutContext(c, planId, { lock: false });
    if (!ctx) return c.redirect("/pricing");

    const form = await c.req.formData();
    const parsedSeats = SeatsField.safeParse(String(form.get("seats") ?? ""));
    if (!parsedSeats.success) {
      return renderCheckout(
        c,
        ctx,
        {
          seats: 1,
          order: null,
          notice: `Choose between 1 and ${seatCeiling(ctx.maxSeats)} seats.`,
        },
        400
      );
    }
    const seats = parsedSeats.data;
    const country = String(form.get("country") ?? "").trim().toUpperCase();

    const result = await startCheckout(deps.db, deps.env, {
      userId,
      planId,
      ...(country.length === 2 ? { country } : {}),
      seats,
      clientIp: deps.clientIp(c),
      origin: new URL(c.req.url).origin,
    });

    if (!result.ok) {
      return renderCheckout(
        c,
        ctx,
        { seats, order: null, notice: checkoutFailureNotice(result) },
        result.status
      );
    }

    return renderCheckout(c, ctx, {
      seats,
      // Both halves come from `result.session` and nowhere else, so the number
      // on the page and the transaction the pay button opens cannot be about
      // different orders.
      order: {
        seats: result.session.seats,
        total: result.session.total,
        session: result.session,
      },
      notice: null,
    });
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
    const { tier, appDeviceLimit, workerLimit } = resolveEntitlement(sub);
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
        appDeviceLimit={appDeviceLimit}
        // Each meter counts only the kind its cap bounds — the desktop app
        // registers BOTH an agent row and an `app` controller row for itself, so
        // an unfiltered count reads as progress against a cap it cannot fill.
        activeAppDevices={devices.filter((d) => d.kind === "app").length}
        workerLimit={workerLimit}
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
    // Same predicates the DELETE endpoint uses — one source of truth.
    const [blocked, blockedByTeam, hasPassword] = await Promise.all([
      hasRenewingPaidSubscription(deps.db, userId),
      isBlockedByTeamMembers(deps.db, userId),
      hasPasswordCredential(deps.db, userId),
    ]);
    return c.html(
      <AccountPage
        user={{ email: c.get("userEmail") }}
        blockedBySubscription={blocked}
        blockedByTeam={blockedByTeam}
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
    // Both blocked results land back on /account, which renders the reason.
    if (result === "blocked_subscription" || result === "blocked_team") {
      return c.redirect("/account");
    }
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
