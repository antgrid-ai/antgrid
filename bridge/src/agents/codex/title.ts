import { Database } from "bun:sqlite";
import { readdir } from "node:fs/promises";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import type { ResolvedTitle } from "../types";
import { firstMessage, generated, readOrNull } from "../title-read";

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
 * session_index.jsonl, which only that app writes). So `title` is reported as
 * "generated" ONLY where it actually diverges from first_user_message — equal
 * means the CLI never named the thread, and the caller has to generate one.
 * Opened read-only; never throws (returns null on any error).
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
    if (title) return title === first ? firstMessage(title) : generated(title);
    return first ? firstMessage(first) : null;
  } catch {
    // DB locked, missing table, or schema drift — fall through to the caller's
    // session_index.jsonl fallback rather than failing the title resolution.
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

/**
 * Legacy/desktop-app fallback: Codex's *desktop app* writes conversation titles
 * to ~/.codex/session_index.jsonl as append-only {id, thread_name, updated_at}
 * lines (the LAST line for an id is current). Every name in here is one the
 * desktop app generated, so a hit is unambiguously a real title. The CLI does
 * not write this file at all, which is why bridge-spawned sessions never appear
 * in it. Scan from the end and return the first match. Never throws.
 */
export async function resolveCodexThreadName(threadId: string, codexHome: string): Promise<ResolvedTitle | null> {
  const raw = await readOrNull(join(codexHome, "session_index.jsonl"));
  if (raw === null) return null;
  const lines = raw.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line) continue;
    try {
      const e = JSON.parse(line) as { id?: string; thread_name?: string };
      if (e.id === threadId && typeof e.thread_name === "string") return generated(e.thread_name);
    } catch {
      // partial/garbage line (e.g. mid-write tail) — skip
    }
  }
  return null;
}
