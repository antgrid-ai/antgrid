import { Layout } from "./layout.js";
import { asset } from "./asset.js";
import { ActiveSessionsCard } from "./active-sessions.js";
import type { UserSession } from "../services/sessions.js";
import type { SubscriptionRow } from "../models/subscription.js";
import type { PlanRow } from "../models/plan.js";
import { FREE_TIER } from "../billing/plans.js";
import { isPendingCancellation } from "../models/subscription.js";

export type DashboardPageProps = {
  user: { email?: string | null };
  subscription: SubscriptionRow;
  plan: PlanRow;
  tier: string;
  deviceLimit: number;
  activeDevices: number;
  sessions: UserSession[] | null;
  sessionLimit: number;
  now: number;
  purchaseSuccess?: boolean;
  cancelNotice?: "immediate" | "pending" | "failed" | null;
  resumeNotice?: "success" | "failed" | null;
};

function formatDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

const STATUS_BADGE: Record<SubscriptionRow["status"], string> = {
  active: "badge-success",
  past_due: "badge-warning",
  canceled: "badge-neutral",
  expired: "badge-error",
};

export function DashboardPage(props: DashboardPageProps) {
  const pageData = JSON.stringify({
    tier: props.tier,
    purchaseSuccess: props.purchaseSuccess === true,
    cancelNotice: props.cancelNotice ?? null,
    resumeNotice: props.resumeNotice ?? null,
  });

  return (
    <Layout title="Dashboard" user={props.user}>
      <div class="mb-6">
        <h1 class="font-mono text-2xl font-semibold">Dashboard</h1>
        <p class="text-sm text-base-content/60 mt-1">
          Manage your subscription and connected devices.
        </p>
      </div>

      <div
        id="purchase-status-banner"
        class={`alert alert-success mb-6 font-mono text-sm ${props.purchaseSuccess ? "" : "hidden"}`}
        role="status"
      >
        <span
          id="purchase-status-spinner"
          class={`loading loading-spinner loading-sm shrink-0 ${props.tier === FREE_TIER ? "" : "hidden"}`}
        />
        <span id="purchase-status-message">
          {props.tier === FREE_TIER
            ? "Payment successful — activating your subscription…"
            : "Payment successful — your subscription is active."}
        </span>
        <button
          type="button"
          id="purchase-status-dismiss"
          class="btn btn-ghost btn-xs ml-auto shrink-0"
          aria-label="Dismiss"
        >
          ✕
        </button>
      </div>

      {props.cancelNotice === "immediate" ? (
        <div class="alert alert-info mb-6 font-mono text-sm" role="status">
          Subscription canceled — you are back on the free plan.
        </div>
      ) : null}
      {props.cancelNotice === "pending" ? (
        <div class="alert alert-info mb-6 font-mono text-sm" role="status">
          Subscription will end on{" "}
          {formatDate(
            new Date(
              props.subscription.cancelledAt ?? props.subscription.currentPeriodEnd ?? Date.now()
            )
          )}
          . You keep Pro until then — use Resume subscription to undo.
        </div>
      ) : null}
      {props.cancelNotice === "failed" ? (
        <div class="alert alert-error mb-6 font-mono text-sm" role="status">
          Could not cancel subscription. Try again or contact support.
        </div>
      ) : null}
      {props.resumeNotice === "success" ? (
        <div class="alert alert-success mb-6 font-mono text-sm" role="status">
          Subscription resumed — your plan will renew as normal.
        </div>
      ) : null}
      {props.resumeNotice === "failed" ? (
        <div class="alert alert-error mb-6 font-mono text-sm" role="status">
          Could not resume subscription. Try again or contact support.
        </div>
      ) : null}

      <div id="subscription-card">
        <SubscriptionCard {...props} />
      </div>
      <ActiveSessionsCard
        tier={props.tier}
        sessions={props.sessions}
        sessionLimit={props.sessionLimit}
        now={props.now}
      />

      <script
        type="application/json"
        id="dashboard-data"
        dangerouslySetInnerHTML={{ __html: pageData }}
      />
      <script src={asset("dashboard")} defer />
    </Layout>
  );
}

function SubscriptionCard({
  subscription,
  plan,
  tier,
  deviceLimit,
  activeDevices,
}: DashboardPageProps) {
  const pendingCancel = isPendingCancellation(subscription);
  const canCancel =
    plan.recurring &&
    plan.slug !== "pro_lifetime" &&
    subscription.status === "active" &&
    !pendingCancel &&
    (subscription.providerSubscriptionId !== null || subscription.provider === "dev");
  const canResume =
    pendingCancel &&
    plan.recurring &&
    plan.slug !== "pro_lifetime" &&
    (subscription.providerSubscriptionId !== null || subscription.provider === "dev");
  const periodEndDate = pendingCancel
    ? subscription.cancelledAt
    : subscription.currentPeriodEnd;

  // TEMP-PROMO: a temporary, unpurchased grant — surface it as the free tier
  // (no plan name, no cancel/resume, no pricing CTA) even though entitlement
  // matches pro under the hood (see ensureDefaultSubscription in
  // web/src/models/subscription.ts — grep "TEMP-PROMO" repo-wide for every
  // related spot). Delete this branch once payment integration ships and
  // `promotional` rows are reconciled.
  if (subscription.promotional) {
    return (
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <div class="flex items-center gap-2 mb-1">
            <span class="badge badge-ghost font-mono text-xs capitalize">{FREE_TIER}</span>
          </div>
          <div class="stats stats-horizontal mt-4 border border-base-300">
            <div class="stat">
              <div class="stat-title">Active devices</div>
              <div class="stat-value text-2xl font-mono">
                {activeDevices}
                <span class="text-base-content/40">
                  {" / "}
                  {deviceLimit}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    );
  }

  if (tier === FREE_TIER) {
    return (
      <div class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <div class="flex items-start justify-between gap-6 flex-wrap">
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 mb-1">
                <span class="badge badge-ghost font-mono text-xs capitalize">{FREE_TIER}</span>
              </div>
              <p class="text-sm text-base-content/70 mt-1 max-w-md">
                Mobile and relay access require Pro — control multiple remote
                agents at once. Pro Yearly from $49/yr or Lifetime for $99.
              </p>
            </div>
            <a class="btn btn-primary" href="/pricing">
              View pricing
            </a>
          </div>
          <div class="stats stats-horizontal mt-4 border border-base-300">
            <div class="stat">
              <div class="stat-title">Active devices</div>
              <div class="stat-value text-2xl font-mono">
                {activeDevices}
                <span class="text-base-content/40">
                  {" / "}
                  {deviceLimit}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    );
  }
  return (
    <div class="card bg-base-100 border border-base-300">
      <div class="card-body">
        <div class="flex items-center gap-2">
          <h2 class="card-title font-mono">{plan.label}</h2>
          {pendingCancel ? (
            <span class="badge badge-warning font-mono text-xs">ending</span>
          ) : (
            <span class={`badge ${STATUS_BADGE[subscription.status]}`}>
              {subscription.status}
            </span>
          )}
        </div>
        <div class="stats stats-horizontal mt-2 border border-base-300">
          <div class="stat">
            <div class="stat-title">Active devices</div>
            <div class="stat-value text-2xl font-mono">
              {activeDevices}
              <span class="text-base-content/40">
                {" / "}
                {deviceLimit}
              </span>
            </div>
          </div>
          <div class="stat">
            <div class="stat-title">Started</div>
            <div class="stat-value text-base font-mono">
              {formatDate(
                new Date(subscription.trialStartedAt ?? subscription.createdAt)
              )}
            </div>
          </div>
          {plan.trial && subscription.trialEndsAt ? (
            <div class="stat">
              <div class="stat-title">First charge</div>
              <div class="stat-value text-base font-mono">
                {formatDate(new Date(subscription.trialEndsAt))}
              </div>
            </div>
          ) : plan.recurring && periodEndDate ? (
            <div class="stat">
              <div class="stat-title">{pendingCancel ? "Ends" : "Renews"}</div>
              <div class="stat-value text-base font-mono">
                {formatDate(new Date(periodEndDate))}
              </div>
            </div>
          ) : null}
        </div>
        {canResume ? (
          <>
            <div class="mt-4 pt-4 border-t border-base-300 flex flex-wrap items-center justify-between gap-3">
              <p class="text-xs text-base-content/60 max-w-lg">
                Your subscription ends on{" "}
                {formatDate(new Date(subscription.cancelledAt ?? Date.now()))}. Resume to keep Pro
                and renew at period end.
              </p>
              <button
                type="button"
                id="resume-subscription-btn"
                class="btn btn-outline btn-primary btn-sm font-mono"
              >
                Resume subscription
              </button>
            </div>
            <div id="resume-subscription-modal" class="modal">
              <div class="modal-box max-w-md">
                <h3 class="font-mono text-lg font-semibold">Resume subscription?</h3>
                <p class="text-sm text-base-content/70 mt-2">
                  Your plan will continue and renew on{" "}
                  {formatDate(new Date(subscription.currentPeriodEnd ?? Date.now()))}.
                </p>
                <div class="modal-action mt-4">
                  <button type="button" class="btn btn-ghost font-mono" data-resume-dismiss>
                    Keep cancellation
                  </button>
                  <form method="post" action="/ui/subscription/resume">
                    <button type="submit" class="btn btn-primary font-mono">
                      Yes, resume
                    </button>
                  </form>
                </div>
              </div>
              <button
                type="button"
                class="modal-backdrop"
                data-resume-dismiss
                aria-label="Close"
              />
            </div>
          </>
        ) : null}
        {canCancel ? (
          <>
            <div class="mt-4 pt-4 border-t border-base-300 flex flex-wrap items-center justify-between gap-3">
              <p class="text-xs text-base-content/60 max-w-lg">
                {plan.trial
                  ? "Cancel before your first charge to avoid billing. Access ends immediately."
                  : "Cancel at period end — you keep Pro until your renewal date, then revert to free."}
              </p>
              <button
                type="button"
                id="cancel-subscription-btn"
                class="btn btn-outline btn-error btn-sm font-mono"
              >
                Cancel subscription
              </button>
            </div>
            <div id="cancel-subscription-modal" class="modal">
              <div class="modal-box max-w-md">
                <h3 class="font-mono text-lg font-semibold">Cancel subscription?</h3>
                <p class="text-sm text-base-content/70 mt-2">
                  {plan.trial
                    ? "You will lose Pro access immediately and your card will not be charged."
                    : "You keep Pro access until the end of your billing period, then revert to free."}
                </p>
                <div class="modal-action mt-4">
                  <button type="button" class="btn btn-ghost font-mono" data-cancel-dismiss>
                    Keep subscription
                  </button>
                  <form method="post" action="/ui/subscription/cancel">
                    <button type="submit" class="btn btn-error font-mono">
                      Yes, cancel
                    </button>
                  </form>
                </div>
              </div>
              <button
                type="button"
                class="modal-backdrop"
                data-cancel-dismiss
                aria-label="Close"
              />
            </div>
          </>
        ) : null}
      </div>
    </div>
  );
}

