import { Database } from "bun:sqlite";
import { readdir } from "node:fs/promises";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import type { ResolvedTitle } from "../types";
import { firstMessage } from "../title-read";

/** Parse the schema-version <N> out of a `state_<N>.sqlite` filename, or -1. */
function stateDbVersion(filename: string): number {
  const m = /^state_(\d+)\.sqlite$/.exec(filename);
  return m ? Number(m[1]) : -1;
}

/**
 * Codex's CLI (`codex-tui`, what the bridge spawns) persists thread metadata to
 * ~/.codex/state_<N>.sqlite (`threads` table: id, title, first_user_message) —
 * NOT to session_index.jsonl, which only the Codex *desktop app* writes. The <N>
 * is a schema version that bumps on Codex upgrades, so glob and take the newest.
 *
 * The CLI writes the first user message into `title` and leaves it there: of 310
 * local threads, every one whose `title` differs from `first_user_message` was
 * written by the Codex DESKTOP app (all 32 appear verbatim in
 * session_index.jsonl, which only that app writes). So a divergent `title` is
 * the desktop app naming the thread for itself, which we deliberately do not
 * read — `first_user_message` is the column that answers what this resolver is
 * for. Opened read-only; never throws (returns null on any error).
 */
export async function resolveCodexThreadTitle(threadId: string, codexHome: string): Promise<ResolvedTitle | null> {
  let dbPath: string;
  try {
    const newest = (await readdir(codexHome))
      .filter((f) => stateDbVersion(f) >= 0)
      .sort((a, b) => stateDbVersion(b) - stateDbVersion(a))[0];
    if (!newest) return null;
    dbPath = join(codexHome, newest);
  } catch {
    return null;
  }
  let db: Database | null = null;
  try {
    db = new Database(dbPath, { readonly: true });
    // bun:sqlite is synchronous even here; don't wait on codex's write lock.
    db.exec("PRAGMA busy_timeout = 0");
    const row = db
      .query("SELECT title, first_user_message FROM threads WHERE id = ?")
      .get(threadId) as { title?: string | null; first_user_message?: string | null } | null;
    if (!row) return null;
    const title = (row.title ?? "").trim();
    const first = (row.first_user_message ?? "").trim();
    if (first) return firstMessage(first);
    // Only reachable with an empty first_user_message, where `title` cannot be
    // told apart from a desktop-written name. Taken as the opening prompt
    // anyway: it holds the slot until our own generated name lands, and the
    // alternative is leaving the session unnamed on a column we can't read.
    return title ? firstMessage(title) : null;
  } catch {
    // DB locked, missing table, or schema drift. Unnameable is not fatal: the
    // caller keeps whatever name the session already has, and the generated
    // title lands on its own path.
    return null;
  } finally {
    db?.close();
  }
}

/**
 * Synchronous existence check for a Codex thread, for the resume pre-flight in
 * SessionManager.start() (which is sync). Mirrors resolveCodexThreadTitle's
 * newest-state_<N>.sqlite selection. Returns true/false when the DB can be
 * queried, or null when undeterminable (DB missing/locked/schema drift) so the
 * caller can fall back to an optimistic resume rather than refusing.
 */
export function codexThreadExistsSync(threadId: string, codexHome: string): boolean | null {
  let dbPath: string;
  try {
    const newest = readdirSync(codexHome)
      .filter((f) => stateDbVersion(f) >= 0)
      .sort((a, b) => stateDbVersion(b) - stateDbVersion(a))[0];
    if (!newest) return null;
    dbPath = join(codexHome, newest);
  } catch {
    return null;
  }
  let db: Database | null = null;
  try {
    db = new Database(dbPath, { readonly: true });
    // Fail fast instead of blocking: start() calls this synchronously on the
    // event loop, so a wait on codex's write lock would stall the bridge.
    // SQLITE_BUSY → caught below → null → optimistic resume.
    db.exec("PRAGMA busy_timeout = 0");
    const row = db.query("SELECT 1 FROM threads WHERE id = ?").get(threadId);
    return row != null;
  } catch {
    return null;
  } finally {
    db?.close();
  }
}
