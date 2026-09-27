// bridge/src/handler/config.ts
import {
  mkdirSync, appendFileSync, statSync, renameSync,
  openSync, readSync, closeSync, fstatSync, existsSync,
} from "node:fs";
import { join } from "node:path";

export interface ActivityRecord {
  recordId: string;
  at: number;
  terminalId: string;
  // "parked"/"resumed" are lifecycle EVENTS, not verdicts about the supervised
  // work — they sit here beside the other non-decision kinds so the activity
  // feed can show why a session went quiet.
  //
  // One kind per item outcome rather than a single "item_resolved": a skip is as
  // consequential as a completion, so the feed must distinguish them without
  // parsing the reason text. Kept in lockstep with the same enum in
  // protocol.ts and the app's handler_state.dart — a value missing from either
  // renders as an unknown row at runtime, never as a build error.
  decision: "continue" | "handle" | "escalate" | "armed" | "goal_edited"
    | "item_done" | "item_blocked" | "item_skipped" | "item_failed"
    | "instruction_dropped" | "instruction_authorized" | "instruction_amended"
    | "floor_warning" | "evidence_rejected"
    | "wrapped_up" | "parked" | "resumed"
    // The three moments of a question that is not a stop. They were `escalate`
    // rows once, and every feed label for that kind leads "Escalated:" — so the
    // one feature built on "a question is not a stop" rendered its question,
    // its answer and its decline as three stops.
    | "asked" | "ask_rejected" | "answered";
  reason: string;
  detail?: string;
}

const ACTIVITY_FILE = "handler-activity.jsonl";
const ACTIVITY_ROLLED_FILE = "handler-activity.1.jsonl";
// Exported so a test can build a file at exactly the cap rather than guess at one.
export const ACTIVITY_LOG_MAX_BYTES = 5_000_000;

function projectDir(abDir: string, projectId: string): string {
  return join(abDir, "agents", projectId);
}

/**
 * Bound the audit log by RENAME, never by rewriting a trailing window in place.
 * This runs on every judge decision, so "keep the last N records" would turn an
 * O(1) append into a read of the whole file each time — strictly worse than the
 * growth it fixes.
 *
 * One rolled generation is kept rather than dropped: the wrap-up record summarises
 * a finished session, but these rows are the only durable copy of what it did
 * decision by decision, and the only place one can be reconstructed from.
 *
 * It must never throw. `HandlerEngine.record` writes here BEFORE it emits the
 * `handler:activity` frame, so an error escaping this would cost the connected app
 * its live row as well as the audit line.
 */
function rotateIfLarge(dir: string, path: string): void {
  try {
    if (statSync(path).size < ACTIVITY_LOG_MAX_BYTES) return;
    renameSync(path, join(dir, ACTIVITY_ROLLED_FILE));
  } catch {
    // No log yet, or a rename Windows refused while something still holds the
    // rolled file — a skipped rotation, retried by the next record.
  }
}

export function appendActivity(abDir: string, projectId: string, rec: ActivityRecord): void {
  const dir = projectDir(abDir, projectId);
  const path = join(dir, ACTIVITY_FILE);
  mkdirSync(dir, { recursive: true });
  rotateIfLarge(dir, path);
  appendFileSync(path, `${JSON.stringify(rec)}\n`, "utf8");
}

/**
 * How much of the log's tail one history read looks at. At roughly 350 bytes a
 * record this covers any sane `limit` many times over, so the read is a single
 * fixed window rather than a loop that grows until it has enough — the log is
 * appended to on every judge decision, and a growing read would race it.
 */
const ACTIVITY_READ_WINDOW_BYTES = 256 * 1024;

export interface RecentActivity {
  /**
   * Newest first. The file is oldest-first (append-only), so this reverses it:
   * the app prepends live rows at index 0 and renders its buffer unreversed, so
   * a page handed over in file order would render a correct feed upside down.
   */
  records: ActivityRecord[];
  /** Older records exist that this answer does not carry. */
  truncated: boolean;
}

/**
 * Last `ACTIVITY_READ_WINDOW_BYTES` of a file as text, and whether that window
 * reached the start of it.
 *
 * Null when the file is absent — which includes vanishing mid-read, since
 * `rotateIfLarge` renames the live log out from under any reader on any append.
 * The size comes from the open descriptor rather than the path for that reason.
 */
function tailUtf8(path: string): { text: string; fromStart: boolean } | null {
  let fd: number | undefined;
  try {
    fd = openSync(path, "r");
    const size = fstatSync(fd).size;
    const start = Math.max(0, size - ACTIVITY_READ_WINDOW_BYTES);
    const len = size - start;
    if (len === 0) return { text: "", fromStart: true };
    const buf = Buffer.allocUnsafe(len);
    let got = 0;
    while (got < len) {
      const n = readSync(fd, buf, got, len - got, start + got);
      if (n <= 0) break;
      got += n;
    }
    return { text: buf.subarray(0, got).toString("utf8"), fromStart: start === 0 };
  } catch {
    return null;
  } finally {
    if (fd !== undefined) {
      try { closeSync(fd); } catch { /* already gone */ }
    }
  }
}

/**
 * Narrow one parsed line to a record, dropping anything malformed.
 *
 * `decision` is checked as a string rather than against the union above: this
 * log is the only durable, decision-by-decision account of a finished session,
 * so a build that no longer knows a kind an older build wrote must still hand
 * the row over. The app types the field as a String for the same reason, and
 * renders a kind it does not know as that row's raw reason.
 */
function toActivityRecord(value: unknown): ActivityRecord | null {
  if (typeof value !== "object" || value === null) return null;
  const r = value as Record<string, unknown>;
  if (typeof r.recordId !== "string") return null;
  if (typeof r.at !== "number") return null;
  if (typeof r.terminalId !== "string") return null;
  if (typeof r.decision !== "string") return null;
  if (typeof r.reason !== "string") return null;
  if (r.detail !== undefined && typeof r.detail !== "string") return null;
  return {
    recordId: r.recordId,
    at: r.at,
    terminalId: r.terminalId,
    decision: r.decision as ActivityRecord["decision"],
    reason: r.reason,
    ...(r.detail === undefined ? {} : { detail: r.detail }),
  };
}

function parseActivityLines(text: string, fromStart: boolean): ActivityRecord[] {
  const lines = text.split("\n");
  // A window that did not reach the start of the file opens mid-record.
  if (!fromStart) lines.shift();
  const out: ActivityRecord[] = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      // A torn trailing line is normal rather than an error: an append can land
      // between this read's stat and its last byte.
      continue;
    }
    const rec = toActivityRecord(parsed);
    if (rec) out.push(rec);
  }
  return out;
}

/**
 * The newest `limit` activity records for a project, answering
 * `handler:history:request`.
 *
 * The sole reader of the activity log. It must never throw: an absent log is
 * the ordinary state of a project whose handler was never armed, and the caller
 * owes an answer to a request that would otherwise hang.
 */
export function readRecentActivity(
  abDir: string,
  projectId: string,
  limit: number,
): RecentActivity {
  if (limit <= 0) return { records: [], truncated: false };
  const dir = projectDir(abDir, projectId);
  const rolledPath = join(dir, ACTIVITY_ROLLED_FILE);

  const live = tailUtf8(join(dir, ACTIVITY_FILE));
  let records = live ? parseActivityLines(live.text, live.fromStart) : [];
  let truncated = live ? !live.fromStart : false;

  if (records.length < limit && !truncated) {
    // One rolled generation is kept so a finished session's account survives a
    // roll; reach into it only when the live log cannot fill the answer.
    const rolled = tailUtf8(rolledPath);
    if (rolled) {
      records = [...parseActivityLines(rolled.text, rolled.fromStart), ...records];
      truncated = !rolled.fromStart;
    }
  } else if (!truncated) {
    // The live log filled the answer, but older rows may still sit in the rolled
    // generation — the feed is shortened whether or not they were read.
    truncated = existsSync(rolledPath);
  }

  if (records.length > limit) {
    records = records.slice(records.length - limit);
    truncated = true;
  }
  records.reverse();
  return { records, truncated };
}
