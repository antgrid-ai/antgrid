import { Layout } from "./layout.js";
import type { AccountMemberRole } from "../models/account-member.js";
import type { TeamNotice } from "./team-notice.js";

export type TeamMemberRow = {
  userId: string;
  email: string;
  role: AccountMemberRole | null;
  joinedAt: Date;
  isSelf: boolean;
  /** False for the account holder, for the last owner, and for the reader's own
   *  row — the three cases `POST /ui/team/members/:userId/remove` refuses. The
   *  server refuses again regardless; this only keeps the page from offering a
   *  button whose answer is already known. */
  removable: boolean;
};

export type TeamInviteRow = {
  id: string;
  email: string;
  role: AccountMemberRole | null;
  expiresAt: Date;
  /** The address hard-bounced. Only a bounce is ever recorded — ZeptoMail sends
   *  no delivered event, so silence is the success case and must not be shown
   *  as one. */
  bounced: boolean;
};

/**
 * Owner and member are separate shapes rather than one shape with the owner's
 * fields nulled out. A member's props have nowhere to put seats purchased, the
 * member list or the invite form, so a forgotten guard in the markup cannot
 * show someone else's contract — the compiler refuses it instead.
 */
export type TeamView =
  | {
      kind: "owner";
      /** Null when the account holds no live contract: there is no seat count to
       *  show, and the invite form says so rather than implying a cap of zero. */
      seatsPurchased: number | null;
      seatsUsed: number;
      members: TeamMemberRow[];
      invites: TeamInviteRow[];
      /** An owner can be a SECOND owner on someone else's account, and that one
       *  may walk out. The account holder cannot, which is why this is not
       *  implied by `kind`. */
      canLeave: boolean;
    }
  | {
      kind: "member";
      ownerEmail: string | null;
      role: AccountMemberRole | null;
      canLeave: boolean;
    };

export type TeamPageProps = {
  user: { email?: string | null };
  notice: TeamNotice | null;
  view: TeamView;
};

const ALERT_CLASS = {
  success: "alert-success",
  warning: "alert-warning",
  error: "alert-error",
} as const;

/** Every outcome the invite verbs redirect back with, in the words the person
 *  reading them can act on. Wording lives here rather than in the query string
 *  so nobody can hand a signed-in owner a page that says whatever they like. */
const NOTICE: Record<TeamNotice, { tone: keyof typeof ALERT_CLASS; text: string }> = {
  sent: { tone: "success", text: "Invitation sent." },
  resent: {
    tone: "success",
    text: "Invitation sent again. The link from the earlier email no longer works.",
  },
  revoked: { tone: "success", text: "Invitation withdrawn." },
  accepted: { tone: "success", text: "You have joined the team." },
  send_failed: {
    tone: "warning",
    text: "The invitation was created but the email could not be sent. Use Resend to try again.",
  },
  seat_cap: {
    tone: "error",
    text: "Every seat is taken or promised to an invitation. Buy another seat, or withdraw one.",
  },
  over_subscribed: {
    tone: "error",
    text: "This account has more members than seats. Buy seats or remove someone before inviting.",
  },
  already_member: { tone: "error", text: "That address is already on this team." },
  already_invited: {
    tone: "error",
    text: "That address already has an invitation waiting. Resend it, or withdraw it first.",
  },
  invalid_email: { tone: "error", text: "That is not a valid email address." },
  no_subscription: {
    tone: "error",
    text: "This account has no active subscription, so it has no seat to give.",
  },
  removed: {
    tone: "success",
    text: "Removed. Their seat is free — the subscription is unchanged, so buying fewer seats is a separate decision.",
  },
  left: {
    tone: "success",
    text: "You have left the team and are back on your own account.",
  },
  last_owner: {
    tone: "error",
    text: "This is the account's last owner. Make someone else an owner first — an account with none cannot be managed by anyone.",
  },
  account_owner: {
    tone: "error",
    text: "The account belongs to that person, so they cannot be removed from it or leave it. Cancel the subscription instead.",
  },
  not_a_member: { tone: "error", text: "That person is not on this team." },
  forbidden: { tone: "error", text: "Only the account owner can manage the team." },
  throttled: { tone: "error", text: "Too many invitations just now. Wait a moment, then try again." },
  failed: { tone: "error", text: "That did not work. Try again." },
};

function formatDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function plural(n: number, word: string): string {
  return n === 1 ? word : `${word}s`;
}

function RoleBadge({ role }: { role: AccountMemberRole | null }) {
  return <span class="badge badge-outline">{role ?? "unknown"}</span>;
}

export function TeamPage(props: TeamPageProps) {
  const notice = props.notice ? NOTICE[props.notice] : null;
  return (
    <Layout title="Team" user={props.user}>
      <div class="mb-6">
        <h1 class="font-mono text-2xl font-semibold">Team</h1>
        <p class="text-sm text-base-content/60 mt-1">
          Everyone on one account shares its plan and limits. Devices and
          machines stay with the person who registered them.
        </p>
      </div>

      {notice && (
        <div
          class={`alert ${ALERT_CLASS[notice.tone]} font-mono text-sm mb-6`}
          role={notice.tone === "error" ? "alert" : "status"}
        >
          <span>{notice.text}</span>
        </div>
      )}

      {props.view.kind === "owner" ? (
        <OwnerView view={props.view} />
      ) : (
        <MemberView view={props.view} />
      )}
    </Layout>
  );
}

/**
 * Leaving, for whoever is reading — a second owner or a plain member.
 *
 * The cancellation is stated every time it is offered rather than behind a
 * confirm dialog: what a departing member loses is a subscription that does not
 * come back, and that is a sentence, not a yes/no.
 */
function LeaveCard() {
  return (
    <div class="card bg-base-100 border border-base-300 mt-6">
      <div class="card-body">
        <h2 class="card-title font-mono">Leave this team</h2>
        <p class="text-sm text-base-content/70">
          You go back to your own account and its plan. The subscription
          cancelled when you joined does not come back, and your devices stay
          registered to you — but they sign out now and reconnect on your own
          entitlement.
        </p>
        <form method="post" action="/ui/team/leave" class="mt-2">
          <button type="submit" class="btn btn-outline btn-error btn-sm font-mono">
            Leave team
          </button>
        </form>
      </div>
    </div>
  );
}

function OwnerView({ view }: { view: Extract<TeamView, { kind: "owner" }> }) {
  const { seatsPurchased, seatsUsed, members, invites, canLeave } = view;
  // Legal and deliberately not repaired: a seat count can be lowered below the
  // headcount, and nobody is ever removed to make the number fit. It blocks new
  // invitations and nothing else.
  const overSubscribed = seatsPurchased !== null && seatsUsed > seatsPurchased;

  return (
    <>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h2 class="card-title font-mono">Seats</h2>
          <p class="text-sm text-base-content/70">
            A seat is a person on this account's bill. Removing someone frees
            their seat; it never lowers the invoice.
          </p>
          <div class="stats stats-horizontal mt-2 border border-base-300">
            <div class="stat">
              <div class="stat-title">Seats used</div>
              <div class="stat-value text-2xl font-mono">
                {seatsUsed}
                <span class="text-base-content/40">
                  {" / "}
                  {seatsPurchased ?? "—"}
                </span>
              </div>
            </div>
            <div class="stat">
              <div class="stat-title">Pending invites</div>
              <div class="stat-value text-2xl font-mono">{invites.length}</div>
            </div>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-300 mt-6">
        <div class="card-body">
          <h2 class="card-title font-mono">Invite someone</h2>
          <p class="text-sm text-base-content/70">
            They move onto this account's plan and limits when they accept, and
            the subscription they hold today is cancelled — including a free Pro
            grant they were never charged for.
          </p>

          {overSubscribed && (
            <div class="alert alert-warning font-mono text-sm mt-2" role="status">
              <span>
                This account has {seatsUsed} {plural(seatsUsed, "member")} on{" "}
                {seatsPurchased} {plural(seatsPurchased ?? 0, "seat")}. Buy seats
                or remove someone before inviting anyone else.
              </span>
            </div>
          )}
          {seatsPurchased === null && (
            <div class="alert alert-warning font-mono text-sm mt-2" role="status">
              <span>
                This account has no active subscription, so it has no seat to
                give.
              </span>
            </div>
          )}

          <form
            method="post"
            action="/ui/team/invite"
            class="mt-4"
            onsubmit="this.querySelector('button[type=submit]').disabled=true;this.querySelector('button[type=submit]').textContent='Sending…';"
          >
            {/* No role field: everyone is invited as a member. The route accepts
                one, but a second owner can cancel the contract, and there is no
                ownership transfer to undo it with. */}
            <fieldset class="fieldset" disabled={overSubscribed || seatsPurchased === null}>
              <label class="fieldset-legend font-mono" for="invite-email">
                Email address
              </label>
              <input
                type="email"
                id="invite-email"
                name="email"
                required
                autocomplete="off"
                placeholder="teammate@example.com"
                class="input input-bordered font-mono w-full"
              />
              <button type="submit" class="btn btn-primary font-mono mt-3">
                Send invitation
              </button>
            </fieldset>
          </form>
        </div>
      </div>

      <h2 class="font-mono text-lg font-semibold mt-8 mb-2">Members</h2>
      <div class="card bg-base-100 border border-base-300 overflow-x-auto">
        <table class="table">
          <thead>
            <tr class="text-xs uppercase tracking-wide text-base-content/60">
              <th>Member</th>
              <th>Role</th>
              <th>Joined</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {members.map((m) => (
              <tr class="font-mono text-sm">
                <td>
                  {m.email}
                  {m.isSelf && <span class="text-base-content/50"> (you)</span>}
                </td>
                <td>
                  <RoleBadge role={m.role} />
                </td>
                <td class="text-base-content/60">{formatDate(m.joinedAt)}</td>
                <td class="text-right whitespace-nowrap">
                  {m.removable && (
                    <form
                      method="post"
                      action={`/ui/team/members/${m.userId}/remove`}
                      class="inline"
                    >
                      <button type="submit" class="btn btn-ghost btn-xs text-error">
                        Remove
                      </button>
                    </form>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {canLeave && <LeaveCard />}

      <h2 class="font-mono text-lg font-semibold mt-8 mb-2">Pending invitations</h2>
      {invites.length === 0 ? (
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body">
            <p class="text-sm text-base-content/60">
              Nobody is waiting on an invitation. A pending one holds a seat
              until it is accepted, withdrawn, or expires.
            </p>
          </div>
        </div>
      ) : (
        <div class="card bg-base-100 border border-base-300 overflow-x-auto">
          <table class="table">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-base-content/60">
                <th>Invited</th>
                <th>Role</th>
                <th>Expires</th>
                <th>Delivery</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {invites.map((i) => (
                <tr class="font-mono text-sm">
                  <td>{i.email}</td>
                  <td>
                    <RoleBadge role={i.role} />
                  </td>
                  <td class="text-base-content/60">{formatDate(i.expiresAt)}</td>
                  <td>
                    {i.bounced ? (
                      <span class="badge badge-error badge-outline">bounced</span>
                    ) : (
                      <span class="text-base-content/40">—</span>
                    )}
                  </td>
                  <td class="text-right whitespace-nowrap">
                    <form
                      method="post"
                      action={`/ui/team/invite/${i.id}/resend`}
                      class="inline"
                    >
                      <button type="submit" class="btn btn-ghost btn-xs">
                        Resend
                      </button>
                    </form>
                    <form
                      method="post"
                      action={`/ui/team/invite/${i.id}/revoke`}
                      class="inline"
                    >
                      <button type="submit" class="btn btn-ghost btn-xs text-error">
                        Withdraw
                      </button>
                    </form>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

function MemberView({ view }: { view: Extract<TeamView, { kind: "member" }> }) {
  return (
    <>
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h2 class="card-title font-mono">Your billing</h2>
          <p class="text-sm text-base-content/70">
            Your plan, limits and invoice come from the account owned by{" "}
            <span class="font-mono">{view.ownerEmail ?? "the account owner"}</span>
            . Your own subscription was cancelled when you joined, and leaving
            does not bring it back.
          </p>
          <div class="stats stats-horizontal mt-2 border border-base-300 w-fit">
            <div class="stat">
              <div class="stat-title">Your role</div>
              <div class="stat-value text-base font-mono">{view.role ?? "unknown"}</div>
            </div>
          </div>
          <p class="text-xs text-base-content/60 mt-2">
            Only the owner can change the subscription, buy seats, or invite
            people.
          </p>
        </div>
      </div>

      {view.canLeave && <LeaveCard />}
    </>
  );
}
