import { Layout } from "./layout.js";

export type ForgotPasswordPageProps = {
  error?: string | null;
  /** Carried by step 2's "Forgot your password?" link so arriving here never
   *  costs the user the address they just typed. */
  email?: string | null;
};

export function ForgotPasswordPage({ error, email }: ForgotPasswordPageProps) {
  return (
    <Layout title="Reset password">
      <div class="max-w-md mx-auto mt-16 card bg-panel shadow-xl">
        <div class="card-body">
          <h1 class="card-title">Reset your password</h1>
          <p class="text-sm text-muted">
            Enter your email and we'll send a reset link. This also works if you
            signed up with a magic link or GitHub/Google and never had a
            password — it sets one.
          </p>

          {error && (
            <div class="alert alert-error mt-4" role="alert">
              <span>{error}</span>
            </div>
          )}

          <form
            method="post"
            action="/ui/forgot-password"
            class="mt-4 space-y-3"
            onsubmit="this.querySelector('button[type=submit]').disabled=true;this.querySelector('button[type=submit]').textContent='Sending…';"
          >
            <fieldset class="fieldset">
              <legend class="fieldset-legend">Email</legend>
              <input
                type="email"
                name="email"
                required
                autocomplete="email"
                value={email ?? ""}
                placeholder="you@example.com"
                class="input input-bordered font-mono w-full"
              />
            </fieldset>
            <button type="submit" class="btn btn-primary w-full">
              Send reset link
            </button>
          </form>

          <p class="text-sm text-muted mt-4 text-center">
            <a class="link" href="/login">
              Back to sign in
            </a>
          </p>
        </div>
      </div>
    </Layout>
  );
}
