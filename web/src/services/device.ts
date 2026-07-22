import type { DB } from "../db/index.js";
import { markDeviceRevoked } from "../models/device.js";
import { deleteDeviceOAuthClient } from "../models/device-oauth.js";
import { pushRevoke, type RelayPushConfig } from "../relay/push.js";
import type { Auth } from "../auth/better-auth.js";

export type RevokeResult = "revoked" | "not_found";

/**
 * Revoke an active device belonging to `userId`. Idempotent: returns
 * `"not_found"` if the device is already revoked or doesn't belong to the user.
 * Shared by the JSON and UI delete routes.
 *
 * `auth` and `headers` are required to delete the Better-Auth OAuth client
 * associated with the device (session-authed endpoint). For non-HTTP callers
 * (e.g. background jobs) pass an empty `new Headers()` — the OAuth client
 * deletion will fail silently; use the internal adapter directly in that case.
 */
export async function revokeUserDevice(
  db: DB,
  relay: RelayPushConfig,
  auth: Auth,
  args: { userId: string; deviceUuid: string; headers: Headers }
): Promise<RevokeResult> {
  const device = await db.device.findFirst({
    where: { id: args.deviceUuid, userId: args.userId, revokedAt: null },
    select: { id: true, deviceId: true, oauthClientId: true },
  });
  if (!device) return "not_found";
  if (device.oauthClientId) {
    await deleteDeviceOAuthClient(auth, device.oauthClientId, args.headers);
  }
  await markDeviceRevoked(db, device.id);
  await pushRevoke(relay, device.deviceId);
  return "revoked";
}
