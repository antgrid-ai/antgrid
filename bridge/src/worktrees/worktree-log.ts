import { logger } from "../logger";

const log = logger.child({ component: "worktree" });

export type WorktreeEvent =
  | "worktree_create_started"
  | "worktree_create_succeeded"
  | "worktree_create_failed"
  | "worktree_resume_missing"
  | "worktree_resume_conflict"
  | "worktree_delete_started"
  | "worktree_delete_blocked"
  | "worktree_delete_succeeded"
  | "worktree_delete_failed";

/** The complete field set. Branch names and filesystem paths are deliberately
 *  absent: these lines are the input to analytics, and a branch name is user
 *  content while a worktree path names the user's home directory layout. */
export interface WorktreeEventFields {
  projectId?: string;
  checkoutId?: string;
  sessionId?: string;
  elapsedMs?: number;
  errorCode?: string;
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
