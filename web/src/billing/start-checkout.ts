import type { DB } from "../db/index.js";
import type { Env } from "../env.js";
import {
  ensureProductAccount,
  ensureProductAccountCountry,
  isBillingProviderLocked,
  lockBillingProvider,
  updateProductAccountCountry,
} from "../models/product-account.js";
import { findBillingCustomer, upsertBillingCustomer } from "../models/billing-customer.js";
import { findPlanBySlug, isSelfServe } from "../models/plan.js";
import { provisionProductAccountForUser } from "../models/subscription.js";
import { detectCountryFromIp } from "./geo.js";
import type { PlanId, ProviderId } from "./plans.js";
import {
  createCheckoutSession,
  isCheckoutConfigError,
  type CheckoutConfigError,
  type CheckoutSession,
} from "./checkout.js";

export type StartCheckoutFailure =
  | { error: "PLAN_NOT_SELF_SERVE"; status: 400 }
  | { error: "SEATS_ABOVE_PLAN_MAX"; status: 400; maxSeats: number }
  | { error: "COUNTRY_REQUIRED"; status: 400 }
  | { error: CheckoutConfigError; status: 503 };

export type StartCheckoutResult =
  | { ok: true; session: CheckoutSession }
  | ({ ok: false } & StartCheckoutFailure);

/**
 * The one path that creates a checkout transaction.
 *
 * Both entry points — the JSON API and the checkout page's order form — go
 * through here, because the buyer's total is read off the gateway response this
 * function returns. A second creating path is a second total, and the two would
 * be compared against one invoice.
 *
 * The seat cap is settled before any write, because the first of those writes
 * locks the account's gateway for good: a request we are going to refuse must
 * not leave that behind.
 */
export async function startCheckout(
  db: DB,
  env: Env,
  args: {
    userId: string;
    planId: PlanId;
    /** Buyer-chosen billing country; falls back to the account's, then geo-IP. */
    country?: string;
    seats: number;
    clientIp: string | null;
    /** Origin of the request being served — the Razorpay redirect target. */
    origin: string;
  }
): Promise<StartCheckoutResult> {
  const plan = await findPlanBySlug(db, args.planId);
  // Ahead of the seat cap and of every write. A contact-sales row is in the
  // catalog and visible, but it has no self-serve price at all — its total is
  // agreed with a human — so there is nothing here to charge and no cap worth
  // quoting. Refusing on the seat count instead would answer a question about a
  // plan that is not for sale.
  if (plan && !isSelfServe(plan)) {
    return { ok: false, error: "PLAN_NOT_SELF_SERVE", status: 400 };
  }
  // NULL max_seats is unlimited. A plan row we cannot read is a cap we cannot
  // verify, so it allows only the single seat every checkout has always bought
  // rather than taking the request's word for it.
  const maxSeats = plan ? plan.maxSeats : 1;
  if (maxSeats !== null && args.seats > maxSeats) {
    return { ok: false, error: "SEATS_ABOVE_PLAN_MAX", status: 400, maxSeats };
  }

  const { id: accountId } = await provisionProductAccountForUser(db, args.userId);
  let account = await ensureProductAccount(db, args.userId);
  const detected = account.country ?? (await detectCountryFromIp(args.clientIp, env.IPINFO_TOKEN));
  if (!account.country && detected) {
    account = await ensureProductAccountCountry(db, accountId, detected, "ipinfo");
  }
  const country = (args.country ?? account.country ?? detected)?.toUpperCase();
  if (!country) return { ok: false, error: "COUNTRY_REQUIRED", status: 400 };

  const locked = isBillingProviderLocked(account);
  let provider: ProviderId;
  const billingCountry = country;

  if (locked) {
    provider = account.billingProvider as ProviderId;
    if (args.country || country !== account.country) {
      await updateProductAccountCountry(db, accountId, billingCountry, "manual");
    }
  } else {
    if (!account.country || args.country) {
      await updateProductAccountCountry(db, accountId, country, "manual");
    }
    provider = await lockBillingProvider(db, accountId, country);
  }

  const billingCustomer = await findBillingCustomer(db, accountId, provider);
  const user = await db.user.findUnique({
    where: { id: args.userId },
    select: { email: true },
  });

  const razorpayCallbackUrl = `${args.origin}/billing/razorpay/callback?planId=${encodeURIComponent(args.planId)}`;

  try {
    const session = await createCheckoutSession(env, {
      planId: args.planId,
      accountId,
      country: billingCountry,
      provider,
      seats: args.seats,
      email: user?.email,
      providerCustomerId: billingCustomer?.providerCustomerId,
      razorpayCallbackUrl,
      // Persist the Razorpay customer the instant it's created — before the
      // order/subscription call that can fail and orphan it (no fetch-by-email
      // API to recover it cheaply). Sole persistence site: the reused-customer
      // path already has the id in the DB, so no post-success upsert is needed.
      onCustomerCreated: async (providerCustomerId) => {
        await upsertBillingCustomer(db, {
          accountId,
          provider: "razorpay",
          providerCustomerId,
        });
      },
    });
    return { ok: true, session };
  } catch (e) {
    const msg = e instanceof Error ? e.message : "checkout failed";
    if (isCheckoutConfigError(msg)) return { ok: false, error: msg, status: 503 };
    throw e; // unexpected → central onError logs the stack and returns 500
  }
}
