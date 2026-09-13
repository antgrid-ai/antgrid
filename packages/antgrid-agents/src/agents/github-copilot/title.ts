import { Database } from "bun:sqlite";
import { join } from "node:path";
import type { ResolvedTitle } from "../types";
import { firstMessage } from "../title-read";

/**
 * The first user turn of a Copilot session, from session-store.db.
 *
 * Copilot also writes a lazy generated summary to the `sessions` row, and it is
 * deliberately not read: we name sessions ourselves (see ResolvedTitle), and
 * depending on it meant a title appeared only once Copilot got round to writing
 * one — never for a short session, and never at a predictable moment.
 */
export async function resolveCopilotSessionTitle(sessionId: string, copilotHome: string): Promise<ResolvedTitle | null> {
  let db: Database | null = null;
  try {
    db = new Database(join(copilotHome, "session-store.db"), { readonly: true });
    db.exec("PRAGMA busy_timeout = 0");
    // Still SELECTed: a session row that does not exist is a different answer
    // from one with no turns yet, and only the first is "unknown session".
    const session = db
      .query("SELECT id FROM sessions WHERE id = ?")
      .get(sessionId) as { id?: string | null } | null;
    if (!session) return null;

    const turn = db
      .query("SELECT user_message FROM turns WHERE session_id = ? AND trim(coalesce(user_message, '')) <> '' ORDER BY turn_index ASC LIMIT 1")
      .get(sessionId) as { user_message?: string | null } | null;
    const first = (turn?.user_message ?? "").trim();
    return first ? firstMessage(first) : null;
  } catch {
    return null;
  } finally {
    db?.close();
  }
}

/**
 * Return null when the Copilot DB cannot be queried so callers can choose an
 * optimistic fallback instead of treating lock/schema/missing-file as absence.
 */
export function copilotSessionExistsSync(sessionId: string, copilotHome: string): boolean | null {
  let db: Database | null = null;
  try {
    db = new Database(join(copilotHome, "session-store.db"), { readonly: true });
    db.exec("PRAGMA busy_timeout = 0");
    return db.query("SELECT 1 FROM sessions WHERE id = ?").get(sessionId) != null;
  } catch {
    return null;
  } finally {
    db?.close();
  }
}
