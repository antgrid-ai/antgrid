import { z } from "zod";
import { Layout } from "./layout.js";

/** Refusals the accept POST can bounce back to this page. A dead link is not
 *  here — it renders `InviteInvalidPage` instead, since there is no form left to
 *  put an alert above. */
export const InviteNoticeSchema = z.enum([
  "seat_cap",
  "no_subscription",
  "has_paid_subscription",
  "throttled",
  "failed",
]);
export type InviteNotice = z.infer<typeof InviteNoticeSchema>;

export function parseInviteNotice(raw: string | null | undefined): InviteNotice | null {
  const parsed = InviteNoticeSchema.safeParse(raw);
  return parsed.success ? parsed.data : null;
}

const NOTICE_TEXT: Record<InviteNotice, string> = {
  seat_cap: "That team has no free seat right now. Ask the owner to buy one, then try again.",
  no_subscription: "That team has no active subscription, so it cannot take a member yet.",
  has_paid_subscription:
    "You are paying for a subscription of your own. Cancel it first — we will not cancel a subscription you bought.",
  throttled: "Too many attempts. Wait a moment, then try again.",
  failed: "Could not accept the invitation. Try again.",
};

export type InvitePageProps = {
  /** Null when signed out — `Layout` keys its nav and avatar off this. */
  user: { email?: string | null } | null;
  invitedEmail: string;
  invitedBy: string;
  inviteId: string;
  token: string;
  /** `ready` is the only state that renders the accept form. The refused
   *  control is left out entirely rather than disabled, the way /account
   *  handles a deletion it will not perform. */
  state: "ready" | "signed-out" | "mismatch";
  signedInAs: string | null;
  notice: InviteNotice | null;
};

/** The cost of accepting, in the two sentences a user must not be able to miss.
 *  Same words as the invitation email — this is the one place in the product
 *  where a user can lose a Pro grant without buying anything, and the grant they
 *  lose is usually one nobody charged them for. */
function CostWarning() {
  return (
    <div class="alert alert-warning font-mono text-sm mt-4" role="status">
      <span>
        Accepting moves your account onto this team's subscription and cancels
        the subscription you hold today — including a free Pro grant you were
        never charged for. Leaving the team later does not bring it back.
      </span>
    </div>
  );
}

export function InvitePage(p: InvitePageProps) {
  return (
    <Layout title="Team invitation" user={p.user}>
      <div class="max-w-xl mx-auto mt-10">
        <h1 class="font-mono text-2xl font-semibold mb-1">Team invitation</h1>
        <p class="text-sm text-base-content/60 mb-8">
          <span class="font-mono">{p.invitedBy}</span> invited{" "}
          <span class="font-mono">{p.invitedEmail}</span> to join their team on
          Antgrid.
        </p>

        <div class="card bg-base-100 border border-base-300">
          <div class="card-body">
            <h2 class="card-title font-mono">Join this team</h2>
            <p class="text-sm text-base-content/70">
              Your machines and devices stay yours. Your plan, limits and
              billing move to the team owner.
            </p>

            {p.notice && (
              <div class="alert alert-error font-mono text-sm mt-2" role="alert">
                <span>{NOTICE_TEXT[p.notice]}</span>
              </div>
            )}

            <CostWarning />

            {p.state === "ready" ? (
              <form
                method="post"
                action="/ui/team/invite/accept"
                class="mt-4"
                onsubmit="this.querySelector('button[type=submit]').disabled=true;this.querySelector('button[type=submit]').textContent='Joining…';"
              >
                <input type="hidden" name="id" value={p.inviteId} />
                <input type="hidden" name="token" value={p.token} />
                <button type="submit" class="btn btn-primary font-mono">
                  Accept and join
                </button>
              </form>
            ) : p.state === "signed-out" ? (
              <>
                <div class="alert alert-info font-mono text-sm mt-2" role="status">
                  <span>
                    Sign in as {p.invitedEmail}, then open this link again.
                    Accepting an invitation never signs you in and never
                    confirms an address on its own.
                  </span>
                </div>
                <a href="/login" class="btn btn-primary font-mono mt-4 w-fit">
                  Sign in
                </a>
              </>
            ) : (
              <>
                <div class="alert alert-error font-mono text-sm mt-2" role="alert">
                  <span>
                    You are signed in as {p.signedInAs}. This invitation was
                    sent to {p.invitedEmail} and only that account can accept
                    it.
                  </span>
                </div>
                <form method="post" action="/logout" class="mt-4">
                  <button type="submit" class="btn btn-ghost font-mono">
                    Sign out
                  </button>
                </form>
              </>
            )}
          </div>
        </div>
      </div>
    </Layout>
  );
}

export function InviteInvalidPage(props: { user: { email?: string | null } | null }) {
  return (
    <Layout title="Team invitation" user={props.user}>
      <div class="max-w-xl mx-auto mt-10">
        <h1 class="font-mono text-2xl font-semibold mb-1">
          This invitation is no longer valid
        </h1>
        <p class="text-sm text-base-content/60 mb-8">
          It may have expired, been withdrawn, or already been accepted. Ask the
          team owner to send a new one.
        </p>
        <a href="/dashboard" class="btn btn-ghost font-mono">
          Back to dashboard
        </a>
      </div>
    </Layout>
  );
}
