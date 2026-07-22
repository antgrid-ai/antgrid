import { Database } from "bun:sqlite";
import { readFile, readdir } from "node:fs/promises";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { logger } from "./logger";

export type StructuredAgent = "claude" | "codex" | "gemini" | "qwen" | "github-copilot";

/** Read a UTF-8 file, returning null on any error (missing / unreadable). Async
 *  so a large Claude transcript can't block the single-threaded bridge event
 *  loop (and its WS sockets) while it's read off the /session-title handler. */
async function readOrNull(path: string): Promise<string | null> {
  try {
    return await readFile(path, "utf8");
  } catch {
    return null;
  }
}

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
 * Title is the CLI's per-thread name (first-message-derived; the desktop app's
 * richer generated title lives only in session_index.jsonl). Falls back to
 * first_user_message. Opened read-only; never throws (returns null on any error).
 */
export async function resolveCodexThreadTitle(threadId: string, codexHome: string): Promise<string | null> {
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
    if (title) return title;
    const first = (row.first_user_message ?? "").trim();
    return first || null;
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
 * Copilot writes a lazy generated summary to session-store.db. When it has not
 * generated one yet, the first user turn is the best available slot title.
 */
export async function resolveCopilotSessionTitle(sessionId: string, copilotHome: string): Promise<string | null> {
  let db: Database | null = null;
  try {
    db = new Database(join(copilotHome, "session-store.db"), { readonly: true });
    db.exec("PRAGMA busy_timeout = 0");
    const session = db
      .query("SELECT summary FROM sessions WHERE id = ?")
      .get(sessionId) as { summary?: string | null } | null;
    if (!session) return null;
    const summary = (session.summary ?? "").trim();
    if (summary) return summary;

    const turn = db
      .query("SELECT user_message FROM turns WHERE session_id = ? AND trim(coalesce(user_message, '')) <> '' ORDER BY turn_index ASC LIMIT 1")
      .get(sessionId) as { user_message?: string | null } | null;
    const first = (turn?.user_message ?? "").trim();
    return first || null;
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

/**
 * Legacy/desktop-app fallback: Codex's *desktop app* writes conversation titles
 * to ~/.codex/session_index.jsonl as append-only {id, thread_name, updated_at}
 * lines (the LAST line for an id is current); it carries the app's richer
 * generated title when present. The CLI does not write this file. Scan from the
 * end and return the first match. Never throws.
 */
export async function resolveCodexThreadName(threadId: string, codexHome: string): Promise<string | null> {
  const raw = await readOrNull(join(codexHome, "session_index.jsonl"));
  if (raw === null) return null;
  const lines = raw.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line) continue;
    try {
      const e = JSON.parse(line) as { id?: string; thread_name?: string };
      if (e.id === threadId && typeof e.thread_name === "string") return e.thread_name;
    } catch {
      // partial/garbage line (e.g. mid-write tail) — skip
    }
  }
  return null;
}

/** Extract plain text from a Claude message `content` field (string or parts array). */
function messageText(content: unknown): string | null {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    for (const part of content) {
      if (part && typeof part === "object" && (part as any).type === "text" && typeof (part as any).text === "string") {
        return (part as any).text;
      }
    }
  }
  return null;
}

/**
 * Claude transcript title, in precedence order:
 *   1. LAST {type:"custom-title", customTitle} — the user's manual `/rename`
 *      (Claude rewrites/appends this line on each rename; the last wins). This is
 *      explicit user intent, so it outranks every derived title.
 *   2. LAST {type:"summary", summary} — a compaction summary (lazy, often absent;
 *      newer transcript formats omit it entirely).
 *   3. First {type:"user"} message's text.
 * Never throws.
 */
export async function resolveClaudeTranscriptTitle(transcriptPath: string): Promise<string | null> {
  const raw = await readOrNull(transcriptPath);
  if (raw === null) return null;
  const lines = raw.split("\n");
  let firstUser: string | null = null;
  let lastSummary: string | null = null;
  let lastCustom: string | null = null;
  for (const line of lines) {
    const t = line.trim();
    if (!t) continue;
    let obj: any;
    try { obj = JSON.parse(t); } catch { continue; }
    // Each branch guards against a blank string: an empty title is not nullish,
    // so storing it would let the `??` chain below return "" and suppress a
    // lower-precedence title that is actually present.
    if (obj?.type === "custom-title" && typeof obj.customTitle === "string" && obj.customTitle.trim()) {
      lastCustom = obj.customTitle;
    } else if (obj?.type === "summary" && typeof obj.summary === "string" && obj.summary.trim()) {
      lastSummary = obj.summary;
    } else if (obj?.type === "user" && firstUser === null) {
      const text = messageText(obj.message?.content);
      if (text) firstUser = text;
    }
  }
  return lastCustom ?? lastSummary ?? firstUser;
}

/**
 * Extract plain text from a Gemini/Qwen `content` field.
 * Gemini/Qwen persist content as `string | Part[]` where a Part is `{text}`
 * with NO `type` field — distinct from Claude's `{type:'text', text}` parts,
 * so this can't reuse messageText.
 */
function geminiPartText(content: unknown): string | null {
  if (typeof content === "string") {
    const s = content.trim();
    return s || null;
  }
  if (Array.isArray(content)) {
    for (const part of content) {
      if (part && typeof part === "object" && typeof (part as any).text === "string") {
        const s = (part as any).text.trim();
        if (s) return s;
      }
    }
  }
  return null;
}

/**
 * Gemini/Qwen session transcript title: first user message's text. Their chat
 * jsonl is a metadata line followed by message records {type, content}.
 * Gemini/Qwen persist `content` as `string | Part[]` where a Part is `{text}`
 * (no `type` field) — distinct from Claude's `{type:'text', text}` parts, so
 * this can't reuse messageText. Never throws.
 */
export async function resolveGeminiTranscriptTitle(transcriptPath: string): Promise<string | null> {
  const raw = await readOrNull(transcriptPath);
  if (raw === null) return null;
  for (const line of raw.split("\n")) {
    const t = line.trim();
    if (!t) continue;
    let obj: any;
    try { obj = JSON.parse(t); } catch { continue; }
    if (obj?.type === "user") {
      const text = geminiPartText(obj.content ?? obj.message?.content);
      if (text) return text;
    }
  }
  return null;
}

/** Dispatch to the right resolver. opencode never reaches here (its title is
 *  supplied inline by the plugin POST). Returns null on any miss. */
export async function resolveStructuredTitle(
  agent: StructuredAgent,
  args: { sessionId: string; transcriptPath?: string },
  opts: { codexHome?: string; copilotHome?: string } = {},
): Promise<string | null> {
  try {
    if (agent === "codex") {
      const codexHome = opts.codexHome ?? join(homedir(), ".codex");
      // Prefer the desktop app's richer generated title (session_index.jsonl) when
      // it has indexed this thread; otherwise use the CLI's live state DB, which is
      // the only source populated for bridge-spawned `codex-tui` sessions.
      return (
        (await resolveCodexThreadName(args.sessionId, codexHome)) ??
        (await resolveCodexThreadTitle(args.sessionId, codexHome))
      );
    }
    if (agent === "claude") {
      return args.transcriptPath ? await resolveClaudeTranscriptTitle(args.transcriptPath) : null;
    }
    if (agent === "gemini" || agent === "qwen") {
      return args.transcriptPath ? await resolveGeminiTranscriptTitle(args.transcriptPath) : null;
    }
    if (agent === "github-copilot") {
      const copilotHome = opts.copilotHome ?? process.env.COPILOT_HOME ?? join(homedir(), ".copilot");
      return await resolveCopilotSessionTitle(args.sessionId, copilotHome);
    }
    return null;
  } catch (err) {
    logger.warn("title resolution failed: %s", err);
    return null;
  }
}
