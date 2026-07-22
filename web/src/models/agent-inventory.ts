import type { Tx } from "../db/index.js";
import type { DeviceKind } from "./device.js";

export type MobileEnabledAgent = {
  deviceId: string;
  displayName: string;
  platform: string;
  publicKey: Buffer;
  relayUrl: string | null;
  lastSeenAt: Date | null;
  machineName: string | null;
};

export async function listMobileEnabledAgents(
  db: Tx,
  userId: string
): Promise<MobileEnabledAgent[]> {
  return db.device.findMany({
    where: {
      userId,
      kind: "agent" as DeviceKind,
      revokedAt: null,
      mobileAccessEnabled: true,
    },
    select: {
      deviceId: true,
      displayName: true,
      platform: true,
      publicKey: true,
      relayUrl: true,
      lastSeenAt: true,
      machineName: true,
    },
    orderBy: { lastSeenAt: { sort: "desc", nulls: "last" } },
  }) as Promise<MobileEnabledAgent[]>;
}
