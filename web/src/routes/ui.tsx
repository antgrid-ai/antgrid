import { Hono } from "hono";
import { z } from "zod";
import { isAPIError } from "better-auth/api";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import type { Env } from "../env.js";
import type { RelayPushConfig } from "../relay/push.js";
import { findByIdWithHashes, checkNonce } from "../models/pending-sign-in.js";
import { ERR_ALREADY_APPROVED } from "../auth/cross-device-plugin.js";
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
import { SignUpPage } from "../ui/signup.js";
import { ForgotPasswordPage } from "../ui/forgot-password.js";
import { ResetPasswordPage, ResetLinkInvalidPage } from "../ui/reset-password.js";
import { CheckEmailPage, VerifyEmailFailedPage } from "../ui/check-email.js";
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
import { PendingPage } from "../ui/pending.js";
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
  const signUpLimiter = tokenBucket(5, 1 / 60); // 5 burst, 1 per minute, per IP
  const passwordEmailLimiter = tokenBucket(5, 1 / 60); // reset + resend sends
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
   *  internal one. */
  r.use("*", async (c, next) => {
    if (c.req.method === "GET" || c.req.method === "HEAD") return next();
    const origin = c.req.header("origin");
    const site = c.req.header("sec-fetch-site");
    const sameOrigin = origin
      ? origin === appOrigin
      : !site || site === "same-origin" || site === "none";
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
    const sent = c.req.query("sent") ?? null;
    const error = c.req.query("error") ?? null;
    const notice = c.req.query("notice") ?? null;
    return c.html(<LoginPage sent={sent} error={error} notice={notice} />);
  });

  r.get("/signup", (c) =>
    c.html(
      <SignUpPage
        error={c.req.query("error") ?? null}
        email={c.req.query("email") ?? null}
        minPasswordLength={MIN_PASSWORD_LENGTH}
        maxPasswordLength={MAX_PASSWORD_LENGTH}
      />
    )
  );

  r.post("/ui/signup", async (c) => {
    // Bucket first, body second. Bun hands the handler the request as soon as
    // the headers land and streams the body lazily, so returning before
    // `formData()` costs nothing — reading it first buffers an attacker-chosen
    // body (128 MiB by default, ~4x that in RSS) for a request already destined
    // for 429. Same order as /ui/login/start below.
    if (!signUpLimiter(ipKey(c))) {
      return redirectWith(c, "/signup", { error: "Too many requests" });
    }
    const form = await c.req.formData();
    const email = String(form.get("email") ?? "").trim().toLowerCase();
    // Never trim a password: leading/trailing spaces are part of what the user
    // chose, and silently dropping them here would break every later compare.
    const password = String(form.get("password") ?? "");
    const confirm = String(form.get("confirmPassword") ?? "");
    const fail = (message: string) => redirectWith(c, "/signup", { error: message, email });

    if (!email) return fail("Email required");
    if (password !== confirm) return fail("Passwords do not match");
    const lengthError = passwordLengthError(password);
    if (lengthError) return fail(lengthError);

    const res = await deps.auth.api.signUpEmail({
      method: "POST",
      headers: forwardedHeaders(c),
      body: { email, password, name: email },
      asResponse: true,
    });
    if (!res.ok) {
      // Not "that email is taken": with requireEmailVerification on,
      // Better-Auth answers an existing address with a synthetic success
      // (api/routes/sign-up.mjs) so sign-up can't be used to enumerate users.
      // A failure here is a real one — validation or the adapter.
      return fail("Could not create the account. Try again.");
    }
    // No cookie to forward — autoSignIn is off, so a session only exists once
    // the emailed link is opened.
    return redirectWith(c, "/login/check-email", { email });
  });

  r.post("/ui/login/password", async (c) => {
    if (!passwordSignInLimiter(ipKey(c))) {
      return redirectWith(c, "/login", { error: "Too many requests" });
    }
    const form = await c.req.formData();
    const email = String(form.get("email") ?? "").trim().toLowerCase();
    const password = String(form.get("password") ?? "");

    if (!email || !password) {
      return redirectWith(c, "/login", { error: "Email and password required" });
    }

    const res = await deps.auth.api.signInEmail({
      method: "POST",
      headers: forwardedHeaders(c),
      body: { email, password },
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
      return redirectWith(c, "/login", { error: "Invalid email or password" });
    }
    forwardSetCookies(c, res);
    return c.redirect("/dashboard");
  });

  r.get("/login/check-email", (c) => {
    const email = c.req.query("email") ?? null;
    const throttled = c.req.query("throttled");
    return c.html(
      <CheckEmailPage
        kind="verify"
        email={email}
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
    // Keeps the bucket ahead of any body read; see /ui/signup for why.
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
    c.html(<ForgotPasswordPage error={c.req.query("error") ?? null} />)
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
    const ip = deps.clientIp(c);
    if (!startLimiter(ip ?? "unknown")) {
      return c.redirect("/login?error=Too%20many%20requests");
    }
    const form = await c.req.formData();
    const email = String(form.get("email") ?? "").trim();
    if (!email) return c.redirect("/login?error=Email%20required");

    const res = await deps.auth.api.crossDeviceStart({
      method: "POST",
      headers: {
        "content-type": "application/json",
        "user-agent": c.req.header("user-agent") ?? "",
        // The plugin has no socket access, so hand it the ALREADY-resolved
        // client IP as a single-hop header instead of the raw (forgeable)
        // chain — it reads the rightmost hop (see cross-device-plugin.ts).
        "x-forwarded-for": ip ?? "",
        cookie: c.req.header("cookie") ?? "",
      },
      body: { email },
      asResponse: true
    });
    if (!res.ok) {
      return c.redirect(`/login?error=${encodeURIComponent("Could not send link")}`);
    }
    // Forward Set-Cookie from the plugin response to the browser.
    for (const [k, v] of res.headers) {
      if (k.toLowerCase() === "set-cookie") c.header("Set-Cookie", v, { append: true });
    }
    const { id } = (await res.json()) as { id: string };
    return c.redirect(`/login/pending/${id}?email=${encodeURIComponent(email)}`);
  });

  r.get("/login/pending/:id", (c) => {
    const id = c.req.param("id");
    const email = c.req.query("email") ?? "";
    if (!z.uuid().safeParse(id).success) return c.redirect("/login");
    return c.html(<PendingPage email={email} pendingId={id} />);
  });

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
    return c.html(
      <div
        id="poll"
        class="text-xs text-base-content/50 font-mono"
        hx-get={`/ui/login/poll/${id}`}
        hx-trigger="every 3s"
        hx-swap="outerHTML"
      >
        Waiting for approval…
      </div>
    );
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
    // Re-opening an approved link — back button, a second tap, a mail client
    // prefetching URLs — is a success the user already earned, not a reused
    // link. Kept after the nonce check so the state isn't readable from the id.
    if (row.approvedAt) {
      return c.redirect("/login/approved");
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
