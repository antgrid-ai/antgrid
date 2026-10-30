import { freemem, totalmem } from "node:os";

/** How often a core re-sends `machine:stats` once an app has attached. */
export const MACHINE_STATS_INTERVAL_MS = 30_000;

type MachineStats = { ramTotalBytes: number; ramAvailableBytes: number };

// Shared by every caller while one read is outstanding: a host runs one core per
// open project, and a handshake and a remote attach can land together, so
// without this each would spawn its own vm_stat and could deliver out of order.
let inFlight: Promise<MachineStats> | null = null;

/** This machine's RAM for `machine:stats`. Never rejects: any failure reading
 *  the macOS figure falls back to `freemem()`. */
export function readMachineStats(): Promise<MachineStats> {
  return (inFlight ??= readMachineStatsNow().finally(() => { inFlight = null; }));
}

async function readMachineStatsNow(): Promise<MachineStats> {
  const ramTotalBytes = totalmem();
  const fromVmStat = process.platform === "darwin" ? await readDarwinAvailable(ramTotalBytes) : null;
  return { ramTotalBytes, ramAvailableBytes: fromVmStat ?? freemem() };
}

// freemem() on macOS counts only never-used pages, so a machine with
// gigabytes of reclaimable file cache reads as nearly full. Spawned rather than
// FFI'd to host_statistics64; async so the 30s tick never stalls the loop.
async function readDarwinAvailable(totalBytes: number): Promise<number | null> {
  try {
    const proc = Bun.spawn(["/usr/bin/vm_stat"], { stdout: "pipe", stderr: "ignore", timeout: 2000 });
    const [text, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
    return code === 0 ? availableFromVmStat(text, totalBytes) : null;
  } catch {
    return null;
  }
}

/** Available bytes from `vm_stat` output, using Activity Monitor's "Memory
 *  Used" (app memory + wired + compressed) so the figure matches what a Mac
 *  user sees there. Null when a field is missing — a format change must fall
 *  back, never report a confident wrong number. */
export function availableFromVmStat(output: string, totalBytes: number): number | null {
  const pageSize = Number(/page size of (\d+) bytes/.exec(output)?.[1]);
  const pages = (label: string): number => {
    const m = new RegExp(`^${label}:\\s+(\\d+)\\.?$`, "m").exec(output);
    return m ? Number(m[1]) : NaN;
  };
  const appPages = pages("Anonymous pages") - pages("Pages purgeable");
  const usedPages = appPages + pages("Pages wired down") + pages("Pages occupied by compressor");
  if (!Number.isFinite(usedPages) || !(pageSize > 0)) return null;
  return Math.min(totalBytes, Math.max(0, totalBytes - usedPages * pageSize));
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
