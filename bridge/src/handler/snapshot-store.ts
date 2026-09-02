// bridge/src/handler/snapshot-store.ts
//
// Where a snapshot lives between being taken and being undone.
//
// Deliberately NOT the session record: a wrap-up disarms the session, and the
// undo offer the wrap-up summary hands the user has to outlive that — the push
// lands at 3am and is read at 9. Project-scoped and keyed by snapshot id for the
// same reason: an undo names only the id, and the entry it names may belong to a
// session that no longer exists.

import { z } from "zod";
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, chmodSync } from "node:fs";
import { join } from "node:path";
import type { SnapshotAction, SnapshotEntry } from "./snapshot";

const SNAPSHOT_BASE = {
  id: z.string(),
  at: z.number(),
  sessionId: z.string(),
  projectPath: z.string(),
  trigger: z.string(),
};

// Hand-mirrored, like the wire schemas mirror the bridge's own types: on-disk
// storage must not be able to move what snapshot.ts produces. The annotation is
// the lockstep check — a field snapshot.ts adds or renames stops compiling here
// rather than rehydrating into an entry `undoSnapshot` cannot act on.
const SnapshotEntrySchema: z.ZodType<SnapshotEntry> = z.discriminatedUnion("kind", [
  z.object({
    ...SNAPSHOT_BASE,
    kind: z.literal("git_stash"),
    headSha: z.string(),
    stashSha: z.string().optional(),
    backupRef: z.string(),
  }),
  z.object({
    ...SNAPSHOT_BASE,
    kind: z.literal("pre_push_sha"),
    remote: z.string(),
    ref: z.string(),
    remoteSha: z.string(),
    backupRef: z.string(),
  }),
  z.object({
    ...SNAPSHOT_BASE,
    kind: z.literal("trash_copy"),
    files: z.array(z.object({ relPath: z.string(), trashPath: z.string() })),
    bytes: z.number(),
  }),
]);

const SNAPSHOT_ACTIONS = ["reset_hard", "force_push", "rm_rf", "git_clean"] as const satisfies
  readonly SnapshotAction[];

export const StoredSnapshotSchema = z.object({
  // Which supervised slot the inject went to. Not an identity for the entry —
  // that is `entry.id` — but the scope a fresh arm retires.
  terminalId: z.string(),
  action: z.enum(SNAPSHOT_ACTIONS),
  entry: SnapshotEntrySchema,
  // Spent, kept rather than deleted: a second tap on the same row has to be a
  // no-op, and it can only tell that from a record that survives the first.
  undoneAt: z.number().optional(),
  // Why the last undo attempt failed. An attempt may fail for reasons that pass
  // (a rejected push, a network blip), so a failure does not spend the entry.
  failure: z.string().optional(),
});
export type StoredSnapshot = z.infer<typeof StoredSnapshotSchema>;

const StoreSchema = z.object({
  version: z.literal(1),
  entries: z.array(StoredSnapshotSchema),
});

// Entries are small, but a long-lived project takes one per flagged inject
// forever. The oldest are the ones whose undo is least likely to still be wanted.
// Exported because the cap has to be applied where the ENGINE caches the list too:
// capping only on the way to disk left the cache advertising offers the next
// restart could not honor, and left their trash copies and backup refs behind.
export const MAX_STORED = 50;

/** The entries a save would keep, and the ones it would drop. */
export function pruneSnapshots(entries: StoredSnapshot[]): { kept: StoredSnapshot[]; dropped: StoredSnapshot[] } {
  if (entries.length <= MAX_STORED) return { kept: entries, dropped: [] };
  return { kept: entries.slice(-MAX_STORED), dropped: entries.slice(0, entries.length - MAX_STORED) };
}

function storePath(abDir: string, projectId: string): string {
  return join(abDir, "agents", projectId, "handler-snapshots.json");
}

export function loadSnapshots(abDir: string, projectId: string): StoredSnapshot[] {
  const path = storePath(abDir, projectId);
  if (!existsSync(path)) return [];
  try {
    const parsed = StoreSchema.safeParse(JSON.parse(readFileSync(path, "utf8")));
    return parsed.success ? parsed.data.entries : [];
  } catch {
    return [];
  }
}

export function saveSnapshots(abDir: string, projectId: string, entries: StoredSnapshot[]): void {
  const path = storePath(abDir, projectId);
  mkdirSync(join(abDir, "agents", projectId), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify({ version: 1, entries: pruneSnapshots(entries).kept }, null, 2), "utf8");
  renameSync(tmp, path);
  if (process.platform !== "win32") { try { chmodSync(path, 0o600); } catch { /* ignore */ } }
}
