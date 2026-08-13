import { Layout } from "./layout.js";
import { AUTH_MEMORY_SCRIPT } from "./auth-memory.js";

// The legal pages live on the marketing site, not this service — and they are
// the same documents whichever app environment you signed in from, so these are
// absolute and unversioned. Same call as download-card.tsx.
const SITE_TERMS_URL = "https://antgrid.ai/terms";
const SITE_PRIVACY_URL = "https://antgrid.ai/privacy";

export type LoginPageProps = {
  error?: string | null;
  notice?: string | null;
  /** Carried back by step 2's "change" link so returning to step 1 never costs
   *  the user the address they already typed. */
  email?: string | null;
};

/** Step 1 of the email-first flow: one field, no sign-in/sign-up decision.
 *
 *  What happens next is decided by `/ui/login/continue` from a hint the BROWSER
 *  supplies (see auth-memory.ts), never from a server-side lookup of the
 *  address. Absent a hint the answer is the magic link, which is correct for
 *  every address: cross-device approve creates the user when there isn't one
 *  (auth/cross-device-plugin.ts), so the same button signs in and signs up. */
export function LoginPage({ error, notice, email }: LoginPageProps) {
  return (
    <Layout title="Sign in">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 shadow-xl">
        <div class="card-body">
          <h1 class="card-title font-mono">Sign in or create an account</h1>
          <p class="text-sm text-base-content/70">
            Enter your email — we'll take it from there.
          </p>

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

          <form
            id="login-form"
            method="post"
            action="/ui/login/continue"
            class="mt-4 space-y-3"
            data-ab-recall
          >
            {/* Filled from localStorage on submit. Empty is the honest default
                and routes to the magic link — with JS off it always is. */}
            <input type="hidden" name="method" value="" />
            <fieldset class="fieldset">
              <label class="fieldset-legend font-mono" for="login-email">
                Email
              </label>
              <input
                type="email"
                id="login-email"
                name="email"
                required
                autofocus
                autocomplete="email"
                value={email ?? ""}
                data-ab-prefill
                placeholder="you@example.com"
                class="input input-bordered font-mono w-full"
              />
            </fieldset>
            <button
              type="submit"
              class="btn btn-primary w-full"
              data-ab-once="Continuing…"
            >
              Continue
            </button>
          </form>

          {/* Two tiers, and the split is what the hint is allowed to decide.
              Continue above is the fast path and the only control that reads
              the hint; every method below names itself and ignores it, so a
              hint that is missing or wrong costs a click rather than the
              account. */}
          <div class="divider">or</div>

          <div class="space-y-2">
            <a
              href="/oauth/start?provider=github&callbackURL=/dashboard"
              class="btn btn-outline w-full"
              data-ab-remember="github"
            >
              Continue with GitHub
            </a>
            <a
              href="/oauth/start?provider=google&callbackURL=/dashboard"
              class="btn btn-outline w-full"
              data-ab-remember="google"
            >
              Continue with Google
            </a>
            {/* The way in for a password this browser has never watched being
                used — a fresh browser, cleared storage, or one set on another
                device. Nothing else opens that door: the hint that routes
                Continue to step 2 is written by a password sign-in and by
                /account, so a browser that has seen neither would send this
                user a magic link forever.

                It is also the way OUT of a hint that is wrong. A browser that
                remembers this address as github/google relaunches that provider
                on every Continue; this button ignores the hint, and the step it
                reaches carries "Email me a link instead" — which corrects the
                hint on its way through.

                No `data-ab-remember`: this is a guess, not a commitment. The
                server refuses to say whether the address has a password, so a
                hint written here could pin a browser to a step that can never
                work for it.

                `form=` rather than nesting: the button belongs to the method
                block visually but has to submit the address typed above, and
                forms cannot be nested. */}
            <button
              type="submit"
              form="login-form"
              name="fallback"
              value="password"
              class="btn btn-outline w-full"
            >
              Continue with a password
            </button>
          </div>

          {/* New tab, so reading the terms never navigates out of a half-filled
              form: `data-ab-prefill` only fills an EMPTY field and only from the
              last address this browser remembered, so coming back to a fresh
              load would silently restore a different address than the one being
              typed. */}
          <p class="text-xs text-base-content/60 mt-4 text-center">
            By continuing you agree to the{" "}
            <a class="link" href={SITE_TERMS_URL} target="_blank" rel="noopener noreferrer">
              Terms
            </a>{" "}
            and{" "}
            <a class="link" href={SITE_PRIVACY_URL} target="_blank" rel="noopener noreferrer">
              Privacy Policy
            </a>
            .
          </p>
        </div>
      </div>
      <script dangerouslySetInnerHTML={{ __html: AUTH_MEMORY_SCRIPT }} />
    </Layout>
  );
}
