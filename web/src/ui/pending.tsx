import { Layout } from "./layout.js";
import { AUTH_MEMORY_SCRIPT } from "./auth-memory.js";
import { AUTH_WAKE_SCRIPT } from "./auth-signal.js";
import { PENDING_TTL_SECONDS } from "../models/pending-sign-in.js";

// Derived from the row's own TTL rather than written out, so the copy cannot
// promise a window the server does not honour.
const EXPIRY_MINUTES = PENDING_TTL_SECONDS / 60;

export type PendingPageProps = {
  email: string;
  pendingId: string;
};

/** The waiting fragment, rendered here on first paint and re-served by
 *  /ui/login/poll on every tick. One component because the re-render IS the
 *  poll loop: triggers that lived in only one of the two copies would work
 *  once and then quietly stop.
 *
 *  `visibilitychange` earns its place in the same-browser case — the link is
 *  opened in another tab, that tab signs in and this one is left stale, so the
 *  moment the user looks back at it is exactly when it must catch up rather
 *  than at the end of whatever remains of its 3s tick. */
export function PollingIndicator({
  pendingId,
  firstPaint,
}: {
  pendingId: string;
  firstPaint?: boolean;
}) {
  return (
    <div
      id="poll"
      class="mt-6 text-xs text-base-content/50 font-mono"
      hx-get={`/ui/login/poll/${pendingId}`}
      hx-trigger={`${firstPaint ? "load delay:2s, " : ""}every 3s, visibilitychange[document.visibilityState=='visible'] from:document`}
      hx-swap="outerHTML"
    >
      Waiting for you to open the link…
    </div>
  );
}

export function PendingPage({ email, pendingId }: PendingPageProps) {
  return (
    <Layout title="Check your email">
      {/* Marks the page as waiting on this address — see auth-signal.ts. */}
      <div
        class="max-w-md mx-auto mt-16 card bg-base-100 border border-base-300"
        data-ab-wake={email}
      >
        <div class="card-body items-center text-center">
          <h1 class="card-title font-mono">Check your email</h1>
          <p class="text-sm text-base-content/70">
            We sent a sign-in link to <span class="font-mono">{email}</span>.
          </p>
          {/* Same-device is the common case and now the short one: the link
              signs that browser straight in. The approval step is what a link
              opened somewhere else gets, and the copy leads with the case the
              reader is actually in. */}
          <p class="text-xs text-base-content/60 mt-2">
            Open it in this browser and you're signed in. On another device,
            tap <strong>Approve</strong> and this page follows along. The link
            expires in {EXPIRY_MINUTES} minutes.
          </p>
          <PollingIndicator pendingId={pendingId} firstPaint />

          {/* No resend route of its own: /ui/login/start mints a fresh pending
              row and redirects to a new pending page, which is precisely what a
              resend is. `-arm` starts the clock on load because THIS page is the
              landing after a send — without it the first retry is offered
              instantly, before the mail it would replace can arrive.

              The row id is in the cooldown KIND, so the stamp is scoped to this
              send rather than to the address: `-arm` only stamps a slot it
              finds unset, so a slot shared across sends would already hold a
              lapsed stamp from an earlier link and hand the next pending page
              an enabled button on load — the exact instant retry `-arm` exists
              to prevent. A reload of THIS page still finds its own stamp and
              so extends nothing. */}
          <form
            method="post"
            action="/ui/login/start"
            class="mt-6"
            data-ab-cooldown={`link.${pendingId}`}
            data-ab-cooldown-arm
          >
            <input type="hidden" name="email" value={email} />
            <button type="submit" class="btn btn-outline btn-sm font-mono">
              Resend the link
            </button>
          </form>

          <p class="text-xs text-base-content/60 mt-6">
            Wrong address?{" "}
            <a class="link" href="/login">
              Start over
            </a>{" "}
            — or{" "}
            <a
              class="link"
              href={`/login/password?email=${encodeURIComponent(email)}`}
            >
              use a password
            </a>
            .
          </p>
        </div>
      </div>
      <script dangerouslySetInnerHTML={{ __html: AUTH_MEMORY_SCRIPT }} />
      <script dangerouslySetInnerHTML={{ __html: AUTH_WAKE_SCRIPT }} />
    </Layout>
  );
}
