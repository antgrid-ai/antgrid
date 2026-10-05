// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { baseSlotDeviceId } from "antgrid-wire";
import type { DB, Tx } from "../db/index.js";
import { MOBILE_PLATFORM_SQL } from "../models/device.js";
import { fetchConnections, type ConnectionSummary, type RelayPushConfig } from "../relay/push.js";

export const DAY_MS = 86_400_000;
const SAMPLE_INTERVAL_MS = 5 * 60_000;
// Today and yesterday. Older device-level rows are already folded into
// usage_daily, so keeping them would only retain per-device presence history.
// Applies to usage_relay_seen and usage_heartbeat_seen alike.
const SEEN_RETENTION_DAYS = 2;

type LiveRelayDevices = {
  /** Bare account deviceUuid → type. Per-machine app slots collapse into one. */
  devices: Map<string, ConnectionSummary["deviceType"]>;
  apps: number;
  agents: number;
};

export function collapseRelaySlots(connections: ConnectionSummary[]): LiveRelayDevices {
  const devices = new Map<string, ConnectionSummary["deviceType"]>();
  for (const c of connections) devices.set(baseSlotDeviceId(c.deviceId), c.deviceType);
  let apps = 0;
  let agents = 0;
  for (const type of devices.values()) {
    if (type === "app") apps++;
    else agents++;
  }
  return { devices, apps, agents };
}

export function utcDayKey(now: Date): string {
  return now.toISOString().slice(0, 10);
}

type UsageSampleResult = { day: string; relay: "ok" | "unavailable" | "unconfigured" };

/**
 * Fold one day's device activity into its usage_daily row. A device counts as
 * active on a day if it heartbeated that day (a usage_heartbeat_seen row,
 * matched exactly on user and device id), or if the relay held it at any
 * sample that day. The relay branch is what counts a desktop controller row,
 * which never heartbeats.
 *
 * devices.device_id is unique only per user, and the relay snapshot carries no
 * user id. A relay-held id therefore activates exactly one unrevoked row (the
 * most recently seen); matching every row would count a UUID re-provisioned
 * under a second account twice.
 *
 * The row is written only when a value would rise, so updated_at means "last
 * changed".
 */
async function foldActiveDevices(tx: Tx, day: string) {
  await tx.$executeRaw`
    WITH seen AS (
      SELECT count(*) FILTER (WHERE device_type = 'app')::int   AS apps,
             count(*) FILTER (WHERE device_type = 'agent')::int AS agents
      FROM usage_relay_seen WHERE day = ${day}::date
    ), active AS (
      SELECT d.id, d.user_id, d.kind, d.platform FROM devices d
      JOIN usage_heartbeat_seen h
        ON h.user_id = d.user_id AND h.device_id = d.device_id AND h.day = ${day}::date
      WHERE d.revoked_at IS NULL
      UNION
      SELECT r.id, r.user_id, r.kind, r.platform FROM (
        SELECT DISTINCT ON (d.device_id) d.id, d.user_id, d.kind, d.platform
        FROM devices d
        WHERE d.revoked_at IS NULL
          AND d.device_id IN (SELECT s.device_id FROM usage_relay_seen s WHERE s.day = ${day}::date)
        ORDER BY d.device_id, d.last_seen_at DESC NULLS LAST, d.activated_at DESC
      ) r
    ), a AS (
      SELECT count(DISTINCT user_id)::int AS users,
             count(*) FILTER (WHERE kind = 'app' AND ${MOBILE_PLATFORM_SQL})::int       AS mobile,
             count(*) FILTER (WHERE kind = 'app' AND NOT (${MOBILE_PLATFORM_SQL}))::int AS desktop,
             count(*) FILTER (WHERE kind = 'agent')::int                                AS agents
      FROM active
    )
    UPDATE usage_daily u SET
      active_users        = GREATEST(u.active_users, a.users),
      active_mobile_apps  = GREATEST(u.active_mobile_apps, a.mobile),
      active_desktop_apps = GREATEST(u.active_desktop_apps, a.desktop),
      active_agents       = GREATEST(u.active_agents, a.agents),
      relay_seen_apps     = GREATEST(u.relay_seen_apps, seen.apps),
      relay_seen_agents   = GREATEST(u.relay_seen_agents, seen.agents),
      updated_at          = now()
    FROM a, seen
    WHERE u.day = ${day}::date
      AND (u.active_users < a.users
        OR u.active_mobile_apps < a.mobile
        OR u.active_desktop_apps < a.desktop
        OR u.active_agents < a.agents
        OR u.relay_seen_apps < seen.apps
        OR u.relay_seen_agents < seen.agents)`;
}

/**
 * Fold one observation into today's usage_daily row, and re-fold yesterday's
 * from its retained heartbeat and relay rows so activity recorded just before
 * midnight, or while no sampler ran, still lands on the right day. The relay
 * peaks come from the live snapshot and so apply to today only.
 *
 * Every write is a GREATEST or a set union. Both deploy colours run this, and
 * the idle colour's RELAY_INTERNAL_URL is its own client-less relay, so its
 * samples must be unable to lower anything the live colour recorded.
 */
export async function recordUsageSample(
  db: DB,
  relay: RelayPushConfig,
  opts: { now?: Date; fetchImpl?: typeof fetch } = {},
): Promise<UsageSampleResult> {
  const now = opts.now ?? new Date();
  const day = utcDayKey(now);
  const dayStart = new Date(`${day}T00:00:00.000Z`);
  const yesterday = utcDayKey(new Date(dayStart.getTime() - DAY_MS));

  let live: LiveRelayDevices | null = null;
  let relayState: UsageSampleResult["relay"] = "unconfigured";
  if (relay.baseUrl && relay.secret) {
    try {
      live = collapseRelaySlots(await fetchConnections(relay, opts.fetchImpl));
      relayState = "ok";
    } catch (e) {
      console.warn("[usage] relay snapshot unavailable; recording heartbeat activity only", e);
      relayState = "unavailable";
    }
  }

  await db.$transaction(async (tx) => {
    await tx.$executeRaw`INSERT INTO usage_daily (day) VALUES (${day}::date) ON CONFLICT DO NOTHING`;
    // Only when yesterday left evidence, so a fresh install does not fabricate
    // an all-zero row for a day it never observed.
    await tx.$executeRaw`
      INSERT INTO usage_daily (day)
      SELECT ${yesterday}::date
      WHERE EXISTS (SELECT 1 FROM usage_heartbeat_seen WHERE day = ${yesterday}::date)
         OR EXISTS (SELECT 1 FROM usage_relay_seen WHERE day = ${yesterday}::date)
      ON CONFLICT DO NOTHING`;

    if (live) {
      if (live.devices.size > 0) {
        await tx.usageRelaySeen.createMany({
          // Sorted so concurrent samplers take row locks in one order and cannot deadlock.
          data: [...live.devices]
            .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
            .map(([deviceId, deviceType]) => ({ day: dayStart, deviceId, deviceType })),
          skipDuplicates: true,
        });
      }
      const total = live.apps + live.agents;
      await tx.$executeRaw`
        UPDATE usage_daily SET
          relay_peak_apps   = GREATEST(relay_peak_apps, ${live.apps}::int),
          relay_peak_agents = GREATEST(relay_peak_agents, ${live.agents}::int),
          relay_peak_total  = GREATEST(relay_peak_total, ${total}::int)
        WHERE day = ${day}::date
          AND (relay_peak_apps < ${live.apps}::int
            OR relay_peak_agents < ${live.agents}::int
            OR relay_peak_total < ${total}::int)`;
    }

    await foldActiveDevices(tx, yesterday);
    await foldActiveDevices(tx, day);

    await tx.$executeRaw`
      DELETE FROM usage_relay_seen WHERE day <= ${day}::date - ${SEEN_RETENTION_DAYS}::int`;
    await tx.$executeRaw`
      DELETE FROM usage_heartbeat_seen WHERE day <= ${day}::date - ${SEEN_RETENTION_DAYS}::int`;
  });

  return { day, relay: relayState };
}

export function startUsageSampler(db: DB, relay: RelayPushConfig) {
  let stopped = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  // A deploy starts the container before `prisma migrate deploy`, so the first
  // sample can fail on a missing table; the catch and the next tick cover it.
  async function tick() {
    try {
      await recordUsageSample(db, relay);
    } catch (e) {
      console.warn("[usage] sample failed", e);
    }
    if (!stopped) {
      timer = setTimeout(tick, SAMPLE_INTERVAL_MS);
      timer.unref();
    }
  }
  void tick();
  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
  };
}
