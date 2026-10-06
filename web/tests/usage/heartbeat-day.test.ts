// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { test, expect } from "bun:test";
import type { DB } from "../../src/db/index.js";
import { heartbeatDayRecorder } from "../../src/usage/heartbeat-day.js";

// Records each INSERT's day parameter; `hold` makes only the next insert wait until released.
function fakeDb() {
  const days: string[] = [];
  let gate: Promise<void> | null = null;
  const db = {
    $executeRaw: async (_sql: TemplateStringsArray, day: string) => {
      days.push(day);
      const held = gate;
      gate = null;
      if (held) await held;
      return 1;
    },
  } as unknown as DB;
  return {
    db,
    days,
    hold() {
      let release!: () => void;
      gate = new Promise((r) => (release = r));
      return release;
    },
  };
}

const T1 = new Date("2026-10-01T10:00:00Z");

test("writes a device once per UTC day", async () => {
  const f = fakeDb();
  const record = heartbeatDayRecorder(f.db);
  await record("u", "d", T1);
  await record("u", "d", new Date("2026-10-01T10:01:00Z"));
  await record("u", "other", T1);
  await record("u", "d", new Date("2026-10-02T00:00:01Z"));
  expect(f.days).toEqual(["2026-10-01", "2026-10-01", "2026-10-02"]);
});

test("a heartbeat in flight across midnight does not suppress the new day's write", async () => {
  const f = fakeDb();
  const record = heartbeatDayRecorder(f.db);
  const release = f.hold();
  const late = record("u", "d", new Date("2026-10-01T23:59:59Z"));
  await record("u", "other", new Date("2026-10-02T00:00:00Z"));
  release();
  await late;
  await record("u", "d", new Date("2026-10-02T00:00:30Z"));
  expect(f.days).toEqual(["2026-10-01", "2026-10-02", "2026-10-02"]);
});
