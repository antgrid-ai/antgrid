import { Layout } from "./layout.js";

export type AccountPageProps = {
  user: { email?: string | null };
  blockedBySubscription: boolean;
  /** False for an account created by magic link or GitHub/Google that has
   *  never had a password — the card offers "set" instead of "change". */
  hasPassword: boolean;
  minPasswordLength: number;
  maxPasswordLength: number;
  passwordNotice?: string | null;
  passwordError?: string | null;
};

export function AccountPage(props: AccountPageProps) {
  return (
    <Layout title="Account" user={props.user}>
      <div class="max-w-xl mx-auto mt-10">
        <h1 class="font-mono text-2xl font-semibold mb-1">Account</h1>
        <p class="text-sm text-base-content/60 mb-8">
          Signed in as <span class="font-mono">{props.user.email}</span>.
        </p>

        <PasswordCard {...props} />

        <div class="card bg-base-100 border border-error/40 mt-6">
          <div class="card-body">
            <h2 class="card-title font-mono text-error">Delete account</h2>
            <p class="text-sm text-base-content/70">
              This permanently deletes your account, sessions, connected devices,
              and sign-in credentials. This cannot be undone. Billing records
              required for tax compliance are retained but detached from your
              identity.
            </p>

            {props.blockedBySubscription ? (
              <div class="alert alert-warning font-mono text-sm mt-2" role="status">
                <span>
                  You have an active subscription. Cancel it on your{" "}
                  <a class="link" href="/dashboard">dashboard</a> before deleting
                  your account.
                </span>
              </div>
            ) : (
              <form method="post" action="/ui/account/delete" class="mt-4">
                <label class="text-xs text-base-content/60 font-mono" for="confirm-input">
                  Type <span class="font-bold">DELETE</span> to confirm:
                </label>
                <input
                  type="text"
                  id="confirm-input"
                  name="confirm"
                  autocomplete="off"
                  class="input input-bordered font-mono w-full mt-1"
                  placeholder="DELETE"
                />
                <button
                  type="submit"
                  id="delete-submit"
                  class="btn btn-error font-mono mt-3"
                  disabled
                >
                  Delete my account
                </button>
              </form>
            )}
          </div>
        </div>
      </div>
      <script
        dangerouslySetInnerHTML={{
          __html:
            `const i=document.getElementById('confirm-input');` +
            `const b=document.getElementById('delete-submit');` +
            `if(i&&b){i.addEventListener('input',()=>{b.disabled=i.value.trim()!=='DELETE';});}`,
        }}
      />
    </Layout>
  );
}

function PasswordCard(props: AccountPageProps) {
  const {
    hasPassword,
    minPasswordLength,
    maxPasswordLength,
    passwordNotice,
    passwordError,
  } = props;
  return (
    <div class="card bg-base-100 border border-base-300">
      <div class="card-body">
        <h2 class="card-title font-mono">
          {hasPassword ? "Change password" : "Set a password"}
        </h2>
        <p class="text-sm text-base-content/70">
          {hasPassword
            ? "Your account can sign in with a password. Changing it signs you out of your other browser sessions."
            : "Your account signs in with a magic link or GitHub/Google. Adding a password gives you a second way in — the existing ones keep working. Saving signs you out of your other browser sessions."}
        </p>

        {passwordNotice && (
          <div class="alert alert-success font-mono text-sm mt-2" role="status">
            <span>{passwordNotice}</span>
          </div>
        )}
        {passwordError && (
          <div class="alert alert-error font-mono text-sm mt-2" role="alert">
            <span>{passwordError}</span>
          </div>
        )}

        <form
          method="post"
          action="/ui/account/password"
          class="mt-4 space-y-3"
          onsubmit="this.querySelector('button[type=submit]').disabled=true;this.querySelector('button[type=submit]').textContent='Saving…';"
        >
          {/* Password managers key a change on an accompanying username field
              and will not update an existing entry without one — they'd save a
              second, blank-username credential and keep autofilling the old
              password at /login. Hidden and unsubmittable; the server takes the
              user from the session. */}
          <input
            type="email"
            name="username"
            value={props.user.email ?? ""}
            autocomplete="username"
            readonly
            hidden
            aria-hidden="true"
            tabindex={-1}
          />
          {/* `label for=` rather than `legend`: a legend names the fieldset, not
              the control, so all three announce as a bare "password, edit".
              Matches the delete form below. */}
          {hasPassword && (
            <fieldset class="fieldset">
              <label class="fieldset-legend font-mono" for="account-current-password">
                Current password
              </label>
              <input
                type="password"
                id="account-current-password"
                name="currentPassword"
                required
                autocomplete="current-password"
                class="input input-bordered font-mono w-full"
              />
            </fieldset>
          )}
          <fieldset class="fieldset">
            <label class="fieldset-legend font-mono" for="account-new-password">
              {hasPassword ? "New password" : "Password"}
            </label>
            <input
              type="password"
              id="account-new-password"
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
            <label class="fieldset-legend font-mono" for="account-confirm-password">
              Confirm password
            </label>
            <input
              type="password"
              id="account-confirm-password"
              name="confirmPassword"
              required
              minlength={minPasswordLength}
              maxlength={maxPasswordLength}
              autocomplete="new-password"
              class="input input-bordered font-mono w-full"
            />
          </fieldset>
          <button type="submit" class="btn btn-primary font-mono">
            {hasPassword ? "Change password" : "Set password"}
          </button>
        </form>
      </div>
    </div>
  );
}

export function AccountDeletedPage() {
  return (
    <Layout title="Account deleted">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 border border-base-300">
        <div class="card-body items-center text-center">
          <h1 class="card-title font-mono">Account deleted</h1>
          <p class="text-sm text-base-content/70">
            Your account has been permanently deleted. You can close this tab.
          </p>
        </div>
      </div>
    </Layout>
  );
}
