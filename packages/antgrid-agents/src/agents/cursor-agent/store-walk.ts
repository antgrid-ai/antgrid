import type { Database } from "bun:sqlite";
import type { DbSerializeOutput, DbSerializer } from "../handoff/db-serializers";
import { HandoffSnapshotError, SAFE_NATIVE_ID } from "../handoff/types";

// Cursor keeps a chat as a content-addressed blob graph: a protobuf root blob
// (ConversationStateStructure) names JSON message blobs by sha256, and names
// each summary archive the same way — an archive is its own protobuf blob, not
// a message inlined in the root. The field numbers come from the shipped CLI
// bundle, not a published schema, so every read is defensive and a root that
// no longer parses is reported rather than guessed at.
const ROOT_MESSAGES_FIELD = 1;
const SUMMARY_ARCHIVES_FIELD = 13;
const ARCHIVE_SUMMARIZED_MESSAGES_FIELD = 1;
const ARCHIVE_SUMMARY_FIELD = 2;
const ARCHIVE_WINDOW_TAIL_FIELD = 3;
const ARCHIVE_SUMMARY_MESSAGE_FIELD = 4;
const BLOB_ID_BYTES = 32;

export interface ProtoField {
  field: number;
  /** Set for varint fields. */
  varint?: number;
  /** Set for length-delimited fields. */
  bytes?: Uint8Array;
}

/** Walks the top level of one protobuf message. Fixed-width fields are skipped,
 * and groups (deprecated, never used by this schema) are refused. */
export function walkProto(buf: Uint8Array): ProtoField[] {
  const fields: ProtoField[] = [];
  let pos = 0;
  const varint = (): number => {
    let result = 0;
    for (let shift = 0; shift < 70; shift += 7) {
      if (pos >= buf.length) throw new Error("truncated varint");
      const byte = buf[pos++]!;
      // Multiplication, not <<, so values past 2^31 stay exact.
      result += (byte & 0x7f) * 2 ** shift;
      if (!(byte & 0x80)) return result;
    }
    throw new Error("varint too long");
  };
  while (pos < buf.length) {
    const tag = varint();
    const field = Math.floor(tag / 8);
    const wire = tag % 8;
    if (field < 1) throw new Error("invalid field number");
    if (wire === 0) fields.push({ field, varint: varint() });
    else if (wire === 1) pos += 8;
    else if (wire === 5) pos += 4;
    else if (wire === 2) {
      const length = varint();
      if (pos + length > buf.length) throw new Error("length-delimited field overruns the message");
      fields.push({ field, bytes: buf.subarray(pos, pos + length) });
      pos += length;
    } else throw new Error(`unsupported wire type ${wire}`);
    if (pos > buf.length) throw new Error("fixed-width field overruns the message");
  }
  return fields;
}

const hex = (bytes: Uint8Array) => Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString("hex");

/** The 32-byte entries of a repeated bytes field, as blob ids, in order. Other
 * lengths under the same field number are not blob references. */
export function blobIdsOf(fields: ProtoField[], field: number): string[] {
  return fields.filter((f) => f.field === field && f.bytes?.length === BLOB_ID_BYTES).map((f) => hex(f.bytes!));
}

export interface SummaryArchive {
  summarizedMessageIds: string[];
  summary?: string;
  windowTail?: number;
  summaryMessageId?: string;
}

export interface RootWalk {
  messageIds: string[];
  archiveIds: string[];
}

export function walkRootBlob(root: Uint8Array): RootWalk {
  const fields = walkProto(root);
  return { messageIds: blobIdsOf(fields, ROOT_MESSAGES_FIELD), archiveIds: blobIdsOf(fields, SUMMARY_ARCHIVES_FIELD) };
}

/** One ConversationSummaryArchive blob, as the root's field-13 id names it. */
export function walkArchiveBlob(archive: Uint8Array): SummaryArchive {
  const inner = walkProto(archive);
  const summary = inner.find((i) => i.field === ARCHIVE_SUMMARY_FIELD && i.bytes);
  const windowTail = inner.find((i) => i.field === ARCHIVE_WINDOW_TAIL_FIELD)?.varint;
  const summaryMessage = blobIdsOf(inner, ARCHIVE_SUMMARY_MESSAGE_FIELD)[0];
  return {
    summarizedMessageIds: blobIdsOf(inner, ARCHIVE_SUMMARIZED_MESSAGES_FIELD),
    ...(summary ? { summary: Buffer.from(summary.bytes!).toString("utf8") } : {}),
    ...(windowTail !== undefined ? { windowTail } : {}),
    ...(summaryMessage ? { summaryMessageId: summaryMessage } : {}),
  };
}

export interface CursorStoreMeta {
  agentId?: string;
  latestRootBlobId?: string;
  name?: string;
  createdAt?: number;
  mode?: string;
  lastUsedModel?: string;
  blobEncryptionKey?: string;
}

/** The chat's identity record: one row whose value is hex-encoded JSON. */
export function readStoreMeta(db: Database): CursorStoreMeta | undefined {
  const row = db.query("SELECT value FROM meta WHERE key = '0'").get() as { value?: unknown } | null;
  if (typeof row?.value !== "string") return undefined;
  try {
    const parsed = JSON.parse(Buffer.from(row.value, "hex").toString("utf8")) as unknown;
    return typeof parsed === "object" && parsed !== null ? (parsed as CursorStoreMeta) : undefined;
  } catch {
    return undefined;
  }
}

export interface CursorSerializerArgs {
  chatId: string;
  /** From meta.json beside the store; folded into the header. */
  cwd?: string;
  title?: string;
  updatedAtMs?: number;
}

function parseArgs(args: unknown): CursorSerializerArgs {
  const value = args as Partial<CursorSerializerArgs> | null;
  if (!value || typeof value.chatId !== "string" || !SAFE_NATIVE_ID.test(value.chatId)) throw new Error("Invalid cursor serializer arguments.");
  return {
    chatId: value.chatId,
    ...(typeof value.cwd === "string" ? { cwd: value.cwd } : {}),
    ...(typeof value.title === "string" ? { title: value.title } : {}),
    ...(typeof value.updatedAtMs === "number" ? { updatedAtMs: value.updatedAtMs } : {}),
  };
}

function blobText(data: unknown): string | undefined {
  if (typeof data === "string") return data;
  return data instanceof Uint8Array ? Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString("utf8") : undefined;
}

/** A message blob is spliced into the JSONL verbatim only when it is valid JSON
 * on one line; re-serializing would alter what the agent stored. */
function messageLine(db: Database, blobId: string, archive: number | undefined, skipped: { count: number }): string | undefined {
  const row = db.query("SELECT data FROM blobs WHERE id = ?").get(blobId) as { data?: unknown } | null;
  const text = row ? blobText(row.data) : undefined;
  if (text === undefined || text.includes("\n")) {
    skipped.count++;
    return undefined;
  }
  try { JSON.parse(text); } catch {
    skipped.count++;
    return undefined;
  }
  const head = JSON.stringify({ type: "message", ...(archive !== undefined ? { archived: true, archiveIndex: archive } : {}), blobId });
  return `${head.slice(0, -1)},"message":${text.trim()}}`;
}

export const cursorChatSerializer: DbSerializer = (db, rawArgs): DbSerializeOutput => {
  const args = parseArgs(rawArgs);
  const meta = readStoreMeta(db);
  if (!meta || meta.agentId !== args.chatId) throw new HandoffSnapshotError("UNREADABLE", "The Cursor chat store does not belong to this chat.");
  if (!meta.latestRootBlobId) throw new HandoffSnapshotError("UNREADABLE", "The Cursor chat store has no root blob yet.");
  const rootRow = db.query("SELECT data FROM blobs WHERE id = ?").get(meta.latestRootBlobId) as { data?: unknown } | null;
  if (!rootRow || !(rootRow.data instanceof Uint8Array)) throw new HandoffSnapshotError("UNREADABLE", "The Cursor chat root blob is missing.");
  let walk: RootWalk;
  try {
    walk = walkRootBlob(rootRow.data);
  } catch (error) {
    throw new HandoffSnapshotError("UNREADABLE", `The Cursor chat root blob did not parse: ${error instanceof Error ? error.message : String(error)}`);
  }

  const lines: string[] = [
    JSON.stringify({
      type: "header",
      chatId: args.chatId,
      name: meta.name,
      mode: meta.mode,
      createdAt: meta.createdAt,
      lastUsedModel: meta.lastUsedModel,
      latestRootBlobId: meta.latestRootBlobId,
      ...(args.cwd !== undefined ? { cwd: args.cwd } : {}),
      ...(args.title !== undefined ? { title: args.title } : {}),
      ...(args.updatedAtMs !== undefined ? { updatedAtMs: args.updatedAtMs } : {}),
    }),
  ];
  const skipped = { count: 0 };
  let skippedArchives = 0;
  walk.archiveIds.forEach((archiveId, index) => {
    const row = db.query("SELECT data FROM blobs WHERE id = ?").get(archiveId) as { data?: unknown } | null;
    let archive: SummaryArchive | undefined;
    // Cursor's own reader treats a missing archive blob as holding no messages
    // and carries on, so one bad archive costs only its own messages here too.
    try {
      if (row?.data instanceof Uint8Array) archive = walkArchiveBlob(row.data);
    } catch {}
    if (!archive) {
      skippedArchives++;
      return;
    }
    lines.push(JSON.stringify({
      type: "summary_archive",
      archiveIndex: index,
      summary: archive.summary,
      windowTail: archive.windowTail,
      summaryMessageBlobId: archive.summaryMessageId,
    }));
    for (const id of archive.summarizedMessageIds) {
      const line = messageLine(db, id, index, skipped);
      if (line) lines.push(line);
    }
  });
  for (const id of walk.messageIds) {
    const line = messageLine(db, id, undefined, skipped);
    if (line) lines.push(line);
  }

  const warnings = [
    ...(skipped.count ? [`Skipped ${skipped.count} message blob${skipped.count === 1 ? "" : "s"} that were missing or not single-line JSON.`] : []),
    ...(skippedArchives ? [`Skipped ${skippedArchives} summary archive${skippedArchives === 1 ? "" : "s"} that were missing or did not parse.`] : []),
  ];
  return {
    files: [{ name: "cursor-chat.jsonl", role: "transcript", text: `${lines.join("\n")}\n` }],
    references: [],
    // The key authenticates the chat to Cursor's servers; it is never read into the output.
    redactions: ["meta.blobEncryptionKey (never copied)"],
    warnings,
  };
};
