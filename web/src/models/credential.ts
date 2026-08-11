import type { Tx } from "../db/index.js";

/** `providerId` Better-Auth writes on the account row holding a password hash.
 *  Social rows use the provider name ("github"/"google") and carry no password. */
export const CREDENTIAL_PROVIDER_ID = "credential";

/**
 * Whether `userId` can sign in with a password.
 *
 * Drives the /account card's set-vs-change split, and the two are NOT
 * interchangeable: `auth.api.setPassword` rejects a user who already has one
 * (PASSWORD_ALREADY_SET) and `changePassword` requires the current password.
 */
export async function hasPasswordCredential(db: Tx, userId: string): Promise<boolean> {
  const row = await db.account.findFirst({
    where: { userId, providerId: CREDENTIAL_PROVIDER_ID, password: { not: null } },
    select: { id: true },
  });
  return row !== null;
}

/**
 * Drop the password of a user whose address is about to be verified by a path
 * that never asked for that password.
 *
 * Sign-up mints the credential row BEFORE the address is proven
 * (api/routes/sign-up.mjs) and `requireEmailVerification` only withholds the
 * session, so anyone may plant a password on an address they don't own. If the
 * real owner then arrives by magic link or GitHub/Google, `emailVerified` flips
 * to true as a side effect of THAT sign-in and the planted hash silently
 * becomes a live way in. Nothing else breaks the chain: `email` is unique, so
 * the owner lands on the squatter's row.
 *
 * Call this only where a foreign path is about to verify a still-unverified
 * user. The verification link itself is exempt on purpose — it is delivered to
 * the address in question, so clicking it IS the proof the sign-up lacked.
 */
export async function purgeUnprovenPasswordCredential(
  db: Tx,
  userId: string
): Promise<void> {
  const { count } = await db.account.deleteMany({
    where: { userId, providerId: CREDENTIAL_PROVIDER_ID },
  });
  if (count > 0) {
    console.warn(
      JSON.stringify({
        evt: "auth.password.unproven_purged",
        userId,
        count,
        at: new Date().toISOString(),
      })
    );
  }
}

/**
 * Collapse a user down to a single password row, keeping the newest.
 *
 * `setPassword` is check-then-create (api/routes/update-user.mjs) and the table
 * has no unique index on (userId, providerId), so two submits that interleave
 * around its own lookup each insert a row. They diverge on the NEXT change:
 * `changePassword` rewrites one row by id while sign-in picks a credential with
 * an unordered `.find()`, which leaves the superseded password still working.
 *
 * Converges under concurrency: whichever call runs last sees every row and
 * keeps the same one. `id` breaks ties and is what makes that true — two rows
 * inserted in the same millisecond order arbitrarily under `createdAt` alone,
 * so two concurrent prunes could each keep the row the other deleted and
 * between them leave the user with NO password.
 */
export async function pruneDuplicatePasswordCredentials(
  db: Tx,
  userId: string
): Promise<void> {
  const rows = await db.account.findMany({
    where: { userId, providerId: CREDENTIAL_PROVIDER_ID },
    select: { id: true },
    orderBy: [{ createdAt: "desc" }, { id: "desc" }],
  });
  if (rows.length < 2) return;
  await db.account.deleteMany({
    where: { id: { in: rows.slice(1).map((r) => r.id) } },
  });
}
