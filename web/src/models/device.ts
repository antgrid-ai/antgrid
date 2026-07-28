import { z } from "zod";
import { Prisma, type Device } from "../generated/prisma/client.js";
import type { DB, Tx } from "../db/index.js";

export const DeviceKindSchema = z.enum(["agent", "app"]);
export const PlatformSchema = z.enum(["macos", "windows", "linux", "ios", "android"]);
export type DeviceKind = z.infer<typeof DeviceKindSchema>;
export type Platform = z.infer<typeof PlatformSchema>;

export type DeviceRow = Device;

export async function countActiveDevices(db: Tx, userId: string): Promise<number> {
  return db.device.count({ where: { userId, revokedAt: null } });
}

export async function listActiveDevices(db: Tx, userId: string): Promise<DeviceRow[]> {
  return db.device.findMany({
    where: { userId, revokedAt: null },
    orderBy: { activatedAt: "desc" },
  });
}

export async function findDeviceByComposite(
  db: DB,
  userId: string,
  deviceId: string
): Promise<DeviceRow | null> {
  return db.device.findUnique({ where: { userId_deviceId: { userId, deviceId } } });
}

export type CheckCapResult =
  | { kind: "cap"; limit: number; devices: DeviceRow[] }
  | { kind: "ok"; device: DeviceRow };

/**
 * Inside the caller's transaction: take an advisory lock on the user, verify
 * the active-device count is under `deviceLimit`, and upsert the device (or
 * report which devices would have to be revoked). The lock + single-statement
 * UPSERT close the count → insert TOCTOU window. This is the fair-use device
 * cap, NOT the paid axis — concurrent remote agents (`sessionLimit`) are gated
 * separately at the relay on connect.
 */
export async function checkCapAndUpsert(
  tx: Tx,
  args: {
    userId: string;
    deviceLimit: number;
    deviceId: string;
    publicKey: Uint8Array;
    kind: DeviceKind;
    platform: Platform;
    displayName: string;
  }
): Promise<CheckCapResult> {
  // Per-user advisory lock for the duration of this transaction.
  await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${args.userId}))`;

  // Single round-trip: active count + whether this device already exists active.
  const counts = await tx.$queryRaw<
    { active: bigint; existing_active: bigint }[]
  >`
    SELECT
      COUNT(*) FILTER (WHERE revoked_at IS NULL) AS active,
      COUNT(*) FILTER (WHERE revoked_at IS NULL AND device_id = ${args.deviceId}) AS existing_active
    FROM devices WHERE user_id = ${args.userId}
  `;
  const activeCount = Number(counts[0].active);
  const isReactivatingActive = Number(counts[0].existing_active) > 0;

  if (!isReactivatingActive && activeCount >= args.deviceLimit) {
    const devices = await listActiveDevices(tx, args.userId);
    return { kind: "cap", limit: args.deviceLimit, devices };
  }

  const pkBuf = Buffer.from(args.publicKey);
  const upserted = await tx.device.upsert({
    where: { userId_deviceId: { userId: args.userId, deviceId: args.deviceId } },
    create: {
      userId: args.userId,
      deviceId: args.deviceId,
      publicKey: pkBuf,
      kind: args.kind,
      platform: args.platform,
      displayName: args.displayName,
    },
    update: {
      revokedAt: null,
      publicKey: pkBuf,
      displayName: args.displayName,
      kind: args.kind,
      platform: args.platform,
    },
  });
  return { kind: "ok", device: upserted };
}

export async function markDeviceRevoked(db: DB, deviceUuid: string): Promise<void> {
  await db.device.update({
    where: { id: deviceUuid },
    data: { revokedAt: new Date() },
  });
}

export async function listAppDeviceKeys(db: Tx, userId: string): Promise<Buffer[]> {
  const rows = await db.device.findMany({
    where: { userId, kind: "app" as DeviceKind, revokedAt: null },
    select: { publicKey: true },
  });
  return rows.map((r) => Buffer.from(r.publicKey));
}

export async function listAppDevicePeers(
  db: Tx,
  userId: string
): Promise<{ deviceId: string; publicKey: Buffer }[]> {
  // Same filter as listAppDeviceKeys — keep the two in lockstep until Phase C
  // deletes the keys-only variant.
  const rows = await db.device.findMany({
    where: { userId, kind: "app" as DeviceKind, revokedAt: null },
    select: { deviceId: true, publicKey: true },
  });
  return rows.map((r) => ({ deviceId: r.deviceId, publicKey: Buffer.from(r.publicKey) }));
}

export { Prisma };
