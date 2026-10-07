// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { Layout } from "./layout.js";
import { AUTH_MEMORY_SCRIPT, type AuthMethod } from "./auth-memory.js";

// The legal pages live on the marketing site, not this service — and they are
// the same documents whichever app environment you signed in from, so these are
// absolute and unversioned. Same call as download-card.tsx.
const SITE_TERMS_URL = "https://antgrid.ai/terms";
const SITE_PRIVACY_URL = "https://antgrid.ai/privacy";
const PROVIDERS = [
  { method: "github", label: "GitHub" },
  { method: "google", label: "Google" },
  { method: "apple", label: "Apple" },
] as const;

export type LoginPageProps = {
  error?: string | null;
  notice?: string | null;
  /** Carried back by step 2's "change" link so returning to step 1 never costs
   *  the user the address they already typed. */
  email?: string | null;
  /** Whether this deployment offers Sign in with Apple (it needs keys that
   *  local and self-hosted setups do not have). */
  apple?: boolean;
};

/** Step 1 of the email-first flow: one field, no sign-in/sign-up decision.
 *
 *  What happens next is decided by `/ui/login/continue` from a hint the BROWSER
 *  supplies (see auth-memory.ts), never from a server-side lookup of the
 *  address. Absent a hint the answer is the magic link, which is correct for
 *  every address: cross-device approve creates the user when there isn't one
 *  (auth/cross-device-plugin.ts), so the same button signs in and signs up. */
export function LoginPage({ error, notice, email, apple = false }: LoginPageProps) {
  return (
    <Layout title="Sign in">
      <section aria-labelledby="login-title" class="max-w-md mx-auto my-6 sm:my-12 rounded-box border border-edge bg-panel">
        <div class="login-card-body p-5 sm:p-8">
          <h1 id="login-title" class="font-display text-[1.75rem] font-semibold tracking-[-0.026em] leading-tight">Sign in to Antgrid</h1>
          <p class="mt-2 text-sm leading-relaxed text-muted">
            Sign in or create an account to get started.
          </p>

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
            id="login-form"
            method="post"
            action="/ui/login/continue"
            class="mt-6"
            data-ab-recall
          >
            {/* Filled from localStorage on submit. Empty is the honest default
                and routes to the magic link — with JS off it always is. */}
            <input type="hidden" name="method" value="" />
            <div>
              <div class="mb-2 flex items-center justify-between gap-2">
                <label class="block text-sm font-medium" for="login-email">
                  Email address
                </label>
                <LastUsedBadge method="link" />
              </div>
              <input
                type="email"
                id="login-email"
                name="email"
                required
                autofocus
                autocomplete="email"
                value={email ?? ""}
                data-ab-prefill
                placeholder="you@example.com"
                class="input input-bordered login-email h-11 font-mono text-sm w-full bg-transparent"
              />
            </div>
            <button
              type="submit"
              class="btn btn-primary mt-3 h-11 w-full shadow-none font-semibold"
              data-ab-once="Continuing…"
            >
              Continue with email
            </button>
          </form>
          {/* An explicit password choice must ignore remembered provider hints;
              otherwise a fresh browser or a stale hint can trap a returning user. */}
          <button
            type="submit"
            form="login-form"
            name="fallback"
            value="password"
            class="mx-auto mt-1 flex min-h-11 items-center justify-center gap-2 rounded-field px-3 text-sm text-muted hover:text-ink hover:underline underline-offset-4 cursor-pointer"
          >
            Use a password instead
            <LastUsedBadge method="password" />
          </button>

          {/* Two tiers, and the split is what the hint is allowed to decide.
              Continue above is the fast path and the only control that reads
              the hint; every method below names itself and ignores it, so a
              hint that is missing or wrong costs a click rather than the
              account. */}
          <div class="mt-4 mb-5 flex items-center gap-3 text-xs text-muted">
            <span class="h-px flex-1 bg-edge" />
            <span>or continue with</span>
            <span class="h-px flex-1 bg-edge" />
          </div>

          <div class={`login-providers${apple ? " login-providers-three" : ""}`}>
            {PROVIDERS.filter(({ method }) => method !== "apple" || apple).map(({ method, label }) => (
              <a
                href={`/oauth/start?provider=${method}&callbackURL=/dashboard`}
                class="btn btn-quiet login-provider relative h-11 gap-2 px-2 shadow-none text-sm font-medium"
                data-ab-remember={method}
              >
                <ProviderIcon provider={method} />
                <span>{label}</span>
                <LastUsedBadge method={method} floating />
              </a>
            ))}
          </div>

          {/* New tab, so reading the terms never navigates out of a half-filled
              form: `data-ab-prefill` only fills an EMPTY field and only from the
              last address this browser remembered, so coming back to a fresh
              load would silently restore a different address than the one being
              typed. */}
          <p class="text-xs leading-relaxed text-muted2 mt-7 text-center">
            By continuing, you agree to our{" "}
            <a class="link" href={SITE_TERMS_URL} target="_blank" rel="noopener noreferrer">
              Terms
            </a>{" "}
            and{" "}
            <a class="link" href={SITE_PRIVACY_URL} target="_blank" rel="noopener noreferrer">
              Privacy Policy
            </a>
            .
          </p>
        </div>
      </section>
      <script dangerouslySetInnerHTML={{ __html: AUTH_MEMORY_SCRIPT }} />
    </Layout>
  );
}

function LastUsedBadge({ method, floating = false }: { method: AuthMethod; floating?: boolean }) {
  return (
    <span
      hidden
      data-ab-last-used={method}
      title="Last used on this browser"
      class={`auth-last-used${floating ? " auth-last-used-floating" : ""}`}
    >
      Last used
    </span>
  );
}

// Simple Icons marks (CC0) keep provider recognition without adding another accent.
function ProviderIcon({ provider }: { provider: "apple" | "github" | "google" }) {
  const paths = {
    apple: "M17.05 12.536c.031 3.25 2.852 4.331 2.883 4.345-.024.076-.451 1.541-1.486 3.054-.895 1.308-1.823 2.611-3.286 2.638-1.438.027-1.901-.852-3.545-.852-1.643 0-2.157.825-3.518.879-1.412.053-2.487-1.414-3.389-2.717C2.765 17.22.899 12.354 2.894 8.99c.99-1.67 2.761-2.727 4.684-2.754 1.465-.027 2.848.933 3.744.933.895 0 2.574-1.154 4.338-.984.739.031 2.813.298 4.144 2.248-.107.066-2.475 1.442-2.449 4.103M14.348 4.418c.749-.907 1.253-2.17 1.116-3.418-1.079.043-2.384.719-3.158 1.626-.693.803-1.299 2.088-1.135 3.316 1.203.093 2.428-.61 3.177-1.524",
    github: "M12 .297C5.37.297 0 5.67 0 12.297c0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.043-1.61-4.043-1.61-.546-1.387-1.333-1.756-1.333-1.756-1.09-.745.083-.729.083-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.418-1.305.762-1.605-2.665-.3-5.466-1.334-5.466-5.931 0-1.31.468-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.323 3.301 1.23a11.52 11.52 0 013.003-.404c1.02.005 2.047.138 3.003.404 2.291-1.553 3.297-1.23 3.297-1.23.654 1.652.243 2.873.12 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.628-5.479 5.921.43.372.823 1.102.823 2.222 0 1.606-.015 2.898-.015 3.293 0 .322.216.694.825.576C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12",
    google: "M12.48 10.92v3.28h7.84c-.24 1.84-.853 3.187-1.787 4.133-1.147 1.147-2.933 2.4-6.053 2.4-4.827 0-8.6-3.893-8.6-8.72s3.773-8.72 8.6-8.72c2.6 0 4.507 1.027 5.907 2.347l2.307-2.307C18.747 1.44 16.133 0 12.48 0 5.867 0 .307 5.387.307 12s5.56 12 12.173 12c3.573 0 6.267-1.173 8.373-3.36 2.16-2.16 2.84-5.213 2.84-7.667 0-.76-.053-1.467-.173-2.053z",
  };
  return (
    <svg class="h-5 w-5" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" focusable="false">
      <path d={paths[provider]} />
    </svg>
  );
}
