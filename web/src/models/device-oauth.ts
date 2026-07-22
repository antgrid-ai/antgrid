import type { Auth } from "../auth/better-auth.js";

/**
 * Create an OAuth client representing a Antgrid device. Stores
 * `{userId, deviceUuid, ed25519Pub}` in the client's metadata; these become
 * `pk`/`uid`/`deviceUuid` claims when `customAccessTokenClaims` runs on token mint.
 *
 * Returns `{clientId, clientSecret}`. The secret is only revealed at creation
 * time — the app stores it in the OS keychain and the server never needs it again.
 *
 * Uses `auth.api.adminCreateOAuthClient` (SERVER_ONLY, no session required).
 * `redirect_uris: []` is required by the Zod schema even for M2M-only clients.
 */
export async function createDeviceOAuthClient(
  auth: Auth,
  args: {
    userId: string;
    deviceUuid: string;
    ed25519Pub: string;
    displayName: string;
  },
  /** Caller's session headers — required by adminCreateOAuthClient's session check. */
  headers?: Headers,
): Promise<{ clientId: string; clientSecret: string }> {
  const result = await auth.api.adminCreateOAuthClient({
    // adminCreateOAuthClient is SERVER_ONLY but still calls assertClientPrivileges
    // which requires a session. Thread the caller's request headers through so
    // Better-Auth can resolve the session cookie.
    headers,
    body: {
      // M2M-only client (client_credentials). Better-Auth requires at least one
      // redirect_uri even for non-interactive clients, so we supply the OOB sentinel.
      redirect_uris: ["urn:ietf:wg:oauth:2.0:oob"],
      client_name: `antgrid-device-${args.deviceUuid}`,
      grant_types: ["client_credentials"],
      scope: "agent",
      skip_consent: true,
      metadata: {
        userId: args.userId,
        deviceUuid: args.deviceUuid,
        ed25519Pub: args.ed25519Pub,
      },
    },
  });
  return {
    clientId: result.client_id,
    clientSecret: result.client_secret!,
  };
}

/**
 * Delete the OAuth client. Idempotent — treats 404 as success.
 *
 * Uses `auth.api.deleteOAuthClient` which requires a user session context;
 * caller must thread request headers through. Use only from within session-authed
 * route handlers. For server-side cleanup without a session, use the internal
 * adapter directly (see api-notes.md).
 */
export async function deleteDeviceOAuthClient(
  auth: Auth,
  clientId: string,
  headers: Headers,
): Promise<void> {
  try {
    await auth.api.deleteOAuthClient({ body: { client_id: clientId }, headers });
  } catch (err) {
    if ((err as { status?: number }).status === 404) return;
    throw err;
  }
}
