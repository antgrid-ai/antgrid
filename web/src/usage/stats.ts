// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { DB } from "../db/index.js";
import type { UsageDaily } from "../generated/prisma/client.js";
import type { ConnectionSummary } from "../relay/push.js";
import { isMobilePlatform, MOBILE_PLATFORM_SQL } from "../models/device.js";
import { collapseRelaySlots, DAY_MS, utcDayKey } from "./sampler.js";

const HISTORY_DAYS = 30;
const SIGNUP_WEEKS = 12;

// A desktop's main row is kind='agent' (also its local bridge identity), so it
// lands in "machine"; "controller" is the separate kind='app' row a desktop
// registers only once it remote-controls another machine.
type DeviceClass = "phone" | "machine" | "controller";

export type UsageStats = {
  users: { total: number; new1d: number; new7d: number; new30d: number };
  waitlist: number;
  signupsByWeek: { week: string; count: number }[];
  subscriptions: { tier: string; status: string; promotional: boolean; count: number }[];
  devices: {
    class: DeviceClass;
    platform: string;
    devices: number;
    users: number;
    heartbeat7d: number;
    heartbeat30d: number;
  }[];
  reach: { phone: number; machine: number; controller: number; machineAndPhone: number };
  installs: { platform: string; d1: number; d7: number; d30: number }[];
  events7d: { name: string; events: number; installs: number }[];
  history: (Omit<UsageDaily, "day" | "updatedAt"> & { day: string })[];
};

// The signup window must start on the Monday date_trunc('week') buckets on, or
// the oldest "Week of" row silently counts only part of its week.
function weekStartUtc(d: Date): Date {
  const daysSinceMonday = (d.getUTCDay() + 6) % 7;
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - daysSinceMonday));
}

export async function loadUsageStats(db: DB, now = new Date()): Promise<UsageStats> {
  const ago = (days: number) => new Date(now.getTime() - days * DAY_MS);
  const d1 = ago(1);
  const d7 = ago(7);
  const d30 = ago(30);

  const [users, waitlist, signupsByWeek, subscriptions, devices, reach, installs, events7d, history] =
    await Promise.all([
      db.$queryRaw<UsageStats["users"][]>`
        SELECT count(*)::int AS total,
               count(*) FILTER (WHERE "createdAt" >= ${d1})::int  AS "new1d",
               count(*) FILTER (WHERE "createdAt" >= ${d7})::int  AS "new7d",
               count(*) FILTER (WHERE "createdAt" >= ${d30})::int AS "new30d"
        FROM "user"`,
      db.waitlistSignup.count(),
      db.$queryRaw<UsageStats["signupsByWeek"]>`
        SELECT to_char(date_trunc('week', "createdAt"), 'YYYY-MM-DD') AS week, count(*)::int AS count
        FROM "user" WHERE "createdAt" >= ${weekStartUtc(ago(SIGNUP_WEEKS * 7))}
        GROUP BY 1 ORDER BY 1 DESC`,
      db.subscription.groupBy({ by: ["tier", "status", "promotional"], _count: { _all: true } }),
      db.$queryRaw<UsageStats["devices"]>`
        SELECT CASE WHEN kind = 'agent' THEN 'machine'
                    WHEN ${MOBILE_PLATFORM_SQL} THEN 'phone'
                    ELSE 'controller' END AS class,
               platform,
               count(*)::int                                            AS devices,
               count(DISTINCT user_id)::int                             AS users,
               count(*) FILTER (WHERE last_seen_at >= ${d7})::int        AS "heartbeat7d",
               count(*) FILTER (WHERE last_seen_at >= ${d30})::int       AS "heartbeat30d"
        FROM devices WHERE revoked_at IS NULL
        GROUP BY 1, 2 ORDER BY 1, 2`,
      db.$queryRaw<UsageStats["reach"][]>`
        WITH per_user AS (
          SELECT user_id,
                 bool_or(kind = 'app' AND ${MOBILE_PLATFORM_SQL})         AS phone,
                 bool_or(kind = 'app' AND NOT (${MOBILE_PLATFORM_SQL})) AS controller,
                 bool_or(kind = 'agent')                                      AS machine
          FROM devices WHERE revoked_at IS NULL GROUP BY user_id
        )
        SELECT count(*) FILTER (WHERE phone)::int               AS phone,
               count(*) FILTER (WHERE controller)::int          AS controller,
               count(*) FILTER (WHERE machine)::int             AS machine,
               count(*) FILTER (WHERE machine AND phone)::int   AS "machineAndPhone"
        FROM per_user`,
      db.$queryRaw<UsageStats["installs"]>`
        SELECT platform,
               count(DISTINCT install_id) FILTER (WHERE created_at >= ${d1})::int AS d1,
               count(DISTINCT install_id) FILTER (WHERE created_at >= ${d7})::int AS d7,
               count(DISTINCT install_id)::int                                    AS d30
        FROM analytic_event WHERE created_at >= ${d30}
        GROUP BY platform ORDER BY d30 DESC, platform`,
      db.$queryRaw<UsageStats["events7d"]>`
        SELECT name, count(*)::int AS events, count(DISTINCT install_id)::int AS installs
        FROM analytic_event WHERE created_at >= ${d7}
        GROUP BY name ORDER BY events DESC, name`,
      db.usageDaily.findMany({ omit: { updatedAt: true }, orderBy: { day: "desc" }, take: HISTORY_DAYS }),
    ]);

  return {
    users: users[0],
    waitlist,
    signupsByWeek,
    subscriptions: subscriptions
      .map((s) => ({ tier: s.tier, status: s.status, promotional: s.promotional, count: s._count._all }))
      .sort((a, b) => b.count - a.count),
    devices,
    reach: reach[0],
    installs,
    events7d,
    history: history.map(({ day, ...counts }) => ({ day: utcDayKey(day), ...counts })),
  };
}

export type LiveRelaySummary = {
  sockets: number;
  machines: number;
  phones: number;
  controllers: number;
  /** Connected ids with no unrevoked `devices` row, whatever type the relay reported. */
  unknown: number;
};

export async function summarizeLiveRelay(
  db: DB,
  connections: ConnectionSummary[],
): Promise<LiveRelaySummary> {
  const { devices } = collapseRelaySlots(connections);
  const ids = [...devices.keys()];
  const rows = ids.length
    ? await db.device.findMany({
        where: { deviceId: { in: ids }, revokedAt: null },
        select: { deviceId: true, kind: true, platform: true },
      })
    : [];
  // A device uuid is minted once with one kind, so any row sharing it classifies it.
  const byId = new Map(rows.map((r) => [r.deviceId, r]));
  let machines = 0;
  let phones = 0;
  let controllers = 0;
  let unknown = 0;
  for (const id of ids) {
    const row = byId.get(id);
    if (row === undefined) unknown++;
    else if (row.kind === "agent") machines++;
    else if (isMobilePlatform(row.platform)) phones++;
    else controllers++;
  }
  return { sockets: connections.length, machines, phones, controllers, unknown };
}
