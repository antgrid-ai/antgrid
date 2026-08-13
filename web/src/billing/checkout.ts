import type {
  IMoney,
  ITimePeriod,
  ITransactionItemWithNonCatalogPrice,
} from "@paddle/paddle-node-sdk";
import {
  resolveCheckoutSku,
  resolvePaddleDiscountId,
  TRIAL_DAYS,
  type BillingEnv,
  type PlanId,
  type ProviderId,
} from "./plans.js";
import { getRazorpayClient } from "./razorpay.js";
import { getPaddleClient, paddleCustomerCheckoutAuth } from "./paddle.js";

/**
 * What the buyer is about to be charged, as reported by the gateway call that
 * created the transaction.
 *
 * `display` is formatted here rather than by whoever renders it, so a page and
 * an API client cannot print two different strings for one charge. `null` in
 * place of a total means the gateway told us nothing usable — render the
 * absence, never a number of our own, since a total we computed is a total that
 * can disagree with the invoice.
 */
export type CheckoutTotal = {
  /** Minor units (cents/paise), matching `currency`. */
  amount: number;
  currency: string;
  display: string;
};

export type PaddleCheckoutSession = {
  provider: "paddle";
  planId: PlanId;
  transactionId: string;
  clientToken: string;
  environment: "sandbox" | "production";
  /** Seats this transaction was created for — echoed so a caller can label the
   *  total below without keeping its own tally of what it asked for. */
  seats: number;
  /** Paddle's own grand total for the transaction just created, tax included. */
  total: CheckoutTotal | null;
  /** Present saved payment methods when a returning Paddle customer checks out again. */
  customerAuthToken?: string;
};

export type RazorpayCheckoutSession = {
  provider: "razorpay";
  planId: PlanId;
  keyId: string;
  customerId: string;
  subscriptionId: string;
  seats: number;
  /** Razorpay's plan amount for the quantity this subscription was created
   *  with. Unlike Paddle's it excludes tax — Razorpay computes no total at
   *  subscription-create time and returns none. */
  total: CheckoutTotal | null;
  /** Razorpay-hosted subscription page (full-page, not checkout.js modal). */
  shortUrl?: string;
  /** POST target for redirect-mode Standard Checkout (subscription fallback). */
  callbackUrl: string;
};

export type CheckoutSession = PaddleCheckoutSession | RazorpayCheckoutSession;

export type CheckoutEnv = BillingEnv & {
  PADDLE_API_KEY?: string;
  PADDLE_CLIENT_TOKEN?: string;
  PADDLE_ENVIRONMENT?: "sandbox" | "production";
  RAZORPAY_KEY_ID?: string;
  RAZORPAY_KEY_SECRET?: string;
};

export type CheckoutReadiness = Record<ProviderId, Record<PlanId, boolean>>;

/** A gateway this deployment has no credentials or SKU for. Distinct from a
 *  refusal: nothing is wrong with the request, so it answers 503, not 400. */
export type CheckoutConfigError =
  | "PADDLE_NOT_CONFIGURED"
  | "PADDLE_PRICE_NOT_CONFIGURED"
  | "RAZORPAY_NOT_CONFIGURED"
  | "RAZORPAY_PLAN_NOT_CONFIGURED";

const CHECKOUT_CONFIG_ERRORS = new Set<string>([
  "PADDLE_NOT_CONFIGURED",
  "PADDLE_PRICE_NOT_CONFIGURED",
  "RAZORPAY_NOT_CONFIGURED",
  "RAZORPAY_PLAN_NOT_CONFIGURED",
]);

export function isCheckoutConfigError(msg: string): msg is CheckoutConfigError {
  return CHECKOUT_CONFIG_ERRORS.has(msg);
}

/**
 * Sanity bound on the seat count a checkout request may name — not a product
 * cap. The product cap is `plans.max_seats`, which is NULL for unlimited; this
 * only keeps an absurd payload from reaching a gateway, where an out-of-range
 * quantity comes back as an opaque wrapped SDK error and reads to the buyer as
 * "something broke" rather than "too many seats".
 */
export const MAX_CHECKOUT_SEATS = 1000;

/**
 * Format a gateway amount for display. Fixed to `en-US` rather than the
 * request's locale so the string a server renders and the string an API client
 * receives are the same one; the currency is the gateway's, not ours, because
 * Razorpay plans are INR-denominated and Paddle's are not.
 */
export function formatMoneyMinor(amount: number, currency: string): string {
  const major = amount / 100;
  try {
    return new Intl.NumberFormat("en-US", {
      style: "currency",
      currency,
      minimumFractionDigits: amount % 100 === 0 ? 0 : 2,
    }).format(major);
  } catch {
    return `${major.toFixed(2)} ${currency}`;
  }
}

function checkoutTotal(amount: number | null, currency: string | null): CheckoutTotal | null {
  if (amount === null || !Number.isFinite(amount) || !currency) return null;
  return { amount, currency, display: formatMoneyMinor(amount, currency) };
}

/** Paddle reports money as a minor-unit string; a value we cannot parse is no
 *  total at all, never a zero the buyer would read as "free". */
function parseMinorUnits(raw: string | null | undefined): number | null {
  if (typeof raw !== "string" || raw.length === 0) return null;
  const n = Number.parseInt(raw, 10);
  return Number.isNaN(n) ? null : n;
}

/** Pro Yearly bills immediately — same catalog price but without trial_period (ignore_trials on create is preview-only). */
export function paddleSkipTrialForPlan(planId: PlanId): boolean {
  return planId === "pro_yearly";
}

/**
 * Razorpay trial defers the first charge with a future `start_at` on subscription create.
 * Pro Yearly omits `start_at` so the auth transaction bills immediately (Razorpay docs).
 */
export function razorpaySubscriptionStartAt(
  planId: PlanId,
  nowMs: number = Date.now()
): number | undefined {
  if (planId !== "trial") return undefined;
  return Math.floor(nowMs / 1000) + TRIAL_DAYS * 24 * 60 * 60;
}

type PaddleCatalogPriceSnapshot = {
  productId: string;
  description: string;
  unitPrice: IMoney;
  billingCycle: ITimePeriod | null;
  taxMode: string;
};

const paddleCatalogPriceCache = new Map<string, Promise<PaddleCatalogPriceSnapshot>>();

async function fetchPaddleCatalogPrice(
  paddle: ReturnType<typeof getPaddleClient>,
  priceId: string
): Promise<PaddleCatalogPriceSnapshot> {
  let pending = paddleCatalogPriceCache.get(priceId);
  if (!pending) {
    pending = paddle.prices.get(priceId).then((price) => {
      if (!price.productId) throw new Error("PADDLE_PRICE_MISSING_PRODUCT");
      return {
        productId: price.productId,
        description: price.description ?? "Pro Yearly",
        unitPrice: price.unitPrice,
        billingCycle: price.billingCycle ?? null,
        taxMode: price.taxMode,
      };
    });
    paddleCatalogPriceCache.set(priceId, pending);
  }
  return pending;
}

export async function buildPaddleTransactionItems(
  paddle: ReturnType<typeof getPaddleClient>,
  planId: PlanId,
  priceId: string,
  seats: number
): Promise<ITransactionItemWithNonCatalogPrice[]> {
  if (!paddleSkipTrialForPlan(planId)) {
    return [{ priceId, quantity: seats }];
  }

  const catalog = await fetchPaddleCatalogPrice(paddle, priceId);
  return [
    {
      quantity: seats,
      price: {
        productId: catalog.productId,
        description: catalog.description,
        unitPrice: catalog.unitPrice,
        billingCycle: catalog.billingCycle,
        trialPeriod: null,
        taxMode: catalog.taxMode as
          | "account_setting"
          | "external"
          | "internal"
          | "location"
          | undefined,
      },
    },
  ];
}

export function isPaddleCheckoutReady(env: CheckoutEnv, planId: PlanId): boolean {
  if (!env.PADDLE_API_KEY || !env.PADDLE_CLIENT_TOKEN) return false;
  const priceId = resolveCheckoutSku(planId, "paddle", env);
  return typeof priceId === "string" && priceId.length > 0;
}

export function isRazorpayCheckoutReady(env: CheckoutEnv, planId: PlanId): boolean {
  if (!env.RAZORPAY_KEY_ID || !env.RAZORPAY_KEY_SECRET) return false;
  const planSku = resolveCheckoutSku(planId, "razorpay", env);
  return typeof planSku === "string" && planSku.length > 0;
}

function emptyPlanReadiness(): Record<PlanId, boolean> {
  return { trial: false, pro_yearly: false };
}

export function checkoutReadiness(env: CheckoutEnv, planIds: PlanId[]): CheckoutReadiness {
  const paddle = emptyPlanReadiness();
  const razorpay = emptyPlanReadiness();
  for (const planId of planIds) {
    paddle[planId] = isPaddleCheckoutReady(env, planId);
    razorpay[planId] = isRazorpayCheckoutReady(env, planId);
  }
  return { paddle, razorpay };
}

export function anyCheckoutReady(readiness: CheckoutReadiness): boolean {
  for (const provider of Object.values(readiness)) {
    for (const ready of Object.values(provider)) {
      if (ready) return true;
    }
  }
  return false;
}

async function createPaddleCheckout(
  env: CheckoutEnv,
  args: {
    planId: PlanId;
    accountId: string;
    seats: number;
    providerCustomerId?: string | null;
  }
): Promise<{
  transactionId: string;
  planId: PlanId;
  total: CheckoutTotal | null;
  customerAuthToken?: string;
}> {
  if (!env.PADDLE_API_KEY) throw new Error("PADDLE_NOT_CONFIGURED");
  if (!isPaddleCheckoutReady(env, args.planId)) {
    throw new Error("PADDLE_PRICE_NOT_CONFIGURED");
  }

  const priceId = resolveCheckoutSku(args.planId, "paddle", env) as string;
  const discountId = resolvePaddleDiscountId(env);
  const paddle = getPaddleClient(env);
  const items = await buildPaddleTransactionItems(paddle, args.planId, priceId, args.seats);

  try {
    const transaction = await paddle.transactions.create({
      items,
      customData: { accountId: args.accountId, planId: args.planId },
      ...(args.providerCustomerId ? { customerId: args.providerCustomerId } : {}),
      ...(discountId ? { discountId } : {}),
    });
    if (!transaction.id) throw new Error("PADDLE_TRANSACTION_MISSING");

    let customerAuthToken: string | undefined;
    if (args.providerCustomerId) {
      const auth = await paddleCustomerCheckoutAuth(paddle, args.providerCustomerId);
      customerAuthToken = auth?.customerAuthToken;
    }

    return {
      transactionId: transaction.id,
      planId: args.planId,
      // Read off the create response and nowhere else: this is the only number
      // that is by construction the one the gateway was asked for, discount and
      // tax included. Recomputing it from the catalog would reintroduce exactly
      // the drift the seat quantity makes possible.
      total: checkoutTotal(
        parseMinorUnits(transaction.details?.totals?.grandTotal),
        transaction.details?.totals?.currencyCode ?? transaction.currencyCode ?? null
      ),
      ...(customerAuthToken ? { customerAuthToken } : {}),
    };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    throw new Error(`paddle transactions failed: ${msg}`);
  }
}

/** Pull Razorpay's `{ error: { code, description } }` (or flattened) envelope. */
function razorpayErrorParts(e: unknown): { code?: string; description?: string } {
  if (typeof e !== "object" || e === null) return {};
  const err = e as { error?: { description?: string; code?: string }; description?: string };
  return { code: err.error?.code, description: err.error?.description ?? err.description };
}

function formatRazorpayError(e: unknown): string {
  if (e instanceof Error && e.message && e.message !== "[object Object]") return e.message;
  const { code, description } = razorpayErrorParts(e);
  if (description && code) return `${code}: ${description}`;
  if (description) return description;
  return String(e);
}

/**
 * True for Razorpay's duplicate-customer rejection. The code is the generic
 * BAD_REQUEST_ERROR, so the description is the only discriminator — match its
 * stable tokens ("customer" + "already exists") rather than one frozen phrase,
 * so a reworded message ("Customer with this email already exists") still hits.
 */
export function isRazorpayCustomerExistsError(e: unknown): boolean {
  const desc = (razorpayErrorParts(e).description ?? "").toLowerCase();
  return desc.includes("customer") && desc.includes("already exists");
}

// Razorpay's list endpoint only paginates (count/skip) — no email/contact
// filter. Page conservatively: our accounts create one customer per email, so
// an orphan is found in the first page in practice; the cap stops a runaway
// scan on a large merchant rather than guaranteeing a hit.
const RAZORPAY_CUSTOMER_PAGE = 100;
const RAZORPAY_CUSTOMER_MAX_PAGES = 10;

/**
 * Recover an already-created customer by email. Razorpay exposes no
 * fetch-by-email API and the duplicate error omits the id, so we walk the list.
 * Returns null if not found within the page budget.
 */
export async function findRazorpayCustomerIdByEmail(
  razorpay: ReturnType<typeof getRazorpayClient>,
  email: string
): Promise<string | null> {
  const target = email.trim().toLowerCase();
  for (let page = 0; page < RAZORPAY_CUSTOMER_MAX_PAGES; page++) {
    const res = (await razorpay.customers.all({
      count: RAZORPAY_CUSTOMER_PAGE,
      skip: page * RAZORPAY_CUSTOMER_PAGE,
    })) as { items?: Array<{ id?: string; email?: string }> };
    const items = res.items ?? [];
    const match = items.find((c) => (c.email ?? "").trim().toLowerCase() === target);
    if (match?.id) return String(match.id);
    if (items.length < RAZORPAY_CUSTOMER_PAGE) break; // short page → list exhausted
  }
  return null;
}

async function ensureRazorpayCustomerId(
  razorpay: ReturnType<typeof getRazorpayClient>,
  args: { accountId: string; email?: string | null; existingCustomerId?: string | null }
): Promise<string> {
  if (args.existingCustomerId) return args.existingCustomerId;
  if (!args.email) throw new Error("RAZORPAY_CUSTOMER_EMAIL_REQUIRED");

  try {
    // fail_existing 0 should return the existing customer instead of erroring.
    const customer = await razorpay.customers.create({
      email: args.email,
      fail_existing: 0,
      notes: { accountId: args.accountId },
    } as Parameters<typeof razorpay.customers.create>[0]);
    if (!customer.id) throw new Error("RAZORPAY_CUSTOMER_MISSING");
    return String(customer.id);
  } catch (e) {
    // fail_existing dedups on contact; with email alone Razorpay can still 400
    // "already exists" (e.g. a prior checkout created the customer but threw
    // before we persisted its id). Recover the orphan by email.
    if (!isRazorpayCustomerExistsError(e)) throw e;
    const recovered = await findRazorpayCustomerIdByEmail(razorpay, args.email);
    if (!recovered) throw e;
    return recovered;
  }
}

type RazorpayPlanSnapshot = {
  /** Billing cycles for one year of access — monthly plan ×12, yearly plan ×1. */
  totalCount: number;
  /** Per-cycle plan amount in minor units, as the gateway holds it. */
  unitAmount: number | null;
  currency: string | null;
};

/** One read of the plan the subscription is about to be created against, so the
 *  cycle count and the amount the buyer is shown come from the same fetch. */
async function fetchRazorpayPlanSnapshot(
  razorpay: ReturnType<typeof getRazorpayClient>,
  razorpayPlanId: string
): Promise<RazorpayPlanSnapshot> {
  const plan = await razorpay.plans.fetch(razorpayPlanId);
  const rawAmount = plan.item?.amount;
  return {
    totalCount: plan.period === "yearly" ? 1 : 12,
    unitAmount:
      typeof rawAmount === "number"
        ? rawAmount
        : parseMinorUnits(typeof rawAmount === "string" ? rawAmount : null),
    currency: typeof plan.item?.currency === "string" ? plan.item.currency : null,
  };
}

/**
 * Razorpay's subscription-create body, spelled out because the call site casts:
 * the SDK types omit `customer_id`/`fail_existing` even though the API accepts
 * them, and a bare cast over an object literal also disables excess-property
 * checking — so a misspelled `quantity` would compile and silently bill one
 * seat. Naming the fields here puts them back under the compiler.
 */
export type RazorpaySubscriptionRequest = {
  plan_id: string;
  total_count: number;
  quantity: number;
  customer_notify: 0 | 1;
  customer_id: string;
  notes: Record<string, string>;
  start_at?: number;
};

export function buildRazorpaySubscriptionRequest(args: {
  planId: PlanId;
  razorpayPlanId: string;
  totalCount: number;
  seats: number;
  customerId: string;
  notes: Record<string, string>;
  nowMs?: number;
}): RazorpaySubscriptionRequest {
  const startAt = razorpaySubscriptionStartAt(args.planId, args.nowMs);
  return {
    plan_id: args.razorpayPlanId,
    total_count: args.totalCount,
    // Razorpay defines quantity as the number of times the plan amount is
    // charged per invoice, so seats scale the charge with no per-seat price of
    // our own — and `total_count` stays billing cycles, not seats.
    quantity: args.seats,
    customer_notify: 1,
    customer_id: args.customerId,
    notes: args.notes,
    ...(startAt ? { start_at: startAt } : {}),
  };
}

async function createRazorpayCheckout(
  env: CheckoutEnv,
  args: {
    planId: PlanId;
    accountId: string;
    seats: number;
    country?: string | null;
    email?: string | null;
    providerCustomerId?: string | null;
    onCustomerCreated?: (customerId: string) => Promise<void>;
  }
): Promise<{
  subscriptionId: string;
  shortUrl?: string;
  keyId: string;
  planId: PlanId;
  customerId: string;
  total: CheckoutTotal | null;
}> {
  const keyId = env.RAZORPAY_KEY_ID;
  const keySecret = env.RAZORPAY_KEY_SECRET;
  if (!keyId || !keySecret) throw new Error("RAZORPAY_NOT_CONFIGURED");

  const razorpay = getRazorpayClient(keyId, keySecret);
  const notes = { accountId: args.accountId, planId: args.planId };

  // Validate plan config before creating a customer, so a misconfigured plan
  // doesn't orphan a freshly created Razorpay customer. Bare throw (not wrapped)
  // so the route's isCheckoutConfigError match still yields a 503.
  if (!isRazorpayCheckoutReady(env, args.planId)) {
    throw new Error("RAZORPAY_PLAN_NOT_CONFIGURED");
  }

  // Wrap only the Razorpay SDK calls as "razorpay checkout failed" — the persist
  // between the two blocks stays unwrapped so a DB fault surfaces as itself.
  let customerId: string;
  try {
    customerId = await ensureRazorpayCustomerId(razorpay, {
      accountId: args.accountId,
      email: args.email,
      existingCustomerId: args.providerCustomerId,
    });
  } catch (e) {
    throw new Error(`razorpay checkout failed: ${formatRazorpayError(e)}`);
  }

  // Persist before the order/subscription call below — that call can throw and
  // would otherwise orphan this customer (Razorpay has no fetch-by-email API to
  // recover it cheaply).
  if (args.onCustomerCreated) await args.onCustomerCreated(customerId);

  try {
    const razorpayPlanId = resolveCheckoutSku(args.planId, "razorpay", env) as string;
    const plan = await fetchRazorpayPlanSnapshot(razorpay, razorpayPlanId);
    const request = buildRazorpaySubscriptionRequest({
      planId: args.planId,
      razorpayPlanId,
      totalCount: plan.totalCount,
      seats: args.seats,
      customerId,
      notes,
    });
    const sub = await razorpay.subscriptions.create(
      request as Parameters<typeof razorpay.subscriptions.create>[0]
    );

    return {
      subscriptionId: String(sub.id),
      shortUrl: typeof sub.short_url === "string" ? sub.short_url : undefined,
      keyId,
      planId: args.planId,
      customerId,
      // Razorpay's subscription-create response carries no amount, so the
      // closest honest number is its own plan amount times the quantity this
      // very request was built with — read from the same fetch that sized the
      // request, not from our catalog constants.
      total: checkoutTotal(
        plan.unitAmount === null ? null : plan.unitAmount * request.quantity,
        plan.currency
      ),
    };
  } catch (e) {
    throw new Error(`razorpay checkout failed: ${formatRazorpayError(e)}`);
  }
}

export async function createCheckoutSession(
  env: CheckoutEnv,
  args: {
    planId: PlanId;
    accountId: string;
    country: string | null;
    provider: ProviderId;
    /** Validated against `plans.max_seats` by the caller. Required, and never
     *  defaulted below this point: a seat count is a price, so the one place
     *  allowed to invent it is the request schema at the edge. */
    seats: number;
    email?: string | null;
    providerCustomerId?: string | null;
    razorpayCallbackUrl: string;
    onCustomerCreated?: (customerId: string) => Promise<void>;
  }
): Promise<CheckoutSession> {
  const provider = args.provider;

  if (provider === "paddle") {
    const clientToken = env.PADDLE_CLIENT_TOKEN;
    if (!clientToken) throw new Error("PADDLE_NOT_CONFIGURED");
    const checkout = await createPaddleCheckout(env, args);
    return {
      provider: "paddle",
      planId: checkout.planId,
      transactionId: checkout.transactionId,
      clientToken,
      environment: env.PADDLE_ENVIRONMENT ?? "production",
      seats: args.seats,
      total: checkout.total,
      ...(checkout.customerAuthToken ? { customerAuthToken: checkout.customerAuthToken } : {}),
    };
  }

  const checkout = await createRazorpayCheckout(env, args);
  return {
    provider: "razorpay",
    planId: checkout.planId,
    keyId: checkout.keyId,
    customerId: checkout.customerId,
    subscriptionId: checkout.subscriptionId,
    seats: args.seats,
    total: checkout.total,
    shortUrl: checkout.shortUrl,
    callbackUrl: args.razorpayCallbackUrl,
  };
}
