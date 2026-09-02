// bridge/src/handler/config.ts
import { mkdirSync, appendFileSync, statSync, renameSync } from "node:fs";
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
    | "wrapped_up" | "parked" | "resumed";
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
