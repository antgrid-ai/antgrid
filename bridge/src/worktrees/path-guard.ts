import { relative, sep } from "node:path";

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
  return rel !== "" && rel !== ".." && !rel.startsWith(`..${sep}`) && !rel.includes(`${sep}..${sep}`);
}
