import type { Database } from "bun:sqlite";
import { existsSync } from "node:fs";
import { isAbsolute } from "node:path";
import type { DbSerializeFile, DbSerializeOutput, DbSerializer } from "./db-serializers";
import { SAFE_NATIVE_ID, type HandoffReference } from "./types";

// Only these session columns leave the database. An allowlist, so a column a
// later version adds (a share URL, an account link) stays out until reviewed.
const SESSION_COLUMNS = /^(id|slug|project_id|directory|path|parent_id|title|version|agent|model|revert|permission|cost|summary_\w+|tokens_\w+|time_\w+)$/;
const JSON_COLUMNS = new Set(["model", "revert", "permission", "summary_diffs"]);
const MAX_CHILD_DEPTH = 3;
const MAX_CHILDREN = 64;
const MAX_REFERENCES = 500;
const ERROR_REDACTION = "message.info.error (kept name, data.message, data.statusCode, data.isRetryable)";
const REASONING_REDACTION = "part reasoningEncryptedContent (removed)";
// Kilo keys its board by the conversation's root session, not by a session_id.
const BOARD_TABLES = [
  { table: "kilo_board", scope: "root_session_id" },
  { table: "kilo_board_message", scope: "board_root_session_id" },
] as const;

export interface OpencodeSerializeOptions {
  includeKiloBoard: boolean;
}

export interface OpencodeSessionDoc {
  info: Record<string, unknown>;
  messages: { info: Record<string, unknown>; parts: Record<string, unknown>[] }[];
  /** Kilo only, and only when the session has board rows. */
  board?: Record<string, unknown[]>;
}

export interface OpencodeSerialized {
  doc: OpencodeSessionDoc;
  children: { id: string; doc: OpencodeSessionDoc }[];
  todo: unknown[];
  references: HandoffReference[];
  redactions: string[];
  warnings: string[];
}

interface Context {
  redactions: Set<string>;
  warnings: string[];
  references: HandoffReference[];
}

function parseJson(text: unknown): unknown {
  if (typeof text !== "string") return undefined;
  try { return JSON.parse(text); } catch { return undefined; }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Provider replies can carry response headers (set-cookie), bodies and request
 * URLs under info.error, deeper than any key census checked, so only the
 * fields a reader needs to understand the failure are kept. */
function allowlistedError(error: unknown): Record<string, unknown> {
  if (!isRecord(error)) return {};
  const out: Record<string, unknown> = {};
  if (error.name !== undefined) out.name = error.name;
  if (isRecord(error.data)) {
    const data: Record<string, unknown> = {};
    for (const key of ["message", "statusCode", "isRetryable"]) if (error.data[key] !== undefined) data[key] = error.data[key];
    out.data = data;
  }
  return out;
}

/** Opaque provider reasoning state: large, unreadable to a target agent and not
 * the user's content. */
function stripReasoningState(value: unknown, ctx: Context): void {
  if (Array.isArray(value)) {
    for (const item of value) stripReasoningState(item, ctx);
    return;
  }
  if (!isRecord(value)) return;
  if ("reasoningEncryptedContent" in value) {
    delete value.reasoningEncryptedContent;
    ctx.redactions.add(REASONING_REDACTION);
  }
  for (const child of Object.values(value)) stripReasoningState(child, ctx);
}

function noteOutputPath(part: Record<string, unknown>, ctx: Context): void {
  const state = part.state;
  const metadata = isRecord(state) ? state.metadata : undefined;
  const outputPath = isRecord(metadata) ? metadata.outputPath : undefined;
  if (typeof outputPath !== "string" || !isAbsolute(outputPath) || ctx.references.length >= MAX_REFERENCES) return;
  // opencode prunes these files, so a path that is gone is not worth naming.
  if (existsSync(outputPath)) ctx.references.push({ path: outputPath, note: "Full tool output the transcript truncated." });
}

function sessionInfo(row: Record<string, unknown>, ctx: Context): Record<string, unknown> {
  const info: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(row)) {
    if (!SESSION_COLUMNS.test(key)) {
      if (key === "share_url" && value != null) ctx.redactions.add("session.share_url (dropped)");
      continue;
    }
    info[key] = JSON_COLUMNS.has(key) ? parseJson(value) ?? value : value;
  }
  return info;
}

function readMessages(db: Database, sessionId: string, ctx: Context): OpencodeSessionDoc["messages"] {
  const messages: OpencodeSessionDoc["messages"] = [];
  const byId = new Map<string, OpencodeSessionDoc["messages"][number]>();
  for (const row of db.query("SELECT id, data FROM message WHERE session_id = ? ORDER BY time_created, id").all(sessionId) as { id: string; data: string }[]) {
    const data = parseJson(row.data);
    if (!isRecord(data)) {
      ctx.warnings.push(`Skipped message ${row.id}: its row was not valid JSON.`);
      continue;
    }
    const info: Record<string, unknown> = { id: row.id, sessionID: sessionId, ...data };
    if ("error" in info) {
      info.error = allowlistedError(info.error);
      ctx.redactions.add(ERROR_REDACTION);
    }
    const entry = { info, parts: [] as Record<string, unknown>[] };
    messages.push(entry);
    byId.set(row.id, entry);
  }
  // One pass over the session's parts rather than a query per message; part ids
  // sort in creation order within a message.
  for (const row of db.query("SELECT id, message_id, data FROM part WHERE session_id = ? ORDER BY id").all(sessionId) as { id: string; message_id: string; data: string }[]) {
    const owner = byId.get(row.message_id);
    const data = parseJson(row.data);
    if (!owner || !isRecord(data)) {
      if (owner) ctx.warnings.push(`Skipped part ${row.id}: its row was not valid JSON.`);
      continue;
    }
    stripReasoningState(data, ctx);
    noteOutputPath(data, ctx);
    owner.parts.push({ id: row.id, sessionID: sessionId, messageID: row.message_id, ...data });
  }
  return messages;
}

function hasTable(db: Database, name: string): boolean {
  return db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(name) != null;
}

function readBoard(db: Database, sessionId: string, ctx: Context): Record<string, unknown[]> | undefined {
  const board: Record<string, unknown[]> = {};
  let clearedSeq = 0;
  for (const { table, scope } of BOARD_TABLES) {
    if (!hasTable(db, table)) continue;
    const columns = (db.query(`PRAGMA table_info(${table})`).all() as { name: string }[]).map((column) => column.name);
    // The board schema is Kilo's and may change; a table with no session link
    // cannot be scoped to this conversation, so it is left out rather than leaked whole.
    if (!columns.includes(scope)) {
      ctx.warnings.push(`Skipped ${table}: it has no ${scope} column.`);
      continue;
    }
    let rows = db.query(`SELECT * FROM ${table} WHERE ${scope} = ?`).all(sessionId) as Record<string, unknown>[];
    if (table === "kilo_board") {
      const cleared = rows[0]?.cleared_seq;
      if (typeof cleared === "number") clearedSeq = cleared;
    } else {
      // Kilo shows only messages after the board's last clear, in seq order.
      rows = rows
        .filter((row) => typeof row.seq !== "number" || row.seq > clearedSeq)
        .sort((a, b) => (typeof a.seq === "number" && typeof b.seq === "number" ? a.seq - b.seq : 0));
    }
    if (rows.length) board[table] = rows;
  }
  return Object.keys(board).length ? board : undefined;
}

function readTodo(db: Database, sessionId: string, ctx: Context): unknown[] {
  if (!hasTable(db, "todo")) return [];
  try {
    return db.query("SELECT * FROM todo WHERE session_id = ? ORDER BY position").all(sessionId);
  } catch {
    try {
      return db.query("SELECT * FROM todo WHERE session_id = ?").all(sessionId);
    } catch (error) {
      ctx.warnings.push(`Could not read todo rows: ${error instanceof Error ? error.message : String(error)}`);
      return [];
    }
  }
}

function readSession(db: Database, sessionId: string, opts: OpencodeSerializeOptions, ctx: Context): OpencodeSessionDoc | undefined {
  const row = db.query("SELECT * FROM session WHERE id = ?").get(sessionId) as Record<string, unknown> | null;
  if (!row) return undefined;
  const doc: OpencodeSessionDoc = { info: sessionInfo(row, ctx), messages: readMessages(db, sessionId, ctx) };
  if (opts.includeKiloBoard) {
    const board = readBoard(db, sessionId, ctx);
    if (board) doc.board = board;
  }
  return doc;
}

/** Output has the `opencode export` shape so a target (or the user) can read or
 * import it, extended with the child sessions and todo rows export omits.
 * Reads only session, message, part, todo and the Kilo board tables: the same
 * database holds account and credential tables that must never be selected. */
export function serializeOpencodeSession(db: Database, sessionId: string, opts: OpencodeSerializeOptions): OpencodeSerialized | undefined {
  const ctx: Context = { redactions: new Set(), warnings: [], references: [] };
  const doc = readSession(db, sessionId, opts, ctx);
  if (!doc) return undefined;

  const children: OpencodeSerialized["children"] = [];
  const seen = new Set([sessionId]);
  let frontier = [sessionId];
  for (let depth = 0; depth < MAX_CHILD_DEPTH && frontier.length; depth++) {
    const next: string[] = [];
    for (const parent of frontier) {
      for (const { id } of db.query("SELECT id FROM session WHERE parent_id = ? ORDER BY time_created, id").all(parent) as { id: string }[]) {
        if (seen.has(id)) continue;
        seen.add(id);
        if (!SAFE_NATIVE_ID.test(id)) {
          ctx.warnings.push("Skipped a child session whose id is not a safe identifier.");
          continue;
        }
        if (children.length >= MAX_CHILDREN) {
          ctx.warnings.push(`Stopped after ${MAX_CHILDREN} child sessions.`);
          continue;
        }
        const childDoc = readSession(db, id, opts, ctx);
        if (!childDoc) continue;
        children.push({ id, doc: childDoc });
        next.push(id);
      }
    }
    frontier = next;
  }
  return { doc, children, todo: readTodo(db, sessionId, ctx), references: ctx.references, redactions: [...ctx.redactions], warnings: ctx.warnings };
}

export interface OpencodeSerializerArgs {
  sessionId: string;
  /** Output file prefix, also the agent name: `<prefix>-session.json`. */
  prefix: "opencode" | "kilo";
  includeKiloBoard: boolean;
}

function parseArgs(args: unknown): OpencodeSerializerArgs {
  const value = args as Partial<OpencodeSerializerArgs> | null;
  if (!value || typeof value.sessionId !== "string" || !SAFE_NATIVE_ID.test(value.sessionId) || (value.prefix !== "opencode" && value.prefix !== "kilo")) {
    throw new Error("Invalid opencode serializer arguments.");
  }
  return { sessionId: value.sessionId, prefix: value.prefix, includeKiloBoard: value.includeKiloBoard === true };
}

const json = (value: unknown) => `${JSON.stringify(value, null, 2)}\n`;

/** A session that is not in the database, or one opened but never prompted (a
 * row with no messages and no children), yields no files, which the caller
 * reports as "no native store": it falls back to the scrollback, or refuses the
 * fork when there is none. */
export const opencodeFamilySerializer: DbSerializer = (db, rawArgs): DbSerializeOutput => {
  const args = parseArgs(rawArgs);
  const result = serializeOpencodeSession(db, args.sessionId, { includeKiloBoard: args.includeKiloBoard });
  if (!result || (!result.doc.messages.length && !result.children.length)) return { files: [], references: [], redactions: [], warnings: [] };
  const files: DbSerializeFile[] = [{ name: `${args.prefix}-session.json`, role: "transcript", text: json(result.doc) }];
  result.children.forEach((child, index) => {
    files.push({
      name: `${args.prefix}-child-${String(index + 1).padStart(2, "0")}.json`,
      role: "sidecar",
      text: json(child.doc),
      originalName: child.id,
    });
  });
  if (result.todo.length) files.push({ name: `${args.prefix}-todo.json`, role: "sidecar", text: json(result.todo) });
  return { files, references: result.references, redactions: result.redactions, warnings: result.warnings };
};
