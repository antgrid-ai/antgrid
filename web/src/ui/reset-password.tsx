import { Layout } from "./layout.js";

export type ResetPasswordPageProps = {
  /** Validated a moment ago by Better-Auth's `/reset-password/:token`
   *  callback, which is what redirected the browser here. */
  token: string;
  error?: string | null;
  minPasswordLength: number;
  maxPasswordLength: number;
};

export function ResetPasswordPage({
  token,
  error,
  minPasswordLength,
  maxPasswordLength,
}: ResetPasswordPageProps) {
  return (
    <Layout title="Choose a password">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 shadow-xl">
        <div class="card-body">
          <h1 class="card-title font-mono">Choose a new password</h1>
          <p class="text-sm text-base-content/70">
            Saving signs you out everywhere, including here — you'll sign back
            in with the new password.
          </p>

          {error && (
            <div class="alert alert-error mt-4" role="alert">
              <span>{error}</span>
            </div>
          )}

          <form
            method="post"
            // Token in the query as well as the hidden field: the route
            // throttles before reading the body, and a throttled reply has to
            // hand the token back or the user loses a still-valid link.
            action={`/ui/reset-password?token=${encodeURIComponent(token)}`}
            class="mt-4 space-y-3"
            onsubmit="this.querySelector('button[type=submit]').disabled=true;this.querySelector('button[type=submit]').textContent='Saving…';"
          >
            <input type="hidden" name="token" value={token} />
            {/* `label for=` rather than `legend`: a legend names the fieldset,
                not the control, leaving both fields announced identically. */}
            <fieldset class="fieldset">
              <label class="fieldset-legend font-mono" for="reset-password">
                New password
              </label>
              <input
                type="password"
                id="reset-password"
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
              <label class="fieldset-legend font-mono" for="reset-confirm">
                Confirm password
              </label>
              <input
                type="password"
                id="reset-confirm"
                name="confirmPassword"
                required
                minlength={minPasswordLength}
                maxlength={maxPasswordLength}
                autocomplete="new-password"
                class="input input-bordered font-mono w-full"
              />
            </fieldset>
            <button type="submit" class="btn btn-primary w-full">
              Save password
            </button>
          </form>
        </div>
      </div>
    </Layout>
  );
}

/** Shown when the emailed reset link is expired, already used, or forged —
 *  the token never reaches a form in that case. */
export function ResetLinkInvalidPage() {
  return (
    <Layout title="Reset link expired">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 border border-base-300">
        <div class="card-body items-center text-center">
          <h1 class="card-title font-mono">Reset link expired</h1>
          <p class="text-sm text-base-content/70">
            That link is no longer valid. Reset links last one hour and can only
            be used once.
          </p>
          <a class="btn btn-primary mt-4" href="/forgot-password">
            Send a new link
          </a>
        </div>
      </div>
    </Layout>
  );
}
