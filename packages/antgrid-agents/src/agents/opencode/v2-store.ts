import type { Database } from "bun:sqlite";
import type { SessionMessageInfo } from "@opencode/client";

export function hasTable(db: Database, name: string): boolean {
  return db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(name) != null;
}

export function hasOpencodeV2Store(db: Database): boolean {
  return hasTable(db, "session_v2");
}

/** Parts move out of the message row while streaming; completed/forked rows
 * may keep them inline. Read both representations in the native sequence order. */
export function readOpencodeV2Messages(db: Database, sessionId: string, limit = -1): SessionMessageInfo[] {
  const rows = db.query("SELECT id, type, data FROM session_message WHERE session_id = ? ORDER BY seq DESC LIMIT ?")
    .all(sessionId, limit) as Array<{ id: string; type: string; data: string }>;
  const parts = new Map<string, unknown[]>();
  const assistants = rows.filter((row) => row.type === "assistant").map((row) => row.id);
  if (assistants.length && hasTable(db, "session_part")) {
    const query = db.query(
      "SELECT message_id, data FROM session_part WHERE session_id = ? AND message_id IN (SELECT value FROM json_each(?)) ORDER BY ordinal",
    );
    for (const part of query.all(sessionId, JSON.stringify(assistants)) as Array<{ message_id: string; data: string }>) {
      const content = parts.get(part.message_id) ?? [];
      content.push(JSON.parse(part.data));
      parts.set(part.message_id, content);
    }
  }
  return rows.reverse().map((row) => {
    const data = JSON.parse(row.data);
    const content = parts.get(row.id);
    if (content) data.content = content;
    return { ...data, id: row.id, type: row.type } as SessionMessageInfo;
  });
}
