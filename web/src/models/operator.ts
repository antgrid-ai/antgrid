// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { z } from "zod";
import { Prisma } from "../generated/prisma/client.js";
import type { Tx } from "../db/index.js";
import { resolveBillingAccountIds } from "./account-member.js";
import { activeSubscriptionWhere, effectiveActiveSubscription } from "./subscription.js";
import { MOBILE_PLATFORM_SQL } from "./device.js";
import { readCapabilities, type Capabilities } from "../billing/capabilities.js";

const page = z.string().regex(/^[1-9]\d*$/).default("1").transform(Number)
  .refine((value) => Number.isSafeInteger(value) && value <= Math.floor(Number.MAX_SAFE_INTEGER / 50));
const toggle = z.enum(["true", "false"]).default("false").transform((value) => value === "true");
const commonQuery = { page, search: z.string().trim().max(200).default(""), includeDeleted: toggle };
export const OperatorUsersQuerySchema = z.object({ ...commonQuery, sort: z.enum(["newest", "activity"]).default("newest") }).strict();
export const OperatorAccountsQuerySchema = z.object({ ...commonQuery, teamsOnly: toggle, paidOnly: toggle }).strict();
export type UsersQuery = z.infer<typeof OperatorUsersQuerySchema>;
export type AccountsQuery = z.infer<typeof OperatorAccountsQuerySchema>;
export const OPERATOR_PAGE_SIZE = 50;

function literalSearch(value: string): string {
  return value.replace(/[\\%_]/g, "\\$&");
}

const identitySelect = { id: true, name: true, email: true } as const;
const accountSelect = {
  id: true, userId: true, country: true, countrySource: true, billingProvider: true,
  createdAt: true, updatedAt: true, deletedAt: true, user: { select: identitySelect },
} as const;
const userSelect = {
  ...identitySelect, emailVerified: true, createdAt: true, registrationOrigin: true, activationOrigin: true,
  ownedProductAccount: { select: { id: true, deletedAt: true } },
  accounts: { select: { id: true, providerId: true, createdAt: true, updatedAt: true } },
} as const;
const subscriptionSelect = {
  id: true, accountId: true, tier: true, status: true, provider: true, promotional: true,
  workerLimit: true, appDeviceLimit: true, seats: true, capabilities: true,
  trialStartedAt: true, trialEndsAt: true, currentPeriodEnd: true, cancelledAt: true,
  createdAt: true, updatedAt: true,
  plan: { select: { id: true, slug: true, label: true, trial: true } },
} as const;
const deviceSelect = {
  id: true, userId: true, deviceId: true, kind: true, platform: true, displayName: true,
  activatedAt: true, lastSeenAt: true, revokedAt: true, mobileAccessEnabled: true,
  relayUrl: true, machineName: true,
} as const;
const inviteSelect = {
  id: true, accountId: true, email: true, role: true, status: true, createdBy: true,
  expiresAt: true, resolvedAt: true, deliveryStatus: true, createdAt: true, updatedAt: true,
} as const;

export type OperatorSubscription = Omit<Prisma.SubscriptionGetPayload<{ select: typeof subscriptionSelect }>, "capabilities"> & { capabilities: Capabilities };
export type OperatorDevice = Prisma.DeviceGetPayload<{ select: typeof deviceSelect }>;
type AccountIdentity = Prisma.ProductAccountGetPayload<{ select: typeof accountSelect }>;
type UserIdentity = Prisma.UserGetPayload<{ select: typeof userSelect }>;
type Usage = {
  machines: number; phones: number; desktopControllers: number; activeSessions: number;
  lastObservedActivity: Date | null;
  lastObservedActivityIso: string | null;
};
const emptyUsage = (): Usage => ({ machines: 0, phones: 0, desktopControllers: 0, activeSessions: 0, lastObservedActivity: null, lastObservedActivityIso: null });
export type OperatorUserRow = Omit<UserIdentity, "ownedProductAccount" | "accounts"> & Usage & {
  deletedAt: Date | null; ownedAccountId: string | null; billingAccountId: string | null;
  subscription: OperatorSubscription | null; credentials: UserIdentity["accounts"];
};
export type OperatorAccountRow = Omit<AccountIdentity, "user"> & Usage & {
  owner: AccountIdentity["user"]; subscription: OperatorSubscription | null;
  occupiedSeats: number; pendingInvites: number;
};

async function activeSubscriptions(db: Tx, accountIds: string[], now: Date) {
  const result = new Map<string, OperatorSubscription | null>();
  if (!accountIds.length) return result;
  const rows = await db.subscription.findMany({
    where: activeSubscriptionWhere({ in: accountIds }, now),
    select: subscriptionSelect,
    orderBy: [{ createdAt: "desc" }, { id: "asc" }],
  });
  const grouped = new Map<string, OperatorSubscription[]>();
  for (const stored of rows) {
    const row = { ...stored, capabilities: readCapabilities(stored.capabilities) };
    const group = grouped.get(row.accountId) ?? [];
    group.push(row);
    grouped.set(row.accountId, group);
  }
  for (const id of accountIds) result.set(id, effectiveActiveSubscription(grouped.get(id) ?? []));
  return result;
}

async function usageForUsers(db: Tx, ids: string[], now: Date): Promise<Map<string, Usage>> {
  if (!ids.length) return new Map();
  const rows = await db.$queryRaw<(Usage & { userId: string })[]>(Prisma.sql`
    WITH device_usage AS (
      SELECT user_id,
        COUNT(*) FILTER (WHERE revoked_at IS NULL AND kind = 'agent')::int AS machines,
        COUNT(*) FILTER (WHERE revoked_at IS NULL AND kind = 'app' AND ${MOBILE_PLATFORM_SQL})::int AS phones,
        COUNT(*) FILTER (WHERE revoked_at IS NULL AND kind = 'app' AND NOT (${MOBILE_PLATFORM_SQL}))::int AS controllers,
        MAX(last_seen_at) AS observed
      FROM devices WHERE user_id IN (${Prisma.join(ids)}) GROUP BY user_id
    ), session_usage AS (
      SELECT "userId", COUNT(*) FILTER (WHERE "expiresAt" > ${now})::int AS active,
        MAX("updatedAt") AS observed
      FROM session WHERE "userId" IN (${Prisma.join(ids)}) GROUP BY "userId"
    )
    SELECT u.id AS "userId", COALESCE(d.machines, 0) AS machines,
      COALESCE(d.phones, 0) AS phones, COALESCE(d.controllers, 0) AS "desktopControllers",
      COALESCE(s.active, 0) AS "activeSessions", GREATEST(d.observed, s.observed) AS "lastObservedActivity",
      TO_CHAR(GREATEST(d.observed, s.observed) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS "lastObservedActivityIso"
    FROM "user" u LEFT JOIN device_usage d ON d.user_id = u.id
      LEFT JOIN session_usage s ON s."userId" = u.id
    WHERE u.id IN (${Prisma.join(ids)})
  `);
  return new Map(rows.map(({ userId, ...usage }) => [userId, usage]));
}

async function userRows(db: Tx, identities: UserIdentity[], now: Date): Promise<OperatorUserRow[]> {
  const ids = identities.map((user) => user.id);
  const [billing, usage] = await Promise.all([resolveBillingAccountIds(db, ids), usageForUsers(db, ids, now)]);
  const subscriptions = await activeSubscriptions(db, [...new Set([...billing.values()].filter((id): id is string => id !== null))], now);
  return identities.map(({ ownedProductAccount, accounts, ...identity }) => {
    const billingAccountId = billing.get(identity.id) ?? null;
    return { ...identity, ...usage.get(identity.id) ?? emptyUsage(),
      deletedAt: ownedProductAccount?.deletedAt ?? null, ownedAccountId: ownedProductAccount?.id ?? null,
      billingAccountId, subscription: billingAccountId ? subscriptions.get(billingAccountId) ?? null : null,
      credentials: accounts };
  });
}

export async function loadOperatorUsers(db: Tx, query: UsersQuery, now = new Date()) {
  const searchValue = literalSearch(query.search);
  const where: Prisma.UserWhereInput = {
    ...(query.search ? { OR: [{ name: { contains: searchValue, mode: "insensitive" } }, { email: { contains: searchValue, mode: "insensitive" } }] } : {}),
    ...(!query.includeDeleted ? { AND: [{ OR: [{ ownedProductAccount: null }, { ownedProductAccount: { deletedAt: null } }] }] } : {}),
  };
  const search = query.search ? Prisma.sql`AND (u.name ILIKE ${`%${searchValue}%`} OR u.email::text ILIKE ${`%${searchValue}%`})` : Prisma.empty;
  const deleted = query.includeDeleted ? Prisma.empty : Prisma.sql`AND NOT EXISTS (SELECT 1 FROM product_accounts a WHERE a.user_id = u.id AND a.deleted_at IS NOT NULL)`;
  const sort = query.sort === "activity" ? Prisma.sql`GREATEST(d.observed, s.observed) DESC NULLS LAST, u.id ASC` : Prisma.sql`u."createdAt" DESC, u.id ASC`;
  const [total, ids] = await Promise.all([
    db.user.count({ where }),
    db.$queryRaw<{ id: string }[]>(Prisma.sql`
      SELECT u.id FROM "user" u
      LEFT JOIN (SELECT user_id, MAX(last_seen_at) AS observed FROM devices GROUP BY user_id) d ON d.user_id = u.id
      LEFT JOIN (SELECT "userId", MAX("updatedAt") AS observed FROM session GROUP BY "userId") s ON s."userId" = u.id
      WHERE TRUE ${search} ${deleted} ORDER BY ${sort}
      LIMIT ${OPERATOR_PAGE_SIZE} OFFSET ${(query.page - 1) * OPERATOR_PAGE_SIZE}
    `),
  ]);
  const identities = await db.user.findMany({ where: { id: { in: ids.map((row) => row.id) } }, select: userSelect });
  const rows = await userRows(db, identities, now);
  const mapped = new Map(rows.map((row) => [row.id, row]));
  return { rows: ids.map(({ id }) => mapped.get(id)!), total, page: query.page, pageSize: OPERATOR_PAGE_SIZE };
}

async function accountRows(db: Tx, accounts: AccountIdentity[], now: Date): Promise<OperatorAccountRow[]> {
  if (!accounts.length) return [];
  const ids = accounts.map((account) => account.id);
  const [subscriptions, members, pendingInvites] = await Promise.all([
    activeSubscriptions(db, ids, now),
    db.accountMember.findMany({ where: { accountId: { in: ids }, status: "active" }, select: { accountId: true, userId: true } }),
    db.accountInvite.groupBy({ by: ["accountId"], where: { accountId: { in: ids }, status: "pending", expiresAt: { gt: now } }, _count: { _all: true } }),
  ]);
  const userIds = [...new Set([...accounts.map((account) => account.userId), ...members.map((member) => member.userId)])];
  const [billing, usage] = await Promise.all([resolveBillingAccountIds(db, userIds), usageForUsers(db, userIds, now)]);
  const totals = new Map(ids.map((id) => [id, emptyUsage()]));
  for (const userId of userIds) {
    const id = billing.get(userId);
    const total = id ? totals.get(id) : undefined;
    const value = usage.get(userId);
    if (!total || !value) continue;
    for (const key of ["machines", "phones", "desktopControllers", "activeSessions"] as const) total[key] += value[key];
    if (value.lastObservedActivityIso && (!total.lastObservedActivityIso || value.lastObservedActivityIso > total.lastObservedActivityIso)) {
      total.lastObservedActivity = value.lastObservedActivity;
      total.lastObservedActivityIso = value.lastObservedActivityIso;
    }
  }
  const seats = new Map<string, number>();
  for (const member of members) seats.set(member.accountId, (seats.get(member.accountId) ?? 0) + 1);
  const invites = new Map(pendingInvites.map((invite) => [invite.accountId, invite._count._all]));
  return accounts.map(({ user, ...account }) => ({ ...account, owner: user, ...totals.get(account.id)!,
    subscription: subscriptions.get(account.id) ?? null, occupiedSeats: seats.get(account.id) ?? 0,
    pendingInvites: invites.get(account.id) ?? 0 }));
}

export async function loadOperatorAccounts(db: Tx, query: AccountsQuery, now = new Date()) {
  const searchValue = literalSearch(query.search);
  const accounts = await db.productAccount.findMany({
    where: {
      ...(!query.includeDeleted ? { deletedAt: null } : {}),
      ...(query.search ? { OR: [...(z.uuid().safeParse(query.search).success ? [{ id: query.search }] : []),
        { user: { OR: [{ name: { contains: searchValue, mode: "insensitive" as const } }, { email: { contains: searchValue, mode: "insensitive" as const } }] } }] } : {}),
    },
    select: accountSelect, orderBy: [{ createdAt: "desc" }, { id: "asc" }],
  });
  const candidates = await activeSubscriptions(db, accounts.map((account) => account.id), now);
  const filtered = accounts.filter((account) => {
    const sub = candidates.get(account.id);
    if (query.teamsOnly && (!sub || sub.seats <= 1)) return false;
    if (query.paidOnly && (!sub || sub.plan.slug === "free" || sub.tier === "free" || sub.tier === "trial" || sub.plan.trial || sub.trialStartedAt || sub.trialEndsAt || sub.promotional || !["paddle", "razorpay", "manual"].includes(sub.provider ?? ""))) return false;
    return true;
  });
  const rows = await accountRows(db, filtered.slice((query.page - 1) * OPERATOR_PAGE_SIZE, query.page * OPERATOR_PAGE_SIZE), now);
  return { rows, total: filtered.length, page: query.page, pageSize: OPERATOR_PAGE_SIZE };
}

export async function loadOperatorUser(db: Tx, id: string, now = new Date()) {
  const identity = await db.user.findUnique({ where: { id }, select: userSelect });
  if (!identity) return null;
  const [row] = await userRows(db, [identity], now);
  const accountIds = [...new Set([row.ownedAccountId, row.billingAccountId].filter((value): value is string => value !== null))];
  const [accounts, memberships, devices, sessions, invites, waitlist] = await Promise.all([
    db.productAccount.findMany({ where: { id: { in: accountIds } }, select: accountSelect }),
    db.accountMember.findMany({ where: { userId: id }, orderBy: [{ joinedAt: "desc" }, { id: "asc" }], select: {
      id: true, accountId: true, userId: true, role: true, status: true, joinedAt: true, endedAt: true,
      account: { select: accountSelect },
    } }),
    db.device.findMany({ where: { userId: id }, select: deviceSelect, orderBy: [{ activatedAt: "desc" }, { id: "asc" }] }),
    db.session.findMany({ where: { userId: id }, select: { id: true, createdAt: true, updatedAt: true, expiresAt: true }, orderBy: [{ updatedAt: "desc" }, { id: "asc" }] }),
    db.accountInvite.findMany({ where: { email: identity.email, status: "pending", expiresAt: { gt: now } }, select: inviteSelect, orderBy: { createdAt: "desc" } }),
    db.waitlistSignup.findFirst({ where: { email: { equals: identity.email, mode: "insensitive" } }, select: { id: true, email: true, source: true, createdAt: true } }),
  ]);
  return { ...row, ownedAccount: accounts.find((account) => account.id === row.ownedAccountId) ?? null,
    billingAccount: accounts.find((account) => account.id === row.billingAccountId) ?? null,
    memberships, devices, sessions, invites, waitlist };
}
export type OperatorUserDetail = NonNullable<Awaited<ReturnType<typeof loadOperatorUser>>>;

export async function loadOperatorAccount(db: Tx, id: string, now = new Date()) {
  if (!z.uuid().safeParse(id).success) return null;
  const account = await db.productAccount.findUnique({ where: { id }, select: accountSelect });
  if (!account) return null;
  const [row] = await accountRows(db, [account], now);
  const [memberships, invites, subscriptions, billingCustomers] = await Promise.all([
    db.accountMember.findMany({ where: { accountId: id }, orderBy: [{ joinedAt: "asc" }, { id: "asc" }], select: {
      id: true, accountId: true, userId: true, role: true, status: true, joinedAt: true, endedAt: true,
      user: { select: userSelect },
    } }),
    db.accountInvite.findMany({ where: { accountId: id }, select: inviteSelect, orderBy: [{ createdAt: "desc" }, { id: "asc" }] }),
    db.subscription.findMany({ where: { accountId: id }, select: subscriptionSelect, orderBy: [{ createdAt: "desc" }, { id: "asc" }] }),
    db.billingCustomer.findMany({ where: { accountId: id }, select: { provider: true, providerCustomerId: true }, orderBy: { provider: "asc" } }),
  ]);
  // A fallback owner can bill here without a membership; the operator must see
  // the same population included in the account's aggregate observations.
  const identities = new Map(memberships.map((member) => [member.user.id, member.user]));
  const owner = await db.user.findUnique({ where: { id: account.userId }, select: userSelect });
  if (owner) identities.set(owner.id, owner);
  const [users, devices] = await Promise.all([
    userRows(db, [...identities.values()], now),
    db.device.findMany({ where: { userId: { in: [...identities.keys()] } }, select: deviceSelect, orderBy: [{ activatedAt: "desc" }, { id: "asc" }] }),
  ]);
  const userMap = new Map(users.map((user) => [user.id, { ...user, devices: devices.filter((device) => device.userId === user.id) }]));
  const members: Array<Omit<typeof memberships[number], "user" | "joinedAt"> & {
    joinedAt: Date | null; retainedMembership: boolean;
    user: NonNullable<ReturnType<typeof userMap.get>>; currentBilling: boolean;
  }> = memberships.map(({ user, ...membership }) => ({ ...membership, retainedMembership: true,
    user: userMap.get(user.id)!, currentBilling: userMap.get(user.id)!.billingAccountId === id }));
  const fallbackOwner = userMap.get(account.userId);
  if (fallbackOwner?.billingAccountId === id && !members.some((member) => member.userId === account.userId && member.currentBilling)) {
    members.push({ id: `owner:${account.userId}`, accountId: id, userId: account.userId, role: "owner", status: "Ownership fallback", joinedAt: null, endedAt: null, user: fallbackOwner, currentBilling: true, retainedMembership: false });
  }
  return { ...row, members, invites: invites.map((invite) => ({ ...invite,
    status: invite.status === "pending" && invite.expiresAt <= now ? "expired" : invite.status })),
    subscriptions: subscriptions.map((sub) => ({ ...sub, capabilities: readCapabilities(sub.capabilities) })), billingCustomers };
}
export type OperatorAccountDetail = NonNullable<Awaited<ReturnType<typeof loadOperatorAccount>>>;
