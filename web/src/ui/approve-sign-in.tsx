import { Layout } from "./layout.js";

export type ApproveSignInProps = {
  email: string;
  requesterUa: string | null;
  requesterIp: string | null;
  requestedAt: Date;
  pendingId: string;
  token: string;
  error?: string | null;
};

function shortUa(ua: string | null): string {
  if (!ua) return "unknown device";
  // The Antgrid app sends `Antgrid/<version> (<os> <osVersion>)`; show it as-is.
  // osVersion itself can contain parens (Windows/macOS embed `(Build NNNNN)`),
  // so take the whole UA rather than trying to balance them.
  if (ua.startsWith("Antgrid/")) return ua.slice(0, 60);
  const m = ua.match(/(Chrome|Firefox|Safari|Edge)\/[\d.]+/);
  return m ? m[0] : ua.slice(0, 60);
}

export function ApproveSignInPage(p: ApproveSignInProps) {
  return (
    <Layout title="Approve sign-in">
      <div class="max-w-md mx-auto mt-16 card bg-base-100 border border-base-300">
        <div class="card-body">
          <h1 class="card-title font-mono">Approve sign-in</h1>
          <p class="text-sm text-base-content/70">
            Someone is trying to sign in to Antgrid as <span class="font-mono">{p.email}</span>.
          </p>
          <dl class="mt-4 text-xs font-mono space-y-1">
            <div class="flex justify-between gap-4">
              <dt class="text-base-content/50">Device</dt>
              <dd class="text-right">{shortUa(p.requesterUa)}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-base-content/50">IP</dt>
              <dd class="text-right">{p.requesterIp ?? "hidden"}</dd>
            </div>
            <div class="flex justify-between gap-4">
              <dt class="text-base-content/50">Requested</dt>
              <dd class="text-right">{p.requestedAt.toISOString().slice(0, 16).replace("T", " ")}Z</dd>
            </div>
          </dl>
          {p.error && (
            <div class="alert alert-error mt-4 text-xs">{p.error}</div>
          )}
          <form
            method="post"
            action="/ui/login/approve"
            class="mt-4"
            onsubmit="this.querySelector('button[type=submit]').disabled=true;this.querySelector('button[type=submit]').textContent='Approving…';"
          >
            <input type="hidden" name="id" value={p.pendingId} />
            <input type="hidden" name="token" value={p.token} />
            <button type="submit" class="btn btn-primary w-full">
              Approve sign-in
            </button>
          </form>
          <p class="text-xs text-base-content/50 mt-3">
            If this wasn't you, close this tab. The sign-in won't proceed
            without approval and the link expires in 10 minutes.
          </p>
        </div>
      </div>
    </Layout>
  );
}
