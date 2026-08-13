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

/** Numerator for `appDeviceLimit` — the cap counts `kind:"app"` rows only, so
 *  anything metering it against every kind reads as a cap the user cannot fill. */
export async function countActiveAppDevices(db: Tx, userId: string): Promise<number> {
  return db.device.count({ where: { userId, kind: "app" as DeviceKind, revokedAt: null } });
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
  | { kind: "app_device_cap"; limit: number; devices: DeviceRow[] }
  | { kind: "worker_cap"; limit: number; devices: DeviceRow[] }
  | { kind: "ok"; device: DeviceRow };

/**
 * Inside the caller's transaction: take an advisory lock on the user, verify
 * both caps, and upsert the device (or report which devices would have to be
 * revoked). The lock + single-statement UPSERT close the count → insert TOCTOU
 * window, which is why both counts come from one query under the same lock.
 *
 * One cap per kind, and a registration is only ever measured against its own:
 * `workerLimit` is the paid axis over active `kind:"agent"` rows, `appDeviceLimit`
 * an abuse bound over active `kind:"app"` rows. A full phone ceiling must never
 * refuse a build machine, and vice versa. A reconnecting device that is already
 * active at its own kind passes.
 */
export async function checkCapAndUpsert(
  tx: Tx,
  args: {
    userId: string;
    appDeviceLimit: number;
    workerLimit: number;
    deviceId: string;
    publicKey: Uint8Array;
    kind: DeviceKind;
    platform: Platform;
    displayName: string;
  }
): Promise<CheckCapResult> {
  // Per-user advisory lock for the duration of this transaction.
  await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${args.userId}))`;

  // Single round-trip: both cap counts + whether this device already exists
  // active at each kind. Every count is kind-scoped, including the reactivation
  // exemptions: `kind` and `deviceUuid` are both client-supplied, so an
  // exemption that ignored kind would let an account at one cap re-POST an
  // active row under the other kind and have the upsert promote it — buying
  // rows on the full axis up to the other axis's limit.
  const counts = await tx.$queryRaw<
    {
      active_apps: bigint;
      active_agents: bigint;
      existing_active_app: bigint;
      existing_active_agent: bigint;
    }[]
  >`
    SELECT
      COUNT(*) FILTER (WHERE revoked_at IS NULL AND kind = 'app') AS active_apps,
      COUNT(*) FILTER (WHERE revoked_at IS NULL AND kind = 'agent') AS active_agents,
      COUNT(*) FILTER (WHERE revoked_at IS NULL AND device_id = ${args.deviceId} AND kind = 'app')
        AS existing_active_app,
      COUNT(*) FILTER (WHERE revoked_at IS NULL AND device_id = ${args.deviceId} AND kind = 'agent')
        AS existing_active_agent
    FROM devices WHERE user_id = ${args.userId}
  `;
  const activeAppCount = Number(counts[0].active_apps);
  const activeAgentCount = Number(counts[0].active_agents);
  const isReactivatingActiveApp = Number(counts[0].existing_active_app) > 0;
  const isReactivatingActiveAgent = Number(counts[0].existing_active_agent) > 0;

  if (args.kind === "app" && !isReactivatingActiveApp && activeAppCount >= args.appDeviceLimit) {
    // App rows only: the remediation list must offer the phones and controllers
    // actually consuming the cap, never the user's build machines.
    const devices = (await listActiveDevices(tx, args.userId)).filter((d) => d.kind === "app");
    return { kind: "app_device_cap", limit: args.appDeviceLimit, devices };
  }

  if (args.kind === "agent" && !isReactivatingActiveAgent && activeAgentCount >= args.workerLimit) {
    // Agent rows only: the remediation list must offer the machines actually
    // consuming the cap, never the user's phone.
    const devices = (await listActiveDevices(tx, args.userId)).filter((d) => d.kind === "agent");
    return { kind: "worker_cap", limit: args.workerLimit, devices };
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
  // Same filter as listAppDeviceKeys — keep the two in lockstep; they list the
  // same active app devices and differ only in the columns selected.
  const rows = await db.device.findMany({
    where: { userId, kind: "app" as DeviceKind, revokedAt: null },
    select: { deviceId: true, publicKey: true },
  });
  return rows.map((r) => ({ deviceId: r.deviceId, publicKey: Buffer.from(r.publicKey) }));
}

export { Prisma };
