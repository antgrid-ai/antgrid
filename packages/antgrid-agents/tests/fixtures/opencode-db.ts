import { Database } from "bun:sqlite";
import type { HandoffSnapshotOpts } from "../../src/agents/handoff";

export function createOpencodeDb(path: string, extraTables = ""): Database {
  const db = new Database(path);
  db.run("PRAGMA journal_mode = WAL");
  db.run("CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, directory TEXT, title TEXT, version TEXT, share_url TEXT, revert TEXT, time_created INTEGER, time_updated INTEGER)");
  db.run("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)");
  db.run("CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, data TEXT)");
  db.run("CREATE TABLE todo (session_id TEXT, content TEXT, status TEXT, position INTEGER)");
  db.run("CREATE TABLE account (id TEXT PRIMARY KEY, access_token TEXT)");
  db.run("INSERT INTO account VALUES ('a1', 'SECRET-ACCESS-TOKEN')");
  if (extraTables) db.run(extraTables);
  return db;
}

export function addSession(db: Database, id: string, parent: string | null, text: string, extra: { error?: unknown; part?: unknown } = {}): void {
  db.run("INSERT INTO session VALUES (?, 'p1', ?, '/work', ?, '1.0', 'https://share.example/SECRET', '{\"messageID\":\"m\"}', 1, 2)", [id, parent, `title ${id}`]);
  db.run("INSERT INTO message VALUES (?, ?, 1, ?)", [`msg_${id}_1`, id, JSON.stringify({ role: "user", time: { created: 1 } })]);
  db.run("INSERT INTO message VALUES (?, ?, 2, ?)", [`msg_${id}_2`, id, JSON.stringify({ role: "assistant", ...(extra.error ? { error: extra.error } : {}) })]);
  db.run("INSERT INTO part VALUES (?, ?, ?, ?)", [`prt_${id}_1`, `msg_${id}_1`, id, JSON.stringify({ type: "text", text })]);
  db.run("INSERT INTO part VALUES (?, ?, ?, ?)", [`prt_${id}_2`, `msg_${id}_2`, id, JSON.stringify(extra.part ?? { type: "text", text: `reply ${id}` })]);
}

export function snapshotOpts(outDir: string, overrides: Partial<HandoffSnapshotOpts>): HandoffSnapshotOpts {
  return { maxMsgs: 10, projectPath: "/work", outDir, sourceCwd: "/work", signal: new AbortController().signal, ...overrides };
}
