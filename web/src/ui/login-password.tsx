import { Layout } from "./layout.js";
import { AUTH_MEMORY_SCRIPT } from "./auth-memory.js";

export type LoginPasswordPageProps = {
  email: string;
  error?: string | null;
};

/** Step 2 for a browser that remembers signing this address in with a password.
 *
 *  Reached only from that client-side hint — the server never decides an address
 *  "has a password", which is the enumeration answer the rest of the auth
 *  surface withholds. So this page must never be a dead end for someone the hint
 *  is wrong about: "Email me a link instead" is the standing escape hatch and
 *  resolves every case a wrong hint can produce (no password on the account, no
 *  account at all, or a provider sign-up), because cross-device approve signs in
 *  and signs up with the same link. */
export function LoginPasswordPage({ email, error }: LoginPasswordPageProps) {
  return (
    <Layout title="Sign in">
      <div class="max-w-md mx-auto mt-16 card bg-panel shadow-xl">
        <div class="card-body">
          <h1 class="card-title">Enter your password</h1>

          <div class="flex items-center gap-2 text-sm">
            <span class="font-mono break-all">{email}</span>
            <a class="link text-xs" href={`/login?email=${encodeURIComponent(email)}`}>
              change
            </a>
          </div>

          {error && (
            <div class="alert alert-error mt-4" role="alert">
              <span>{error}</span>
            </div>
          )}

          <form
            method="post"
            action="/ui/login/password"
            class="mt-4 space-y-3"
            data-ab-remember="password"
            data-ab-email={email}
          >
            <input type="hidden" name="email" value={email} />
            <fieldset class="fieldset">
              <label class="fieldset-legend" for="login-password">
                Password
              </label>
              <input
                type="password"
                id="login-password"
                name="password"
                required
                autofocus
                autocomplete="current-password"
                class="input input-bordered font-mono w-full"
              />
            </fieldset>
            <div class="flex items-center justify-between gap-3">
              <label class="label cursor-pointer gap-2 text-sm">
                {/* Unchecked checkboxes are simply absent from the body, which
                    is what the route reads as "do not remember". */}
                <input
                  type="checkbox"
                  name="rememberMe"
                  value="1"
                  checked
                  class="checkbox checkbox-sm"
                />
                <span>Keep me signed in</span>
              </label>
              <a
                class="link text-xs"
                href={`/forgot-password?email=${encodeURIComponent(email)}`}
              >
                Forgot your password?
              </a>
            </div>
            <button
              type="submit"
              class="btn btn-primary w-full"
              data-ab-once="Signing in…"
            >
              Sign in
            </button>
          </form>

          <form
            method="post"
            action="/ui/login/start"
            class="mt-2"
            data-ab-remember="link"
            data-ab-email={email}
          >
            <input type="hidden" name="email" value={email} />
            <button
              type="submit"
              class="btn btn-quiet w-full"
              data-ab-once="Sending…"
            >
              Email me a link instead
            </button>
          </form>

          <p class="text-xs text-muted mt-4 text-center">
            No password on this account? The link above signs you in — and
            creates the account if you don't have one yet.
          </p>

          {/* The only door to a password account, and this is where it belongs:
              reaching this page at all means the user asked for a password, and
              for someone who has never had one the form above is a dead end.
              Step 1 deliberately does not carry it — a sign-up link there would
              re-open the sign-in/sign-up decision that step exists to remove. */}
          <p class="text-xs text-muted mt-2 text-center">
            No account yet?{" "}
            <a class="link" href={`/signup?email=${encodeURIComponent(email)}`}>
              Create one with a password
            </a>
            .
          </p>
        </div>
      </div>
      <script dangerouslySetInnerHTML={{ __html: AUTH_MEMORY_SCRIPT }} />
    </Layout>
  );
}
