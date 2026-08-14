import { Layout } from "./layout.js";
import { asset } from "./asset.js";
import { formatUsd, TRIAL_DAYS } from "../billing/plans.js";
import {
  MAX_CHECKOUT_SEATS,
  type CheckoutReadiness,
  type CheckoutSession,
  type CheckoutTotal,
} from "../billing/checkout.js";

export type CheckoutPlan = {
  id: string;
  label: string;
  recurring: boolean;
  trial: boolean;
  workerLimit: number;
  displayPrice: number;
  chargePrice: number;
  discountLabel?: string;
};

/**
 * The transaction the buyer is looking at, exactly as the gateway call that
 * created it reported back.
 *
 * This is the only source of a total on this page. Multiplying `chargePrice` by
 * a seat count would put a number in front of the buyer that no gateway ever
 * agreed to — discounts, tax and the gateway's own rounding all live on the far
 * side of that arithmetic — and the two would then be settled against one
 * invoice. No order, no total.
 */
export type CheckoutOrder = {
  /** Seats this session was created for. Kept beside the total so a stepper
   *  moved afterwards can be recognized as having invalidated it. */
  seats: number;
  total: CheckoutTotal | null;
  session: CheckoutSession;
};

export type CheckoutPageProps = {
  user: { email?: string | null };
  plan: CheckoutPlan;
  detectedCountry: string | null;
  gateway: "paddle" | "razorpay";
  readiness: CheckoutReadiness;
  checkoutAvailable: boolean;
  isDev: boolean;
  /** Seats in the stepper — echoed back on a refusal so a buyer does not have
   *  to retype the count that was just rejected. */
  seats: number;
  /** `plans.max_seats`. NULL is unlimited, leaving only the request bound. */
  maxSeats: number | null;
  order: CheckoutOrder | null;
  /** Why the last submission produced no order. */
  notice: string | null;
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

/** Stands in for a total nobody has quoted yet. Deliberately not a currency
 *  amount: a placeholder that reads as money is a number the buyer will believe. */
const NO_TOTAL = "—";

function formatDate(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function trialFirstChargeDate(): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + TRIAL_DAYS);
  return formatDate(d);
}

/** The catalog price of ONE seat. Safe to render from our own constants because
 *  it is not a charge — it is the sticker the gateway prices against. */
function unitPriceLabel(plan: CheckoutPlan): string {
  return `${formatUsd(plan.chargePrice)}/seat/year`;
}

function totalLabel(order: CheckoutOrder | null): string {
  return order?.total?.display ?? NO_TOTAL;
}

function gatewayLabel(provider: "paddle" | "razorpay"): string {
  return provider === "razorpay" ? "Razorpay" : "Paddle";
}

/** The highest count the stepper will offer: the plan's cap, or the request
 *  sanity bound when the plan is unlimited. */
export function seatCeiling(maxSeats: number | null): number {
  return maxSeats === null ? MAX_CHECKOUT_SEATS : Math.min(maxSeats, MAX_CHECKOUT_SEATS);
}

function billingCadence(plan: CheckoutPlan): string {
  if (plan.trial) {
    return `${TRIAL_DAYS}-day free trial, then ${unitPriceLabel(plan)}`;
  }
  return `Billed yearly · ${unitPriceLabel(plan)}`;
}

function billingDisclosure(plan: CheckoutPlan): string {
  if (plan.trial) {
    return `Your card won't be charged until ${trialFirstChargeDate()}. Cancel anytime before then to avoid the ${unitPriceLabel(plan)} charge. Subscription renews automatically unless canceled.`;
  }
  return `Renews automatically at ${unitPriceLabel(plan)}. Cancel anytime before your renewal date.`;
}

function checkoutCtaLabel(plan: CheckoutPlan): string {
  if (plan.trial) return `Start ${TRIAL_DAYS}-day free trial`;
  return "Confirm & checkout";
}

function totalNote(props: CheckoutPageProps): string {
  if (!props.order) return "Your total is quoted when you review the order.";
  const seats = props.order.seats;
  return `Quoted by ${gatewayLabel(props.order.session.provider)} for ${seats} seat${seats === 1 ? "" : "s"}.`;
}

/** Inline JSON for a `<script type="application/json">` block. `<` is escaped
 *  because the HTML parser ends that block at the first `</script`, wherever it
 *  appears — including inside a string the gateway chose. */
function jsonScript(value: unknown): string {
  return JSON.stringify(value).replace(/</g, "\\u003c");
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
          Upgrade to {plan.label} to give everyone on your team full remote access and up to{" "}
          {plan.workerLimit} machines of their own.
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
                <div class="stat-title font-mono text-xs">Machines per seat</div>
                <div class="stat-value text-xl font-mono">up to {plan.workerLimit}</div>
              </div>
              <div class="stat py-3">
                <div class="stat-title font-mono text-xs">Per seat</div>
                <div class="stat-value text-xl font-mono">{formatUsd(plan.chargePrice)}</div>
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
  const due = totalLabel(props.order);
  const ceiling = seatCeiling(props.maxSeats);
  const wizardData = jsonScript({
    email: props.user.email ?? "",
    plan,
    detectedCountry: props.detectedCountry,
    gateway: props.gateway,
    readiness: props.readiness,
    seats: props.seats,
    maxSeats: ceiling,
    /** Null until an order exists; a stepper away from it means the total on
     *  screen belongs to a transaction the buyer no longer wants. */
    orderSeats: props.order?.seats ?? null,
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
                  {gatewayLabel(props.order?.session.provider ?? props.gateway)}
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

                {/* Submitting this form is what creates the transaction, and the
                    total below is read off that same response. The +/- buttons
                    are deliberately not submits: one gateway object per click
                    would litter the merchant account with abandoned orders. The
                    plan rides in the query string rather than a hidden field
                    because the handler must know which page to re-render before
                    it may read the body, and a throttled request never does. */}
                <form
                  method="post"
                  action={`/ui/checkout/seats?planId=${encodeURIComponent(plan.id)}`}
                  id="seat-form"
                  class="space-y-3 border-t border-base-300 pt-3"
                >
                  {/* The country control lives in the panel beside this one, so
                      it is mirrored here — the form must still carry a country
                      with scripting off. */}
                  <input
                    type="hidden"
                    name="country"
                    id="seat-country"
                    value={props.detectedCountry ?? ""}
                  />
                  <div class="flex items-center justify-between gap-3">
                    <label class="text-sm font-mono text-base-content/60" for="seats-input">
                      Seats
                    </label>
                    <div class="join">
                      <button
                        type="button"
                        id="seats-dec"
                        class="btn btn-sm join-item font-mono"
                        aria-label="One fewer seat"
                      >
                        −
                      </button>
                      <input
                        id="seats-input"
                        name="seats"
                        type="number"
                        inputmode="numeric"
                        min="1"
                        max={String(ceiling)}
                        step="1"
                        value={String(props.seats)}
                        class="input input-sm input-bordered join-item w-20 text-center font-mono"
                      />
                      <button
                        type="button"
                        id="seats-inc"
                        class="btn btn-sm join-item font-mono"
                        aria-label="One more seat"
                      >
                        +
                      </button>
                    </div>
                  </div>
                  <p id="seat-limit-note" class="text-xs font-mono text-base-content/50">
                    {props.maxSeats === null
                      ? "Add as many seats as you need."
                      : `Up to ${props.maxSeats} seat${props.maxSeats === 1 ? "" : "s"} on this plan.`}
                  </p>
                  <button
                    type="submit"
                    id="btn-review"
                    class="btn btn-sm btn-outline font-mono w-full"
                    disabled={!props.checkoutAvailable}
                  >
                    {props.order ? "Update total" : "Review order"}
                  </button>
                </form>

                <div class="space-y-1.5 text-sm font-mono border-t border-base-300 pt-3">
                  <div class="flex justify-between">
                    <span class="text-base-content/60">Machines per seat</span>
                    <span id="summary-workers">up to {plan.workerLimit}</span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-base-content/60">Due today</span>
                    <span id="summary-due" class="font-semibold">
                      {due}
                    </span>
                  </div>
                </div>
                <p id="summary-total-note" class="text-xs font-mono text-base-content/50">
                  {totalNote(props)}
                </p>
                <p
                  id="summary-disclosure"
                  class="text-xs text-base-content/50 font-mono leading-relaxed"
                >
                  {billingDisclosure(plan)}
                </p>
              </div>
            </div>

            {props.notice && (
              <div id="checkout-notice" class="alert alert-warning mt-4">
                <span class="font-mono text-sm">{props.notice}</span>
              </div>
            )}

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
              Due today{" "}
              <strong id="footer-due" class={plan.trial ? "text-success" : "text-base-content"}>
                {due}
              </strong>
            </span>
            <button
              type="button"
              id="btn-pay"
              class={`btn btn-sm font-mono gap-1 ${plan.trial ? "btn-success" : "btn-primary"}`}
              // No order means no transaction to open and no quoted total. The
              // button that spends money stays shut until both exist.
              disabled={!props.checkoutAvailable || !props.order}
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
      {props.order && (
        <script
          type="application/json"
          id="checkout-session-data"
          dangerouslySetInnerHTML={{ __html: jsonScript(props.order.session) }}
        />
      )}
      <script src={asset("checkout")} defer />
    </Layout>
  );
}
