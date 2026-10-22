import { Database } from "bun:sqlite";
import { HandoffSnapshotError } from "./types";

function isBusy(error: unknown): boolean {
  const { code, message } = error as { code?: string; message?: string };
  return (code?.startsWith("SQLITE_BUSY") ?? false) || /database is locked|SQLITE_BUSY/i.test(message ?? "");
}

function readOnce<T>(dbPath: string, read: (db: Database) => T): T {
  const db = new Database(dbPath, { readonly: true });
  try {
    // Fail fast on a locked database (the caller retries once): a read
    // transaction we hold would otherwise stall the agent's own checkpoint.
    db.run("PRAGMA busy_timeout = 0");
    // One transaction around every SELECT so the whole read sees one consistent
    // WAL snapshot of a store the agent is still writing.
    db.run("BEGIN");
    try {
      return read(db);
    } finally {
      try { db.run("COMMIT"); } catch { /* read-only: nothing to lose if it is already closed out */ }
    }
  } finally {
    db.close();
  }
}

/** Opens the agent's live database read-only, never immutable and never copied
 * (a copy would miss the WAL; immutable would ignore it), so rows a running
 * agent has only written to the -wal are visible. No VACUUM INTO, backup API,
 * `<agent> export` or wal_checkpoint: each writes to, or waits on, the agent's
 * own store. Closing the last connection may leave an empty -wal and a -shm
 * behind, which is ordinary SQLite behaviour. */
export function withReadSnapshot<T>(dbPath: string, read: (db: Database) => T): T {
  for (let attempt = 0; ; attempt++) {
    try {
      return readOnce(dbPath, read);
    } catch (error) {
      if (error instanceof HandoffSnapshotError) throw error;
      if (isBusy(error) && attempt === 0) continue;
      const detail = error instanceof Error ? error.message : String(error);
      throw new HandoffSnapshotError("UNREADABLE", `Could not read the agent database: ${detail}`);
    }
  }
}
