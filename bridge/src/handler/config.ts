// bridge/src/handler/config.ts
import { mkdirSync, appendFileSync } from "node:fs";
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
  // consequential as a completion (spec §4.3), so the feed must distinguish them
  // without parsing the reason text. Kept in lockstep with the same enum in
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

function projectDir(abDir: string, projectId: string): string {
  return join(abDir, "agents", projectId);
}

export function appendActivity(abDir: string, projectId: string, rec: ActivityRecord): void {
  const dir = projectDir(abDir, projectId);
  mkdirSync(dir, { recursive: true });
  appendFileSync(join(dir, "handler-activity.jsonl"), `${JSON.stringify(rec)}\n`, "utf8");
}
