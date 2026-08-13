import { randomBytes } from "node:crypto";
import type { PrismaClient } from "../../src/generated/prisma/client.js";
import type { DeviceKind, Platform } from "../../src/models/device.js";
import { PLAN_UUID } from "../../src/models/plan.js";
import { TEST_BETTER_AUTH_SECRET } from "./app.js";

/** HMAC-SHA-256 signature using the same algorithm Hono's serializeSigned uses. */
async function makeSignature(value: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
  return btoa(String.fromCharCode(...new Uint8Array(sig)));
}

export type TestUser = { id: string; email: string };

export async function createTestUser(
  db: PrismaClient,
  email = `u+${randomBytes(4).toString("hex")}@test.local`
): Promise<TestUser> {
  const id = crypto.randomUUID();
  await db.user.create({ data: { id, email, name: email, emailVerified: true } });
  return { id, email };
}

export type TestSubscription = {
  id: string;
  userId: string;
  tier: "trial" | "pro";
  workerLimit: number;
};

export async function createTestSubscription(
  db: PrismaClient,
  userId: string,
  opts: Partial<{
    tier: "trial" | "pro";
    workerLimit: number;
    appDeviceLimit: number;
    planId: string;
    status: string;
    trialEndsAt: Date;
    /** Purchased seat count. Left to the column default of one unless a suite
     *  needs an over-subscribed account (headcount above seats), which is a
     *  legal state no other fixture can reach. */
    seats: number;
  }> = {}
): Promise<TestSubscription> {
  const tier = opts.tier ?? "pro";
  // Deliberately above every real plan value so unrelated suites never trip the
  // worker cap incidentally; cap tests pass an explicit limit.
  const workerLimit = opts.workerLimit ?? (tier === "trial" ? 2 : 10);
  const appDeviceLimit = opts.appDeviceLimit ?? 10;
  const status = opts.status ?? "active";
  const trialEndsAt = opts.trialEndsAt ?? null;
  const planId = opts.planId ?? PLAN_UUID.pro_yearly;
  const account = await db.productAccount.upsert({
    where: { userId },
    create: { userId },
    update: {},
  });
  // Production reaches account_members through the better-auth hooks, which no
  // fixture runs. Without this row every suite would resolve entitlement down
  // the personal-account fallback and prove nothing about membership. Upsert,
  // not create: a second call for the same user would otherwise trip
  // account_members_one_active_per_user_idx.
  await db.accountMember.upsert({
    where: { accountId_userId: { accountId: account.id, userId } },
    create: { accountId: account.id, userId, role: "owner", status: "active" },
    update: {},
  });
  const row = await db.subscription.create({
    data: {
      accountId: account.id,
      planId,
      tier,
      status,
      workerLimit,
      appDeviceLimit,
      trialEndsAt,
      ...(opts.seats !== undefined ? { seats: opts.seats } : {}),
    },
    select: { id: true },
  });
  return { id: row.id, userId, tier, workerLimit };
}

/**
 * Move `userId` onto `accountId` as an active member — the only way to build a
 * team anywhere, since the invite flow does not exist yet.
 *
 * Closes any prior active membership first: the partial unique index rejects a
 * second active row for a user, and every user a fixture has touched already
 * owns one. Also writes the denormalized `user.account_id`, which nothing in
 * `src/` reads but production's join path maintains.
 */
export async function addTestMember(
  db: PrismaClient,
  accountId: string,
  userId: string,
  role: "owner" | "member" = "member"
): Promise<void> {
  await db.accountMember.updateMany({
    where: { userId, status: "active" },
    data: { status: "left", endedAt: new Date() },
  });
  await db.accountMember.upsert({
    where: { accountId_userId: { accountId, userId } },
    create: { accountId, userId, role, status: "active" },
    update: { role, status: "active", endedAt: null },
  });
  await db.user.update({ where: { id: userId }, data: { accountId } });
}

export async function createTestSession(
  db: PrismaClient,
  userId: string
): Promise<{ sessionId: string; cookie: string }> {
  const sessionId = crypto.randomUUID();
  const token = randomBytes(32).toString("base64url");
  const expires = new Date(Date.now() + 24 * 3600 * 1000);
  await db.session.create({
    data: { id: sessionId, userId, token, expiresAt: expires },
  });
  const signature = await makeSignature(token, TEST_BETTER_AUTH_SECRET);
  const signedToken = `${token}.${signature}`;
  return { sessionId, cookie: `better-auth.session_token=${signedToken}` };
}

export async function createTestDevice(
  db: PrismaClient,
  args: {
    userId: string;
    deviceId: string;
    kind?: DeviceKind;
    platform?: Platform;
    displayName?: string;
    publicKey?: Uint8Array;
  }
): Promise<{ id: string; deviceId: string; publicKey: Uint8Array }> {
  const publicKey = args.publicKey ?? randomBytes(32);
  const row = await db.device.create({
    data: {
      userId: args.userId,
      deviceId: args.deviceId,
      kind: args.kind ?? "agent",
      platform: args.platform ?? "linux",
      displayName: args.displayName ?? args.deviceId,
      publicKey: Buffer.from(publicKey),
    },
    select: { id: true, deviceId: true, publicKey: true },
  });
  return { id: row.id, deviceId: row.deviceId, publicKey: new Uint8Array(row.publicKey) };
}
