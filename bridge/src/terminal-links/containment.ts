// The one answer to "is this path inside the checkout root" and to "may the OS
// be asked about it". It sits apart from the resolver because `file-tree.ts`
// needs it too, and the resolver already imports from `file-tree.ts`.

import { posix, win32 } from "node:path";
import { foldPathCase } from "./chars";
import { isRefusedPathShape } from "./grammar";

/** Distinct roots, base sets and token sets a process holds on to; a terminal
 *  session has a handful of each, so this only bounds a pathological churn. */
export const MAX_MEMO_ENTRIES = 4096;

export function pathApi(platform: NodeJS.Platform): typeof posix {
  return platform === "win32" ? win32 : posix;
}

export function fold(path: string, platform: NodeJS.Platform): string {
  return platform === "win32" ? foldPathCase(path) : path;
}

export function remember<K, V>(memo: Map<K, V>, key: K, value: V): V {
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
export interface RootInfo {
  folded: string;
  prefix: string;
}

const rootInfos = new Map<string, RootInfo>();

export function rootInfoOf(root: string, platform: NodeJS.Platform): RootInfo {
  const key = `${platform}:${root}`;
  const hit = rootInfos.get(key);
  if (hit) return hit;
  const api = pathApi(platform);
  const folded = fold(api.resolve(root), platform);
  return remember(rootInfos, key, { folded, prefix: folded.endsWith(api.sep) ? folded : folded + api.sep });
}

export function withinRoot(foldedAbs: string, info: RootInfo): boolean {
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

/** `isRefusedPathShape` for a resolved path, except that what lies inside the
 *  checkout root is judged by the part after the root. The root is where the
 *  bridge already works and may itself be a UNC share (a WSL distribution, a
 *  file server), so only what follows it can open a new network session. A path
 *  outside the root is judged whole. */
export function refusedUnderRoot(abs: string, root: string, platform: NodeJS.Platform = process.platform): boolean {
  const info = rootInfoOf(root, platform);
  if (!withinRoot(fold(abs, platform), info)) return isRefusedPathShape(abs, platform);
  return isRefusedPathShape(abs.slice(info.folded.length), platform);
}
