import { freemem, totalmem } from "node:os";

/** How often a core re-sends `machine:stats` once an app has attached. */
export const MACHINE_STATS_INTERVAL_MS = 30_000;

/** This machine's RAM for `machine:stats`, as the OS reports it. macOS counts
 *  only truly free pages as free, so the available figure reads low there. */
export function readMachineStats(): { ramTotalBytes: number; ramAvailableBytes: number } {
  return { ramTotalBytes: totalmem(), ramAvailableBytes: freemem() };
}

/** What a connected device last said about its own hardware. Every field is
 *  optional: each platform reports a different subset (the macOS and Linux
 *  apps report no storage, for one), and an absent field must render as
 *  "unknown", never as zero. */
export interface DeviceStats {
  model?: string;
  ramTotalBytes?: number;
  ramAvailableBytes?: number;
  storageTotalBytes?: number;
  storageFreeBytes?: number;
  reportedAt: string;
}

/** Latest `device:stats` per device, keyed by phonePubkey like the
 *  paired-phones rows it decorates.
 *
 *  Memory only, deliberately kept out of `paired-phones.json`: the numbers are
 *  stale the moment they land, so persisting them buys nothing, and every write
 *  to that file re-advertises to each connected phone. After a restart a row
 *  shows nothing until its device next connects. */
export interface DeviceStatsStore {
  record(phonePubkey: string, stats: DeviceStats): void;
  get(phonePubkey: string): DeviceStats | undefined;
}

export function createDeviceStatsStore(): DeviceStatsStore {
  const byPubkey = new Map<string, DeviceStats>();
  return {
    record: (pk, stats) => {
      byPubkey.set(pk, { ...stats });
    },
    get: (pk) => byPubkey.get(pk),
  };
}
