import { Layout } from "./layout.js";

export type PendingPageProps = {
  email: string;
  pendingId: string;
};

export function PendingPage({ email, pendingId }: PendingPageProps) {
  return (
    <Layout title="Check your email">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 border border-base-300">
        <div class="card-body items-center text-center">
          <h1 class="card-title font-mono">Check your email</h1>
          <p class="text-sm text-base-content/70">
            We sent a sign-in link to <span class="font-mono">{email}</span>.
          </p>
          <p class="text-xs text-base-content/60 mt-2">
            Open the link on any device and tap <strong>Approve</strong>.
            This page will sign in automatically.
          </p>
          <div
            id="poll"
            class="mt-6 text-xs text-base-content/50 font-mono"
            hx-get={`/ui/login/poll/${pendingId}`}
            hx-trigger="load delay:2s, every 3s"
            hx-swap="outerHTML"
          >
            Waiting for approval…
          </div>
        </div>
      </div>
    </Layout>
  );
}
