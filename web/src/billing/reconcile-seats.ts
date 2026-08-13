// web/src/billing/reconcile-seats.ts
//
// The daily sweep that compares what each gateway is billing against what
// `subscriptions.seats` says, and makes the row agree.
//
// It exists because a seat change is only ever announced once. A webhook that is
// dropped, arrives while the service is down, or was emitted before the seat
// path shipped at all leaves the row holding a number the invoice moved past —
// permanently, since nothing else ever re-reads the count. An owner who edits
// 5 → 3 in the provider portal is then billed for 3 while five members keep
// working. This is the only thing that catches that, in either direction.

import type { DB } from "../db/index.js";
import { countActiveSeatHolders } from "../models/account-member.js";
import type { ProviderId } from "./plans.js";
import type { CheckoutEnv } from "./checkout.js";
import { getPaddleClient, paddleReadSubscriptionQuantity } from "./paddle.js";
import { getRazorpayClient, razorpayReadSubscriptionQuantity } from "./razorpay.js";

/**
 * The providers a live seat count can be fetched from.
 *
 * A Record over ProviderId rather than a bare array, so a third gateway is a
 * compile error here rather than a set of subscriptions this sweep silently
 * never visits.
 */
const GATEWAY_PROVIDERS: Record<ProviderId, true> = { paddle: true, razorpay: true };

/** Seats a gateway is billing on one subscription, or null when it reports none
 *  this side can read. Injected so the sweep needs no credentials to be tested. */
export type SeatQuantityReader = (
  provider: string,
  providerSubscriptionId: string
) => Promise<number | null>;

export type ReconcileSeatsDeps = {
  db: DB;
  readQuantity: SeatQuantityReader;
  /** Passed in rather than called directly, so a report is reproducible. */
  now: () => Date;
};

/** A subscription whose stored count disagreed with the gateway, and now does
 *  not. `seatsAfter` is what the gateway said — this never invents a number. */
export type SeatDrift = {
  accountId: string;
  subscriptionId: string;
  provider: string;
  providerSubscriptionId: string;
  seatsBefore: number;
  seatsAfter: number;
  direction: "increase" | "decrease";
  headcount: number;
};

/** More people on the account than seats billed for. Reported and nothing else:
 *  nobody is removed and the count is not raised to fit them. Being
 *  over-subscribed blocks new invites, which is the whole of its effect. */
export type OverSubscribedAccount = {
  accountId: string;
  subscriptionId: string;
  seats: number;
  headcount: number;
};

/** `unreadable_quantity` — the gateway answered, with nothing a seat count can
 *  be read from (several live lines, a scheduled change not yet applied).
 *  `no_longer_live` — the row stopped being active while this sweep was on the
 *  network, so there is nothing left to bill. `changed_during_read` — a webhook
 *  moved the count while this sweep was on the network; see `storeBilledSeats`.
 *  None of the three is an error. */
export type SkipReason = "unreadable_quantity" | "no_longer_live" | "changed_during_read";

export type SkippedSubscription = {
  accountId: string;
  subscriptionId: string;
  provider: string;
  providerSubscriptionId: string;
  reason: SkipReason;
};

export type FailedSubscription = {
  accountId: string;
  subscriptionId: string;
  provider: string;
  providerSubscriptionId: string;
  reason: string;
};

/** What an operator reads. Every subscription selected appears in exactly one of
 *  `drifted`, `skipped`, `failed`, or nowhere at all — nowhere meaning it already
 *  agreed, which is the answer this tool hopes for. */
export type ReconcileSeatsReport = {
  startedAt: Date;
  finishedAt: Date;
  checked: number;
  drifted: SeatDrift[];
  overSubscribed: OverSubscribedAccount[];
  skipped: SkippedSubscription[];
  failed: FailedSubscription[];
};

/** Where a finding happened — the four fields every report entry carries. */
type SubscriptionRef = {
  accountId: string;
  subscriptionId: string;
  provider: string;
  providerSubscriptionId: string;
};

type StoreOutcome =
  | { kind: "stored"; seatsBefore: number; headcount: number }
  | { kind: "skipped"; reason: Extract<SkipReason, "no_longer_live" | "changed_during_read"> };

/**
 * Store what the gateway says, and count the people occupying the seats.
 *
 * The advisory lock is `hashtext('billing:' || accountId)` — byte-for-byte the
 * key `applySubscriptionEvent` and `updateSubscriptionSeats` take, copied from
 * `update-seats.ts` rather than paraphrased, because a key that differs by one
 * character locks nothing and the mutual exclusion becomes fiction.
 *
 * The gateway round trip already happened, OUTSIDE this transaction and on
 * purpose: `update-seats.ts` spells out why an HTTP call inside an interactive
 * transaction is forbidden — it blocks every webhook for the account behind the
 * lock and dies on Prisma's 5s timeout.
 *
 * The cost of that ordering is that the reading is already old by the time the
 * lock is held, which is what `observedSeats` is for. The row is RE-READ here
 * and compared against the value this sweep started from: if they differ,
 * something else — a webhook, an owner resizing — wrote in the meantime, and
 * that writer saw the gateway later than this fetch did. It wins. This is a
 * backstop for a channel that failed, so it must never overwrite that channel
 * working with a reading taken before it ran. Left alone, tomorrow's sweep
 * confirms it.
 */
async function storeBilledSeats(
  db: DB,
  args: {
    accountId: string;
    subscriptionId: string;
    observedSeats: number;
    billedSeats: number;
    now: Date;
  }
): Promise<StoreOutcome> {
  return db.$transaction(async (tx): Promise<StoreOutcome> => {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`billing:${args.accountId}`}))`;

    const current = await tx.subscription.findUnique({ where: { id: args.subscriptionId } });
    if (!current || current.status !== "active") return { kind: "skipped", reason: "no_longer_live" };
    if (current.seats !== args.observedSeats) {
      return { kind: "skipped", reason: "changed_during_read" };
    }

    const headcount = await countActiveSeatHolders(tx, args.accountId);

    // Below headcount included. The provider is the source of truth for what is
    // billed, and a row that disagrees with the invoice IS the undercharging
    // bug this sweep exists to close. Clamping lives in POST /billing/seats, the
    // path we control and the only one that may refuse; here and in the reducer
    // it would hide the very disagreement being looked for. Nobody is removed.
    if (current.seats !== args.billedSeats) {
      await tx.subscription.update({
        where: { id: args.subscriptionId },
        data: { seats: args.billedSeats, updatedAt: args.now },
      });
    }

    return { kind: "stored", seatsBefore: current.seats, headcount };
  });
}

/**
 * Reconcile every subscription a gateway is billing.
 *
 * Seats are never derived from headcount: the count is read from the provider
 * and compared against the row, and the member total is reported beside it and
 * acted on nowhere.
 */
export async function reconcileSeats(deps: ReconcileSeatsDeps): Promise<ReconcileSeatsReport> {
  const { db, readQuantity, now } = deps;
  const startedAt = now();

  // Only rows with somewhere to read a count FROM. `manual` is a negotiated
  // contract, `promo` and `dev` are grants nobody was charged for, and NULL is a
  // free row — none of them has a gateway holding an authoritative seat count,
  // so a sweep that visited them could only ever overwrite a human's decision
  // with a fetch that has no answer. Same boundary the catalog re-sync draws
  // with `IS DISTINCT FROM 'manual'`, and for the same reason.
  //
  // A pending cancellation stays in scope deliberately: it is billed until the
  // period ends, so its seat count is still live.
  const subscriptions = await db.subscription.findMany({
    where: {
      status: "active",
      provider: { in: Object.keys(GATEWAY_PROVIDERS) },
      providerSubscriptionId: { not: null },
    },
    orderBy: { createdAt: "asc" },
  });

  const drifted: SeatDrift[] = [];
  const overSubscribed: OverSubscribedAccount[] = [];
  const skipped: SkippedSubscription[] = [];
  const failed: FailedSubscription[] = [];

  for (const sub of subscriptions) {
    // The where clause already guarantees both, but the columns are nullable and
    // the narrowing has to be earned somewhere.
    if (!sub.provider || !sub.providerSubscriptionId) continue;
    const at: SubscriptionRef = {
      accountId: sub.accountId,
      subscriptionId: sub.id,
      provider: sub.provider,
      providerSubscriptionId: sub.providerSubscriptionId,
    };

    try {
      const billedSeats = await readQuantity(at.provider, at.providerSubscriptionId);
      // Not zero, and not the stored count either. An unreadable answer is an
      // absence of information; writing a 0 would strand a whole team on a
      // number no gateway ever billed.
      if (billedSeats === null) {
        skipped.push({ ...at, reason: "unreadable_quantity" });
        continue;
      }

      const stored = await storeBilledSeats(db, {
        accountId: at.accountId,
        subscriptionId: at.subscriptionId,
        observedSeats: sub.seats,
        billedSeats,
        now: now(),
      });
      if (stored.kind === "skipped") {
        skipped.push({ ...at, reason: stored.reason });
        continue;
      }

      if (stored.seatsBefore !== billedSeats) {
        drifted.push({
          ...at,
          seatsBefore: stored.seatsBefore,
          seatsAfter: billedSeats,
          direction: billedSeats > stored.seatsBefore ? "increase" : "decrease",
          headcount: stored.headcount,
        });
      }
      if (stored.headcount > billedSeats) {
        overSubscribed.push({
          accountId: at.accountId,
          subscriptionId: at.subscriptionId,
          seats: billedSeats,
          headcount: stored.headcount,
        });
      }
    } catch (e) {
      // One account's gateway is not the run. A sweep that stopped at the first
      // 500 would reconcile whatever sorted before it and nothing else, and the
      // accounts it never reached would look identical to accounts that agreed.
      failed.push({ ...at, reason: e instanceof Error ? e.message : String(e) });
    }
  }

  return {
    startedAt,
    finishedAt: now(),
    checked: subscriptions.length,
    drifted,
    overSubscribed,
    skipped,
    failed,
  };
}

/**
 * The production reader: one live subscription fetch per gateway.
 *
 * Razorpay's credentials are checked here and Paddle's are not, matching the two
 * getters — `getPaddleClient` gates on its own key, while `getRazorpayClient`
 * takes bare strings and leaves the check to every caller.
 */
export function providerSeatReader(env: CheckoutEnv): SeatQuantityReader {
  return async (provider, providerSubscriptionId) => {
    if (provider === "paddle") {
      return paddleReadSubscriptionQuantity(getPaddleClient(env), providerSubscriptionId);
    }
    if (provider === "razorpay") {
      if (!env.RAZORPAY_KEY_ID || !env.RAZORPAY_KEY_SECRET) {
        throw new Error("RAZORPAY_NOT_CONFIGURED");
      }
      return razorpayReadSubscriptionQuantity(
        getRazorpayClient(env.RAZORPAY_KEY_ID, env.RAZORPAY_KEY_SECRET),
        providerSubscriptionId
      );
    }
    throw new Error(`UNSUPPORTED_PROVIDER: ${provider}`);
  };
}
