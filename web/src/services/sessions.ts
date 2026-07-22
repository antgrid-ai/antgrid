import { fetchUserConnections, type RelayPushConfig } from "../relay/push.js";
import type { DeviceRow } from "../models/device.js";

/** A running remote agent owned by the signed-in user (the paid axis). */
export type UserSession = {
  deviceUuid: string;
  projectId: string;
  displayName: string;
  connectedAt: number;
};

/**
 * The relay feed is already scoped to this user (filtered relay-side by the
 * userId it stores), so attribution is done. Here we keep only running project
 * agents — compound (`deviceUuid.projectId`) `agent` registrations, excluding
 * the bare control plane and `app` devices — and join display names from the
 * user's web device rows. Returns null when the relay is unreachable so the
 * caller can render an explicit "couldn't reach" state rather than a misleading
 * empty list.
 */
export async function listUserSessions(
  relay: RelayPushConfig,
  userId: string,
  devices: DeviceRow[],
  fetchImpl: typeof fetch = fetch,
): Promise<UserSession[] | null> {
  let connections;
  try {
    connections = await fetchUserConnections(relay, userId, fetchImpl);
  } catch (e) {
    console.warn("[sessions] relay fetch failed", e);
    return null;
  }

  const uuidToName = new Map(devices.map((d) => [d.deviceId, d.displayName]));
  const sessions: UserSession[] = [];
  for (const c of connections) {
    if (c.deviceType !== "agent") continue;
    const dot = c.deviceId.indexOf(".");
    if (dot < 0) continue; // bare control plane — not a billable session
    const deviceUuid = c.deviceId.slice(0, dot);
    sessions.push({
      deviceUuid,
      projectId: c.deviceId.slice(dot + 1),
      displayName: uuidToName.get(deviceUuid) ?? deviceUuid,
      connectedAt: c.connectedAt,
    });
  }
  return sessions;
}
