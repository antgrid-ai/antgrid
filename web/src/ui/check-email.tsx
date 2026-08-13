import { Layout } from "./layout.js";
import { AUTH_MEMORY_SCRIPT } from "./auth-memory.js";

export type CheckEmailPageProps = {
  /** Absent when we must not confirm the address exists — the reset flow is
   *  deliberately enumeration-safe and answers identically either way. */
  email?: string | null;
  kind: "verify" | "reset";
  notice?: string | null;
  /** Set when the send was SKIPPED — rate limiting, so far. The page otherwise
   *  states a link is on its way, which would be a lie in that case. */
  error?: string | null;
  /** Set by the sign-up landing only. Teaches this browser that the address
   *  signs in with a password, which nothing else can: step 1 routes on what it
   *  has watched an address do, and a user who just created a password has by
   *  definition never been watched using it.
   *
   *  Written here rather than on the sign-up form because a form carries an
   *  intent that outlives a rejected password, while this page is only rendered
   *  after the account write succeeded. The one case it can still be wrong —
   *  an address that already had a provider-only account, which sign-up answers
   *  with a synthetic success — costs a click at step 2, whose "Email me a link
   *  instead" retires the hint on its way through. */
  rememberPassword?: boolean;
};

export function CheckEmailPage({
  email,
  kind,
  notice,
  error,
  rememberPassword,
}: CheckEmailPageProps) {
  const isVerify = kind === "verify";
  const remember =
    rememberPassword && email
      ? { "data-ab-remember-now": "password", "data-ab-email": email }
      : {};
  return (
    <Layout title="Check your email">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 border border-base-300">
        <div class="card-body items-center text-center">
          <h1 class="card-title font-mono">Check your email</h1>
          {isVerify ? (
            <p class="text-sm text-base-content/70" {...remember}>
              We sent a verification link to{" "}
              <span class="font-mono">{email}</span>. Open it to finish creating
              your account — you can't sign in until you do.
            </p>
          ) : (
            <p class="text-sm text-base-content/70">
              If that address has an Antgrid account, a password reset link is
              on its way. The link expires in one hour.
            </p>
          )}

          {notice && (
            <div class="alert alert-success mt-4" role="status">
              <span>{notice}</span>
            </div>
          )}

          {error && (
            <div class="alert alert-error mt-4" role="alert">
              <span>{error}</span>
            </div>
          )}

          {isVerify && email && (
            <form
              method="post"
              // In the query rather than a hidden field so the route can bounce
              // a throttled request back WITH the address without reading the
              // body — it throttles before any body read.
              action={`/ui/verify-email/resend?email=${encodeURIComponent(email)}`}
              class="mt-4"
              // The cooldown script owns `disabled` from here on; a second
              // handler setting it would fight the countdown's re-enable.
              // `-arm` because this page is itself the landing after a send.
              // The address is in the action's query string, not a field, so
              // without `data-ab-email` the slot would key on the empty string
              // and every address in the tab would share one countdown.
              data-ab-cooldown="verify"
              data-ab-cooldown-arm
              data-ab-email={email}
            >
              <button type="submit" class="btn btn-outline btn-sm font-mono">
                Resend the link
              </button>
            </form>
          )}

          {/* Sign-up answers an address that ALREADY has an account with a
              synthetic success and sends nothing (api/routes/sign-up.mjs) —
              deliberately, so sign-up can't enumerate users. That user is
              otherwise stranded here waiting on mail that will never arrive,
              and the resend button is a no-op for them too. Say so without
              claiming which case they are in. */}
          {isVerify && (
            <p class="text-xs text-base-content/60 mt-6">
              Already had an account with this address? Nothing was sent — sign
              in with your magic link, GitHub or Google, or{" "}
              <a class="link" href="/forgot-password">
                reset your password
              </a>
              .
            </p>
          )}

          <p class="text-xs text-base-content/60 mt-6">
            <a class="link" href="/login">
              Back to sign in
            </a>
          </p>
        </div>
      </div>
      <script dangerouslySetInnerHTML={{ __html: AUTH_MEMORY_SCRIPT }} />
    </Layout>
  );
}

/** Landing for a verification link that no longer works. Better-Auth redirects
 *  here with `?error=<CODE>`; the codes we can act on are TOKEN_EXPIRED and
 *  INVALID_TOKEN, and both mean the same thing to the user. */
export function VerifyEmailFailedPage() {
  return (
    <Layout title="Verification link expired">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 border border-base-300">
        <div class="card-body items-center text-center">
          <h1 class="card-title font-mono">Verification link expired</h1>
          <p class="text-sm text-base-content/70">
            That link is no longer valid. Verification links last one hour.
            Signing in again sends a fresh one.
          </p>
          <a class="btn btn-primary mt-4" href="/login">
            Back to sign in
          </a>
        </div>
      </div>
    </Layout>
  );
}
