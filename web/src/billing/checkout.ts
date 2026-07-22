import type {
  IMoney,
  ITimePeriod,
  ITransactionItemWithNonCatalogPrice,
} from "@paddle/paddle-node-sdk";
import type { DB } from "../db/index.js";
import type { RelayPushConfig } from "../relay/push.js";
import { applySubscriptionEvent } from "./reducer.js";
import {
  displayPriceCents,
  isPlanId,
  PRICING,
  resolveCheckoutSku,
  resolvePaddleDiscountId,
  TRIAL_DAYS,
  type BillingEnv,
  type PlanId,
  type ProviderId,
} from "./plans.js";
import { verifyRazorpayHmac, getRazorpayClient } from "./razorpay.js";
import { getPaddleClient, paddleCustomerCheckoutAuth } from "./paddle.js";
import type { NormalizedEvent } from "./events.js";

export type PaddleCheckoutSession = {
  provider: "paddle";
  planId: PlanId;
  transactionId: string;
  clientToken: string;
  environment: "sandbox" | "production";
  /** Present saved payment methods when a returning Paddle customer checks out again. */
  customerAuthToken?: string;
};

export type RazorpayCheckoutSession = {
  provider: "razorpay";
  planId: PlanId;
  keyId: string;
  customerId: string;
  isSubscription: boolean;
  subscriptionId?: string;
  /** Razorpay-hosted subscription page (full-page, not checkout.js modal). */
  shortUrl?: string;
  /** POST target for redirect-mode Standard Checkout (lifetime + subscription fallback). */
  callbackUrl: string;
  orderId?: string;
  amount?: number;
  currency?: string;
};

export type CheckoutSession = PaddleCheckoutSession | RazorpayCheckoutSession;

export type CheckoutEnv = BillingEnv & {
  PADDLE_API_KEY?: string;
  PADDLE_CLIENT_TOKEN?: string;
  PADDLE_ENVIRONMENT?: "sandbox" | "production";
  RAZORPAY_KEY_ID?: string;
  RAZORPAY_KEY_SECRET?: string;
};

export type VerifyPaymentInput =
  | {
      provider: "razorpay";
      orderId: string;
      paymentId: string;
      signature: string;
    }
  | {
      provider: "paddle";
      transactionId: string;
    };

export type CheckoutReadiness = Record<ProviderId, Record<PlanId, boolean>>;

const CHECKOUT_CONFIG_ERRORS = new Set([
  "PADDLE_NOT_CONFIGURED",
  "PADDLE_PRICE_NOT_CONFIGURED",
  "RAZORPAY_NOT_CONFIGURED",
  "RAZORPAY_PLAN_NOT_CONFIGURED",
]);

export function isCheckoutConfigError(msg: string): boolean {
  return CHECKOUT_CONFIG_ERRORS.has(msg);
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

async function buildPaddleTransactionItems(
  paddle: ReturnType<typeof getPaddleClient>,
  planId: PlanId,
  priceId: string
): Promise<ITransactionItemWithNonCatalogPrice[]> {
  if (!paddleSkipTrialForPlan(planId)) {
    return [{ priceId, quantity: 1 }];
  }

  const catalog = await fetchPaddleCatalogPrice(paddle, priceId);
  return [
    {
      quantity: 1,
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
  if (planId === "pro_lifetime") return true;
  const planSku = resolveCheckoutSku(planId, "razorpay", env);
  return typeof planSku === "string" && planSku.length > 0;
}

function emptyPlanReadiness(): Record<PlanId, boolean> {
  return { trial: false, pro_yearly: false, pro_lifetime: false };
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
  args: { planId: PlanId; accountId: string; providerCustomerId?: string | null }
): Promise<{ transactionId: string; planId: PlanId; customerAuthToken?: string }> {
  if (!env.PADDLE_API_KEY) throw new Error("PADDLE_NOT_CONFIGURED");
  if (!isPaddleCheckoutReady(env, args.planId)) {
    throw new Error("PADDLE_PRICE_NOT_CONFIGURED");
  }

  const priceId = resolveCheckoutSku(args.planId, "paddle", env) as string;
  const discountId = resolvePaddleDiscountId(args.planId, env);
  const paddle = getPaddleClient(env);
  const items = await buildPaddleTransactionItems(paddle, args.planId, priceId);

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

/** Billing cycles for one year of access — monthly plan ×12, yearly plan ×1. */
async function razorpaySubscriptionTotalCount(
  razorpay: ReturnType<typeof getRazorpayClient>,
  razorpayPlanId: string
): Promise<number> {
  const plan = await razorpay.plans.fetch(razorpayPlanId);
  return plan.period === "yearly" ? 1 : 12;
}

async function createRazorpayCheckout(
  env: CheckoutEnv,
  args: {
    planId: PlanId;
    accountId: string;
    country?: string | null;
    currency?: string;
    email?: string | null;
    providerCustomerId?: string | null;
    onCustomerCreated?: (customerId: string) => Promise<void>;
  }
): Promise<
  | {
      isSubscription: true;
      subscriptionId: string;
      shortUrl?: string;
      keyId: string;
      planId: PlanId;
      customerId: string;
    }
  | {
      isSubscription: false;
      orderId: string;
      keyId: string;
      amount: number;
      currency: string;
      planId: PlanId;
      customerId: string;
    }
> {
  const keyId = env.RAZORPAY_KEY_ID;
  const keySecret = env.RAZORPAY_KEY_SECRET;
  if (!keyId || !keySecret) throw new Error("RAZORPAY_NOT_CONFIGURED");

  const razorpay = getRazorpayClient(keyId, keySecret);
  const notes = { accountId: args.accountId, planId: args.planId };
  const currency = args.currency ?? "USD";
  const isLifetime = args.planId === "pro_lifetime";

  // Validate plan config before creating a customer, so a misconfigured plan
  // doesn't orphan a freshly created Razorpay customer. Bare throw (not wrapped)
  // so the route's isCheckoutConfigError match still yields a 503.
  if (!isLifetime && !isRazorpayCheckoutReady(env, args.planId)) {
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
    if (isLifetime) {
      const amount = env.RAZORPAY_AMOUNT_LIFETIME ?? displayPriceCents("pro_lifetime", env);
      const order = await razorpay.orders.create({
        amount,
        currency,
        receipt: `ltd_${args.accountId.slice(0, 8)}`,
        notes: { ...notes, customerId },
      });
      return {
        isSubscription: false,
        orderId: String(order.id),
        keyId,
        amount: Number(order.amount),
        currency: String(order.currency ?? currency),
        planId: args.planId,
        customerId,
      };
    }

    const razorpayPlanId = resolveCheckoutSku(args.planId, "razorpay", env) as string;
    const startAt = razorpaySubscriptionStartAt(args.planId);
    const totalCount = await razorpaySubscriptionTotalCount(razorpay, razorpayPlanId);
    // SDK types omit customer_id / fail_existing even though the API accepts them.
    const sub = await razorpay.subscriptions.create({
      plan_id: razorpayPlanId,
      total_count: totalCount,
      quantity: 1,
      customer_notify: 1,
      customer_id: customerId,
      notes,
      ...(startAt ? { start_at: startAt } : {}),
    } as Parameters<typeof razorpay.subscriptions.create>[0]);

    return {
      isSubscription: true,
      subscriptionId: String(sub.id),
      shortUrl: typeof sub.short_url === "string" ? sub.short_url : undefined,
      keyId,
      planId: args.planId,
      customerId,
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
    currency?: string;
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
      ...(checkout.customerAuthToken ? { customerAuthToken: checkout.customerAuthToken } : {}),
    };
  }

  const checkout = await createRazorpayCheckout(env, args);
  if (checkout.isSubscription) {
    return {
      provider: "razorpay",
      planId: checkout.planId,
      keyId: checkout.keyId,
      customerId: checkout.customerId,
      isSubscription: true,
      subscriptionId: checkout.subscriptionId,
      shortUrl: checkout.shortUrl,
      callbackUrl: args.razorpayCallbackUrl,
    };
  }

  return {
    provider: "razorpay",
    planId: checkout.planId,
    keyId: checkout.keyId,
    customerId: checkout.customerId,
    isSubscription: false,
    orderId: checkout.orderId,
    amount: checkout.amount,
    currency: checkout.currency,
    callbackUrl: args.razorpayCallbackUrl,
  };
}

async function verifyRazorpayOrderPayment(
  env: CheckoutEnv,
  args: { orderId: string; paymentId: string; signature: string }
): Promise<NormalizedEvent | null> {
  const keyId = env.RAZORPAY_KEY_ID;
  const keySecret = env.RAZORPAY_KEY_SECRET;
  if (!keyId || !keySecret) throw new Error("RAZORPAY_NOT_CONFIGURED");

  const valid = verifyRazorpayHmac(
    `${args.orderId}|${args.paymentId}`,
    keySecret,
    args.signature
  );
  if (!valid) throw new Error("INVALID_SIGNATURE");

  const razorpay = getRazorpayClient(keyId, keySecret);
  const payment = await razorpay.payments.fetch(args.paymentId);
  const notes = payment.notes as
    | { accountId?: string; planId?: string; customerId?: string }
    | undefined;
  if (!notes || typeof notes.accountId !== "string" || typeof notes.planId !== "string") {
    console.warn("[billing] razorpay verify-payment: missing order notes", {
      paymentId: args.paymentId,
    });
    return null;
  }
  if (!isPlanId(notes.planId) || notes.planId !== "pro_lifetime") {
    console.warn("[billing] razorpay verify-payment: not a lifetime order", {
      paymentId: args.paymentId,
      planId: notes.planId,
    });
    return null;
  }

  const customerId =
    typeof payment.customer_id === "string" && payment.customer_id.length > 0
      ? payment.customer_id
      : typeof notes.customerId === "string" && notes.customerId.length > 0
        ? notes.customerId
        : null;
  if (!customerId) throw new Error("RAZORPAY_CUSTOMER_MISSING");

  return {
    provider: "razorpay",
    providerEventId: `verify:${args.paymentId}`,
    type: "activated",
    accountId: notes.accountId,
    planId: notes.planId,
    customerId,
    providerTransactionId: args.paymentId,
  };
}

export async function verifyPayment(
  db: DB,
  relay: RelayPushConfig,
  env: CheckoutEnv,
  input: VerifyPaymentInput
): Promise<{ ok: true; pending?: boolean }> {
  if (input.provider === "paddle") {
    // Paddle provisions via webhook; client redirect is optimistic.
    return { ok: true, pending: true };
  }

  const event = await verifyRazorpayOrderPayment(env, input);
  if (!event) throw new Error("INVALID_PAYMENT");
  await applySubscriptionEvent(db, relay, event, input);
  return { ok: true };
}
