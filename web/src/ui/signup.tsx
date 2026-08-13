import { Layout } from "./layout.js";
import { AUTH_MEMORY_SCRIPT } from "./auth-memory.js";

export type SignUpPageProps = {
  /** Carried in from step 2's "create one" link, so deciding to sign up never
   *  costs the user the address they already typed. */
  email?: string | null;
  error?: string | null;
  minPasswordLength: number;
  maxPasswordLength: number;
};

/** The only page that creates an account with a password.
 *
 *  It exists because a password is the one method a browser cannot reach on its
 *  own: step 1 routes on what this browser has WATCHED an address do, and the
 *  password step is a sign-in form, so a user who has never had a password had
 *  nowhere to make one. Every other door — magic link, GitHub, Google — signs
 *  up and signs in with the same click and needs no page of its own.
 *
 *  Nothing here reveals whether the address is already taken. Better-Auth
 *  answers a duplicate sign-up with a synthetic success and leaves the existing
 *  credential untouched; the route this posts to is written to keep that
 *  indistinguishable from a fresh one, and the page it lands on says what a
 *  user in that case should do instead. */
export function SignUpPage({
  email,
  error,
  minPasswordLength,
  maxPasswordLength,
}: SignUpPageProps) {
  return (
    <Layout title="Create an account">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 shadow-xl">
        <div class="card-body">
          <h1 class="card-title font-mono">Create an account</h1>
          <p class="text-sm text-base-content/70">
            We'll email you a link to confirm the address before you can sign
            in.
          </p>

          {error && (
            <div class="alert alert-error mt-4" role="alert">
              <span>{error}</span>
            </div>
          )}

          {/* No `data-ab-prefill`: that fills from the last address this browser
              remembered, and the whole point of this page is an address it has
              never seen. The `email` prop is a deliberate hand-off from step 2. */}
          <form method="post" action="/ui/signup" class="mt-4 space-y-3">
            <fieldset class="fieldset">
              <label class="fieldset-legend font-mono" for="signup-email">
                Email
              </label>
              <input
                type="email"
                id="signup-email"
                name="email"
                required
                autofocus
                autocomplete="email"
                value={email ?? ""}
                placeholder="you@example.com"
                class="input input-bordered font-mono w-full"
              />
            </fieldset>
            <fieldset class="fieldset">
              <label class="fieldset-legend font-mono" for="signup-password">
                Password
              </label>
              <input
                type="password"
                id="signup-password"
                name="password"
                required
                minlength={minPasswordLength}
                maxlength={maxPasswordLength}
                autocomplete="new-password"
                class="input input-bordered font-mono w-full"
              />
              <p class="label text-xs">
                Between {minPasswordLength} and {maxPasswordLength} characters.
              </p>
            </fieldset>
            {/* A typo here would otherwise only surface at the first sign-in,
                by which point the reset flow is the only way back in. */}
            <fieldset class="fieldset">
              <label class="fieldset-legend font-mono" for="signup-confirm">
                Confirm password
              </label>
              <input
                type="password"
                id="signup-confirm"
                name="confirmPassword"
                required
                minlength={minPasswordLength}
                maxlength={maxPasswordLength}
                autocomplete="new-password"
                class="input input-bordered font-mono w-full"
              />
            </fieldset>
            {/* No `data-ab-remember`: this is a submit-time INTENT and would
                outlive a password the server rejects. The hint is written by
                the page the successful post lands on (check-email.tsx), which
                is the only place the write is a fact. */}
            <button
              type="submit"
              class="btn btn-primary w-full"
              data-ab-once="Creating…"
            >
              Create account
            </button>
          </form>

          <p class="text-xs text-base-content/60 mt-4 text-center">
            Already have an account?{" "}
            <a
              class="link"
              href={email ? `/login?email=${encodeURIComponent(email)}` : "/login"}
            >
              Sign in
            </a>
            .
          </p>
        </div>
      </div>
      <script dangerouslySetInnerHTML={{ __html: AUTH_MEMORY_SCRIPT }} />
    </Layout>
  );
}
