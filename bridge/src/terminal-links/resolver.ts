import { posix, win32 } from "node:path";
import { externalSafeImageMime } from "../file-tree";
import { foldPathCase, hasDriveLetterAt, isDriveAbsolute, isSeparator } from "./chars";
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
  /** Lexically inside the checkout root, decided once when the candidate is
   *  made so classification need not repeat it. Links are not followed. */
  inside: boolean;
}

const MAX_BASE_CHARS = 4096;
/** Distinct roots, base sets and token sets a process holds on to; a terminal
 *  session has a handful of each, so this only bounds a pathological churn. */
const MAX_MEMO_ENTRIES = 4096;

function pathApi(platform: NodeJS.Platform): typeof posix {
  return platform === "win32" ? win32 : posix;
}

/** Drive-qualified on Windows: a bare `\x` or `/x` is rooted on the current
 *  drive, which is not a place a printed path can name. */
export function isAbsoluteFor(path: string, platform: NodeJS.Platform): boolean {
  return platform === "win32" ? isDriveAbsolute(path) : path.startsWith("/");
}

function fold(path: string, platform: NodeJS.Platform): string {
  return platform === "win32" ? foldPathCase(path) : path;
}

function remember<K, V>(memo: Map<K, V>, key: K, value: V): V {
  if (memo.size >= MAX_MEMO_ENTRIES) {
    const oldest = memo.keys().next();
    if (!oldest.done) memo.delete(oldest.value);
  }
  memo.set(key, value);
  return value;
}

/** A root normalized once: resolved, case-folded and given the trailing
 *  separator a prefix test needs, so testing a path against it is one string
 *  comparison instead of two `path.resolve` calls. */
interface RootInfo {
  folded: string;
  prefix: string;
}

const rootInfos = new Map<string, RootInfo>();

function rootInfoOf(root: string, platform: NodeJS.Platform): RootInfo {
  const key = `${platform}:${root}`;
  const hit = rootInfos.get(key);
  if (hit) return hit;
  const api = pathApi(platform);
  const folded = fold(api.resolve(root), platform);
  return remember(rootInfos, key, { folded, prefix: folded.endsWith(api.sep) ? folded : folded + api.sep });
}

function withinRoot(foldedAbs: string, info: RootInfo): boolean {
  return foldedAbs === info.folded || foldedAbs.startsWith(info.prefix);
}

/** Lexical containment, case-folded on Windows the way NTFS compares names: a
 *  printed path and the root it is tested against can disagree on the case of
 *  the same drive letter. Links are not followed. */
export function isInsideRoot(abs: string, root: string, platform: NodeJS.Platform = process.platform): boolean {
  return withinRoot(fold(pathApi(platform).resolve(abs), platform), rootInfoOf(root, platform));
}

/** `isInsideRoot` for a path that is already resolved, such as a candidate or a
 *  real path a stat walk reached: skips the `path.resolve` of `abs`. */
export function isInsideResolved(abs: string, root: string, platform: NodeJS.Platform = process.platform): boolean {
  return withinRoot(fold(abs, platform), rootInfoOf(root, platform));
}

/** Length-prefixed, so no choice of path text can make two different base sets
 *  share a key. */
function basesKey(platform: NodeJS.Platform, b: LinkBases): string | undefined {
  let key = platform;
  for (const value of [b.checkoutRoot, b.spawnCwd, b.liveCwd]) {
    if (value === undefined) key += "|-";
    else if (typeof value !== "string" || value.length > MAX_BASE_CHARS) return undefined;
    else key += `|${value.length}:${value}`;
  }
  return key;
}

const normalized = new Map<string, LinkBases>();

/** Drops refused and non-absolute bases, and live/spawn cwds that are not
 *  contained in the checkout root. A cwd is client- or program-supplied, so
 *  without the containment rule it would let a terminal choose which
 *  directory this machine probes for the existence of files.
 *
 *  Pure, so the answer for one set of inputs is computed once and the same
 *  frozen object comes back every time: a caller that normalizes on every frame
 *  pays a map lookup, and everything keyed on the object's identity (see
 *  `candidatesFor`) stays warm across frames. */
export function normalizeBases(b: LinkBases, platform: NodeJS.Platform = process.platform): LinkBases {
  const key = basesKey(platform, b);
  const hit = key === undefined ? undefined : normalized.get(key);
  if (hit) return hit;
  const out = Object.freeze(computeBases(b, platform));
  return key === undefined ? out : remember(normalized, key, out);
}

function computeBases(b: LinkBases, platform: NodeJS.Platform): LinkBases {
  const api = pathApi(platform);
  const usable = (p: string | undefined): string | undefined => {
    if (typeof p !== "string" || p.length === 0 || p.length > MAX_BASE_CHARS) return undefined;
    if (!isAbsoluteFor(p, platform) || isRefusedPathShape(p, platform)) return undefined;
    return api.resolve(p);
  };
  const root = usable(b.checkoutRoot);
  const out: LinkBases = {};
  if (root === undefined) return out;
  const info = rootInfoOf(root, platform);
  const live = usable(b.liveCwd);
  const spawn = usable(b.spawnCwd);
  if (live !== undefined && withinRoot(fold(live, platform), info)) out.liveCwd = live;
  if (spawn !== undefined && withinRoot(fold(spawn, platform), info)) out.spawnCwd = spawn;
  out.checkoutRoot = root;
  return out;
}

const candidateMemo = new WeakMap<LinkBases, Map<string, readonly Candidate[]>>();

/** Order is variants, then live cwd, spawn cwd, checkout root: the most
 *  specific base a shell reported wins over the one the terminal started in.
 *
 *  Candidates depend on nothing but the variants and the bases, so for a base
 *  set that cannot change under the memo (the frozen object `normalizeBases`
 *  returns) a token printed again, on the next frame or the next line, costs a
 *  map lookup. The returned list and its candidates are shared and frozen. */
export function candidatesFor(
  variants: readonly string[],
  bases: LinkBases,
  platform: NodeJS.Platform = process.platform,
): readonly Candidate[] {
  if (!Object.isFrozen(bases)) return computeCandidates(variants, bases, platform);
  let memo = candidateMemo.get(bases);
  if (!memo) candidateMemo.set(bases, (memo = new Map()));
  let key: string = platform;
  for (const v of variants) key += `|${v.length}:${v}`;
  const hit = memo.get(key);
  if (hit) return hit;
  return remember(memo, key, Object.freeze(computeCandidates(variants, bases, platform)));
}

function computeCandidates(variants: readonly string[], bases: LinkBases, platform: NodeJS.Platform): Candidate[] {
  const api = pathApi(platform);
  const root = bases.checkoutRoot;
  const info = root === undefined ? undefined : rootInfoOf(root, platform);
  const out: Candidate[] = [];
  const seen = new Set<string>();

  // `text` was vetted by the caller, and every base is a vetted directory in
  // the checkout, so what is still unchecked about `abs` is only whether it
  // left the checkout: a path that did is judged on its own shape.
  const add = (text: string, base: PrintedPathBase, abs: string): void => {
    const key = fold(abs, platform);
    const inside = info !== undefined && withinRoot(key, info);
    // Outside the checkout only an image the preview popup can show is
    // worth a stat; anything else would be an oracle for the whole disk.
    if (!inside && (!externalSafeImageMime(abs) || isRefusedPathShape(abs, platform))) return;
    if (seen.has(key)) return;
    seen.add(key);
    out.push(Object.freeze({ text, base, abs, inside }));
  };

  for (const text of variants) {
    if (isRefusedPathShape(text, platform)) continue;
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

/** What a stat walk learned beyond the printed path. Without it containment is
 *  lexical. */
export interface ClassifyHints {
  /** `Candidate.inside`, when the caller has it. */
  inside?: boolean;
  /** The directory entry the printed path actually reached, links expanded,
   *  and the checkout root's own. Both are needed to judge a link. */
  real?: string;
  realRoot?: string;
}

/** The kind of link a found path earns, or undefined for none. Containment is
 *  lexical unless both real paths are known: a path inside the checkout that
 *  reaches outside it through a link is outside, and then earns a link only as
 *  an image the preview can show. */
export function classifyPath(
  abs: string,
  status: "file" | "dir",
  checkoutRoot: string | undefined,
  platform: NodeJS.Platform = process.platform,
  hints: ClassifyHints = {},
): PrintedPathKind | undefined {
  const inside = hints.inside ?? (checkoutRoot !== undefined && isInsideRoot(abs, checkoutRoot, platform));
  const { real, realRoot } = hints;
  const escaped = inside && real !== undefined && realRoot !== undefined && !isInsideResolved(real, realRoot, platform);
  if (inside && !escaped) return status === "dir" ? "d" : "f";
  if (status !== "file" || !externalSafeImageMime(abs)) return undefined;
  // The preview is gated on the printed name, so the file it lands on has to
  // be an image too, not just the link that leads there.
  if (escaped && !externalSafeImageMime(real!)) return undefined;
  return "i";
}
