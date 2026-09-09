import { z } from "zod";
import type { Tx } from "../db/index.js";
import { Prisma } from "../generated/prisma/client.js";

/**
 * `Task.pushBlocked`: the per-field record of pushes that succeeded and changed
 * nothing, and the counter that eventually stops sending the field.
 *
 * **It lives on the task, never on `TaskSyncOp`.** Ops are superseded and
 * replaced, so a counter on one resets every time the user edits the field
 * again — which is precisely the loop it exists to stop. A user re-typing a
 * title GitHub keeps declining would restart the count from zero for ever.
 *
 * **The detector's blind spot is load-bearing.** What fills this blob is a
 * response that came back *different* from what was asked for. A push whose
 * target value is already correct in provider space returns exactly what was
 * asked for and reads as a clean success — the `in_progress → open` loop — and
 * no amount of response comparison catches it. Only merging `status` in provider
 * space does (`src/tasks/merge.ts`). The two guards are complements, not
 * alternatives: provider-space comparison stops the loops that arise from our
 * vocabulary being finer than the provider's, this counter stops the loops that
 * arise from the provider silently declining ours.
 */

/** The fields v1 can push. `assignee` is deliberately absent: it is never sent,
 *  for the reason `GithubIssuePatch` spells out. */
export const PushFieldSchema = z.enum(["title", "body", "status", "labels"]);
export type PushField = z.infer<typeof PushFieldSchema>;

const PushBlockedEntrySchema = z.object({
  count: z.number().int().min(0),
  lastAt: z.string(),
  /** Shown beside the field in the UI — the only explanation a user gets for a
   *  value that stopped syncing, so it is a sentence rather than a code. */
  reason: z.string(),
});
export type PushBlockedEntry = z.infer<typeof PushBlockedEntrySchema>;

/** Keyed loosely and filtered on read, so a blob written before a field existed
 *  — or after one was retired — still parses instead of being discarded whole. */
const PushBlockedSchema = z.record(z.string(), PushBlockedEntrySchema);

export type PushBlockedBlob = Partial<Record<PushField, PushBlockedEntry>>;

/**
 * No-effect pushes of one field before it stops being sent.
 *
 * **Three, not one.** A single no-effect response is also what a genuine race
 * produces — a human set the same value a moment before we did. Three is enough
 * that a real non-convergence is unmistakable, and small enough that we burn
 * three writes rather than thirty of a 500/hour budget.
 */
export const PUSH_BLOCK_THRESHOLD = 3;

export function parsePushBlocked(value: unknown): PushBlockedBlob {
  const parsed = PushBlockedSchema.safeParse(value);
  if (!parsed.success) return {};
  const blob: PushBlockedBlob = {};
  for (const [key, entry] of Object.entries(parsed.data)) {
    const field = PushFieldSchema.safeParse(key);
    if (field.success) blob[field.data] = entry;
  }
  return blob;
}

export function isEmptyPushBlocked(blob: PushBlockedBlob): boolean {
  return Object.keys(blob).length === 0;
}

/**
 * Whether the field has stopped being pushed.
 *
 * **A block has no expiry, and that is the decision rather than an omission.** A
 * timer would restart the loop on its own schedule, which is the failure mode
 * being prevented. It also means a field blocked by a transient provider bug
 * needs a person to unblock it — the UI marker is that action, and a push that
 * finally takes effect clears the entry on its own.
 */
export function isPushBlocked(blob: PushBlockedBlob, field: PushField): boolean {
  return (blob[field]?.count ?? 0) >= PUSH_BLOCK_THRESHOLD;
}

export function blockedFields(blob: PushBlockedBlob): PushField[] {
  return PushFieldSchema.options.filter((field) => isPushBlocked(blob, field));
}

/** Count one no-effect push per field, returning a new blob. */
export function recordNoEffect(
  blob: PushBlockedBlob,
  entries: readonly { field: PushField; reason: string }[],
  at: Date
): PushBlockedBlob {
  if (entries.length === 0) return blob;
  const next: PushBlockedBlob = { ...blob };
  for (const { field, reason } of entries) {
    next[field] = {
      count: (next[field]?.count ?? 0) + 1,
      lastAt: at.toISOString(),
      reason,
    };
  }
  return next;
}

/** A push of these fields took effect, so whatever was declining them stopped.
 *  The automatic exit from a block; `clearTaskPushBlock` is the manual one. */
export function clearPushBlocked(
  blob: PushBlockedBlob,
  fields: readonly PushField[]
): PushBlockedBlob {
  if (fields.length === 0) return blob;
  const next: PushBlockedBlob = { ...blob };
  for (const field of fields) delete next[field];
  return next;
}

/**
 * The user's way out of a block, and the only one there is.
 *
 * A field past the threshold stops being pushed, so it can never take effect on
 * its own — deliberately, because the alternative is a timer that restarts the
 * loop on its own schedule. That makes the UI marker beside the field the
 * action, and this the verb behind it. The caller supplies the transaction; the
 * `tasksync:` lock is taken here because every read-modify-write of a task row
 * shares one key with the outbox and the webhook drain.
 */
export async function clearTaskPushBlock(
  tx: Tx,
  args: { taskId: string; field: PushField }
): Promise<boolean> {
  await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`tasksync:${args.taskId}`}))`;
  const row = await tx.task.findUnique({
    where: { id: args.taskId },
    select: { pushBlocked: true },
  });
  if (!row) return false;

  const blob = parsePushBlocked(row.pushBlocked);
  if (blob[args.field] === undefined) return false;
  const next = clearPushBlocked(blob, [args.field]);
  await tx.task.update({
    where: { id: args.taskId },
    data: {
      pushBlocked: isEmptyPushBlocked(next)
        ? Prisma.DbNull
        : (next as unknown as Prisma.InputJsonValue),
    },
  });
  return true;
}
