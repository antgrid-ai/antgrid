// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { AuthContext } from "better-auth";
import { decryptOAuthToken, setTokenUtil } from "better-auth/oauth2";
import type { DB } from "../db/index.js";
import type { Auth } from "../auth/better-auth.js";
import { AppleTokenError, type AppleTokenClient } from "../auth/apple-tokens.js";

const APPLE_PROVIDER_ID = "apple";

/** The context Better-Auth's token codec takes. `$context` is typed against
 *  our exact options, which the codec's general signature does not accept;
 *  it is the same object at runtime. */
async function tokenContext(auth: Auth): Promise<AuthContext> {
  return (await auth.$context) as unknown as AuthContext;
}

export type StoreAppleAuthorizationResult = "stored" | "invalid_code" | "not_this_user";

/**
 * Keep the refresh token for a native Sign in with Apple, so deleting the
 * account can revoke it.
 *
 * The app signs in with Apple's id token, from which Better-Auth creates the
 * account row but keeps no refresh token; the app then hands over the one-time
 * authorization code from the same sign-in, and this trades it for one.
 *
 * The tokens are written only onto an Apple account this user already has for
 * the same Apple user. A code is proof of an Apple sign-in, not of which
 * Antgrid user did it, so without that check a signed-in user could park
 * someone else's Apple tokens on their own row.
 *
 * Written through Better-Auth's own token codec, so the row reads back exactly
 * like one its web callback wrote under `account.encryptOAuthTokens`.
 */
export async function storeAppleNativeAuthorization(
  db: DB,
  auth: Auth,
  apple: AppleTokenClient,
  args: { userId: string; code: string },
): Promise<StoreAppleAuthorizationResult> {
  let tokens;
  try {
    tokens = await apple.exchangeNativeCode(args.code);
  } catch (err) {
    // invalid_grant covers a code that expired (five minutes), was already
    // used, or was issued to another client. Anything else is Apple or the
    // network failing, which the caller should not report as a bad request.
    if (err instanceof AppleTokenError && err.code === "invalid_grant") return "invalid_code";
    throw err;
  }
  const ctx = await tokenContext(auth);
  const { count } = await db.account.updateMany({
    where: { userId: args.userId, providerId: APPLE_PROVIDER_ID, accountId: tokens.appleUserId },
    data: {
      refreshToken: await setTokenUtil(tokens.refreshToken, ctx),
      idToken: tokens.idToken,
      accessToken: tokens.accessToken ? await setTokenUtil(tokens.accessToken, ctx) : null,
      accessTokenExpiresAt: tokens.accessTokenExpiresAt ?? null,
    },
  });
  if (count === 0) {
    // The exchange already minted Apple a session we will never use.
    const clientId = apple.clientIdOf(tokens.idToken);
    if (clientId) {
      await apple.revoke({ refreshToken: tokens.refreshToken, clientId }).catch(() => {});
    }
    return "not_this_user";
  }
  return "stored";
}

/**
 * Revoke every Apple refresh token held for `userId`, as App Review requires
 * when an account is deleted.
 *
 * Best-effort by design: the deletion goes ahead whatever Apple answers, so a
 * failure is logged rather than thrown. An account with no refresh token is a
 * native sign-in whose code never arrived; there is nothing to revoke with.
 */
export async function revokeAppleAuthorizations(
  db: DB,
  auth: Auth,
  apple: AppleTokenClient,
  userId: string,
): Promise<void> {
  const ctx = await tokenContext(auth);
  const accounts = await db.account.findMany({
    where: { userId, providerId: APPLE_PROVIDER_ID, refreshToken: { not: null } },
    select: { id: true, refreshToken: true, idToken: true },
  });
  await Promise.all(
    accounts.map(async (account) => {
      const clientId = apple.clientIdOf(account.idToken);
      if (!clientId) {
        console.error("[account] Apple token issued to an unknown client; not revoked", {
          userId,
          accountId: account.id,
        });
        return;
      }
      try {
        const refreshToken = await decryptOAuthToken(account.refreshToken!, ctx);
        await apple.revoke({ refreshToken, clientId });
      } catch (err) {
        console.error("[account] Apple token revocation failed during deletion; continuing", {
          userId,
          accountId: account.id,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }),
  );
}
