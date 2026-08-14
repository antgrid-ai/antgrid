import { Layout, PageHead } from "./layout.js";
import { asset } from "./asset.js";
import { CellMeter } from "./cell-meter.js";
import { ActiveSessionsCard } from "./active-sessions.js";
import { DownloadCard } from "./download-card.js";
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
  appDeviceLimit: number;
  activeAppDevices: number;
  workerLimit: number;
  activeWorkers: number;
  sessions: UserSession[] | null;
  now: number;
  purchaseSuccess?: boolean;
  cancelNotice?: "immediate" | "pending" | "failed" | null;
  resumeNotice?: "success" | "failed" | null;
};

function formatDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

/** `active` is what a reader sees every visit, so it is tinted rather than
 *  filled — a solid green slab spent the page's loudest colour on its least
 *  actionable fact. The states that need the reader to do something keep it. */
const STATUS_BADGE: Record<SubscriptionRow["status"], string> = {
  active: "badge-sm border-ok/40 bg-ok/10 text-ok",
  past_due: "badge-sm badge-warning",
  canceled: "badge-sm border-edge text-muted",
  expired: "badge-sm badge-error",
};

export function DashboardPage(props: DashboardPageProps) {
  const pageData = JSON.stringify({
    // Rendering this page means the session gate passed, so it is the honest
    // place to announce a sign-in to any tab still waiting on one — see
    // auth-signal.ts for why the address travels with it.
    email: props.user.email ?? null,
    tier: props.tier,
    purchaseSuccess: props.purchaseSuccess === true,
    cancelNotice: props.cancelNotice ?? null,
    resumeNotice: props.resumeNotice ?? null,
  });

  return (
    <Layout title="Dashboard" user={props.user} section="dashboard">
      <PageHead title="Dashboard">
        Your plan, how much of it you are using, and which machines are
        connected right now.
      </PageHead>

      <div
        id="purchase-status-banner"
        class={`alert alert-success mb-6 text-sm ${props.purchaseSuccess ? "" : "hidden"}`}
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
        <div class="alert alert-info mb-6 text-sm" role="status">
          Subscription canceled — you are back on the free plan.
        </div>
      ) : null}
      {props.cancelNotice === "pending" ? (
        <div class="alert alert-info mb-6 text-sm" role="status">
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
        <div class="alert alert-error mb-6 text-sm" role="status">
          Could not cancel subscription. Try again or contact support.
        </div>
      ) : null}
      {props.resumeNotice === "success" ? (
        <div class="alert alert-success mb-6 text-sm" role="status">
          Subscription resumed — your plan will renew as normal.
        </div>
      ) : null}
      {props.resumeNotice === "failed" ? (
        <div class="alert alert-error mb-6 text-sm" role="status">
          Could not resume subscription. Try again or contact support.
        </div>
      ) : null}

      <div id="subscription-card">
        <SubscriptionCard {...props} />
      </div>
      {/* Gate on the worker axis, not tier/promotional — during the beta every
          account is promotional, and the card must show there too. */}
      {props.activeWorkers === 0 ? <DownloadCard /> : null}
      <ActiveSessionsCard sessions={props.sessions} now={props.now} />

      <script
        type="application/json"
        id="dashboard-data"
        dangerouslySetInnerHTML={{ __html: pageData }}
      />
      <script src={asset("dashboard")} defer />
    </Layout>
  );
}

/**
 * `Machines` is the paid axis (machines running an agent, `kind:"agent"` device
 * rows), counted per person rather than pooled across the account; `App devices`
 * is the flat fair-use registration ceiling across every device kind. They are
 * counted separately and only the first can be raised.
 */
function CapacityRow({
  activeWorkers,
  workerLimit,
  activeAppDevices,
  appDeviceLimit,
  children,
}: {
  activeWorkers: number;
  workerLimit: number;
  activeAppDevices: number;
  appDeviceLimit: number;
  children?: unknown;
}) {
  return (
    <div class="mt-5 grid grid-cols-2 gap-x-8 gap-y-6 rounded-box border border-edge bg-page/40 p-5 sm:grid-cols-4">
      <CellMeter label="Machines" used={activeWorkers} limit={workerLimit} unit="machines" />
      <CellMeter
        label="App devices"
        used={activeAppDevices}
        limit={appDeviceLimit}
        unit="app devices"
      />
      {children}
    </div>
  );
}

/** A dated fact alongside the meters — same label register, no meter. */
function Fact({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div class="text-[0.6875rem] font-medium uppercase tracking-[0.12em] text-muted2">
        {label}
      </div>
      <div class="mt-1 font-mono text-base leading-none text-ink2">{value}</div>
    </div>
  );
}

function SubscriptionCard({
  subscription,
  plan,
  tier,
  appDeviceLimit,
  activeAppDevices,
  workerLimit,
  activeWorkers,
}: DashboardPageProps) {
  const pendingCancel = isPendingCancellation(subscription);
  const canCancel =
    plan.recurring &&
    subscription.status === "active" &&
    !pendingCancel &&
    (subscription.providerSubscriptionId !== null || subscription.provider === "dev");
  const canResume =
    pendingCancel &&
    plan.recurring &&
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
      <div class="card bg-panel border border-edge">
        <div class="card-body">
          <div class="flex items-center gap-2">
            <span class="badge badge-ghost text-xs capitalize">{FREE_TIER}</span>
          </div>
          <CapacityRow
            activeWorkers={activeWorkers}
            workerLimit={workerLimit}
            activeAppDevices={activeAppDevices}
            appDeviceLimit={appDeviceLimit}
          />
        </div>
      </div>
    );
  }

  if (tier === FREE_TIER) {
    return (
      <div class="card bg-panel border border-edge">
        <div class="card-body">
          <div class="flex items-start justify-between gap-6 flex-wrap">
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 mb-1">
                <span class="badge badge-ghost text-xs capitalize">{FREE_TIER}</span>
              </div>
              <p class="text-sm text-muted mt-1 max-w-md">
                Remote control is included, capped at {workerLimit} worker
                {workerLimit === 1 ? " machine" : " machines"}. Pro raises the
                cap and is billed per seat, so you can bring your team along.
              </p>
            </div>
            <a class="btn btn-primary" href="/pricing">
              View pricing
            </a>
          </div>
          <CapacityRow
            activeWorkers={activeWorkers}
            workerLimit={workerLimit}
            activeAppDevices={activeAppDevices}
            appDeviceLimit={appDeviceLimit}
          />
        </div>
      </div>
    );
  }
  return (
    <div class="card bg-panel border border-edge">
      <div class="card-body">
        <div class="flex items-center gap-2">
          <h2 class="card-title font-display text-xl tracking-[-0.02em]">{plan.label}</h2>
          {pendingCancel ? (
            <span class="badge badge-warning text-xs">ending</span>
          ) : (
            <span class={`badge ${STATUS_BADGE[subscription.status]}`}>
              {subscription.status}
            </span>
          )}
        </div>
        <CapacityRow
          activeWorkers={activeWorkers}
          workerLimit={workerLimit}
          activeAppDevices={activeAppDevices}
          appDeviceLimit={appDeviceLimit}
        >
          <Fact
            label="Started"
            value={formatDate(
              new Date(subscription.trialStartedAt ?? subscription.createdAt)
            )}
          />
          {plan.trial && subscription.trialEndsAt ? (
            <Fact label="First charge" value={formatDate(new Date(subscription.trialEndsAt))} />
          ) : plan.recurring && periodEndDate ? (
            <Fact
              label={pendingCancel ? "Ends" : "Renews"}
              value={formatDate(new Date(periodEndDate))}
            />
          ) : null}
        </CapacityRow>
        {canResume ? (
          <>
            <div class="mt-4 pt-4 border-t border-edge flex flex-wrap items-center justify-between gap-3">
              <p class="text-xs text-muted max-w-lg">
                Your subscription ends on{" "}
                {formatDate(new Date(subscription.cancelledAt ?? Date.now()))}. Resume to keep Pro
                and renew at period end.
              </p>
              <button
                type="button"
                id="resume-subscription-btn"
                class="btn btn-outline btn-primary btn-sm"
              >
                Resume subscription
              </button>
            </div>
            <div id="resume-subscription-modal" class="modal">
              <div class="modal-box max-w-md">
                <h3 class="text-lg font-semibold">Resume subscription?</h3>
                <p class="text-sm text-muted mt-2">
                  Your plan will continue and renew on{" "}
                  {formatDate(new Date(subscription.currentPeriodEnd ?? Date.now()))}.
                </p>
                <div class="modal-action mt-4">
                  <button type="button" class="btn btn-ghost" data-resume-dismiss>
                    Keep cancellation
                  </button>
                  <form method="post" action="/ui/subscription/resume">
                    <button type="submit" class="btn btn-primary">
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
            <div class="mt-4 pt-4 border-t border-edge flex flex-wrap items-center justify-between gap-3">
              <p class="text-xs text-muted max-w-lg">
                {plan.trial
                  ? "Cancel before your first charge to avoid billing. Access ends immediately."
                  : "Cancel at period end — you keep Pro until your renewal date, then revert to free."}
              </p>
              <button
                type="button"
                id="cancel-subscription-btn"
                class="btn btn-outline btn-error btn-sm"
              >
                Cancel subscription
              </button>
            </div>
            <div id="cancel-subscription-modal" class="modal">
              <div class="modal-box max-w-md">
                <h3 class="text-lg font-semibold">Cancel subscription?</h3>
                <p class="text-sm text-muted mt-2">
                  {plan.trial
                    ? "You will lose Pro access immediately and your card will not be charged."
                    : "You keep Pro access until the end of your billing period, then revert to free."}
                </p>
                <div class="modal-action mt-4">
                  <button type="button" class="btn btn-ghost" data-cancel-dismiss>
                    Keep subscription
                  </button>
                  <form method="post" action="/ui/subscription/cancel">
                    <button type="submit" class="btn btn-error">
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

