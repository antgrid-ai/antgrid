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
    deviceLimit: number;
    planId: string;
    planSlug: "pro_yearly" | "pro_lifetime";
    status: string;
    trialEndsAt: Date;
  }> = {}
): Promise<TestSubscription> {
  const tier = opts.tier ?? "pro";
  // Deliberately above every real plan value so unrelated suites never trip the
  // worker cap incidentally; cap tests pass an explicit limit.
  const workerLimit = opts.workerLimit ?? (tier === "trial" ? 2 : 10);
  const deviceLimit = opts.deviceLimit ?? 10;
  const status = opts.status ?? "active";
  const trialEndsAt = opts.trialEndsAt ?? null;
  const planId =
    opts.planId ??
    (opts.planSlug === "pro_lifetime" ? PLAN_UUID.pro_lifetime : PLAN_UUID.pro_yearly);
  const account = await db.productAccount.upsert({
    where: { userId },
    create: { userId },
    update: {},
  });
  const row = await db.subscription.create({
    data: {
      accountId: account.id,
      planId,
      tier,
      status,
      workerLimit,
      deviceLimit,
      trialEndsAt,
    },
    select: { id: true },
  });
  return { id: row.id, userId, tier, workerLimit };
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
