// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import {
  createTestUser,
  createTestSession,
  createTestDevice,
  createTestSubscription,
} from "../helpers/fixtures.js";
import { loadUsageStats, summarizeLiveRelay } from "../../src/usage/stats.js";
import { recordUsageSample, utcDayKey } from "../../src/usage/sampler.js";

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

const OPERATOR = "bharathm@radhaai.com";
const HOUR = 3_600_000;
const DAY = 86_400_000;

test("operator email → 200, relay unreachable state shown", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const user = await createTestUser(pg.db, OPERATOR);
  const { cookie } = await createTestSession(pg.db, user.id);

  const res = await app.request("/internal/stats", { headers: { cookie } });
  expect(res.status).toBe(200);
  const html = await res.text();
  expect(html).toContain("Usage");
  expect(html).toContain("Could not reach the relay");
  expect(html).toContain("No samples yet.");
});

test("seeded data is counted exactly and rendered", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const now = new Date();
  const op = await createTestUser(pg.db, OPERATOR);
  const u2 = await createTestUser(pg.db);
  const u3 = await createTestUser(pg.db);
  const u4 = await createTestUser(pg.db);
  const u5 = await createTestUser(pg.db);
  await pg.db.user.update({ where: { id: u5.id }, data: { createdAt: new Date(now.getTime() - 40 * DAY) } });
  await pg.db.user.update({ where: { id: u2.id }, data: { createdAt: new Date(now.getTime() - 3 * DAY) } });
  await pg.db.user.update({ where: { id: u3.id }, data: { createdAt: new Date(now.getTime() - 15 * DAY) } });

  const mk = async (
    userId: string,
    kind: "app" | "agent",
    platform: "android" | "windows" | "linux" | "ios",
    seen: Date | null,
  ) => {
    const d = await createTestDevice(pg.db, { userId, deviceId: crypto.randomUUID(), kind, platform });
    await pg.db.device.update({ where: { id: d.id }, data: { lastSeenAt: seen } });
    return d;
  };
  const opPhone = await mk(op.id, "app", "android", now);
  await mk(op.id, "agent", "linux", null);
  await mk(u2.id, "app", "android", new Date(now.getTime() - 10 * DAY));
  const u3Desk = await mk(u3.id, "app", "windows", now);
  await mk(u4.id, "agent", "linux", new Date(now.getTime() - 20 * DAY));
  const revoked = await mk(u4.id, "app", "ios", now);
  await pg.db.device.update({ where: { id: revoked.id }, data: { revokedAt: now } });
  const today = new Date(`${utcDayKey(now)}T00:00:00Z`);
  await pg.db.usageHeartbeatSeen.createMany({
    data: [
      { day: today, userId: op.id, deviceId: opPhone.deviceId },
      { day: today, userId: u3.id, deviceId: u3Desk.deviceId },
      { day: today, userId: u4.id, deviceId: revoked.deviceId },
    ],
  });

  await createTestSubscription(pg.db, op.id, { tier: "pro", status: "active" });
  const promo = await createTestSubscription(pg.db, u2.id, { tier: "pro", status: "active" });
  await pg.db.subscription.update({ where: { id: promo.id }, data: { promotional: true } });

  // ts and install_id are client-supplied on an unauthenticated endpoint, so
  // windows key on the server-stamped created_at; the fixture sets both.
  const ev = (installId: string, name: string, platform: string, ago: number) => ({
    installId,
    name,
    platform,
    appVersion: "1.0.0",
    ts: new Date(now.getTime() - ago),
    createdAt: new Date(now.getTime() - ago),
  });
  await pg.db.analyticEvent.createMany({
    data: [
      ev("install-a", "app_open", "android", HOUR),
      ev("install-a", "app_open", "android", HOUR),
      ev("install-a", "session_start", "android", HOUR),
      ev("install-b", "app_open", "windows", 3 * DAY),
      ev("install-b", "app_open", "windows", 20 * DAY),
      // A forged future ts must not pull a 40-day-old row into any window.
      {
        ...ev("install-c", "app_open", "ios", 40 * DAY),
        ts: new Date(now.getTime() + DAY),
      },
    ],
  });

  expect(await recordUsageSample(pg.db, {}, { now })).toEqual({ day: utcDayKey(now), relay: "unconfigured" });

  const stats = await loadUsageStats(pg.db, now);
  expect(stats.users).toEqual({ total: 5, new1d: 2, new7d: 3, new30d: 4 });
  expect(stats.reach).toEqual({ phone: 2, controller: 1, machine: 2, machineAndPhone: 1 });
  expect(stats.devices).toEqual([
    { class: "controller", platform: "windows", devices: 1, users: 1, heartbeat7d: 1, heartbeat30d: 1 },
    { class: "machine", platform: "linux", devices: 2, users: 2, heartbeat7d: 0, heartbeat30d: 1 },
    { class: "phone", platform: "android", devices: 2, users: 2, heartbeat7d: 1, heartbeat30d: 2 },
  ]);
  expect(stats.subscriptions).toHaveLength(2);
  expect(stats.subscriptions).toContainEqual({ tier: "pro", status: "active", promotional: false, count: 1 });
  expect(stats.subscriptions).toContainEqual({ tier: "pro", status: "active", promotional: true, count: 1 });
  expect(stats.installs).toEqual([
    { platform: "android", d1: 1, d7: 1, d30: 1 },
    { platform: "windows", d1: 0, d7: 1, d30: 1 },
  ]);
  expect(stats.events7d).toEqual([
    { name: "app_open", events: 3, installs: 2 },
    { name: "session_start", events: 1, installs: 1 },
  ]);
  expect(stats.history).toHaveLength(1);
  expect(stats.history[0]).toMatchObject({
    day: utcDayKey(now),
    activeUsers: 2,
    activeMobileApps: 1,
    activeDesktopApps: 1,
    activeAgents: 0,
    relayPeakApps: 0,
    relayPeakAgents: 0,
    relayPeakTotal: 0,
  });

  const { cookie } = await createTestSession(pg.db, op.id);
  const res = await app.request("/internal/stats", { headers: { cookie } });
  expect(res.status).toBe(200);
  const html = await res.text();
  expect(html).toContain(utcDayKey(now));
  expect(html).toContain("Daily activity");
  expect(html).toContain("android");
  expect(html).toContain("windows");
  expect(html).toContain("app_open");
  expect(html).toContain("session_start");
  expect(html).toContain("pro");
  expect(html).toContain("promo");
  expect(html).toContain("paid");
  expect(html).toContain("With a desktop controller");
  expect(html).not.toContain("No devices registered.");
  expect(html).not.toContain("No samples yet.");
  // The revoked iOS device must not surface as a registered platform row.
  expect(html).not.toContain(">ios<");
});

test("summarizeLiveRelay collapses slots and classifies by registered kind", async () => {
  const u = await createTestUser(pg.db);
  const reg = (kind: "app" | "agent", platform: "android" | "windows" | "linux") =>
    createTestDevice(pg.db, { userId: u.id, deviceId: crypto.randomUUID(), kind, platform });
  const phone = await reg("app", "android");
  const controller = await reg("app", "windows");
  const machine = await reg("agent", "windows");
  const revoked = await reg("app", "android");
  await pg.db.device.update({ where: { id: revoked.id }, data: { revokedAt: new Date() } });
  const unregisteredApp = crypto.randomUUID();
  const unregisteredAgent = crypto.randomUUID();
  const c = (deviceId: string, deviceType: "app" | "agent") => ({
    deviceId,
    deviceType,
    connectedAt: 0,
    lastSeen: 0,
  });

  const connections = [
    c(phone.deviceId, "app"),
    c(`${phone.deviceId}#m1`, "app"),
    c(`${controller.deviceId}#m2`, "app"),
    c(machine.deviceId, "agent"),
    c(revoked.deviceId, "app"),
    c(unregisteredApp, "app"),
    c(unregisteredAgent, "agent"),
  ];
  expect(await summarizeLiveRelay(pg.db, connections)).toEqual({
    sockets: 7,
    machines: 1,
    phones: 1,
    controllers: 1,
    unknown: 3,
  });
});
