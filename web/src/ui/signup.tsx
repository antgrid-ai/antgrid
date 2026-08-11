import { Layout } from "./layout.js";

export type SignUpPageProps = {
  error?: string | null;
  /** Preserved across a failed submit so a rejected password doesn't cost the
   *  user the address they already typed. Never round-trip the password. */
  email?: string | null;
  minPasswordLength: number;
  maxPasswordLength: number;
};

export function SignUpPage({
  error,
  email,
  minPasswordLength,
  maxPasswordLength,
}: SignUpPageProps) {
  return (
    <Layout title="Sign up">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 shadow-xl">
        <div class="card-body">
          <h1 class="card-title font-mono">Create an Antgrid account</h1>
          <p class="text-sm text-base-content/70">
            We'll email you a link to verify the address before your account
            becomes usable.
          </p>

          {error && (
            <div class="alert alert-error mt-4" role="alert">
              <span>{error}</span>
            </div>
          )}

          <form
            method="post"
            action="/ui/signup"
            class="mt-4 space-y-3"
            onsubmit="this.querySelector('button[type=submit]').disabled=true;this.querySelector('button[type=submit]').textContent='Creating…';"
          >
            {/* `label for=` rather than `legend`: a legend names the fieldset,
                not the control inside it, so a screen reader announces three
                identical "password, edit" fields. Same anchor the delete form
                in account.tsx uses. */}
            <fieldset class="fieldset">
              <label class="fieldset-legend font-mono" for="signup-email">
                Email
              </label>
              <input
                type="email"
                id="signup-email"
                name="email"
                required
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
            <button type="submit" class="btn btn-primary w-full">
              Create account
            </button>
          </form>

          <p class="text-sm text-base-content/70 mt-4 text-center">
            Already have an account?{" "}
            <a class="link" href="/login">
              Sign in
            </a>
          </p>
        </div>
      </div>
    </Layout>
  );
}
