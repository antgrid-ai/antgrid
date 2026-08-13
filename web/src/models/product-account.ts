import type { ProductAccount } from "../generated/prisma/client.js";
import type { Tx } from "../db/index.js";
import { providerForCountry } from "../billing/routing.js";
import type { ProviderId } from "../billing/plans.js";
import { ensureOwnerMembership } from "./account-member.js";

export type ProductAccountRow = ProductAccount;

/** The account this user OWNS, which is not necessarily the account they bill
 *  against — a member owns an idle personal account and bills against their
 *  team's. Anything reading entitlement wants `resolveBillingAccountId`
 *  (models/account-member.ts); this is only its fallback leg. */
export async function findProductAccountByUserId(
  db: Tx,
  userId: string
): Promise<ProductAccountRow | null> {
  return db.productAccount.findUnique({ where: { userId } });
}

/** The `accountId IS NULL OR accountId = <new>` guard is load-bearing, not
 *  defensive noise: `ensureProductAccount` runs on nearly every authenticated
 *  request, and without it a member's `user.account_id` would be stomped back
 *  from their team to their personal account on each one. It reads like a no-op
 *  because the only subject it declines to write is a member. */
async function syncUserAccountId(db: Tx, userId: string, accountId: string): Promise<void> {
  await db.user.updateMany({
    where: { id: userId, OR: [{ accountId: null }, { accountId }] },
    data: { accountId },
  });
}

export async function ensureProductAccount(db: Tx, userId: string): Promise<ProductAccountRow> {
  const account = await db.productAccount.upsert({
    where: { userId },
    create: { userId },
    update: {},
  });
  await syncUserAccountId(db, userId, account.id);
  // Owner membership is healed here, not only backfilled by the migration, so
  // every account has one however it was created. Callers that iterate
  // membership — the entitlement fan-out above all — would otherwise silently
  // skip owners of accounts created after the backfill. Tombstoned accounts are
  // skipped for the same reason the backfill skips them: re-arming an active
  // membership would resurrect entitlement for a user deletion already retired.
  if (!account.deletedAt) await ensureOwnerMembership(db, account.id, userId);
  return account;
}

export async function updateProductAccountCountry(
  db: Tx,
  accountId: string,
  country: string,
  countrySource: "ipinfo" | "manual"
): Promise<ProductAccountRow> {
  return db.productAccount.update({
    where: { id: accountId },
    data: { country: country.toUpperCase(), countrySource },
  });
}

export async function ensureProductAccountCountry(
  db: Tx,
  accountId: string,
  country: string,
  countrySource: "ipinfo" | "manual"
): Promise<ProductAccountRow> {
  const existing = await db.productAccount.findUnique({ where: { id: accountId } });
  if (existing?.country) return existing;
  return updateProductAccountCountry(db, accountId, country, countrySource);
}

function lockedProvider(account: ProductAccountRow): ProviderId | null {
  if (account.billingProvider === "paddle" || account.billingProvider === "razorpay") {
    return account.billingProvider;
  }
  return null;
}

export function isBillingProviderLocked(account: ProductAccountRow): boolean {
  return lockedProvider(account) !== null;
}

/** Read-only gateway routing — does not persist billingProvider. */
export function previewBillingProvider(
  account: ProductAccountRow,
  country: string | null
): ProviderId {
  return lockedProvider(account) ?? providerForCountry(country);
}

/** Persist billing provider on checkout confirm; immutable once set. */
export async function lockBillingProvider(
  db: Tx,
  accountId: string,
  country: string
): Promise<ProviderId> {
  const account = await db.productAccount.findUniqueOrThrow({ where: { id: accountId } });
  const existing = lockedProvider(account);
  if (existing) return existing;

  const provider = providerForCountry(country);
  await db.productAccount.update({
    where: { id: accountId },
    data: {
      billingProvider: provider,
      country: country.toUpperCase(),
      countrySource: account.countrySource ?? "manual",
    },
  });
  return provider;
}
