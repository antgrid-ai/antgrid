import { Layout } from "./layout.js";
import { asset } from "./asset.js";
import { formatUsd, TRIAL_DAYS } from "../billing/plans.js";
import type { CheckoutReadiness } from "../billing/checkout.js";

export type CheckoutPlan = {
  id: string;
  label: string;
  recurring: boolean;
  trial: boolean;
  sessionLimit: number;
  displayPrice: number;
  chargePrice: number;
  discountLabel?: string;
};

export type CheckoutPageProps = {
  user: { email?: string | null };
  plan: CheckoutPlan;
  detectedCountry: string | null;
  gateway: "paddle" | "razorpay";
  readiness: CheckoutReadiness;
  checkoutAvailable: boolean;
  isDev: boolean;
};

const BILLING_COUNTRIES: { code: string; name: string }[] = [
  { code: "US", name: "United States" },
  { code: "IN", name: "India" },
  { code: "GB", name: "United Kingdom" },
  { code: "CA", name: "Canada" },
  { code: "AU", name: "Australia" },
  { code: "DE", name: "Germany" },
  { code: "FR", name: "France" },
  { code: "NL", name: "Netherlands" },
  { code: "SG", name: "Singapore" },
  { code: "JP", name: "Japan" },
  { code: "BR", name: "Brazil" },
  { code: "MX", name: "Mexico" },
  { code: "AE", name: "United Arab Emirates" },
  { code: "NZ", name: "New Zealand" },
  { code: "SE", name: "Sweden" },
  { code: "CH", name: "Switzerland" },
  { code: "IE", name: "Ireland" },
  { code: "PL", name: "Poland" },
  { code: "IT", name: "Italy" },
  { code: "ES", name: "Spain" },
];

const SETTINGS_NAV = [
  { label: "Dashboard", href: "/dashboard" },
  { label: "Subscription", href: null, active: true },
  { label: "Pricing", href: "/pricing" },
] as const;

function formatDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function trialFirstChargeDate(): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + TRIAL_DAYS);
  return formatDate(d);
}

function dueTodayLabel(plan: CheckoutPlan): string {
  if (plan.trial && plan.recurring) return "$0";
  return formatUsd(plan.chargePrice);
}

function billingCadence(plan: CheckoutPlan): string {
  if (plan.trial && plan.recurring) {
    return `${TRIAL_DAYS}-day free trial, then ${formatUsd(plan.chargePrice)}/year`;
  }
  if (plan.recurring) return `Billed yearly · ${formatUsd(plan.chargePrice)}/year`;
  return "One-time payment · no subscription";
}

function billingDisclosure(plan: CheckoutPlan): string {
  if (plan.trial && plan.recurring) {
    return `Your card won't be charged until ${trialFirstChargeDate()}. Cancel anytime before then to avoid the ${formatUsd(plan.chargePrice)}/year charge. Subscription renews automatically unless canceled.`;
  }
  if (plan.recurring) {
    return `Renews automatically at ${formatUsd(plan.chargePrice)}/year. Cancel anytime before your renewal date.`;
  }
  return "One-time payment. No renewals or recurring charges.";
}

function checkoutCtaLabel(plan: CheckoutPlan): string {
  if (plan.trial && plan.recurring) return `Start ${TRIAL_DAYS}-day free trial`;
  if (plan.recurring) return "Confirm & checkout";
  return "Complete purchase";
}

function SubscriptionShell(props: CheckoutPageProps) {
  const plan = props.plan;
  return (
    <div class="flex flex-col lg:flex-row gap-8 min-h-[60vh]">
      <aside class="lg:w-52 shrink-0">
        <h1 class="font-mono text-2xl font-semibold mb-4">Account</h1>
        <ul class="menu menu-sm bg-base-100 border border-base-300 rounded-lg p-1 w-full font-mono">
          {SETTINGS_NAV.map((item) => (
            <li>
              {item.href ? (
                <a href={item.href}>{item.label}</a>
              ) : (
                <span class="active font-semibold">{item.label}</span>
              )}
            </li>
          ))}
        </ul>
      </aside>

      <section class="flex-1 min-w-0">
        <h2 class="font-mono text-xl font-semibold">Subscription</h2>
        <p class="text-sm text-base-content/60 mt-1 max-w-xl">
          Upgrade to {plan.label} for up to {plan.sessionLimit} paired devices and full remote
          agent access.
        </p>
        <div class="card bg-base-100 border border-base-300 mt-6">
          <div class="card-body">
            <p class="text-xs font-mono text-base-content/50 uppercase tracking-wider">
              Selected plan
            </p>
            <h3 class="font-mono text-lg font-semibold mt-1">{plan.label}</h3>
            <p class="text-sm text-base-content/60 mt-1">{billingCadence(plan)}</p>
            <div class="stats stats-horizontal mt-4 border border-base-300">
              <div class="stat py-3">
                <div class="stat-title font-mono text-xs">Devices</div>
                <div class="stat-value text-xl font-mono">up to {plan.sessionLimit}</div>
              </div>
              <div class="stat py-3">
                <div class="stat-title font-mono text-xs">Due today</div>
                <div class="stat-value text-xl font-mono">{dueTodayLabel(plan)}</div>
              </div>
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}

export function CheckoutPage(props: CheckoutPageProps) {
  const plan = props.plan;
  const due = dueTodayLabel(plan);
  const wizardData = JSON.stringify({
    email: props.user.email ?? "",
    plan,
    detectedCountry: props.detectedCountry,
    gateway: props.gateway,
    readiness: props.readiness,
  });

  return (
    <Layout title="Subscription" user={props.user}>
      <div id="checkout-settings-shell">
        <SubscriptionShell {...props} />
      </div>

      <div id="checkout-modal" class="modal modal-open">
        <div class="modal-box w-full max-w-none sm:max-w-4xl p-0 overflow-hidden flex flex-col rounded-none sm:rounded-2xl h-auto max-h-[92dvh]">
          <div class="flex items-stretch border-b border-base-300 shrink-0">
            <div class="flex-1 py-4 text-sm font-mono font-medium text-primary flex items-center justify-center">
              Billing
            </div>
            <a
              href="/pricing"
              class="px-5 text-base-content/40 hover:text-base-content transition-colors text-lg flex items-center"
              aria-label="Close"
            >
              ✕
            </a>
          </div>

          <div class="overflow-y-auto p-4 sm:p-6">
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-6">
              <div class="border border-base-300 rounded-xl p-5 h-fit">
                <h3 class="font-mono font-semibold">Billing address</h3>
                <p class="text-sm text-base-content/60 mt-0.5">
                  Used for tax calculation and invoicing
                </p>
                <div class="form-control mt-4">
                  <label class="label py-1" for="billing-country">
                    <span class="label-text font-mono text-sm">Country</span>
                  </label>
                  <select
                    id="billing-country"
                    class="select select-bordered w-full font-mono text-sm"
                  >
                    <option value="">Select your country…</option>
                    {BILLING_COUNTRIES.map((c) => (
                      <option
                        value={c.code}
                        selected={c.code === (props.detectedCountry ?? "")}
                      >
                        {c.name}
                      </option>
                    ))}
                  </select>
                </div>
                <span id="gateway-label" class="hidden">
                  {props.gateway === "razorpay" ? "Razorpay" : "Paddle"}
                </span>
              </div>

              <div class="border border-base-300 rounded-xl p-5 space-y-3 h-fit">
                <p class="text-xs font-mono font-semibold text-base-content/50 uppercase tracking-wider">
                  Your order
                </p>
                <div>
                  <h1 class="font-mono text-lg font-semibold">{plan.label}</h1>
                  <p class="text-sm text-base-content/60 mt-1">{billingCadence(plan)}</p>
                  {plan.discountLabel && (
                    <p class="text-xs text-success font-mono mt-2">{plan.discountLabel}</p>
                  )}
                </div>
                <div class="space-y-1.5 text-sm font-mono border-t border-base-300 pt-3">
                  <div class="flex justify-between">
                    <span class="text-base-content/60">Devices</span>
                    <span id="summary-devices">up to {plan.sessionLimit}</span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-base-content/60">Due today</span>
                    <span id="summary-due" class="font-semibold">
                      {due}
                    </span>
                  </div>
                </div>
                <p
                  id="summary-disclosure"
                  class="text-xs text-base-content/50 font-mono leading-relaxed"
                >
                  {billingDisclosure(plan)}
                </p>
              </div>
            </div>

            {!props.checkoutAvailable && (
              <div class="alert alert-warning mt-4">
                <span class="font-mono text-sm">
                  {props.isDev ? (
                    <>
                      Payment providers are not configured. Set billing secrets in{" "}
                      <code class="text-xs">web/.env</code> and plan/price IDs in{" "}
                      <code class="text-xs">web/src/config/billing.ts</code>.
                    </>
                  ) : (
                    <>
                      Checkout is temporarily unavailable. Contact{" "}
                      <a href="mailto:support@antgrid.dev" class="underline">
                        support@antgrid.dev
                      </a>
                      .
                    </>
                  )}
                </span>
              </div>
            )}

            <div id="checkout-status" class="mt-4 min-h-[2.5rem]">
              <div id="checkout-status-content" class="hidden">
                <div class="flex items-center gap-3">
                  <span
                    id="checkout-spinner"
                    class="loading loading-spinner loading-sm text-primary shrink-0"
                  />
                  <p id="checkout-status-text" class="font-mono text-sm text-base-content/70" />
                </div>
                <button
                  type="button"
                  id="checkout-retry"
                  class="btn btn-primary btn-sm font-mono mt-3 hidden"
                >
                  Retry payment
                </button>
              </div>
            </div>
          </div>

          <div class="shrink-0 border-t border-base-300 px-4 sm:px-6 py-3 sm:py-4 flex flex-wrap items-center justify-between gap-y-2 bg-base-100">
            <span class="text-sm font-mono text-base-content/60">
              {plan.trial && plan.recurring ? (
                <>
                  Due today <strong class="text-success">$0</strong>
                </>
              ) : (
                <>
                  Due today <strong class="text-base-content">{due}</strong>
                </>
              )}
            </span>
            <button
              type="button"
              id="btn-pay"
              class={`btn btn-sm font-mono gap-1 ${plan.trial && plan.recurring ? "btn-success" : "btn-primary"}`}
              disabled={!props.checkoutAvailable}
            >
              {checkoutCtaLabel(plan)}
              <span aria-hidden="true">→</span>
            </button>
          </div>
        </div>
        <a href="/pricing" class="modal-backdrop checkout-backdrop" aria-label="Close">
          close
        </a>
      </div>

      <script
        type="application/json"
        id="checkout-wizard-data"
        dangerouslySetInnerHTML={{ __html: wizardData }}
      />
      <script src={asset("checkout")} defer />
    </Layout>
  );
}
