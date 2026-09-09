import { z } from "zod";

const UuidSchema = z.uuid();

/**
 * Whether a client-supplied id can be put in front of a `@db.Uuid` column.
 *
 * Not a tenancy check and no substitute for one — it exists because Postgres
 * rejects a malformed uuid at the driver, which surfaces as a 500 rather than
 * the refusal the caller earned.
 */
export function isUuid(value: string): boolean {
  return UuidSchema.safeParse(value).success;
}
