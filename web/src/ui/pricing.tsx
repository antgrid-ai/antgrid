import { Layout } from "./layout.js";
import {
  displayPriceCents,
  formatUsd,
  FREE_WORKER_LIMIT,
  TRIAL_DAYS,
  type BillingEnv,
} from "../billing/plans.js";
import type { PlanRow } from "../models/plan.js";

export type PricingPageProps = {
  user: { email?: string | null };
  plans: PlanRow[];
  env: BillingEnv;
};

const COMING_SOON_LABEL = "Coming soon";

const FREE_FEATURES = [
  "Run agents on up to {workers} machines",
  "Remote control from your phone",
  "Unlimited terminal sessions",
  "File explorer & git viewer",
  "E2E encrypted — zero-knowledge relay",
] as const;

const PRO_YEARLY_FEATURES = [
  "Run agents on up to {workers} machines",
  "Unlimited terminal sessions",
  "File explorer & git viewer",
  "Browser preview tunneling",
  "E2E encrypted — zero-knowledge relay",
  "Priority support",
] as const;

function CheckIcon() {
  return (
    <svg
      class="w-4 h-4 shrink-0 text-primary mt-0.5"
      viewBox="0 0 16 16"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path
        d="M3 8.5l3 3 7-7"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
  );
}

function FeatureList({ items, workers }: { items: readonly string[]; workers: number }) {
  return (
    <ul class="mt-5 space-y-2.5">
      {items.map((item) => (
        <li class="flex items-start gap-2.5 text-sm text-base-content/70">
          <CheckIcon />
          <span>{item.replace("{workers}", String(workers))}</span>
        </li>
      ))}
    </ul>
  );
}

function ComingSoonCta({ footer }: { footer: string }) {
  return (
    <div class="mt-auto pt-6">
      <button type="button" class="btn btn-disabled font-mono w-full" disabled>
        {COMING_SOON_LABEL}
      </button>
      <p class="text-xs text-base-content/40 font-mono text-center mt-3 min-h-[2.5rem]">
        {footer}
      </p>
    </div>
  );
}

export function PricingPage(props: PricingPageProps) {
  const yearlyPrice = displayPriceCents("pro_yearly", props.env);
  const trialPlan = props.plans.find((p) => p.slug === "trial");
  const yearlyPlan = props.plans.find((p) => p.slug === "pro_yearly");

  return (
    <Layout title="Pricing" user={props.user}>
      <div class="text-center mb-10">
        <h1 class="font-mono text-3xl font-bold tracking-tight">Simple, honest pricing</h1>
        <p class="text-sm text-base-content/60 mt-3 max-w-lg mx-auto">
          Monitor and control your AI coding agents from anywhere. E2E encrypted,
          zero-knowledge relay.
        </p>
      </div>

      {trialPlan && (
        <FreeTrialBanner yearlyPrice={yearlyPrice} trialWorkers={trialPlan.workerLimit} />
      )}

      <div class="grid gap-6 md:grid-cols-2 mt-6">
        {/* The free plan row is excluded from listActivePlans, so its worker
            count comes from the same constant that seeds it. */}
        <FreeCard workers={FREE_WORKER_LIMIT} />
        {yearlyPlan && <ProYearlyCard plan={yearlyPlan} price={yearlyPrice} />}
      </div>
    </Layout>
  );
}

function trialFirstChargeDate(): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + TRIAL_DAYS);
  return d.toISOString().slice(0, 10);
}

function FreeTrialBanner({
  yearlyPrice,
  trialWorkers,
}: {
  yearlyPrice: number;
  trialWorkers: number;
}) {
  const firstCharge = trialFirstChargeDate();
  return (
    <div class="rounded-lg border border-base-300 opacity-60 bg-base-100 p-5 md:p-6 flex flex-col md:flex-row md:items-center gap-5">
      <div class="flex-1 min-w-0">
        <div class="flex flex-wrap items-center gap-2 mb-2">
          <span class="badge badge-success font-mono text-xs font-bold px-2">FREE TRIAL</span>
          <span class="text-xs text-base-content/50 font-mono">{TRIAL_DAYS}-day trial</span>
        </div>
        <h2 class="font-mono text-lg font-semibold">
          {TRIAL_DAYS}-day free trial, then {formatUsd(yearlyPrice)}/year
        </h2>
        <p class="text-sm text-base-content/60 mt-1.5 max-w-2xl">
          Add your card to start. Run agents on up to{" "}
          <strong class="text-base-content/80">{trialWorkers} machines</strong> during the
          trial. Your card won't be charged until{" "}
          <strong class="text-base-content/80">{firstCharge}</strong> — cancel anytime before then
          to avoid the {formatUsd(yearlyPrice)}/year charge. Subscription renews automatically
          unless canceled.
        </p>
      </div>
      <button type="button" class="btn btn-disabled font-mono shrink-0" disabled>
        {COMING_SOON_LABEL}
      </button>
    </div>
  );
}

function FreeCard({ workers }: { workers: number }) {
  return (
    <div class="card bg-base-100 h-full border border-base-300">
      <div class="card-body flex flex-col h-full">
        <h2 class="font-mono text-xl font-bold">Free</h2>

        <div class="mt-3 font-mono min-h-[4.75rem]">
          <span class="text-4xl font-bold">$0</span>
          <p class="text-xs text-base-content/50 font-mono mt-1.5">No card required.</p>
        </div>

        <FeatureList items={FREE_FEATURES} workers={workers} />

        <div class="mt-auto pt-6">
          <button type="button" class="btn btn-disabled font-mono w-full" disabled>
            Your plan
          </button>
          <p class="text-xs text-base-content/40 font-mono text-center mt-3 min-h-[2.5rem]">
            Included with every account.
          </p>
        </div>
      </div>
    </div>
  );
}

function ProYearlyCard({ plan, price }: { plan: PlanRow; price: number }) {
  return (
    <div class="card bg-base-100 h-full border border-base-300 opacity-60">
      <div class="card-body flex flex-col h-full">
        <h2 class="font-mono text-xl font-bold">{plan.label}</h2>

        <div class="mt-3 font-mono min-h-[4.75rem]">
          <span class="text-4xl font-bold">{formatUsd(price)}</span>
          <span class="text-sm text-base-content/50 ml-1">/ year</span>
          <p class="text-xs text-base-content/50 font-mono mt-1.5">Renews annually.</p>
        </div>

        <FeatureList items={PRO_YEARLY_FEATURES} workers={plan.workerLimit} />

        <ComingSoonCta footer={`${formatUsd(price)}/year · Renews automatically · Cancel anytime`} />
      </div>
    </div>
  );
}

// ============================================================================
// TEMP-PROMO: disabled for the promotional release — grep "TEMP-PROMO" repo-
// wide to find every related spot (backend grant logic + this UI).
//
// Every account currently gets full Pro access for free while in-app
// purchases aren't live (see ensureDefaultSubscription in
// web/src/models/subscription.ts). So the real, working pricing/checkout UI
// below — current-plan detection, the active-plan banner, and the actual
// /checkout links — is kept here as comments instead of deleted, and the
// static always-"Coming soon" cards above are shown instead.
//
// TO RESTORE ONCE PAYMENT INTEGRATION SHIPS:
//   1. Delete the static replacement above this marker: PricingPageProps,
//      COMING_SOON_LABEL, FREE_FEATURES, ComingSoonCta, PricingPage,
//      FreeTrialBanner, FreeCard, ProYearlyCard (everything from `export type
//      PricingPageProps` down to just above this marker). Re-add a Free card.
//   2. Select everything below this marker and strip the leading "// " from
//      each line (most editors: select + "toggle line comment").
//   3. In web/src/routes/ui.tsx's `/pricing` handler, do the matching restore
//      — see the "TEMP-PROMO" comment there for the currentPlanSlug plumbing.
//   4. Delete this marker block itself (down through the end of this file).
//   5. Run `cd web && bun run typecheck && bun run test` to confirm nothing
//      still depends on the promo-only code paths.
// ============================================================================
// import { Layout } from "./layout.js";
// import {
//   displayPriceCents,
//   formatUsd,
//   TRIAL_DAYS,
//   type BillingEnv,
//   type PlanId,
// } from "../billing/plans.js";
// import type { PlanRow } from "../models/plan.js";
// 
// export type PricingPageProps = {
//   user: { email?: string | null };
//   plans: PlanRow[];
//   env: BillingEnv;
//   /** Active paid plan slug, if any (trial | pro_yearly). */
//   currentPlanSlug: PlanId | null;
// };
// 
// const ACTIVE_PLAN_NOTICE =
//   "You already have full access. Plan changes aren't available here.";
// 
// function activePlanLabel(
//   current: PlanId | null,
//   plans: PlanRow[]
// ): string | null {
//   if (!current) return null;
//   const plan = plans.find((p) => p.slug === current);
//   return plan?.label ?? null;
// }
// 
// const PRO_YEARLY_FEATURES = [
//   "Run agents on up to {workers} machines",
//   "Unlimited terminal sessions",
//   "File explorer & git viewer",
//   "Browser preview tunneling",
//   "E2E encrypted — zero-knowledge relay",
//   "Priority support",
// ] as const;
// 
// function CheckIcon() {
//   return (
//     <svg
//       class="w-4 h-4 shrink-0 text-primary mt-0.5"
//       viewBox="0 0 16 16"
//       fill="none"
//       xmlns="http://www.w3.org/2000/svg"
//     >
//       <path
//         d="M3 8.5l3 3 7-7"
//         stroke="currentColor"
//         stroke-width="1.5"
//         stroke-linecap="round"
//         stroke-linejoin="round"
//       />
//     </svg>
//   );
// }
// 
// function FeatureList({ items, workers }: { items: readonly string[]; workers: number }) {
//   return (
//     <ul class="mt-5 space-y-2.5">
//       {items.map((item) => (
//         <li class="flex items-start gap-2.5 text-sm text-base-content/70">
//           <CheckIcon />
//           <span>{item.replace("{workers}", String(workers))}</span>
//         </li>
//       ))}
//     </ul>
//   );
// }
// 
// function PlanCta({
//   planId,
//   label,
//   footer,
//   isCurrent,
//   isDisabled = false,
// }: {
//   planId: PlanId;
//   label: string;
//   footer: string;
//   isCurrent: boolean;
//   isDisabled?: boolean;
// }) {
//   return (
//     <div class="mt-auto pt-6">
//       {isCurrent ? (
//         <button type="button" class="btn btn-disabled font-mono w-full" disabled>
//           Current plan
//         </button>
//       ) : isDisabled ? (
//         <button type="button" class="btn btn-disabled font-mono w-full" disabled>
//           {label}
//         </button>
//       ) : (
//         <a href={`/checkout?planId=${planId}`} class="btn btn-outline font-mono w-full gap-1.5">
//           {label}
//           <span aria-hidden="true">→</span>
//         </a>
//       )}
//       <p class="text-xs text-base-content/40 font-mono text-center mt-3 min-h-[2.5rem]">
//         {isCurrent ? "You're on this plan." : footer}
//       </p>
//     </div>
//   );
// }
// 
// export function PricingPage(props: PricingPageProps) {
//   const yearlyPrice = displayPriceCents("pro_yearly", props.env);
//   const trialPlan = props.plans.find((p) => p.slug === "trial");
//   const yearlyPlan = props.plans.find((p) => p.slug === "pro_yearly");
//   const current = props.currentPlanSlug;
//   const hasActivePlan = current !== null;
//   const showTrialBanner = current !== "pro_yearly";
//   const planLabel = activePlanLabel(current, props.plans);
// 
//   return (
//     <Layout title="Pricing" user={props.user}>
//       <div class="text-center mb-10">
//         <h1 class="font-mono text-3xl font-bold tracking-tight">Simple, honest pricing</h1>
//         <p class="text-sm text-base-content/60 mt-3 max-w-lg mx-auto">
//           Monitor and control your AI coding agents from anywhere. E2E encrypted,
//           zero-knowledge relay.
//         </p>
//       </div>
// 
//       {hasActivePlan ? (
//         <div
//           class="rounded-lg border border-primary/30 bg-base-100 p-4 mb-6"
//           role="status"
//         >
//           <p class="font-mono text-sm font-semibold">
//             {planLabel ? `You're on ${planLabel}` : "Your plan is active"}
//           </p>
//           <p class="text-sm text-base-content/60 mt-1.5">{ACTIVE_PLAN_NOTICE}</p>
//         </div>
//       ) : null}
// 
//       {trialPlan && showTrialBanner && (
//         <FreeTrialBanner
//           yearlyPrice={yearlyPrice}
//           trialWorkers={trialPlan.workerLimit}
//           isCurrent={current === "trial"}
//           isDisabled={hasActivePlan}
//         />
//       )}
// 
//       <div class="grid gap-6 md:grid-cols-2 mt-6">
//         {yearlyPlan && (
//           <ProYearlyCard
//             plan={yearlyPlan}
//             price={yearlyPrice}
//             isCurrent={current === "pro_yearly"}
//             isDisabled={hasActivePlan && current !== "pro_yearly"}
//           />
//         )}
//       </div>
//     </Layout>
//   );
// }
// 
// function trialFirstChargeDate(): string {
//   const d = new Date();
//   d.setUTCDate(d.getUTCDate() + TRIAL_DAYS);
//   return d.toISOString().slice(0, 10);
// }
// 
// function FreeTrialBanner({
//   yearlyPrice,
//   trialWorkers,
//   isCurrent,
//   isDisabled = false,
// }: {
//   yearlyPrice: number;
//   trialWorkers: number;
//   isCurrent: boolean;
//   isDisabled?: boolean;
// }) {
//   const firstCharge = trialFirstChargeDate();
//   return (
//     <div
//       class={`rounded-lg border bg-base-100 p-5 md:p-6 flex flex-col md:flex-row md:items-center gap-5 ${
//         isCurrent ? "border-primary" : isDisabled ? "border-base-300 opacity-60" : "border-base-300"
//       }`}
//     >
//       <div class="flex-1 min-w-0">
//         <div class="flex flex-wrap items-center gap-2 mb-2">
//           {isCurrent ? (
//             <span class="badge badge-primary font-mono text-xs font-bold px-2">CURRENT PLAN</span>
//           ) : (
//             <span class="badge badge-success font-mono text-xs font-bold px-2">FREE TRIAL</span>
//           )}
//           <span class="text-xs text-base-content/50 font-mono">{TRIAL_DAYS}-day trial</span>
//         </div>
//         <h2 class="font-mono text-lg font-semibold">
//           {TRIAL_DAYS}-day free trial, then {formatUsd(yearlyPrice)}/year
//         </h2>
//         <p class="text-sm text-base-content/60 mt-1.5 max-w-2xl">
//           Add your card to start. Up to{" "}
//           <strong class="text-base-content/80">
//             {trialWorkers} worker machines
//           </strong>{" "}
//           during the trial. Your card won't be charged until{" "}
//           <strong class="text-base-content/80">{firstCharge}</strong> — cancel anytime before then
//           to avoid the {formatUsd(yearlyPrice)}/year charge. Subscription renews automatically
//           unless canceled.
//         </p>
//       </div>
//       {isCurrent ? (
//         <button type="button" class="btn btn-disabled font-mono shrink-0" disabled>
//           Current plan
//         </button>
//       ) : isDisabled ? (
//         <button type="button" class="btn btn-disabled font-mono shrink-0" disabled>
//           Start {TRIAL_DAYS}-day trial
//         </button>
//       ) : (
//         <a href="/checkout?planId=trial" class="btn btn-outline font-mono shrink-0 gap-1.5">
//           Start {TRIAL_DAYS}-day trial
//           <span aria-hidden="true">→</span>
//         </a>
//       )}
//     </div>
//   );
// }
// 
// function planCardClass(isCurrent: boolean, isDisabled: boolean): string {
//   const base = "card bg-base-100 h-full border";
//   if (isCurrent) return `${base} border-primary`;
//   if (isDisabled) return `${base} border-base-300 opacity-60`;
//   return `${base} border-base-300`;
// }
// 
// function ProYearlyCard({
//   plan,
//   price,
//   isCurrent,
//   isDisabled = false,
// }: {
//   plan: PlanRow;
//   price: number;
//   isCurrent: boolean;
//   isDisabled?: boolean;
// }) {
//   return (
//     <div class={planCardClass(isCurrent, isDisabled)}>
//       <div class="card-body flex flex-col h-full">
//         <div class="flex items-center gap-2">
//           <h2 class="font-mono text-xl font-bold">{plan.label}</h2>
//           {isCurrent && (
//             <span class="badge badge-primary font-mono text-xs font-bold">CURRENT</span>
//           )}
//         </div>
// 
//         <div class="mt-3 font-mono min-h-[4.75rem]">
//           <span class="text-4xl font-bold">{formatUsd(price)}</span>
//           <span class="text-sm text-base-content/50 ml-1">/ year</span>
//           <p class="text-xs text-base-content/50 font-mono mt-1.5">Renews annually.</p>
//         </div>
// 
//         <FeatureList items={PRO_YEARLY_FEATURES} workers={plan.workerLimit} />
// 
//         <PlanCta
//           planId="pro_yearly"
//           label="Get Pro Yearly"
//           footer={`${formatUsd(price)}/year · Renews automatically · Cancel anytime`}
//           isCurrent={isCurrent}
//           isDisabled={isDisabled}
//         />
//       </div>
//     </div>
//   );
// }
