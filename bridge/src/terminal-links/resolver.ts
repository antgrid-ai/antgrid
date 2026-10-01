import { externalSafeImageMime } from "../file-tree";
import { hasDriveLetterAt, isAbsoluteFor, isSeparator, startsWithDoubleSeparator } from "./chars";
import {
  fold,
  isInsideResolved,
  isInsideRoot,
  pathApi,
  refusedUnderRoot,
  remember,
  rootInfoOf,
  withinRoot,
} from "./containment";
import { isRefusedPathShape, type PrintedPathBase, type PrintedPathKind } from "./grammar";
import { uncShareOf } from "./win32-volume";

export { isInsideResolved, isInsideRoot };

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
  const sane = (p: string | undefined): p is string =>
    typeof p === "string" && p.length > 0 && p.length <= MAX_BASE_CHARS;
  const out: LinkBases = {};
  const rootText = b.checkoutRoot;
  if (!sane(rootText) || !usableRoot(rootText, platform)) return out;
  const root = api.resolve(rootText);
  const info = rootInfoOf(root, platform);
  // A UNC cwd is judged past the root only, so one on the root's own share is
  // kept and one on any other share is not. A drive cwd is judged whole: its
  // unresolved text can repeat a separator just after the root, which the
  // part past the root would read as a UNC prefix.
  const usableCwd = (p: string | undefined): string | undefined => {
    if (!sane(p)) return undefined;
    if (isAbsoluteFor(p, platform)) {
      if (isRefusedPathShape(p, platform)) return undefined;
    } else if (!(platform === "win32" && startsWithDoubleSeparator(p)) || refusedUnderRoot(p, root, platform)) {
      return undefined;
    }
    const abs = api.resolve(p);
    return withinRoot(fold(abs, platform), info) ? abs : undefined;
  };
  const live = usableCwd(b.liveCwd);
  const spawn = usableCwd(b.spawnCwd);
  if (live !== undefined) out.liveCwd = live;
  if (spawn !== undefined) out.spawnCwd = spawn;
  out.checkoutRoot = root;
  return out;
}

/** The checkout root is where the bridge already works, so a UNC share (a WSL
 *  distribution, a file server) is as valid a root as a drive; what follows the
 *  share is still judged. */
function usableRoot(root: string, platform: NodeJS.Platform): boolean {
  if (isAbsoluteFor(root, platform)) return !isRefusedPathShape(root, platform);
  if (platform !== "win32") return false;
  const share = uncShareOf(root);
  return share !== undefined && !isRefusedPathShape(root.slice(share.end), platform);
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
  let memo = candidateMemo.get(bases);
  if (!memo) {
    if (!Object.isFrozen(bases)) return computeCandidates(variants, bases, platform);
    candidateMemo.set(bases, (memo = new Map()));
  }
  let key: string = platform;
  for (const v of variants) key += `|${v.length}:${v}`;
  const hit = memo.get(key);
  if (hit) return hit;
  return remember(memo, key, Object.freeze(computeCandidates(variants, bases, platform)));
}

/** Where `text` lands under `base`, or undefined when that base means nothing
 *  for it: the base is unavailable, or on Windows the text is rooted on the
 *  current drive or relative to one, which resolve against the bridge's own
 *  drive and directory. The shape refusal is the caller's, because only the
 *  caller knows whether a UNC spelling may still be judged by where it lands. */
export function resolveAgainstBase(
  text: string,
  base: PrintedPathBase,
  bases: LinkBases,
  platform: NodeJS.Platform = process.platform,
): string | undefined {
  const api = pathApi(platform);
  if (base === "a") return isAbsoluteFor(text, platform) ? api.resolve(text) : undefined;
  if (platform === "win32" && !isAbsoluteFor(text, platform) && (isSeparator(text[0]) || hasDriveLetterAt(text))) {
    return undefined;
  }
  const dir = base === "l" ? bases.liveCwd : base === "s" ? bases.spawnCwd : bases.checkoutRoot;
  return dir === undefined ? undefined : api.resolve(dir, text);
}

const RELATIVE_BASES: readonly PrintedPathBase[] = ["l", "s", "r"];

function computeCandidates(variants: readonly string[], bases: LinkBases, platform: NodeJS.Platform): Candidate[] {
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
      add(text, "a", pathApi(platform).resolve(text));
      continue;
    }
    for (const base of RELATIVE_BASES) {
      const abs = resolveAgainstBase(text, base, bases, platform);
      if (abs !== undefined) add(text, base, abs);
    }
  }
  return out;
}

/** What a stat walk learned beyond the printed path. */
export interface ClassifyHints {
  /** `Candidate.inside`: lexical containment in the checkout root. */
  inside: boolean;
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
  platform: NodeJS.Platform,
  hints: ClassifyHints,
): PrintedPathKind | undefined {
  const { inside, real, realRoot } = hints;
  const escaped = inside && real !== undefined && realRoot !== undefined && !isInsideResolved(real, realRoot, platform);
  if (inside && !escaped) return status === "dir" ? "d" : "f";
  if (status !== "file" || !externalSafeImageMime(abs)) return undefined;
  // The preview is gated on the printed name, so the file it lands on has to
  // be an image too, not just the link that leads there.
  if (escaped && !externalSafeImageMime(real!)) return undefined;
  return "i";
}
