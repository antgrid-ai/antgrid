// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { afterAll, beforeAll, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { startTestPg, type PgHandle } from "../helpers/pg.js";
import { buildTestApp } from "../helpers/app.js";
import { addTestMember, createTestDevice, createTestSession, createTestSubscription, createTestUser } from "../helpers/fixtures.js";
import { PLAN_UUID } from "../../src/models/plan.js";
import { activeSubscriptionForAccount } from "../../src/models/subscription.js";
import { loadOperatorAccount, loadOperatorAccounts, loadOperatorUser, loadOperatorUsers, OperatorAccountsQuerySchema, OperatorUsersQuerySchema } from "../../src/models/operator.js";

let pg: PgHandle;
beforeAll(async () => { pg = await startTestPg(); });
afterAll(async () => { await pg.stop(); });
beforeEach(async () => { await pg.truncate(); });

const OPERATOR = "bharathm@radhaai.com";
const DAY = 86_400_000;

async function operator() {
  const user = await createTestUser(pg.db, OPERATOR);
  return { user, ...(await createTestSession(pg.db, user.id)) };
}

test("operator reads do not refresh old sessions, heal memberships, provision accounts or expire invites", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const { user: op, cookie, sessionId } = await operator();
  const stale = new Date(Date.now() - 3 * DAY);
  await pg.db.session.update({ where: { id: sessionId }, data: { createdAt: stale, updatedAt: stale } });
  const target = await createTestUser(pg.db);
  const account = await personalAccount(target.id);
  const expiredInvite = await invite(account.id, target.id, "expired@test.local", stale);
  const before = await pg.db.session.findUnique({ where: { id: sessionId } });
  for (const path of ["/internal/users", "/internal/accounts", `/internal/users/${op.id}`, `/internal/users/${target.id}`, `/internal/accounts/${account.id}`]) {
    expect((await app.request(path, { headers: { cookie } })).status).toBe(200);
  }
  expect(await pg.db.session.findUnique({ where: { id: sessionId } })).toEqual(before);
  expect(await pg.db.productAccount.count()).toBe(1);
  expect(await pg.db.accountMember.count()).toBe(0);
  expect(await pg.db.subscription.count()).toBe(0);
  expect(await pg.db.accountInvite.findUnique({ where: { id: expiredInvite.id } })).toEqual(expiredInvite);
  await pg.db.session.update({ where: { id: sessionId }, data: { expiresAt: stale } });
  const expiredSession = await pg.db.session.findUnique({ where: { id: sessionId } });
  const result = await app.request("/internal/users", { headers: { cookie } });
  expect(result.status).toBe(302);
  expect(result.headers.get("location")).toBe("/login");
  expect(await pg.db.session.findUnique({ where: { id: sessionId } })).toEqual(expiredSession);
});

test("user details exclude secrets and distinguish linked credentials from email-link availability", async () => {
  const { app } = buildTestApp(pg.db, pg.url);
  const { cookie } = await operator();
  const target = await createTestUser(pg.db, "credentials@test.local");
  const session = await createTestSession(pg.db, target.id);
  await pg.db.session.update({ where: { id: session.sessionId }, data: { ipAddress: "192.0.2.77", userAgent: "private-user-agent" } });
  await pg.db.account.createMany({ data: [
    { id: crypto.randomUUID(), userId: target.id, accountId: "oauth-private-id", providerId: "github", accessToken: "private-access-token", refreshToken: "private-refresh-token", idToken: "private-id-token" },
    { id: crypto.randomUUID(), userId: target.id, accountId: target.id, providerId: "credential", password: "private-password-hash" },
  ] });
  const device = await createTestDevice(pg.db, { userId: target.id, deviceId: crypto.randomUUID(), displayName: "Retained machine", publicKey: Buffer.from("private-device-public-key") });
  await pg.db.device.update({ where: { id: device.id }, data: { revokedAt: new Date(), mobileAccessEnabled: true } });
  const account = await personalAccount(target.id);
  await invite(account.id, target.id, target.email, new Date(Date.now() + DAY));
  await pg.db.waitlistSignup.create({ data: { email: target.email, source: "operator-test" } });
  const res = await app.request(`/internal/users/${target.id}`, { headers: { cookie } });
  expect(res.status).toBe(200);
  const html = await res.text();
  expect(html).toContain("github");
  expect(html.toLowerCase()).toContain("password");
  expect(html.toLowerCase()).toContain("email-link");
  expect(html).toContain("Retained machine");
  expect(html.toLowerCase()).toContain("revoked");
  expect(html.toLowerCase()).toContain("machine setting");
  expect(html).toContain("operator-test");
  expect(html).toContain(`href="/internal/accounts/${account.id}"`);
  for (const sensitive of ["192.0.2.77", "private-user-agent", "private-access-token", "private-refresh-token", "private-id-token", "private-password-hash", "private-device-public-key", "private-invite-hash", "oauth-private-id"]) {
    expect(html).not.toContain(sensitive);
  }
  const magicOnly = await createTestUser(pg.db, "magic-only@test.local");
  const magicHtml = await (await app.request(`/internal/users/${magicOnly.id}`, { headers: { cookie } })).text();
  expect(magicHtml.toLowerCase()).toContain("email-link");
  expect(magicHtml).toContain("No active subscription");
  expect(magicHtml).toContain("Unknown");
});

test("relay connections are user-scoped, fetched only on user details, and distinguish empty from failure", async () => {
  const requests: Record<string, unknown>[] = [];
  let status = 200;
  let connections: { deviceId: string; deviceType: "agent" | "app"; connectedAt: number; lastSeen: number }[] = [];
  const relay = Bun.serve({ port: 0, fetch: async (req) => {
    requests.push(await req.json() as Record<string, unknown>);
    return Response.json({ connections }, { status });
  } });
  try {
    const { app } = buildTestApp(pg.db, pg.url, { envOverrides: { RELAY_INTERNAL_URL: relay.url.toString().replace(/\/$/, ""), RELAY_INTERNAL_SECRET: "operator-test-relay-secret" } });
    const { cookie } = await operator();
    const target = await createTestUser(pg.db);
    const account = await personalAccount(target.id);
    const machine = await createTestDevice(pg.db, { userId: target.id, deviceId: crypto.randomUUID(), displayName: "Live machine" });
    for (const path of ["/internal/users", "/internal/accounts", `/internal/accounts/${account.id}`]) {
      expect((await app.request(path, { headers: { cookie } })).status).toBe(200);
    }
    expect(requests).toHaveLength(0);
    const detail = `/internal/users/${target.id}`;
    const empty = await (await app.request(detail, { headers: { cookie } })).text();
    expect(empty).toContain("No relay connections");
    expect(requests[0]).toMatchObject({ userId: target.id });
    connections = [machine.deviceId, `${machine.deviceId}#slot-one`, `${machine.deviceId}#slot-two`].map((deviceId) => ({ deviceId, deviceType: "agent", connectedAt: 0, lastSeen: 0 }));
    const live = await (await app.request(detail, { headers: { cookie } })).text();
    expect(live).toContain("Connected to relay");
    expect(live).toContain("1 unique connected devices");
    expect(rowContaining(live, "Live machine")).toContain("Connected to relay");
    status = 503;
    const unavailable = await (await app.request(detail, { headers: { cookie } })).text();
    expect(unavailable).toContain("Unavailable");
    expect(unavailable).not.toContain("No relay connections");
    expect(requests.every((request) => request.userId === target.id)).toBe(true);
  } finally { await relay.stop(true); }
});

async function personalAccount(userId: string) {
  return pg.db.productAccount.create({ data: { userId } });
}

async function invite(accountId: string, createdBy: string, email: string, expiresAt: Date, deliveryStatus: string | null = null) {
  return pg.db.accountInvite.create({ data: {
    accountId, createdBy, email, expiresAt, deliveryStatus,
    status: "pending", role: "member", tokenHash: Buffer.from("private-invite-hash"),
  } });
}

function rowContaining(html: string, text: string): string {
  const row = html.match(/<tr\b[^>]*>[\s\S]*?<\/tr>/g)?.find((candidate) => candidate.includes(text));
  expect(row).toBeDefined();
  return row!;
}

test("loader observations retain timestamp precision, count only unexpired sessions and separate desktop controllers", async () => {
  const now = new Date("2026-10-05T12:00:00.000Z");
  const heartbeat = new Date("2026-10-04T11:12:13.456Z");
  const sessionObserved = new Date("2026-10-04T12:13:14.789Z");
  const target = await createTestUser(pg.db, "activity@test.local");
  const unknown = await createTestUser(pg.db, "unknown@test.local");
  const addDevice = async (kind: "agent" | "app", platform: "linux" | "android" | "windows", revoked = false) => {
    const device = await createTestDevice(pg.db, { userId: target.id, deviceId: crypto.randomUUID(), kind, platform });
    await pg.db.device.update({ where: { id: device.id }, data: { lastSeenAt: heartbeat, revokedAt: revoked ? now : null } });
    return device;
  };
  const machine = await addDevice("agent", "linux");
  await addDevice("app", "android");
  await addDevice("app", "windows");
  await addDevice("app", "android", true);
  await pg.db.session.createMany({ data: [
    { id: crypto.randomUUID(), token: "private-live-token", userId: target.id, expiresAt: new Date(now.getTime() + DAY), updatedAt: sessionObserved },
    { id: crypto.randomUUID(), token: "private-expired-token", userId: target.id, expiresAt: now, updatedAt: heartbeat },
  ] });
  const result = await loadOperatorUsers(pg.db, OperatorUsersQuerySchema.parse({ sort: "activity" }), now);
  expect(result.rows.map((row) => row.id)).toEqual([target.id, unknown.id]);
  expect(result.rows[0]).toMatchObject({ machines: 1, phones: 1, desktopControllers: 1, activeSessions: 1, lastObservedActivity: sessionObserved });
  expect(result.rows[1].lastObservedActivity).toBeNull();
  const later = new Date("2026-10-05T10:11:12.123Z");
  await pg.db.device.update({ where: { id: machine.id }, data: { lastSeenAt: later } });
  expect((await loadOperatorUser(pg.db, target.id, now))!.lastObservedActivity).toEqual(later);
  const deleted = await personalAccount(target.id);
  await pg.db.productAccount.update({ where: { id: deleted.id }, data: { deletedAt: now } });
  expect((await loadOperatorUsers(pg.db, OperatorUsersQuerySchema.parse({}), now)).rows.map((row) => row.id)).toEqual([unknown.id]);
  expect((await loadOperatorUsers(pg.db, OperatorUsersQuerySchema.parse({ includeDeleted: "true" }), now)).rows.find((row) => row.id === target.id)).toMatchObject({ deletedAt: now, lastObservedActivity: later });
});

test("activity sorting and account aggregation preserve microseconds from retained revoked devices", async () => {
  const older = await pg.db.user.create({ data: { id: "00000000-0000-4000-8000-000000000001", name: "Older activity", email: "older-precision@test.local" } });
  const newer = await pg.db.user.create({ data: { id: "00000000-0000-4000-8000-000000000002", name: "Newer activity", email: "newer-precision@test.local" } });
  await createTestSubscription(pg.db, older.id, { seats: 2 });
  const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: older.id } });
  await addTestMember(pg.db, account.id, newer.id);
  const active = await createTestDevice(pg.db, { userId: older.id, deviceId: crypto.randomUUID() });
  const revoked = await createTestDevice(pg.db, { userId: newer.id, deviceId: crypto.randomUUID() });
  await pg.db.device.update({ where: { id: revoked.id }, data: { revokedAt: new Date() } });
  await pg.db.$executeRaw`UPDATE devices SET last_seen_at = '2026-10-05T10:11:12.123456Z'::timestamptz WHERE id = ${active.id}::uuid`;
  await pg.db.$executeRaw`UPDATE devices SET last_seen_at = '2026-10-05T10:11:12.123457Z'::timestamptz WHERE id = ${revoked.id}::uuid`;
  const users = await loadOperatorUsers(pg.db, OperatorUsersQuerySchema.parse({ sort: "activity" }));
  expect(users.rows.map((row) => row.id)).toEqual([newer.id, older.id]);
  expect(users.rows[0]).toMatchObject({ machines: 0, lastObservedActivityIso: "2026-10-05T10:11:12.123457Z" });
  const accounts = await loadOperatorAccounts(pg.db, OperatorAccountsQuerySchema.parse({}));
  expect(accounts.rows[0]).toMatchObject({ machines: 1, lastObservedActivityIso: "2026-10-05T10:11:12.123457Z" });
  const { app } = buildTestApp(pg.db, pg.url);
  const { cookie } = await operator();
  const html = await (await app.request(`/internal/users/${newer.id}`, { headers: { cookie } })).text();
  expect(html).toContain("2026-10-05T10:11:12.123457Z");
});

test("team billing uses subscription snapshots per user and excludes former members and idle personal accounts from totals", async () => {
  const now = new Date();
  const owner = await createTestUser(pg.db, "team-owner@test.local");
  const member = await createTestUser(pg.db, "team-member@test.local");
  const former = await createTestUser(pg.db, "former-member@test.local");
  const subscription = await createTestSubscription(pg.db, owner.id, { workerLimit: 7, appDeviceLimit: 13, seats: 4, planId: PLAN_UUID.enterprise });
  await pg.db.subscription.update({ where: { id: subscription.id }, data: { provider: "manual", capabilities: { sso: true }, createdAt: new Date(now.getTime() - DAY) } });
  const team = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: owner.id } });
  await createTestSubscription(pg.db, member.id, { workerLimit: 999 });
  const idlePersonal = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: member.id } });
  await addTestMember(pg.db, team.id, member.id);
  await createTestSubscription(pg.db, former.id, { workerLimit: 3 });
  await pg.db.accountMember.create({ data: { accountId: team.id, userId: former.id, role: "member", status: "left", endedAt: now } });
  for (const user of [owner, member, former]) {
    const device = await createTestDevice(pg.db, { userId: user.id, deviceId: crypto.randomUUID(), displayName: user.email });
    await pg.db.device.update({ where: { id: device.id }, data: { lastSeenAt: new Date(now.getTime() - (user.id === former.id ? 0 : DAY)) } });
    const session = await createTestSession(pg.db, user.id);
    await pg.db.session.update({ where: { id: session.sessionId }, data: { updatedAt: new Date(now.getTime() - (user.id === former.id ? 0 : DAY)) } });
  }
  const pending = await invite(team.id, owner.id, "pending@test.local", new Date(now.getTime() + DAY), "bounced");
  const expired = await invite(team.id, owner.id, "expired@test.local", new Date(now.getTime() - DAY));
  await pg.db.subscription.create({ data: { accountId: team.id, planId: PLAN_UUID.free, tier: "free", status: "active", workerLimit: 1, appDeviceLimit: 2, createdAt: now } });
  await pg.db.billingCustomer.create({ data: { accountId: team.id, provider: "manual", providerCustomerId: "contract-customer" } });
  const result = await loadOperatorAccounts(pg.db, OperatorAccountsQuerySchema.parse({}), now);
  expect(result.rows.find((row) => row.id === team.id)).toMatchObject({ machines: 2, activeSessions: 2, occupiedSeats: 2, pendingInvites: 1, subscription: { id: subscription.id, workerLimit: 7, appDeviceLimit: 13, seats: 4, capabilities: { sso: true } } });
  expect(result.rows.find((row) => row.id === idlePersonal.id)).toMatchObject({ machines: 0, activeSessions: 0, lastObservedActivity: null });
  const detail = (await loadOperatorAccount(pg.db, team.id, now))!;
  expect(detail.lastObservedActivity).not.toEqual(now);
  expect(detail.members.find((row) => row.userId === member.id)).toMatchObject({ currentBilling: true, user: { billingAccountId: team.id, ownedAccountId: idlePersonal.id, subscription: { workerLimit: 7, appDeviceLimit: 13 } } });
  expect(detail.members.find((row) => row.userId === former.id)).toMatchObject({ currentBilling: false, user: { machines: 1, activeSessions: 1, lastObservedActivity: now } });
  expect(detail.invites.find((row) => row.id === expired.id)!.status).toBe("expired");
  expect(detail.invites.find((row) => row.id === pending.id)!.deliveryStatus).toBe("bounced");
  expect(detail.billingCustomers).toEqual([{ provider: "manual", providerCustomerId: "contract-customer" }]);
  expect(detail.subscriptions).toHaveLength(2);
  expect((await pg.db.accountInvite.findUniqueOrThrow({ where: { id: expired.id } })).status).toBe("pending");
  const { app } = buildTestApp(pg.db, pg.url);
  const { cookie } = await operator();
  const html = await (await app.request(`/internal/accounts/${team.id}`, { headers: { cookie } })).text();
  expect(html).toContain(`href="/internal/users/${member.id}"`);
  expect(html).toContain("expired");
  expect(html).toContain("bounced");
  expect(html).toContain("contract-customer");
  expect(html.toLowerCase()).toContain("current observations");
});

test("team and paid filters use purchased seats and the effective subscription provider classification", async () => {
  const cases = [
    { email: "paddle@test.local", provider: "paddle", seats: 3, paid: true, team: true },
    { email: "razorpay@test.local", provider: "razorpay", seats: 1, paid: true, team: false },
    { email: "manual@test.local", provider: "manual", seats: 2, paid: true, team: true },
    { email: "dev@test.local", provider: "dev", seats: 2, paid: false, team: true },
    { email: "promo@test.local", provider: "paddle", seats: 2, promotional: true, paid: false, team: true },
    { email: "trial@test.local", provider: "paddle", seats: 2, planId: PLAN_UUID.trial, paid: false, team: true },
    { email: "trial-tier@test.local", provider: "paddle", seats: 1, tier: "trial", paid: false, team: false },
    { email: "free@test.local", provider: "manual", seats: 2, planId: PLAN_UUID.free, tier: "free", paid: false, team: true },
    { email: "expired@test.local", provider: "manual", seats: 8, expired: true, paid: false, team: false },
    { email: "missing-provider@test.local", provider: null, seats: 1, paid: false, team: false },
  ];
  const ids = new Map<string, string>();
  for (const item of cases) {
    const user = await createTestUser(pg.db, item.email);
    const sub = await createTestSubscription(pg.db, user.id, { seats: item.seats, planId: item.planId });
    await pg.db.subscription.update({ where: { id: sub.id }, data: { provider: item.provider, promotional: item.promotional ?? false, tier: item.tier ?? "pro", currentPeriodEnd: item.expired ? new Date(Date.now() - DAY) : null } });
    ids.set(item.email, (await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } })).id);
  }
  const noSub = await createTestUser(pg.db, "no-subscription@test.local");
  await personalAccount(noSub.id);
  const paid = await loadOperatorAccounts(pg.db, OperatorAccountsQuerySchema.parse({ paidOnly: "true" }));
  expect(paid.rows.map((row) => row.id).sort()).toEqual(cases.filter((item) => item.paid).map((item) => ids.get(item.email)!).sort());
  const teams = await loadOperatorAccounts(pg.db, OperatorAccountsQuerySchema.parse({ teamsOnly: "true" }));
  expect(teams.rows.map((row) => row.id).sort()).toEqual(cases.filter((item) => item.team).map((item) => ids.get(item.email)!).sort());
  const both = await loadOperatorAccounts(pg.db, OperatorAccountsQuerySchema.parse({ paidOnly: "true", teamsOnly: "true" }));
  expect(both.rows.map((row) => row.id).sort()).toEqual(cases.filter((item) => item.paid && item.team).map((item) => ids.get(item.email)!).sort());
});

test("batched subscription selection shares single-account precedence with stable ties", async () => {
  const owner = await createTestUser(pg.db);
  const account = await personalAccount(owner.id);
  const date = new Date("2026-10-01T00:00:00Z");
  const earlierId = "00000000-0000-4000-8000-000000000010";
  await pg.db.subscription.createMany({ data: [
    { id: "00000000-0000-4000-8000-000000000020", accountId: account.id, planId: PLAN_UUID.pro_yearly, tier: "pro", status: "active", provider: "paddle", workerLimit: 5, appDeviceLimit: 10, createdAt: date },
    { id: earlierId, accountId: account.id, planId: PLAN_UUID.enterprise, tier: "enterprise", status: "active", provider: "manual", workerLimit: 27, appDeviceLimit: 18, createdAt: date },
    { accountId: account.id, planId: PLAN_UUID.free, tier: "free", status: "active", workerLimit: 1, appDeviceLimit: 2, createdAt: new Date(date.getTime() + DAY) },
  ] });
  expect((await activeSubscriptionForAccount(pg.db, account.id))!.id).toBe(earlierId);
  expect((await loadOperatorAccount(pg.db, account.id))!.subscription!.id).toBe(earlierId);
  expect((await loadOperatorUsers(pg.db, OperatorUsersQuerySchema.parse({}))).rows[0].subscription!.id).toBe(earlierId);
});

test("search, stable ID tie-breakers, pagination and deleted-account filtering apply before the page limit", async () => {
  const date = new Date("2026-01-01T00:00:00Z");
  for (let index = 1; index <= 53; index++) {
    const id = `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;
    const user = await pg.db.user.create({ data: { id, name: `Match ${index}`, email: `match-${index}@test.local`, createdAt: date } });
    await pg.db.productAccount.create({ data: { id, userId: user.id, createdAt: date, deletedAt: index === 53 ? date : null } });
  }
  const users1 = await loadOperatorUsers(pg.db, OperatorUsersQuerySchema.parse({ search: "MATCH" }));
  const users2 = await loadOperatorUsers(pg.db, OperatorUsersQuerySchema.parse({ search: "MATCH", page: "2" }));
  expect(users1.total).toBe(52);
  expect(users1.rows).toHaveLength(50);
  expect(users2.rows).toHaveLength(2);
  expect(users1.rows[0].id).toBe("00000000-0000-4000-8000-000000000001");
  expect(users2.rows[0].id).toBe("00000000-0000-4000-8000-000000000051");
  expect((await loadOperatorUsers(pg.db, OperatorUsersQuerySchema.parse({ search: "no-match" }))).total).toBe(0);
  expect((await loadOperatorUsers(pg.db, OperatorUsersQuerySchema.parse({ page: "3" }))).rows).toEqual([]);
  const accounts = await loadOperatorAccounts(pg.db, OperatorAccountsQuerySchema.parse({ search: "match-51" }));
  expect(accounts.rows.map((row) => row.id)).toEqual(["00000000-0000-4000-8000-000000000051"]);
  const accounts2 = await loadOperatorAccounts(pg.db, OperatorAccountsQuerySchema.parse({ page: "2" }));
  expect(accounts2.total).toBe(52);
  expect(accounts2.rows.map((row) => row.id)).toEqual(users2.rows.map((row) => row.id));
  expect((await loadOperatorAccounts(pg.db, OperatorAccountsQuerySchema.parse({ includeDeleted: "true" }))).total).toBe(53);
  expect((await loadOperatorAccounts(pg.db, OperatorAccountsQuerySchema.parse({ page: "3" }))).rows).toEqual([]);
});

test("all operator loaders succeed in a database-enforced read-only transaction and project only safe fields", async () => {
  const user = await createTestUser(pg.db);
  await createTestSubscription(pg.db, user.id);
  const account = await pg.db.productAccount.findUniqueOrThrow({ where: { userId: user.id } });
  await createTestSession(pg.db, user.id);
  await createTestDevice(pg.db, { userId: user.id, deviceId: crypto.randomUUID() });
  await invite(account.id, user.id, user.email, new Date(Date.now() + DAY));
  const output = await pg.db.$transaction(async (tx) => {
    await tx.$executeRawUnsafe("SET TRANSACTION READ ONLY");
    return Promise.all([
      loadOperatorUsers(tx, OperatorUsersQuerySchema.parse({})),
      loadOperatorAccounts(tx, OperatorAccountsQuerySchema.parse({})),
      loadOperatorUser(tx, user.id), loadOperatorAccount(tx, account.id),
    ]);
  });
  const forbidden = new Set(["token", "ipAddress", "userAgent", "password", "accessToken", "refreshToken", "idToken", "tokenHash", "publicKey", "privateKey", "clientSecret"]);
  const assertSafe = (value: unknown): void => {
    if (!value || typeof value !== "object" || value instanceof Date) return;
    if (Array.isArray(value)) { for (const item of value) assertSafe(item); return; }
    for (const [key, nested] of Object.entries(value)) { expect(forbidden.has(key)).toBe(false); assertSafe(nested); }
  };
  assertSafe(output);
  const reads: { select?: unknown }[] = [];
  const projectedDb = pg.db.$extends({ query: { $allModels: { $allOperations: async ({ args, operation, query }) => {
    if (["findMany", "findUnique", "findFirst"].includes(operation)) reads.push(args as { select?: unknown });
    return query(args);
  } } } }) as unknown as typeof pg.db;
  await loadOperatorUsers(projectedDb, OperatorUsersQuerySchema.parse({}));
  await loadOperatorAccounts(projectedDb, OperatorAccountsQuerySchema.parse({}));
  await loadOperatorUser(projectedDb, user.id);
  await loadOperatorAccount(projectedDb, account.id);
  expect(reads.length).toBeGreaterThan(0);
  for (const query of reads) {
    expect(query.select).toBeDefined();
    assertSafe(query.select);
  }
});

test("search treats percent, underscore and backslash as literal characters with consistent totals", async () => {
  for (const [name, email] of [["Percent %", "percent@test.local"], ["Underscore _", "underscore@test.local"], ["Backslash \\", "backslash@test.local"], ["Ordinary", "ordinary@test.local"]]) {
    const user = await createTestUser(pg.db, email);
    await pg.db.user.update({ where: { id: user.id }, data: { name } });
    await personalAccount(user.id);
  }
  for (const [search, email] of [["%", "percent@test.local"], ["_", "underscore@test.local"], ["\\", "backslash@test.local"]]) {
    const users = await loadOperatorUsers(pg.db, OperatorUsersQuerySchema.parse({ search }));
    expect(users.total).toBe(1);
    expect(users.rows.map((row) => row.email)).toEqual([email]);
    const accounts = await loadOperatorAccounts(pg.db, OperatorAccountsQuerySchema.parse({ search }));
    expect(accounts.total).toBe(1);
    expect(accounts.rows.map((row) => row.owner.email)).toEqual([email]);
  }
});

for (const page of ["users", "accounts"]) {
  describe(`/internal/${page}`, () => {
    test("requires sign-in and hides the route from non-operators", async () => {
      const { app } = buildTestApp(pg.db, pg.url);
      expect((await app.request(`/internal/${page}`)).headers.get("location")).toBe("/login");
      const outsider = await createTestUser(pg.db);
      const { cookie } = await createTestSession(pg.db, outsider.id);
      const warn = spyOn(console, "warn").mockImplementation(() => {});
      try {
        const res = await app.request(`/internal/${page}`, { headers: { cookie } });
        expect(res.status).toBe(404);
        const hit = warn.mock.calls.map((args) => String(args[0])).find((line) => line.includes(`internal.${page}.denied`));
        expect(JSON.parse(hit!)).toMatchObject({ actorId: outsider.id });
      } finally { warn.mockRestore(); }
    });

    test("operator gate is case-insensitive, responses are private and navigation is shared", async () => {
      const { app } = buildTestApp(pg.db, pg.url);
      const op = await createTestUser(pg.db, "BharathM@Radhaai.com");
      const { cookie } = await createTestSession(pg.db, op.id);
      const res = await app.request(`/internal/${page}`, { headers: { cookie } });
      expect(res.status).toBe(200);
      expect(res.headers.get("cache-control")).toBe("private, no-store");
      const html = await res.text();
      expect(html).not.toContain("data-website-id");
      for (const destination of ["users", "accounts", "stats", "connections"]) {
        expect(html).toContain(`href="/internal/${destination}"`);
      }
    });

    test("invalid list parameters are rejected and out-of-range pages are empty", async () => {
      const { app } = buildTestApp(pg.db, pg.url);
      const { cookie } = await operator();
      for (const query of ["page=0", "page=-1", "page=1.5", "page=word", "page=", "page=9007199254740992", "includeDeleted=perhaps", "sort=unknown"]) {
        const res = await app.request(`/internal/${page}?${query}`, { headers: { cookie } });
        expect(res.status).toBe(400);
      }
      expect((await app.request(`/internal/${page}?page=999`, { headers: { cookie } })).status).toBe(200);
    });

    test("detail access audits distinct actor and target IDs, including denied probes", async () => {
      const { app } = buildTestApp(pg.db, pg.url);
      const { user: op, cookie } = await operator();
      const target = await createTestUser(pg.db);
      const account = await personalAccount(target.id);
      const targetId = page === "users" ? target.id : account.id;
      const info = spyOn(console, "info").mockImplementation(() => {});
      const warn = spyOn(console, "warn").mockImplementation(() => {});
      try {
        const result = await app.request(`/internal/${page}/${targetId}`, { headers: { cookie } });
        expect(result.status).toBe(200);
        expect(result.headers.get("cache-control")).toBe("private, no-store");
        const access = info.mock.calls.map((args) => String(args[0])).find((line) => line.includes(`internal.${page}.detail.access`));
        const targetField = page === "users" ? "targetUserId" : "targetAccountId";
        expect(JSON.parse(access!)).toMatchObject({ actorId: op.id, [targetField]: targetId });
        const { cookie: targetCookie } = await createTestSession(pg.db, target.id);
        expect((await app.request(`/internal/${page}/${targetId}`, { headers: { cookie: targetCookie } })).status).toBe(404);
        const denied = warn.mock.calls.map((args) => String(args[0])).find((line) => line.includes(`internal.${page}.detail.denied`));
        expect(JSON.parse(denied!)).toMatchObject({ actorId: target.id, [targetField]: targetId });
        for (const id of ["invalid-id", crypto.randomUUID()]) {
          expect((await app.request(`/internal/${page}/${id}`, { headers: { cookie } })).status).toBe(404);
        }
        expect((await app.request(`/internal/${page}/${targetId}`)).headers.get("location")).toBe("/login");
      } finally { info.mockRestore(); warn.mockRestore(); }
    });
  });
}
