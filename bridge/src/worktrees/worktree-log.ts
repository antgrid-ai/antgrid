import { logger } from "../logger";

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
