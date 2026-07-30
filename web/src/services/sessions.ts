import { fetchUserConnections, type RelayPushConfig } from "../relay/push.js";
import type { DeviceRow } from "../models/device.js";

/** A live agent machine owned by the signed-in user, with its running-session count. */
export type UserSession = {
  deviceUuid: string;
  displayName: string;
  connectedAt: number;
  /** Open project streams on this machine — the paid axis, summed per user. */
  openStreamCount: number;
};

/**
 * The relay feed is already scoped to this user (filtered relay-side by the
 * userId it stores), so attribution is done. Here we keep the live `agent`
 * connections — one per machine, since v3 agents register under a bare account
 * `deviceUuid` and multiplex projects as sealed streams — and join display
 * names from the user's web device rows. Returns null when the relay is
 * unreachable so the caller can render an explicit "couldn't reach" state
 * rather than a misleading empty list.
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
    sessions.push({
      deviceUuid: c.deviceId,
      displayName: uuidToName.get(c.deviceId) ?? c.deviceId,
      connectedAt: c.connectedAt,
      openStreamCount: c.openStreamCount,
    });
  }
  return sessions;
}

/**
 * The number the relay enforces `sessionLimit` against: streams summed across
 * every live agent connection, NOT the machine count. An idle agent holding no
 * project stream costs nothing, so it must not consume the displayed quota.
 */
export function runningSessionCount(sessions: UserSession[]): number {
  return sessions.reduce((n, s) => n + s.openStreamCount, 0);
}
