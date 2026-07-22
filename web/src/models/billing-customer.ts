import type { BillingCustomer } from "../generated/prisma/client.js";
import type { Tx } from "../db/index.js";

export type BillingCustomerRow = BillingCustomer;

export async function findBillingCustomer(
  db: Tx,
  accountId: string,
  provider: string
): Promise<BillingCustomerRow | null> {
  return db.billingCustomer.findUnique({
    where: { accountId_provider: { accountId, provider } },
  });
}

export async function hasBillingCustomer(db: Tx, accountId: string): Promise<boolean> {
  const row = await db.billingCustomer.findFirst({
    where: { accountId },
    select: { accountId: true },
  });
  return row !== null;
}

export async function upsertBillingCustomer(
  db: Tx,
  args: { accountId: string; provider: string; providerCustomerId: string }
): Promise<BillingCustomerRow> {
  return db.billingCustomer.upsert({
    where: { accountId_provider: { accountId: args.accountId, provider: args.provider } },
    create: {
      accountId: args.accountId,
      provider: args.provider,
      providerCustomerId: args.providerCustomerId,
    },
    update: { providerCustomerId: args.providerCustomerId },
  });
}
