import { Layout } from "./layout.js";

export function ApprovedPage() {
  return (
    <Layout title="Sign-in approved">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 border border-base-300">
        <div class="card-body items-center text-center">
          <h1 class="card-title font-mono">Sign-in approved</h1>
          <p class="text-sm text-base-content/70">
            The other browser is being signed in. You can close this tab.
          </p>
        </div>
      </div>
    </Layout>
  );
}
