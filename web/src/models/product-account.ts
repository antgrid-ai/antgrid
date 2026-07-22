import type { ProductAccount } from "../generated/prisma/client.js";
import type { Tx } from "../db/index.js";
import { providerForCountry } from "../billing/routing.js";
import type { ProviderId } from "../billing/plans.js";

export type ProductAccountRow = ProductAccount;

/** Owner user for this billing account (v1: 1:1; future: members join same account). */
export async function findProductAccountByUserId(
  db: Tx,
  userId: string
): Promise<ProductAccountRow | null> {
  return db.productAccount.findUnique({ where: { userId } });
}

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
