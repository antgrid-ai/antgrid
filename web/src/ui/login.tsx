import { Layout } from "./layout.js";

export type LoginPageProps = {
  error?: string | null;
  sent?: string | null;
  notice?: string | null;
};

export function LoginPage({ error, sent, notice }: LoginPageProps) {
  return (
    <Layout title="Sign in">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 shadow-xl">
        <div class="card-body">
          <h1 class="card-title font-mono">Sign in to Antgrid</h1>
          <p class="text-sm text-base-content/70">
            Magic link, GitHub, or Google — no password needed.
          </p>

          {sent && (
            <div class="alert alert-success mt-4">
              <span>Check your inbox — we sent a sign-in link to {sent}.</span>
            </div>
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
                id="magic-email"
                name="email"
                required
                autocomplete="email"
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

          <details id="password-disclosure" class="collapse collapse-arrow border border-base-300 mt-4">
            <summary class="collapse-title font-mono text-sm">
              Sign in with a password
            </summary>
            <div class="collapse-content">
              <form method="post" action="/ui/login/password" class="space-y-3">
                <fieldset class="fieldset">
                  <legend class="fieldset-legend font-mono">Email</legend>
                  <input
                    type="email"
                    id="password-email"
                    name="email"
                    required
                    autocomplete="email"
                    placeholder="you@example.com"
                    class="input input-bordered font-mono w-full"
                  />
                </fieldset>
                <fieldset class="fieldset">
                  <legend class="fieldset-legend font-mono">Password</legend>
                  <input
                    type="password"
                    name="password"
                    required
                    autocomplete="current-password"
                    class="input input-bordered font-mono w-full"
                  />
                </fieldset>
                <button type="submit" class="btn btn-neutral w-full">
                  Sign in
                </button>
              </form>
              <p class="text-xs text-base-content/60 mt-3">
                <a class="link" href="/forgot-password">
                  Forgot your password?
                </a>{" "}
                Accounts created with a magic link or GitHub/Google have no
                password until you set one.
              </p>
            </div>
          </details>

          <p class="text-sm text-base-content/70 mt-4 text-center">
            No account yet?{" "}
            <a class="link" href="/signup">
              Sign up with a password
            </a>
          </p>
        </div>
      </div>
      {/* Carry whatever the user already typed above into the password form so
          opening the disclosure never costs them a retype. */}
      <script
        dangerouslySetInnerHTML={{
          __html:
            `const d=document.getElementById('password-disclosure');` +
            `const a=document.getElementById('magic-email');` +
            `const b=document.getElementById('password-email');` +
            `if(d&&a&&b){d.addEventListener('toggle',()=>{if(d.open&&a.value&&!b.value)b.value=a.value;});}`,
        }}
      />
    </Layout>
  );
}
