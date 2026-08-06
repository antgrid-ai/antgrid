import { Database } from "bun:sqlite";
import { join } from "node:path";
import type { ResolvedTitle } from "../types";
import { firstMessage, generated } from "../title-read";

/**
 * Copilot writes a lazy generated summary to session-store.db. When it has not
 * generated one yet, the first user turn is the best available slot title.
 */
export async function resolveCopilotSessionTitle(sessionId: string, copilotHome: string): Promise<ResolvedTitle | null> {
  let db: Database | null = null;
  try {
    db = new Database(join(copilotHome, "session-store.db"), { readonly: true });
    db.exec("PRAGMA busy_timeout = 0");
    const session = db
      .query("SELECT summary FROM sessions WHERE id = ?")
      .get(sessionId) as { summary?: string | null } | null;
    if (!session) return null;
    const summary = (session.summary ?? "").trim();
    if (summary) return generated(summary);

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
