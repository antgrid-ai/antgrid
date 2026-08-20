import { readFileSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";

/** Which repository a directory under Antgrid's worktree root belongs to.
 * `none` is a directory that is not a checkout at all — a leftover `git
 * worktree add` never finished, or something a user dropped in. `unknown` is
 * the one that is not an answer: a `.git` that exists and could not be read. */
export type CheckoutOwner =
  | { kind: "worktree"; commonDir: string }
  | { kind: "repository" }
  | { kind: "unknown" }
  | { kind: "none" };

/** Ownership read from the worktree's own `.git` pointer rather than from Git.
 * Two reasons it is a file read: the pointer survives the main repository being
 * DELETED, which is the exact situation `reclaimForgottenProject` runs in and
 * the one where `git rev-parse` refuses to answer at all; and a sweep that has
 * already decided a directory is a deletion candidate must not depend on
 * spawning a process to find out whose it is. */
export function readCheckoutOwner(dir: string): CheckoutOwner {
  const pointer = join(dir, ".git");
  let raw: string;
  try {
    // A checkout Antgrid manages is always a worktree, so a `.git` DIRECTORY is
    // a full clone someone else put here — never ours, whatever else is true.
    if (statSync(pointer).isDirectory()) return { kind: "repository" };
    raw = readFileSync(pointer, "utf8");
  } catch (err) {
    // ENOENT is the only failure that PROVES there is no checkout here. A
    // pointer that exists but cannot be read (a Windows sharing violation, a
    // permissions problem) is an unanswered question, and answering it with
    // `none` would hand a live checkout to the recursive deletes downstream.
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return { kind: "none" };
    return { kind: "unknown" };
  }

  const match = /^gitdir:\s*(.+?)\s*$/m.exec(raw);
  if (!match?.[1]) return { kind: "none" };
  // Relative since Git 2.48 (`worktree.useRelativePaths`), absolute before it,
  // and either spelling may reach a machine whose user has that config on.
  const gitDir = isAbsolute(match[1]) ? resolve(match[1]) : resolve(dir, match[1]);
  // `<common>/worktrees/<name>` for a worktree. Anything else is answered with
  // the path itself: an unrecognised layout must still compare UNEQUAL to our
  // own common dir rather than silently match it.
  const parent = dirname(gitDir);
  return { kind: "worktree", commonDir: basename(parent) === "worktrees" ? dirname(parent) : gitDir };
}

/** Path equality for repositories, which on Windows and macOS is not string
 * equality — the same `computeProjectId` case rule, for the same reason.
 *
 * Resolved through symlinks first, because only one side of the comparison ever
 * goes through Git: `git worktree add` writes the REAL path into the checkout's
 * pointer, while our own side is built from the project path the user handed us
 * — and on a machine whose repositories live under a symlinked home (or macOS's
 * `/var`), the two spell the same directory differently. Mismatching there does
 * not delete anything, it does the quieter thing: every one of this project's
 * own orphans is written off as another project's and never reclaimed. A path
 * that no longer exists cannot be resolved, and falls back to the lexical form
 * on both sides alike. */
export function sameRepository(a: string, b: string): boolean {
  const fold = (path: string) => {
    let normalized: string;
    try { normalized = realpathSync.native(path); } catch { normalized = resolve(path); }
    return process.platform === "win32" || process.platform === "darwin"
      ? normalized.toLowerCase()
      : normalized;
  };
  return fold(a) === fold(b);
}
