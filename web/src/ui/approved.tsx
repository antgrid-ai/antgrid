import { Layout } from "./layout.js";

export function ApprovedPage() {
  return (
    <Layout title="Sign-in approved">
      <div class="max-w-md mx-auto mt-16 card bg-panel border border-edge">
        <div class="card-body items-center text-center">
          <h1 class="card-title">Sign-in approved</h1>
          <p class="text-sm text-muted">
            The other browser is being signed in. You can close this tab.
          </p>
        </div>
      </div>
    </Layout>
  );
}
