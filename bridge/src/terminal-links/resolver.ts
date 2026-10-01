import { posix, win32 } from "node:path";
import { externalSafeImageMime } from "../file-tree";
import { hasDriveLetterAt, isDriveAbsolute, isSeparator } from "./chars";
import { isRefusedPathShape, type PrintedPathBase, type PrintedPathKind } from "./grammar";

/** Where a printed relative path may be anchored. Every field is optional:
 *  nothing here falls back to `process.cwd()`, because the bridge's own working
 *  directory says nothing about where the printing program was. */
export interface LinkBases {
  liveCwd?: string;
  spawnCwd?: string;
  checkoutRoot?: string;
}

export interface Candidate {
  /** The path as printed (one of the claim's variants), never resolved. */
  text: string;
  base: PrintedPathBase;
  abs: string;
}

const MAX_BASE_CHARS = 4096;

function pathApi(platform: NodeJS.Platform): typeof posix {
  return platform === "win32" ? win32 : posix;
}

/** Drive-qualified on Windows: a bare `\x` or `/x` is rooted on the current
 *  drive, which is not a place a printed path can name. */
export function isAbsoluteFor(path: string, platform: NodeJS.Platform): boolean {
  return platform === "win32" ? isDriveAbsolute(path) : path.startsWith("/");
}

function fold(path: string, platform: NodeJS.Platform): string {
  return platform === "win32" ? path.toLowerCase() : path;
}

/** Lexical containment, case-folded on Windows like `containedBy` in
 *  `file-tree.ts`: a printed path and the root it is tested against can
 *  disagree on the case of the same drive letter. Links are not followed. */
export function isInsideRoot(abs: string, root: string, platform: NodeJS.Platform = process.platform): boolean {
  const api = pathApi(platform);
  const a = fold(api.resolve(abs), platform);
  const r = fold(api.resolve(root), platform);
  if (a === r) return true;
  return a.startsWith(r.endsWith(api.sep) ? r : r + api.sep);
}

/** Drops refused and non-absolute bases, and live/spawn cwds that are not
 *  contained in the checkout root. A cwd is client- or program-supplied, so
 *  without the containment rule it would let a terminal choose which
 *  directory this machine probes for the existence of files. */
export function normalizeBases(b: LinkBases, platform: NodeJS.Platform = process.platform): LinkBases {
  const api = pathApi(platform);
  const usable = (p: string | undefined): string | undefined => {
    if (typeof p !== "string" || p.length === 0 || p.length > MAX_BASE_CHARS) return undefined;
    if (!isAbsoluteFor(p, platform) || isRefusedPathShape(p, platform)) return undefined;
    return api.resolve(p);
  };
  const root = usable(b.checkoutRoot);
  const out: LinkBases = {};
  if (root === undefined) return out;
  const live = usable(b.liveCwd);
  const spawn = usable(b.spawnCwd);
  if (live !== undefined && isInsideRoot(live, root, platform)) out.liveCwd = live;
  if (spawn !== undefined && isInsideRoot(spawn, root, platform)) out.spawnCwd = spawn;
  out.checkoutRoot = root;
  return out;
}

/** Order is variants, then live cwd, spawn cwd, checkout root: the most
 *  specific base a shell reported wins over the one the terminal started in. */
export function candidatesFor(
  variants: readonly string[],
  bases: LinkBases,
  platform: NodeJS.Platform = process.platform,
): Candidate[] {
  const api = pathApi(platform);
  const root = bases.checkoutRoot;
  const out: Candidate[] = [];
  const seen = new Set<string>();

  const add = (text: string, base: PrintedPathBase, abs: string): void => {
    if (isRefusedPathShape(abs, platform)) return;
    // Outside the checkout only an image the preview popup can show is
    // worth a stat; anything else would be an oracle for the whole disk.
    if ((root === undefined || !isInsideRoot(abs, root, platform)) && !externalSafeImageMime(abs)) return;
    const key = fold(abs, platform);
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ text, base, abs });
  };

  for (const text of variants) {
    if (isAbsoluteFor(text, platform)) {
      add(text, "a", api.resolve(text));
      continue;
    }
    // Rooted-without-drive and drive-relative forms resolve against the
    // bridge's own current drive or directory, which means nothing here.
    if (platform === "win32" && (isSeparator(text[0]) || hasDriveLetterAt(text))) continue;
    if (platform !== "win32" && text.startsWith("/")) continue;
    const anchors: Array<[PrintedPathBase, string | undefined]> = [
      ["l", bases.liveCwd],
      ["s", bases.spawnCwd],
      ["r", root],
    ];
    for (const [base, dir] of anchors) {
      if (dir !== undefined) add(text, base, api.resolve(dir, text));
    }
  }
  return out;
}

export function classifyPath(
  abs: string,
  status: "file" | "dir",
  checkoutRoot: string | undefined,
  platform: NodeJS.Platform = process.platform,
): PrintedPathKind | undefined {
  if (checkoutRoot !== undefined && isInsideRoot(abs, checkoutRoot, platform)) {
    return status === "dir" ? "d" : "f";
  }
  if (status === "file" && externalSafeImageMime(abs)) return "i";
  return undefined;
}
