import { dlopen, FFIType, ptr } from "bun:ffi";
import { logger } from "../logger";

const log = logger.child({ component: "win32-volume" });

const DRIVE_REMOVABLE = 2;
const DRIVE_FIXED = 3;
const DRIVE_RAMDISK = 6;

/** A drive's type does not change under a running process often enough to be
 *  worth a syscall per candidate path. */
const DRIVE_TYPE_TTL_MS = 60_000;

const kernel32Symbols = {
  GetDriveTypeW: { args: [FFIType.ptr], returns: FFIType.u32 },
} as const;

type Kernel32 = ReturnType<typeof dlopen<typeof kernel32Symbols>>["symbols"];

/** `undefined` = not attempted, `null` = unavailable and already reported. */
let kernel32: Kernel32 | null | undefined;

function loadKernel32(): Kernel32 | null {
  if (kernel32 !== undefined) return kernel32;
  if (process.platform !== "win32") return (kernel32 = null);
  try {
    kernel32 = dlopen("kernel32.dll", kernel32Symbols).symbols;
  } catch (err) {
    log.warn("drive type lookup unavailable: %s", err);
    kernel32 = null;
  }
  return kernel32;
}

const driveTypeCache = new Map<string, { local: boolean; at: number }>();

function driveIsLocal(letter: string): boolean {
  const now = Date.now();
  const hit = driveTypeCache.get(letter);
  if (hit && now - hit.at < DRIVE_TYPE_TTL_MS) return hit.local;
  const api = loadKernel32();
  if (api === null) return false;
  let local = false;
  try {
    const root = new Uint16Array([letter.charCodeAt(0), 0x3a, 0x5c, 0]);
    const type = api.GetDriveTypeW(ptr(root));
    local = type === DRIVE_REMOVABLE || type === DRIVE_FIXED || type === DRIVE_RAMDISK;
  } catch (err) {
    log.debug({ err: String(err) }, "drive type lookup failed");
  }
  driveTypeCache.set(letter, { local, at: now });
  return local;
}

/**
 * True when `abs`'s volume is a local disk, or is one of `trusted` (drive
 * letters, either case; the checkout root's own volume, where the bridge
 * already works). Always true off Windows.
 *
 * A stat on a mapped network drive, or a `subst` of one, does network I/O with
 * zero clicks, and a dead share pins a filesystem worker until the OS gives up.
 * Lexical checks cannot see this: `Z:\x` looks like any other local path.
 */
export function isLocalVolume(
  abs: string,
  trusted: ReadonlySet<string>,
  platform: NodeJS.Platform = process.platform,
): boolean {
  if (platform !== "win32") return true;
  const m = /^([A-Za-z]):/.exec(abs);
  if (!m) return false;
  const letter = m[1]!.toUpperCase();
  if (trusted.has(letter) || trusted.has(letter.toLowerCase())) return true;
  return driveIsLocal(letter);
}
