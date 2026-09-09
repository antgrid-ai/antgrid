import { z } from "zod";

/**
 * A task's link state, in the one place every writer of it can import.
 *
 * It lives here rather than in `models/task.ts` because the dependency runs one
 * way: that module imports `sync-op.ts`, `push-blocked.ts` and `publish.ts`, so
 * none of them can import the vocabulary back. Each used to restate the two
 * values it needed with a "keep in lockstep" comment, which is three spellings
 * of one enum and a drift nothing would catch — a renamed member still
 * type-checks against a string literal.
 *
 * `models/task.ts` re-exports it, so callers that already had it keep working.
 */

/** null until the task is linked. `unlinked` is a tombstone: the external
 *  identity stays on the row so the UI can name the issue it used to be. */
export const TaskSyncStateSchema = z.enum(["pending", "synced", "conflict", "unlinked"]);
export type TaskSyncState = z.infer<typeof TaskSyncStateSchema>;
