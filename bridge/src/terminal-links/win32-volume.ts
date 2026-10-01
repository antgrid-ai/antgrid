import { dlopen, FFIType, ptr } from "bun:ffi";
import { logger } from "../logger";
import { foldAsciiCase, hasDriveLetterAt, isSeparator } from "./chars";

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

function separatorAt(path: string, from: number): number {
  for (let i = from; i < path.length; i++) if (isSeparator(path[i])) return i;
  return path.length;
}

function isPlainName(name: string): boolean {
  for (let i = 0; i < name.length; i++) {
    const code = name.charCodeAt(i);
    if (code <= 0x1f || (code >= 0x7f && code <= 0x9f) || code === 0x3a) return false;
  }
  return true;
}

/**
 * The `\\server\share` a UNC path names, as the folded key a trust set holds
 * and as the length of that prefix in `path`. Undefined for everything else:
 * the `\\?\` and `\\.\` device namespaces, a name with a colon or a control
 * character, and a path with no share, none of which is ever a volume to trust.
 */
export function uncShareOf(path: string): { key: string; end: number } | undefined {
  if (!isSeparator(path[0]) || !isSeparator(path[1])) return undefined;
  const serverEnd = separatorAt(path, 2);
  const server = path.slice(2, serverEnd);
  if (server === "" || server === "." || server === "?" || serverEnd >= path.length) return undefined;
  const shareEnd = separatorAt(path, serverEnd + 1);
  const share = path.slice(serverEnd + 1, shareEnd);
  if (share === "" || !isPlainName(server) || !isPlainName(share)) return undefined;
  // ASCII-only fold: a host name is resolved by DNS/NetBIOS, which keep U+0131
  // and U+017F apart from `i` and `s`, so a Unicode fold would let a different
  // server inherit the trusted share's key and be stat'ed.
  return { key: foldAsciiCase(`\\\\${server}\\${share}`), end: shareEnd };
}

/**
 * True when `abs`'s volume is a local disk, or is one of `trusted` (drive
 * letters, either case, or a UNC share key from `uncShareOf`; the checkout
 * root's own volume, where the bridge already works). Always true off Windows.
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
  if (!hasDriveLetterAt(abs)) {
    const share = uncShareOf(abs);
    return share !== undefined && trusted.has(share.key);
  }
  const letter = abs[0]!.toUpperCase();
  if (trusted.has(letter) || trusted.has(letter.toLowerCase())) return true;
  return driveIsLocal(letter);
}
