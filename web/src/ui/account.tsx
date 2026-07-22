import { Layout } from "./layout.js";

export type AccountPageProps = {
  user: { email?: string | null };
  blockedBySubscription: boolean;
};

export function AccountPage(props: AccountPageProps) {
  return (
    <Layout title="Account" user={props.user}>
      <div class="max-w-xl mx-auto mt-10">
        <h1 class="font-mono text-2xl font-semibold mb-1">Account</h1>
        <p class="text-sm text-base-content/60 mb-8">
          Signed in as <span class="font-mono">{props.user.email}</span>.
        </p>

        <div class="card bg-base-100 border border-error/40">
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
