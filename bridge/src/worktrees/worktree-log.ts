import { logger } from "../logger";
import type { DirectoryHolder } from "../win32-process";

const log = logger.child({ component: "worktree" });

export type WorktreeEvent =
  | "worktree_create_started"
  | "worktree_create_succeeded"
  | "worktree_create_failed"
  | "worktree_resume_missing"
  | "worktree_resume_conflict"
  | "worktree_resume_failed"
  | "worktree_delete_started"
  | "worktree_delete_blocked"
  | "worktree_delete_succeeded"
  /** The worktree went, its branch stayed: Git refused the delete, usually
   *  because the branch was renamed away or is checked out somewhere else.
   *  Not an error — the session is deleted either way — but the user asked for
   *  the branch to go, so a support bundle has to be able to see that it did not. */
  | "worktree_delete_branch_kept"
  | "worktree_delete_failed"
  /** A reconcile's orphan sweep attempted a directory and it survived. Its own
   *  event because the sweep's counts cannot express it: a failed reclaim moves
   *  none of them, so `worktree_reconcile_completed` reads exactly like a sweep
   *  that found nothing to do, on every create, for as long as the directories
   *  stay stranded. */
  | "worktree_reclaim_failed"
  | "worktree_reconcile_completed"
  | "worktree_forget_reclaimed";

/** The complete field set. Branch names and filesystem paths are deliberately
 *  absent: these lines are the input to analytics, and a branch name is user
 *  content while a worktree path names the user's home directory layout. */
export interface WorktreeEventFields {
  projectId?: string;
  checkoutId?: string;
  sessionId?: string;
  elapsedMs?: number;
  errorCode?: string;
  /** Counts only — reclamation and reconciliation are otherwise silent, so a
   *  support bundle cannot tell "the user's worktrees vanished" from "we
   *  reclaimed them". A count names no branch and no path. */
  pruned?: number;
  reclaimed?: number;
  stranded?: number;
  /** Directories under our own worktree root that belong to another
   *  repository. Zero on a healthy machine, so it is worth a support bundle
   *  noticing. */
  foreign?: number;
  /** How many live processes held the directory a delete or reclaim could not
   *  remove. The count is the whole analytics-safe part — a holder's name and
   *  current directory go to the local log, like Git's stderr does — and it is
   *  what separates "Windows refused because something is running in there"
   *  from every other way a delete fails. Absent rather than zero wherever the
   *  question could not be asked: only Windows can answer it, and a zero would
   *  read as "nothing held it" everywhere else. */
  holders?: number;
}

export function logWorktreeEvent(event: WorktreeEvent, fields: WorktreeEventFields = {}): void {
  log.info({ event, ...fields }, event);
}

/** Typed error code of a thrown value, for the `*_failed` events. Anything that
 *  is not a WorktreeError is reported as UNKNOWN rather than by message: an
 *  arbitrary error message can carry a path. */
export function worktreeErrorCode(error: unknown): string {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" ? code : "UNKNOWN";
}

/** Git's own words for a failed invocation. Deliberately NOT part of
 *  `logWorktreeEvent`: the structured events feed analytics and so carry no
 *  message, because a message can carry a path. That leaves a support bundle
 *  unable to tell "Git could not delete the directory" from "Git does not know
 *  this worktree" — opposite problems needing opposite fixes — even though the
 *  local log already records checkout paths elsewhere. This line closes that
 *  gap without widening the analytics schema. */
export function logGitFailure(what: string, result: { exitCode: number; stderr: string }): void {
  log.warn({ exitCode: result.exitCode, stderr: result.stderr.trim().slice(0, 500) }, `git ${what} failed`);
}

/** The directory a delete or reclaim could not remove, and who was still
 *  running inside it: pid, image name and the subdirectory each one sits in.
 *  Local log only, for the same reason as [logGitFailure] — a current directory
 *  names the user's home directory layout, and the structured events feed
 *  analytics. The user-facing message names at most a few of these; a support
 *  bundle needs all of them, because the holder that matters is routinely the
 *  third one.
 *
 *  Emitted even when no holder could be named, which is the ordinary case off
 *  Windows and past a reconcile's scan budget: this is the ONLY line that ever
 *  names the directory, and `worktree_reclaim_failed` carries a projectId and
 *  nothing else — so without it five stranded checkouts are five byte-identical
 *  events, and a support bundle can see that the sweep failed but not how many
 *  directories are stranded, let alone which. Both callers log from a failure
 *  they are already reporting, so no path here wants a silent answer. */
export function logDirectoryHolders(what: string, path: string, holders: readonly DirectoryHolder[]): void {
  log.warn(
    { path, holders: holders.map((holder) => ({ pid: holder.pid, name: holder.name, cwd: holder.cwd })) },
    holders.length === 0
      ? `${what}: directory survived with no holder named`
      : `${what}: directory held by ${holders.length} process(es)`,
  );
}
