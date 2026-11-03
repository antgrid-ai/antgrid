import type { Database } from "bun:sqlite";
import type { SessionMessageInfo } from "@opencode/client";

export function hasOpencodeV2Store(db: Database): boolean {
  return !!db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_v2'").get();
}

/** Parts move out of the message row while streaming; completed/forked rows
 * may keep them inline. Read both representations in the native sequence order. */
export function readOpencodeV2Messages(db: Database, sessionId: string, limit = -1): SessionMessageInfo[] {
  const rows = db.query("SELECT id, type, data FROM session_message WHERE session_id = ? ORDER BY seq DESC LIMIT ?")
    .all(sessionId, limit) as Array<{ id: string; type: string; data: string }>;
  const hasParts = !!db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_part'").get();
  const parts = hasParts ? db.query("SELECT data FROM session_part WHERE session_id = ? AND message_id = ? ORDER BY ordinal") : undefined;
  return rows.reverse().map((row) => {
    const data = JSON.parse(row.data);
    if (row.type === "assistant" && parts) {
      const content = (parts.all(sessionId, row.id) as Array<{ data: string }>).map((part) => JSON.parse(part.data));
      if (content.length) data.content = content;
    }
    return { ...data, id: row.id, type: row.type } as SessionMessageInfo;
  });
}
