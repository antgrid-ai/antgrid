// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { DB } from "../db/index.js";
import { utcDayKey } from "./sampler.js";

/**
 * Records that a device heartbeated on the current UTC day, which is the
 * sampler's per-day activity evidence (see foldActiveDevices in sampler.ts).
 *
 * A machine heartbeats every minute, so the recorder remembers what it has
 * already written today and skips the repeat round trip; the table's primary
 * key still absorbs repeats from the other deploy colour or after a restart.
 *
 * Never throws: a deploy serves requests before `prisma migrate deploy` has
 * created the table, and a usage statistic is not worth refusing a device's
 * liveness report. A failed write is not remembered, so the next heartbeat
 * retries it.
 */
export function heartbeatDayRecorder(db: DB) {
  let day = "";
  let written = new Set<string>();
  return async (userId: string, deviceId: string, now: Date): Promise<void> => {
    const today = utcDayKey(now);
    if (today !== day) {
      day = today;
      written = new Set();
    }
    // Held across the await: a heartbeat straddling midnight must not mark the
    // device as written in the new day's set.
    const set = written;
    const key = `${userId}\n${deviceId}`;
    if (set.has(key)) return;
    try {
      await db.$executeRaw`
        INSERT INTO usage_heartbeat_seen (day, user_id, device_id)
        VALUES (${today}::date, ${userId}, ${deviceId})
        ON CONFLICT DO NOTHING`;
      set.add(key);
    } catch (e) {
      console.warn("[usage] heartbeat day not recorded", e);
    }
  };
}
