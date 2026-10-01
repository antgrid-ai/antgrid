// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { test, expect, beforeAll, afterAll, beforeEach, spyOn } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { createTestUser, createTestDevice } from "../helpers/fixtures.js";
import { recordUsageSample } from "../../src/usage/sampler.js";

let pg: PgHandle;
beforeAll(async () => {
  pg = await startTestPg();
});
afterAll(async () => {
  await pg.stop();
});
beforeEach(async () => {
  await pg.truncate();
});

const RELAY = { baseUrl: "http://relay.test", secret: "s".repeat(32) };
const NOON = new Date("2026-10-01T12:00:00Z");
const DAY = new Date("2026-10-01T00:00:00.000Z");

type Held = { id: string; type: "agent" | "app" };

function fakeRelay(held: Held[]): typeof fetch {
  const connections = held.map((h) => ({
    deviceId: h.id,
    deviceType: h.type,
    connectedAt: NOON.getTime(),
    lastSeen: NOON.getTime(),
  }));
  return (async () => Response.json({ connections })) as unknown as typeof fetch;
}

function sample(held: Held[], now = NOON) {
  return recordUsageSample(pg.db, RELAY, { now, fetchImpl: fakeRelay(held) });
}

async function row(day = DAY) {
  return pg.db.usageDaily.findUniqueOrThrow({ where: { day } });
}

async function setDevice(deviceId: string, data: { lastSeenAt?: Date; revokedAt?: Date }) {
  await pg.db.device.updateMany({ where: { deviceId }, data });
}

async function heartbeat(userId: string, deviceId: string, day = DAY) {
  await pg.db.usageHeartbeatSeen.create({ data: { day, userId, deviceId } });
}

test("collapses app slots and classifies devices", async () => {
  const u1 = await createTestUser(pg.db, "a@test.local");
  const u2 = await createTestUser(pg.db, "b@test.local");
  await createTestDevice(pg.db, { userId: u1.id, deviceId: "agent-1", kind: "agent" });
  await createTestDevice(pg.db, { userId: u1.id, deviceId: "phone-1", kind: "app", platform: "ios" });
  await createTestDevice(pg.db, { userId: u2.id, deviceId: "desk-1", kind: "app", platform: "windows" });

  const res = await sample([
    { id: "agent-1", type: "agent" },
    { id: "phone-1#m1", type: "app" },
    { id: "phone-1#m2", type: "app" },
    { id: "desk-1", type: "app" },
  ]);
  expect(res).toEqual({ day: "2026-10-01", relay: "ok" });

  const r = await row();
  expect(r.relayPeakApps).toBe(2);
  expect(r.relayPeakAgents).toBe(1);
  expect(r.relayPeakTotal).toBe(3);
  expect(r.relaySeenApps).toBe(2);
  expect(r.relaySeenAgents).toBe(1);
  expect(r.activeMobileApps).toBe(1);
  expect(r.activeDesktopApps).toBe(1);
  expect(r.activeAgents).toBe(1);
  expect(r.activeUsers).toBe(2);
});

test("active_users counts distinct owners", async () => {
  const u = await createTestUser(pg.db, "a@test.local");
  await createTestDevice(pg.db, { userId: u.id, deviceId: "agent-1", kind: "agent" });
  await createTestDevice(pg.db, { userId: u.id, deviceId: "phone-1", kind: "app", platform: "android" });
  await sample([
    { id: "agent-1", type: "agent" },
    { id: "phone-1", type: "app" },
  ]);
  const r = await row();
  expect(r.activeUsers).toBe(1);
  expect(r.activeMobileApps).toBe(1);
  expect(r.activeAgents).toBe(1);
});

test("a later smaller sample never lowers peaks; seen counts are a union", async () => {
  const u = await createTestUser(pg.db, "a@test.local");
  await createTestDevice(pg.db, { userId: u.id, deviceId: "agent-a", kind: "agent" });
  await createTestDevice(pg.db, { userId: u.id, deviceId: "agent-b", kind: "agent" });
  await createTestDevice(pg.db, { userId: u.id, deviceId: "app-1", kind: "app", platform: "macos" });

  await sample([
    { id: "agent-a", type: "agent" },
    { id: "app-1", type: "app" },
  ]);
  await sample([{ id: "agent-b", type: "agent" }], new Date("2026-10-01T12:05:00Z"));

  const r = await row();
  expect(r.relayPeakAgents).toBe(1);
  expect(r.relayPeakApps).toBe(1);
  expect(r.relayPeakTotal).toBe(2);
  expect(r.relaySeenAgents).toBe(2);
  expect(r.relaySeenApps).toBe(1);
  expect(r.activeAgents).toBe(2);
  expect(r.activeDesktopApps).toBe(1);
});

test("heartbeat-only activity counts; stale and revoked devices do not", async () => {
  const u = await createTestUser(pg.db, "a@test.local");
  await createTestDevice(pg.db, { userId: u.id, deviceId: "today", kind: "agent" });
  await createTestDevice(pg.db, { userId: u.id, deviceId: "yesterday", kind: "agent" });
  await createTestDevice(pg.db, { userId: u.id, deviceId: "revoked", kind: "agent" });
  await heartbeat(u.id, "today");
  await heartbeat(u.id, "yesterday", new Date("2026-09-30T00:00:00.000Z"));
  await heartbeat(u.id, "revoked");
  await setDevice("revoked", { revokedAt: new Date("2026-10-01T04:00:00Z") });

  // The relay holds the revoked device; it must still not count as active.
  await sample([{ id: "revoked", type: "agent" }]);
  const r = await row();
  expect(r.activeAgents).toBe(1);
  expect(r.activeUsers).toBe(1);
  expect(r.relaySeenAgents).toBe(1);
});

test("a device the relay holds is active even with null last_seen", async () => {
  const u = await createTestUser(pg.db, "a@test.local");
  await createTestDevice(pg.db, { userId: u.id, deviceId: "long-lived", kind: "agent" });
  const before = await pg.db.device.findFirstOrThrow({ where: { deviceId: "long-lived" } });
  expect(before.lastSeenAt).toBeNull();

  await sample([{ id: "long-lived", type: "agent" }]);
  const r = await row();
  expect(r.activeAgents).toBe(1);
  expect(r.activeUsers).toBe(1);
});

test("relay failure still records heartbeat activity", async () => {
  const u = await createTestUser(pg.db, "a@test.local");
  await createTestDevice(pg.db, { userId: u.id, deviceId: "hb", kind: "app", platform: "ios" });
  await heartbeat(u.id, "hb");

  const failing = (async () => new Response("boom", { status: 500 })) as unknown as typeof fetch;
  const warn = spyOn(console, "warn").mockImplementation(() => {});
  let res;
  try {
    res = await recordUsageSample(pg.db, RELAY, { now: NOON, fetchImpl: failing });
  } finally {
    warn.mockRestore();
  }
  expect(res).toEqual({ day: "2026-10-01", relay: "unavailable" });

  const r = await row();
  expect(r.activeMobileApps).toBe(1);
  expect(r.activeUsers).toBe(1);
  expect(r.relayPeakTotal).toBe(0);
  expect(r.relaySeenApps).toBe(0);
});

test("missing relay config is unconfigured and never fetches", async () => {
  const u = await createTestUser(pg.db, "a@test.local");
  await createTestDevice(pg.db, { userId: u.id, deviceId: "hb", kind: "agent" });
  await heartbeat(u.id, "hb");

  let calls = 0;
  const spy = (async () => {
    calls++;
    return Response.json({ connections: [] });
  }) as unknown as typeof fetch;

  for (const cfg of [
    { baseUrl: "", secret: "s".repeat(32) },
    { baseUrl: "http://relay.test", secret: "" },
  ]) {
    const res = await recordUsageSample(pg.db, cfg as typeof RELAY, { now: NOON, fetchImpl: spy });
    expect(res.relay).toBe("unconfigured");
  }
  expect(calls).toBe(0);
  expect((await row()).activeAgents).toBe(1);
});

test("prunes relay-seen rows from two or more days ago, keeps yesterday", async () => {
  await pg.db.usageRelaySeen.createMany({
    data: [
      { day: new Date("2026-09-29T00:00:00.000Z"), deviceId: "old", deviceType: "agent" },
      { day: new Date("2026-09-25T00:00:00.000Z"), deviceId: "older", deviceType: "app" },
      { day: new Date("2026-09-30T00:00:00.000Z"), deviceId: "yday", deviceType: "agent" },
    ],
  });
  await sample([{ id: "now-agent", type: "agent" }]);

  const ids = (await pg.db.usageRelaySeen.findMany()).map((s) => s.deviceId).sort();
  expect(ids).toEqual(["now-agent", "yday"]);
});

test("a sample on the next UTC day creates a new row and leaves the old one", async () => {
  const u = await createTestUser(pg.db, "a@test.local");
  await createTestDevice(pg.db, { userId: u.id, deviceId: "agent-1", kind: "agent" });
  await sample([{ id: "agent-1", type: "agent" }]);
  const first = await row();

  const res = await sample([], new Date("2026-10-02T00:30:00Z"));
  expect(res.day).toBe("2026-10-02");

  expect(await pg.db.usageDaily.count()).toBe(2);
  expect(await row()).toEqual(first);
  const second = await row(new Date("2026-10-02T00:00:00.000Z"));
  expect(second.relayPeakTotal).toBe(0);
  expect(second.activeAgents).toBe(0);
});

test("an empty snapshot after a populated one changes nothing", async () => {
  const u = await createTestUser(pg.db, "a@test.local");
  await createTestDevice(pg.db, { userId: u.id, deviceId: "agent-1", kind: "agent" });
  await createTestDevice(pg.db, { userId: u.id, deviceId: "phone-1", kind: "app", platform: "android" });
  await sample([
    { id: "agent-1", type: "agent" },
    { id: "phone-1#m", type: "app" },
  ]);
  const { updatedAt: _before, ...before } = await row();

  await sample([], new Date("2026-10-01T12:05:00Z"));
  const { updatedAt: _after, ...after } = await row();
  expect(after).toEqual(before);
  expect(after.relayPeakTotal).toBe(2);
  expect(after.activeUsers).toBe(1);
});

test("a relay-held device_id shared by two users counts once, on the most recently seen row", async () => {
  const u1 = await createTestUser(pg.db, "a@test.local");
  const u2 = await createTestUser(pg.db, "b@test.local");
  await createTestDevice(pg.db, { userId: u1.id, deviceId: "shared", kind: "agent" });
  await createTestDevice(pg.db, { userId: u2.id, deviceId: "shared", kind: "agent" });
  await pg.db.device.updateMany({
    where: { userId: u1.id, deviceId: "shared" },
    data: { lastSeenAt: new Date("2026-09-20T00:00:00Z") },
  });
  await pg.db.device.updateMany({
    where: { userId: u2.id, deviceId: "shared" },
    data: { lastSeenAt: new Date("2026-09-25T00:00:00Z") },
  });

  await sample([{ id: "shared", type: "agent" }]);
  const r = await row();
  expect(r.activeAgents).toBe(1);
  expect(r.activeUsers).toBe(1);
});

const YDAY = new Date("2026-09-30T00:00:00.000Z");

test("a heartbeat recorded for yesterday counts for yesterday only", async () => {
  const u = await createTestUser(pg.db, "a@test.local");
  await createTestDevice(pg.db, { userId: u.id, deviceId: "late", kind: "agent" });
  await createTestDevice(pg.db, { userId: u.id, deviceId: "phone", kind: "app", platform: "ios" });
  await pg.db.usageHeartbeatSeen.createMany({
    data: [
      { day: YDAY, userId: u.id, deviceId: "late" },
      { day: YDAY, userId: u.id, deviceId: "phone" },
    ],
  });

  await sample([]);

  const y = await row(YDAY);
  expect(y.activeAgents).toBe(1);
  expect(y.activeMobileApps).toBe(1);
  expect(y.activeUsers).toBe(1);
  const t = await row();
  expect(t.activeAgents).toBe(0);
  expect(t.activeMobileApps).toBe(0);
  expect(t.activeUsers).toBe(0);
});

test("last_seen_at alone counts for no day", async () => {
  const u = await createTestUser(pg.db, "a@test.local");
  await createTestDevice(pg.db, { userId: u.id, deviceId: "new", kind: "agent" });
  await createTestDevice(pg.db, { userId: u.id, deviceId: "old", kind: "agent" });
  await heartbeat(u.id, "old", YDAY);
  await setDevice("new", { lastSeenAt: new Date("2026-10-01T03:00:00Z") });

  await sample([]);

  expect((await row(YDAY)).activeAgents).toBe(1);
  expect((await row()).activeAgents).toBe(0);
});

test("no yesterday row is created when yesterday left no evidence", async () => {
  await sample([]);
  expect(await pg.db.usageDaily.count()).toBe(1);
});

test("heartbeat matching is exact on user and device id", async () => {
  const u1 = await createTestUser(pg.db, "a@test.local");
  const u2 = await createTestUser(pg.db, "b@test.local");
  await createTestDevice(pg.db, { userId: u1.id, deviceId: "shared", kind: "agent" });
  await createTestDevice(pg.db, { userId: u2.id, deviceId: "shared", kind: "agent" });
  await pg.db.usageHeartbeatSeen.create({ data: { day: YDAY, userId: u2.id, deviceId: "shared" } });

  await sample([]);

  const y = await row(YDAY);
  expect(y.activeAgents).toBe(1);
  expect(y.activeUsers).toBe(1);
});

test("a rerun over unchanged yesterday data leaves its row untouched", async () => {
  const u = await createTestUser(pg.db, "a@test.local");
  await createTestDevice(pg.db, { userId: u.id, deviceId: "d", kind: "agent" });
  await pg.db.usageHeartbeatSeen.create({ data: { day: YDAY, userId: u.id, deviceId: "d" } });
  await sample([]);
  const first = await row(YDAY);
  await sample([], new Date("2026-10-01T12:05:00Z"));
  expect(await row(YDAY)).toEqual(first);
});

test("prunes heartbeat-seen rows from two or more days ago, keeps yesterday and today", async () => {
  await pg.db.usageHeartbeatSeen.createMany({
    data: [
      { day: new Date("2026-09-29T00:00:00.000Z"), userId: "u", deviceId: "old" },
      { day: new Date("2026-09-25T00:00:00.000Z"), userId: "u", deviceId: "older" },
      { day: YDAY, userId: "u", deviceId: "yday" },
      { day: DAY, userId: "u", deviceId: "today" },
    ],
  });
  await sample([]);

  const ids = (await pg.db.usageHeartbeatSeen.findMany()).map((s) => s.deviceId).sort();
  expect(ids).toEqual(["today", "yday"]);
});
