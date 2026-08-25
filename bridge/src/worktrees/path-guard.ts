import { isAbsolute, relative, sep } from "node:path";

/**
 * True when `target` is a strict descendant of `root`.
 *
 * The guard every path Antgrid derives from client- or branch-supplied text
 * must pass before it is read, written or removed. Equality is deliberately
 * NOT below: a caller that accepted the root itself would let `copy: ["."]`
 * overwrite a whole tree, and every caller here means "somewhere inside".
 *
 * Lives on its own because both the worktree lifecycle and the setup runner
 * need it and a second copy drifting from this one is exactly the class of bug
 * the check exists to prevent.
 */
export function pathBelow(root: string, target: string): boolean {
  const rel = relative(root, target);
  // An ABSOLUTE relative path is `relative()` reporting that no walk connects
  // the two: on Windows that is every cross-root pair — another drive letter,
  // a drive-relative spelling like `C:foo` that resolved elsewhere, or a UNC
  // share — and the `..` tests below all pass for one, so an escape would read
  // as "inside". Measured: `relative("D:\proj", "C:\Windows")` is
  // `"C:\Windows"`. Comparing parsed roots instead would reject a pair that
  // differs only in drive-letter case; this does not.
  if (rel === "" || isAbsolute(rel)) return false;
  return rel !== ".." && !rel.startsWith(`..${sep}`) && !rel.includes(`${sep}..${sep}`);
}
