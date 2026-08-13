import type { DB } from "../db/index.js";
import type { PlanRow } from "../models/plan.js";
import type { SubscriptionRow } from "../models/subscription.js";
import { isPendingCancellation } from "../models/subscription.js";
import { countActiveSeatHolders } from "../models/account-member.js";
import type { CheckoutEnv } from "./checkout.js";
import { getPaddleClient, paddleUpdateSubscriptionQuantity } from "./paddle.js";
import { getRazorpayClient, razorpayUpdateSubscriptionQuantity } from "./razorpay.js";

export class UpdateSeatsError extends Error {
  constructor(
    readonly code:
      | "NOT_RECURRING"
      | "NO_ACTIVE_SUBSCRIPTION"
      | "NO_PROVIDER_SUBSCRIPTION"
      | "SEATS_BELOW_HEADCOUNT"
      | "SEATS_ABOVE_PLAN_MAX"
      | "UNSUPPORTED_PROVIDER"
      | "PADDLE_NOT_CONFIGURED"
      | "RAZORPAY_NOT_CONFIGURED"
      | "PROVIDER_UPDATE_FAILED",
    message?: string,
    /** The number the refusal is about — active headcount for
     *  SEATS_BELOW_HEADCOUNT, `plans.max_seats` for SEATS_ABOVE_PLAN_MAX. An
     *  owner told only "too low" cannot tell what to do next. */
    readonly limit?: number
  ) {
    super(message ?? code);
    this.name = "UpdateSeatsError";
  }
}

async function updateQuantityAtProvider(
  env: CheckoutEnv,
  args: { provider: string; providerSubscriptionId: string; seats: number }
): Promise<void> {
  if (args.provider === "paddle") {
    if (!env.PADDLE_API_KEY) throw new UpdateSeatsError("PADDLE_NOT_CONFIGURED");
    const paddle = getPaddleClient(env);
    try {
      await paddleUpdateSubscriptionQuantity(paddle, args.providerSubscriptionId, args.seats);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      throw new UpdateSeatsError("PROVIDER_UPDATE_FAILED", msg);
    }
    return;
  }

  if (args.provider === "razorpay") {
    if (!env.RAZORPAY_KEY_ID || !env.RAZORPAY_KEY_SECRET) {
      throw new UpdateSeatsError("RAZORPAY_NOT_CONFIGURED");
    }
    const razorpay = getRazorpayClient(env.RAZORPAY_KEY_ID, env.RAZORPAY_KEY_SECRET);
    try {
      await razorpayUpdateSubscriptionQuantity(razorpay, args.providerSubscriptionId, args.seats);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      throw new UpdateSeatsError("PROVIDER_UPDATE_FAILED", msg);
    }
    return;
  }

  throw new UpdateSeatsError("UNSUPPORTED_PROVIDER", args.provider);
}

/**
 * Resize the seats an account is billed for, refusing to go below the people
 * already occupying them.
 *
 * This is the half of the seat story we control, and the only half that may
 * refuse. The webhook reducer observes and writes whatever the provider billed,
 * below headcount included — the provider already made that change, and a row
 * that disagrees with the invoice is the undercharging bug the seat work exists
 * to close. Clamping there would hide it; clamping here happens before anything
 * is billed. Nobody is ever removed to make a number fit.
 *
 * The advisory lock is `hashtext('billing:' || accountId)` — byte-for-byte the
 * key `applySubscriptionEvent` takes, or the mutual exclusion is fiction. It
 * covers the headcount read and the row write as one, and NOT the gateway round
 * trip: an HTTP call inside an interactive transaction blocks every webhook for
 * the account behind the lock and aborts on Prisma's 5s timeout. So the row is
 * written optimistically and restored if the gateway refuses, the same ordering
 * `cancelRecurringSubscription` uses.
 */
export async function updateSubscriptionSeats(
  db: DB,
  env: CheckoutEnv,
  args: {
    accountId: string;
    subscription: SubscriptionRow & { plan: PlanRow };
    seats: number;
  }
): Promise<{ seats: number; headcount: number }> {
  const { accountId, subscription, seats } = args;

  if (!subscription.plan.recurring) throw new UpdateSeatsError("NOT_RECURRING");
  if (subscription.status !== "active" || isPendingCancellation(subscription)) {
    throw new UpdateSeatsError("NO_ACTIVE_SUBSCRIPTION");
  }
  // NULL is unlimited. The cap is a catalog value, not a price, so it holds
  // whether or not the gateway plans are configured yet.
  const maxSeats = subscription.plan.maxSeats;
  if (maxSeats !== null && seats > maxSeats) {
    throw new UpdateSeatsError(
      "SEATS_ABOVE_PLAN_MAX",
      `plan ${subscription.plan.slug} allows at most ${maxSeats} seats`,
      maxSeats
    );
  }

  const previousSeats = subscription.seats;
  const now = new Date();

  const headcount = await db.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`billing:${accountId}`}))`;

    // Read under the lock, not before it: a webhook or a second resize between
    // an unlocked count and the write would let the refused number through.
    const active = await countActiveSeatHolders(tx, accountId);
    if (seats < active) {
      throw new UpdateSeatsError(
        "SEATS_BELOW_HEADCOUNT",
        `the account has ${active} active members; remove someone before dropping to ${seats} seats`,
        active
      );
    }

    await tx.subscription.update({
      where: { id: subscription.id },
      data: { seats, updatedAt: now },
    });
    return active;
  });

  if (subscription.provider === "dev" || subscription.provider === null) {
    return { seats, headcount };
  }
  if (!subscription.providerSubscriptionId) {
    await db.subscription.update({
      where: { id: subscription.id },
      data: { seats: previousSeats, updatedAt: now },
    });
    throw new UpdateSeatsError("NO_PROVIDER_SUBSCRIPTION");
  }

  try {
    await updateQuantityAtProvider(env, {
      provider: subscription.provider,
      providerSubscriptionId: subscription.providerSubscriptionId,
      seats,
    });
  } catch (e) {
    await db.subscription.update({
      where: { id: subscription.id },
      data: { seats: previousSeats, updatedAt: now },
    });
    throw e;
  }

  return { seats, headcount };
}
