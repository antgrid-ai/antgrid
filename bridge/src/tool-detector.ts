import { existsSync, statSync } from "node:fs";
import { join, delimiter } from "node:path";
import { platform } from "node:os";
import { KNOWN_AGENTS } from "./known-agents";

export interface DetectedTool {
  tool: string;
  path: string;
}

const WINDOWS_EXTS = [".exe", ".cmd", ".bat", ".ps1"];

/**
 * Resolve `bin` against `pathDirs`, returning the absolute path of the first
 * existing regular file. On Windows each directory is probed with every entry
 * in `exts` (in order) before moving to the next directory — matching cmd.exe's
 * dir-major, ext-major search. The `isFile()` guard rejects directories that
 * happen to share an executable's name. Returns null if nothing matches.
 */
export function findOnPath(
  bin: string,
  pathDirs: string[],
  exts: string[] = WINDOWS_EXTS,
): string | null {
  const isWin = platform() === "win32";
  const candidates = isWin ? exts.map((e) => bin + e) : [bin];
  for (const dir of pathDirs) {
    for (const cand of candidates) {
      const full = join(dir, cand);
      try {
        if (existsSync(full) && statSync(full).isFile()) return full;
      } catch {
        /* ignore */
      }
    }
  }
  return null;
}

export interface DetectOptions {
  pathOverride?: string; // PATH-style string, used in tests
}

/** Memoized result of the production (no-override) probe. Installed tools don't
 *  change within a process, yet detection runs on every control-plane handshake,
 *  re-advertise, and `tools:list` — each call walks the whole PATH × KNOWN_AGENTS
 *  matrix (hundreds of `statSync`s). Cache the no-override result; an explicit
 *  `pathOverride` (tests) always re-probes and never reads or writes this cache. */
let cachedTools: DetectedTool[] | null = null;

export function detectInstalledTools(opts: DetectOptions = {}): DetectedTool[] {
  if (opts.pathOverride === undefined && cachedTools !== null) return cachedTools;
  const pathStr = opts.pathOverride ?? process.env.PATH ?? "";
  const dirs = pathStr.split(delimiter).filter((d) => d.length > 0);
  const out: DetectedTool[] = [];
  for (const [tool, entry] of Object.entries(KNOWN_AGENTS)) {
    const found = findOnPath(entry.bin, dirs);
    if (found) out.push({ tool, path: found });
  }
  if (opts.pathOverride === undefined) cachedTools = out;
  return out;
}

/** Test seam: drop the memoized no-override probe so a test that exercises the
 *  production path starts from a clean cache. */
export function resetToolDetectionCacheForTest(): void {
  cachedTools = null;
}
