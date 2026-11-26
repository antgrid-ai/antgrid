// bridge/src/agents/opencode/db-read.ts
import { Database } from "bun:sqlite";
import { join, isAbsolute } from "node:path";
import { homedir } from "node:os";

// Rows fetched per read. Must stay comfortably wider than DECIDE_MAX_MSGS
// (handler/context.ts): most assistant rows are tool-only and
// yield no text parts, so the message budget is filled from a larger row window.
const ROW_CAP = 200;

/**
 * opencode's xdg lib has no Windows branch, so ~/.local/share holds on every
 * platform. OPENCODE_DB mirrors opencode's flag: absolute path used as-is, a
 * bare name resolves under the data dir. Channel-suffixed dev DBs
 * (opencode-<channel>.db) are out of scope.
 */
export function resolveOpencodeDbPath(): string {
  const dataDir = join(process.env.XDG_DATA_HOME || join(homedir(), ".local", "share"), "opencode");
  const override = process.env.OPENCODE_DB;
  if (override) return isAbsolute(override) ? override : join(dataDir, override);
  return join(dataDir, "opencode.db");
}

/**
 * Last n conversation texts for a session, chronological. Readonly open with
 * busy_timeout 0 (the per-agent title.ts pattern): the DB is WAL so a snapshot
 * read beside a live opencode is safe, and any failure — missing DB, lock,
 * schema drift — returns [] so the caller falls back to PTY scrollback.
 * Ordered by (time_created, id), not bare id: opencode's monotonic id scheme
 * wraps every ~795 days while time_created is written once and never updated.
 * Synchronous on the event loop, but indexed and LIMIT-bounded — the same
 * trade agents/codex/title.ts already accepts. Never throws.
 */
export function readLastOpencodeMessages(sessionId: string, n: number, dbPath?: string): string[] {
  if (n <= 0) return []; // slice(-0) === slice(0) — the whole array, not none
  let db: Database | null = null;
  try {
    db = new Database(dbPath ?? resolveOpencodeDbPath(), { readonly: true });
    db.exec("PRAGMA busy_timeout = 0");
    const rows = db.query(
      "SELECT id, data FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT ?",
    ).all(sessionId, ROW_CAP) as Array<{ id: string; data: string }>;
    if (!rows.length) return [];
    rows.reverse();

    const partQ = db.query("SELECT data FROM part WHERE message_id = ? ORDER BY id");
    const texts: (string | null)[] = [];
    const infos: any[] = [];
    const compactions = new Map<number, any>(); // row index -> its compaction part
    for (let i = 0; i < rows.length; i++) {
      let info: any;
      try { info = JSON.parse(rows[i].data); } catch { texts.push(null); infos.push(null); continue; }
      infos.push(info);
      const role = info?.role;
      if (role !== "user" && role !== "assistant") { texts.push(null); continue; }
      const chunks: string[] = [];
      for (const part of partQ.all(rows[i].id) as Array<{ data: string }>) {
        let d: any;
        try { d = JSON.parse(part.data); } catch { continue; }
        if (role === "user" && d?.type === "compaction") compactions.set(i, d);
        // synthetic/ignored text is injected machinery ("Continue if you have
        // next steps…"); opencode's own TUI filters both the same way.
        if (d?.type === "text" && typeof d.text === "string" && !d.synthetic && !d.ignored) chunks.push(d.text);
      }
      const t = chunks.join("\n").trim();
      texts.push(t || null);
    }
    const boundary = compactionBoundary(rows, infos, compactions);
    const out: string[] = [];
    for (let i = boundary; i < texts.length; i++) if (texts[i]) out.push(texts[i]!);
    return out.slice(-n);
  } catch {
    return [];
  } finally {
    db?.close();
  }
}

/**
 * Index of the oldest row still in the model's context, mirroring opencode's
 * MessageV2.filterCompacted: walking newest-first, a compaction user message
 * counts only once a newer summary assistant (parentID = its id) finished
 * without error — a failed compaction leaves the whole history in context.
 * The newest counted compaction cuts there, or at its tail_start_id when
 * opencode retained a tail of recent turns from before the compaction; a tail
 * id not found among older rows keeps everything, as opencode does.
 */
function compactionBoundary(rows: Array<{ id: string }>, infos: any[], compactions: Map<number, any>): number {
  const completed = new Set<unknown>();
  for (let i = rows.length - 1; i >= 0; i--) {
    const info = infos[i];
    const part = compactions.get(i);
    if (part && completed.has(rows[i].id)) {
      if (!part.tail_start_id) return i;
      for (let j = i; j >= 0; j--) if (rows[j].id === part.tail_start_id) return j;
      return 0;
    }
    if (info?.role === "assistant" && info.summary && info.finish && !info.error) completed.add(info.parentID);
  }
  return 0;
}
