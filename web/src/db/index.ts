import { PrismaClient } from "../generated/prisma/client.js";
import type { Prisma } from "../generated/prisma/client.js";
import { PrismaPg } from "@prisma/adapter-pg";

/** The application database handle. */
export type DB = PrismaClient;

/** A handle that may be the top-level client or a transaction. Helpers that
 *  may run inside or outside a transaction take this. */
export type Tx = PrismaClient | Prisma.TransactionClient;

/** Back-compat alias: previously the union of postgres.js handle + tx. */
export type SqlRunner = Tx;

export function createDb(url: string): DB {
  const adapter = new PrismaPg({ connectionString: url });
  return new PrismaClient({
    adapter,
    log: ["warn", "error"],
  });
}
