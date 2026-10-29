import { cpus, freemem, totalmem } from "node:os";

function sampleCpuTimes(): { busy: number; total: number } {
  let busy = 0;
  let total = 0;
  for (const { times } of cpus()) {
    const all = times.user + times.nice + times.sys + times.irq + times.idle;
    total += all;
    busy += all - times.idle;
  }
  return { busy, total };
}

/** Under this much accumulated CPU time (ms, summed over cores) a delta is too
 *  small to be a rate, so the previous figure stands. Every core shares one
 *  sampler and can ask within the same instant. */
const MIN_CPU_WINDOW_MS = 1000;

let lastCpu = sampleCpuTimes();
let lastCpuPercent: number | undefined;

/** Whole-machine busy share since the last usable sample, 0-100. Primed at
 *  import, so the first report averages over the process's lifetime. */
export function readCpuPercent(): number | undefined {
  const now = sampleCpuTimes();
  const total = now.total - lastCpu.total;
  if (total >= MIN_CPU_WINDOW_MS) {
    lastCpuPercent = Math.min(100, Math.max(0, Math.round(((now.busy - lastCpu.busy) / total) * 100)));
    lastCpu = now;
  }
  return lastCpuPercent;
}

/** This machine's RAM and CPU load for `machine:stats`, as the OS reports it.
 *  macOS counts only truly free pages as free, so the available figure reads
 *  low there. CPU is absent when the OS reports no per-core times. */
export function readMachineStats(): { ramTotalBytes: number; ramAvailableBytes: number; cpuPercent?: number } {
  const cpuPercent = readCpuPercent();
  return {
    ramTotalBytes: totalmem(),
    ramAvailableBytes: freemem(),
    ...(cpuPercent === undefined ? {} : { cpuPercent }),
  };
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
