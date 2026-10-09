// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { Layout } from "./layout.js";

export type SwitchAccountPageProps = {
  /** The browser's current Better-Auth session — always present, since this
   *  page is only reached after `requireUserOrRedirect` already passed. */
  currentEmail: string | null;
  /** The account the app asked to continue as. */
  expectedEmail: string;
};

/**
 * Interposed between a mismatched `asEmail` and actually signing the browser
 * out — GET must stay side-effect-free, so this only asks; the form below is
 * what carries the sign-out, as a POST the router's same-origin check guards.
 */
export function SwitchAccountPage(p: SwitchAccountPageProps) {
  return (
    <Layout title="Switch account">
      <div class="max-w-md mx-auto mt-16 card bg-panel border border-edge">
        <div class="card-body">
          <h1 class="card-title">Switch account</h1>
          <p class="text-sm text-muted">
            This browser is signed in as{" "}
            <span class="font-mono">{p.currentEmail ?? "another account"}</span>, but the app is
            signed in as <span class="font-mono">{p.expectedEmail}</span>.
          </p>
          <form method="post" action="/ui/integrations/switch-account" class="mt-4">
            <input type="hidden" name="asEmail" value={p.expectedEmail} />
            <button type="submit" class="btn btn-primary w-full">
              Sign out and switch accounts
            </button>
          </form>
          <p class="text-xs text-muted2 mt-3">
            Nothing happens until you press the button — close this tab to leave this browser
            signed in as it is.
          </p>
        </div>
      </div>
    </Layout>
  );
}
