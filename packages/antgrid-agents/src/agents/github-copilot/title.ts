import { Database } from "bun:sqlite";
import { createReadStream } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import type { ResolvedTitle } from "../types";
import { firstMessage } from "../title-read";

/**
 * The first user turn of a Copilot session, from session-store.db, or from the
 * session's event log while that turn has no row yet.
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
    const first = (turn?.user_message ?? "").trim() || await firstEventsPrompt(copilotHome, sessionId);
    return first ? firstMessage(first) : null;
  } catch {
    return null;
  } finally {
    db?.close();
  }
}

// Session ids reach this reader from hook posts, so one is checked before it
// becomes a path segment.
const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The first prompt from the session's own event log. Copilot writes a `turns`
 * row only once the NEXT prompt arrives or the session shuts down, so a
 * one-prompt session has none, while `events.jsonl` records each `user.message`
 * as it is sent. `content` is what the user typed; `transformedContent` adds
 * Copilot's injected context and is never a name.
 */
async function firstEventsPrompt(copilotHome: string, sessionId: string): Promise<string> {
  if (!SESSION_ID.test(sessionId)) return "";
  const stream = createReadStream(join(copilotHome, "session-state", sessionId, "events.jsonl"), { encoding: "utf8" });
  const lines = createInterface({ input: stream, crlfDelay: Infinity });
  try {
    for await (const line of lines) {
      if (!line.includes('"user.message"')) continue;
      try {
        const event = JSON.parse(line) as { type?: unknown; data?: { content?: unknown } };
        const content = event.type === "user.message" && typeof event.data?.content === "string" ? event.data.content.trim() : "";
        if (content) return content;
      } catch {}
    }
  } catch {
    // No log yet: the session has not been sent a prompt.
  } finally {
    lines.close();
    stream.destroy();
  }
  return "";
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
