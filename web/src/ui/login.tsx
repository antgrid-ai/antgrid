import { Layout } from "./layout.js";

export type LoginPageProps = {
  error?: string | null;
  sent?: string | null;
};

export function LoginPage({ error, sent }: LoginPageProps) {
  return (
    <Layout title="Sign in">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 shadow-xl">
        <div class="card-body">
          <h1 class="card-title font-mono">Sign in to Antgrid</h1>
          <p class="text-sm text-base-content/70">
            Magic link, GitHub, or Google. No passwords.
          </p>

          {sent && (
            <div class="alert alert-success mt-4">
              <span>Check your inbox — we sent a sign-in link to {sent}.</span>
            </div>
          )}
          {error && (
            <div class="alert alert-error mt-4">
              <span>{error}</span>
            </div>
          )}

          <form
            method="post"
            action="/ui/login/start"
            class="mt-4 space-y-3"
            onsubmit="this.querySelector('button[type=submit]').disabled=true;this.querySelector('button[type=submit]').textContent='Sending…';"
          >
            <fieldset class="fieldset">
              <legend class="fieldset-legend font-mono">Email</legend>
              <input
                type="email"
                name="email"
                required
                placeholder="you@example.com"
                class="input input-bordered font-mono w-full"
              />
            </fieldset>
            <button type="submit" class="btn btn-primary w-full">
              Send magic link
            </button>
          </form>

          <div class="divider">or</div>

          <div class="space-y-2">
            <a
              href="/oauth/start?provider=github&callbackURL=/dashboard"
              class="btn btn-outline w-full"
            >
              Continue with GitHub
            </a>
            <a
              href="/oauth/start?provider=google&callbackURL=/dashboard"
              class="btn btn-outline w-full"
            >
              Continue with Google
            </a>
          </div>
        </div>
      </div>
    </Layout>
  );
}
