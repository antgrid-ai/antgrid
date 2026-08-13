import { describe, test, expect, beforeAll, afterAll, beforeEach, afterEach } from "bun:test";
import postgres from "postgres";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { testBillingEnv } from "../helpers/billing-env.js";
import { addTestMember, createTestUser } from "../helpers/fixtures.js";
import { applySubscriptionEvent } from "../../src/billing/reducer.js";
import type { CheckoutEnv } from "../../src/billing/checkout.js";
import { razorpayReadSubscriptionQuantity } from "../../src/billing/razorpay.js";
import {
  providerSeatReader,
  reconcileSeats,
  type ReconcileSeatsReport,
  type SeatQuantityReader,
} from "../../src/billing/reconcile-seats.js";
import {
  cancelActiveSubscriptions,
  ensureFreeSubscription,
  grantDevSubscription,
  grantManualContract,
  provisionProductAccountForUser,
  MANUAL_PROVIDER,
} from "../../src/models/subscription.js";

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});
beforeEach(async () => {
  await pg.truncate();
});

/** Injected, so a report is the same every run and a write is visible as an
 *  `updated_at` that moved to a value no fixture could have written. */
const CLOCK = new Date("2026-08-13T04:00:00.000Z");

/**
 * An account on a live gateway subscription billing `seats`, provisioned through
 * the reducer so the row under test is the one production writes.
 */
async function billedAccount(
  seats: number,
  opts: { providerSubscriptionId?: string; provider?: string } = {}
): Promise<{ userId: string; accountId: string; providerSubscriptionId: string }> {
  const user = await createTestUser(pg.db);
  const account = await provisionProductAccountForUser(pg.db, user.id);
  const providerSubscriptionId = opts.providerSubscriptionId ?? `sub_${account.id}`;
  await applySubscriptionEvent(
    pg.db,
    {},
    {
      provider: "paddle",
      providerEventId: `evt_${providerSubscriptionId}`,
      type: "activated",
      accountId: account.id,
      planId: "pro_yearly",
      // One gateway customer belongs to one account (billing_customers is unique
      // on provider + customer id), so a shared literal here silently collapses
      // the second account into a duplicate and the sweep sees one row.
      customerId: `ctm_${providerSubscriptionId}`,
      providerSubscriptionId,
      currentPeriodEnd: new Date("2027-06-08T00:00:00Z"),
      quantity: seats,
    },
    {}
  );
  if (opts.provider) {
    await pg.db.subscription.updateMany({
      where: { providerSubscriptionId },
      data: { provider: opts.provider },
    });
  }
  return { userId: user.id, accountId: account.id, providerSubscriptionId };
}

function subOf(providerSubscriptionId: string) {
  return pg.db.subscription.findFirstOrThrow({ where: { providerSubscriptionId } });
}

async function seatsOf(providerSubscriptionId: string): Promise<number> {
  return (await subOf(providerSubscriptionId)).seats;
}

/** Grow the account to `total` active members, owner included. */
async function staffTo(accountId: string, total: number): Promise<void> {
  const current = await pg.db.accountMember.count({ where: { accountId, status: "active" } });
  for (let i = current; i < total; i++) {
    const extra = await createTestUser(pg.db);
    await addTestMember(pg.db, accountId, extra.id);
  }
}

type GatewayAnswer = number | null | Error;

/** A gateway that answers from this file. `calls` is what proves a row was never
 *  visited — a skip has to be invisible at the network, not just at the row. */
function gatewaySaying(answers: Record<string, GatewayAnswer>) {
  const calls: string[] = [];
  const readQuantity: SeatQuantityReader = async (_provider, providerSubscriptionId) => {
    calls.push(providerSubscriptionId);
    const answer = answers[providerSubscriptionId];
    if (answer instanceof Error) throw answer;
    if (answer === undefined) throw new Error(`no fixture for ${providerSubscriptionId}`);
    return answer;
  };
  return { readQuantity, calls };
}

function run(readQuantity: SeatQuantityReader): Promise<ReconcileSeatsReport> {
  return reconcileSeats({ db: pg.db, readQuantity, now: () => CLOCK });
}

/**
 * Whether the account's billing lock is free, asked from a connection of its
 * own. The key is `hashtext('billing:' || accountId)` spelled exactly as
 * `storeBilledSeats` spells it, since a key differing by one character reports
 * an unrelated lock as free.
 *
 * A separate connection and not the sweep's pool, because an advisory lock is
 * re-entrant within a session: a probe sharing the holder's connection answers
 * "free" however tightly the lock is held. `pg_try_advisory_xact_lock` never
 * waits, so a held lock fails the caller rather than hanging it.
 */
async function billingLockIsFree(accountId: string): Promise<boolean> {
  const sql = postgres(pg.url, { max: 1, prepare: false, onnotice: () => {} });
  try {
    return await sql.begin(async (tx) => {
      const rows = await tx`
        SELECT pg_try_advisory_xact_lock(hashtext(${`billing:${accountId}`})) AS free
      `;
      return rows[0]?.free === true;
    });
  } finally {
    await sql.end();
  }
}

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

const PADDLE_SUB_ID = "sub_reconcile_paddle";

/** One live line at `quantity`, shaped as Paddle's API returns it. Enough of the
 *  entity for the SDK's constructors, which build a Price and a Product eagerly
 *  and throw on a thinner body than this. */
function paddleSubscriptionBody(items: { status: string; quantity: number }[]) {
  const at = "2026-01-01T00:00:00.000Z";
  return {
    data: {
      id: PADDLE_SUB_ID,
      status: "active",
      customer_id: "ctm_reconcile",
      address_id: "add_reconcile",
      business_id: null,
      currency_code: "USD",
      created_at: at,
      updated_at: at,
      started_at: at,
      first_billed_at: at,
      next_billed_at: at,
      paused_at: null,
      canceled_at: null,
      discount: null,
      collection_mode: "automatic",
      billing_details: null,
      current_billing_period: { starts_at: at, ends_at: at },
      billing_cycle: { interval: "year", frequency: 1 },
      scheduled_change: null,
      management_urls: null,
      custom_data: null,
      import_meta: null,
      items: items.map((item) => ({
        status: item.status,
        quantity: item.quantity,
        recurring: true,
        created_at: at,
        updated_at: at,
        previously_billed_at: at,
        next_billed_at: at,
        trial_dates: null,
        price: {
          id: "pri_reconcile",
          product_id: "pro_reconcile",
          description: "Pro Yearly",
          name: "Pro Yearly",
          type: "standard",
          billing_cycle: { interval: "year", frequency: 1 },
          trial_period: null,
          tax_mode: "account_setting",
          unit_price: { amount: "4900", currency_code: "USD" },
          unit_price_overrides: [],
          // The decoy: a plausible small integer on the price that never moves
          // when seats do. A reader that took this would report 1 forever.
          quantity: { minimum: 1, maximum: 1000 },
          status: "active",
          custom_data: null,
          import_meta: null,
          created_at: at,
          updated_at: at,
        },
        product: {
          id: "pro_reconcile",
          name: "Antgrid Pro",
          type: "standard",
          description: null,
          tax_category: "standard",
          image_url: null,
          custom_data: null,
          status: "active",
          created_at: at,
          updated_at: at,
          import_meta: null,
        },
      })),
    },
    meta: { request_id: "req_reconcile" },
  };
}

/** Paddle answering from this process, through the real SDK. */
function paddleReporting(items: { status: string; quantity: number }[]): { fetched: string[] } {
  const fetched: string[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    if (!url.includes("paddle.com")) return realFetch(input as RequestInfo, init);
    fetched.push(new URL(url).pathname);
    return Response.json(paddleSubscriptionBody(items));
  }) as typeof fetch;
  return { fetched };
}

function paddleReader(): SeatQuantityReader {
  return providerSeatReader(testBillingEnv() as CheckoutEnv);
}

describe("the daily seat reconciler", () => {
  test("a portal edit from five seats to three is written back to the row", async () => {
    const { accountId } = await billedAccount(5, { providerSubscriptionId: PADDLE_SUB_ID });
    await staffTo(accountId, 3);
    const { fetched } = paddleReporting([{ status: "active", quantity: 3 }]);

    const report = await run(paddleReader());

    // The whole point of the phase: the row followed the invoice, and it did so
    // from a count fetched off the live subscription, not from anything local.
    expect(fetched).toEqual([`/subscriptions/${PADDLE_SUB_ID}`]);
    expect(await seatsOf(PADDLE_SUB_ID)).toBe(3);
    expect(report.checked).toBe(1);
    expect(report.drifted).toMatchObject([
      { accountId, provider: "paddle", seatsBefore: 5, seatsAfter: 3, direction: "decrease", headcount: 3 },
    ]);
    expect(report.overSubscribed).toEqual([]);
    expect(report.failed).toEqual([]);
    expect(report.startedAt).toEqual(CLOCK);
  });

  test("the same edit with five members still lands, and removes nobody", async () => {
    const { accountId, providerSubscriptionId } = await billedAccount(5);
    await staffTo(accountId, 5);
    const { readQuantity } = gatewaySaying({ [providerSubscriptionId]: 3 });

    const report = await run(readQuantity);

    // Seats are never derived from headcount. The provider billed three, so the
    // row says three even though five people are working — refusing that is how
    // the database ends up disagreeing with the invoice.
    expect(await seatsOf(providerSubscriptionId)).toBe(3);
    expect(await pg.db.accountMember.count({ where: { accountId, status: "active" } })).toBe(5);
    expect(report.drifted).toMatchObject([{ seatsBefore: 5, seatsAfter: 3, direction: "decrease" }]);
    // Reported, and that is the entire consequence: being over-subscribed blocks
    // new invites and nothing else.
    expect(report.overSubscribed).toMatchObject([{ accountId, seats: 3, headcount: 5 }]);
  });

  test("an edit upward is written back too", async () => {
    const { providerSubscriptionId } = await billedAccount(3);
    const { readQuantity } = gatewaySaying({ [providerSubscriptionId]: 5 });

    const report = await run(readQuantity);

    expect(await seatsOf(providerSubscriptionId)).toBe(5);
    expect(report.drifted).toMatchObject([{ seatsBefore: 3, seatsAfter: 5, direction: "increase" }]);
    expect(report.overSubscribed).toEqual([]);
  });

  test("a row that already agrees is not written at all", async () => {
    const { providerSubscriptionId } = await billedAccount(4);
    const before = await subOf(providerSubscriptionId);
    const { readQuantity } = gatewaySaying({ [providerSubscriptionId]: 4 });

    const report = await run(readQuantity);

    expect(report.checked).toBe(1);
    expect(report.drifted).toEqual([]);
    // A no-op write would still stamp updated_at with the injected clock, so
    // this is what tells "wrote the same number" from "wrote nothing".
    const after = await subOf(providerSubscriptionId);
    expect(after.updatedAt).toEqual(before.updatedAt);
    expect(after.updatedAt).not.toEqual(CLOCK);
  });

  test("a quantity the gateway cannot report leaves the row alone — never zero", async () => {
    const { providerSubscriptionId } = await billedAccount(5);
    const before = await subOf(providerSubscriptionId);
    const { readQuantity } = gatewaySaying({ [providerSubscriptionId]: null });

    const report = await run(readQuantity);

    expect(await seatsOf(providerSubscriptionId)).toBe(5);
    expect(report.drifted).toEqual([]);
    expect(report.failed).toEqual([]);
    expect(report.skipped).toMatchObject([
      { providerSubscriptionId, reason: "unreadable_quantity" },
    ]);
    expect((await subOf(providerSubscriptionId)).updatedAt).toEqual(before.updatedAt);
  });

  test("one account's gateway failure does not stop the next", async () => {
    const broken = await billedAccount(2, { providerSubscriptionId: "sub_broken" });
    const healthy = await billedAccount(2, { providerSubscriptionId: "sub_healthy" });
    const { readQuantity, calls } = gatewaySaying({
      sub_broken: new Error("PADDLE_HTTP_500"),
      sub_healthy: 6,
    });

    const report = await run(readQuantity);

    // A sweep that stopped at the first 500 would leave every later account
    // looking exactly like an account that agreed.
    expect(calls.sort()).toEqual(["sub_broken", "sub_healthy"]);
    expect(report.checked).toBe(2);
    expect(await seatsOf("sub_healthy")).toBe(6);
    expect(await seatsOf("sub_broken")).toBe(2);
    expect(report.drifted).toMatchObject([
      { accountId: healthy.accountId, seatsBefore: 2, seatsAfter: 6 },
    ]);
    expect(report.failed).toMatchObject([
      { accountId: broken.accountId, providerSubscriptionId: "sub_broken", reason: "PADDLE_HTTP_500" },
    ]);
  });

  test("a seat change that landed while the gateway was answering is left alone", async () => {
    const { providerSubscriptionId } = await billedAccount(5);
    // A webhook arriving mid-flight: it read the same gateway later than this
    // sweep's fetch did, so its number is the fresher one.
    const readQuantity: SeatQuantityReader = async () => {
      await pg.db.subscription.updateMany({
        where: { providerSubscriptionId },
        data: { seats: 7 },
      });
      return 5;
    };

    const report = await run(readQuantity);

    // The backstop must never overwrite the live channel working with a reading
    // taken before it ran. Without the re-read under the lock this row would be
    // clobbered back to 5 and reported as no drift at all.
    expect(await seatsOf(providerSubscriptionId)).toBe(7);
    expect(report.drifted).toEqual([]);
    expect(report.skipped).toMatchObject([
      { providerSubscriptionId, reason: "changed_during_read" },
    ]);
  });

  test("the gateway is on the network with the billing lock unheld", async () => {
    const { accountId, providerSubscriptionId } = await billedAccount(5);
    const lockFreeDuringFetch: boolean[] = [];
    const readQuantity: SeatQuantityReader = async () => {
      lockFreeDuringFetch.push(await billingLockIsFree(accountId));
      return 3;
    };

    const report = await run(readQuantity);

    // Holding the per-account lock across an HTTP round trip queues every
    // webhook for that account behind the network and blows Prisma's 5s
    // interactive-transaction timeout under load. Reading the count first and
    // locking only to write is the whole reason `observedSeats` exists, so the
    // ordering has to be asserted and not merely commented.
    expect(lockFreeDuringFetch).toEqual([true]);
    expect(await seatsOf(providerSubscriptionId)).toBe(3);
    expect(report.drifted).toMatchObject([{ accountId, seatsBefore: 5, seatsAfter: 3 }]);
  });

  test("a second run immediately after the first finds nothing to do", async () => {
    const { providerSubscriptionId } = await billedAccount(5);
    const { readQuantity } = gatewaySaying({ [providerSubscriptionId]: 3 });

    const first = await run(readQuantity);
    const settled = await subOf(providerSubscriptionId);
    const second = await run(readQuantity);

    expect(first.drifted).toHaveLength(1);
    expect(second.checked).toBe(1);
    expect(second.drifted).toEqual([]);
    expect(second.skipped).toEqual([]);
    expect((await subOf(providerSubscriptionId)).updatedAt).toEqual(settled.updatedAt);
  });
});

describe("subscriptions with no gateway to reconcile against", () => {
  /**
   * Every one of these is given a provider subscription id it has no business
   * having. Without that the rows would be excluded by the null-id filter alone
   * and this test would still pass with the provider filter deleted.
   */
  async function unbilledRows(): Promise<{ id: string; seats: number }[]> {
    const manualUser = await createTestUser(pg.db);
    const manual = await grantManualContract(pg.db, manualUser.id, { seats: 40 });

    const promoUser = await createTestUser(pg.db);
    const promoAccount = await provisionProductAccountForUser(pg.db, promoUser.id);
    const promo = await pg.db.subscription.findFirstOrThrow({
      where: { accountId: promoAccount.id, status: "active" },
    });

    const devUser = await createTestUser(pg.db);
    const dev = await grantDevSubscription(pg.db, devUser.id, { seats: 4 });

    const freeUser = await createTestUser(pg.db);
    const freeAccount = await provisionProductAccountForUser(pg.db, freeUser.id);
    await cancelActiveSubscriptions(pg.db, freeAccount.id);
    const free = await ensureFreeSubscription(pg.db, freeAccount.id);

    const rows = [manual, promo, dev, free];
    return Promise.all(
      rows.map(async (row, i) => {
        const updated = await pg.db.subscription.update({
          where: { id: row.id },
          data: { providerSubscriptionId: `sub_unbilled_${i}` },
        });
        return { id: updated.id, seats: updated.seats };
      })
    );
  }

  test("a manual contract, a promotional grant, a dev grant and a free row are never visited", async () => {
    const before = await unbilledRows();
    const { readQuantity, calls } = gatewaySaying({});

    const report = await run(readQuantity);

    // None of them has a gateway holding an authoritative count, so a sweep that
    // reached them could only overwrite a human's decision with a fetch that has
    // no answer.
    expect(calls).toEqual([]);
    expect(report.checked).toBe(0);
    expect(report.drifted).toEqual([]);
    expect(report.skipped).toEqual([]);
    expect(report.failed).toEqual([]);
    for (const row of before) {
      expect((await pg.db.subscription.findUniqueOrThrow({ where: { id: row.id } })).seats).toBe(
        row.seats
      );
    }
    // The negotiated one specifically: 40 seats a human agreed, still 40.
    const contract = await pg.db.subscription.findFirstOrThrow({
      where: { provider: MANUAL_PROVIDER },
    });
    expect(contract.seats).toBe(40);
  });

  test("a gateway row alongside them is still reconciled", async () => {
    await unbilledRows();
    const { providerSubscriptionId } = await billedAccount(5);
    const { readQuantity } = gatewaySaying({ [providerSubscriptionId]: 2 });

    const report = await run(readQuantity);

    expect(report.checked).toBe(1);
    expect(await seatsOf(providerSubscriptionId)).toBe(2);
  });
});

describe("reading the live count from a gateway", () => {
  test("Paddle reports it on the one live line, not on the price's allowed range", async () => {
    paddleReporting([
      { status: "inactive", quantity: 99 },
      { status: "active", quantity: 3 },
    ]);

    expect(await paddleReader()("paddle", PADDLE_SUB_ID)).toBe(3);
  });

  test("Paddle with several live lines reports nothing rather than guessing", async () => {
    paddleReporting([
      { status: "active", quantity: 3 },
      { status: "active", quantity: 4 },
    ]);

    // Two live lines means the subscription is not one of ours, and summing
    // them would count proration entries as seats.
    expect(await paddleReader()("paddle", PADDLE_SUB_ID)).toBeNull();
  });

  function razorpayStub(entity: Record<string, unknown>) {
    const calls: string[] = [];
    return {
      calls,
      client: {
        subscriptions: {
          fetch: async (id: string) => {
            calls.push(id);
            return entity;
          },
        },
      },
    };
  }

  test("Razorpay reports it as `quantity` on the fetched subscription", async () => {
    const stub = razorpayStub({ status: "active", quantity: 4, has_scheduled_changes: false });

    expect(await razorpayReadSubscriptionQuantity(stub.client as never, "sub_rzp")).toBe(4);
    expect(stub.calls).toEqual(["sub_rzp"]);
  });

  test("Razorpay's cycle counts are not seats", async () => {
    const stub = razorpayStub({
      status: "active",
      total_count: 12,
      paid_count: 3,
      remaining_count: "9",
      has_scheduled_changes: false,
    });

    expect(await razorpayReadSubscriptionQuantity(stub.client as never, "sub_rzp")).toBeNull();
  });

  test("a Razorpay change scheduled for cycle end reads as no count at all", async () => {
    const stub = razorpayStub({ status: "active", quantity: 5, has_scheduled_changes: true });

    // `quantity` is still the count the next charge will move past, so storing
    // it would record a number the invoice has already left behind.
    expect(await razorpayReadSubscriptionQuantity(stub.client as never, "sub_rzp")).toBeNull();
  });

  test("an unconfigured gateway fails the account rather than reporting zero seats", async () => {
    const read = providerSeatReader({} as CheckoutEnv);

    await expect(read("razorpay", "sub_rzp")).rejects.toThrow("RAZORPAY_NOT_CONFIGURED");
    await expect(read("paddle", "sub_pdl")).rejects.toThrow("PADDLE_NOT_CONFIGURED");
  });
});
