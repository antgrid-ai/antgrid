import { findCodexRolloutPath, readLastCodexMessages } from "./rollout-read";
import type { TranscriptOpts } from "../types";

/**
 * Whether one parsed rollout-JSONL record marks Codex's turn as aborted by
 * the user — the only trace an interrupt leaves, since no installed build
 * fires a hook or notify on Esc/Ctrl+C. `reason` is what tells a user abort
 * apart from any other kind this event type may carry; an absent reason is
 * never read as a match.
 */
export function isInterruptRecord(record: unknown): boolean {
  if (!record || typeof record !== "object") return false;
  const r = record as { type?: unknown; payload?: unknown };
  if (r.type !== "event_msg" || !r.payload || typeof r.payload !== "object") return false;
  const payload = r.payload as { type?: unknown; reason?: unknown };
  return payload.type === "turn_aborted" && payload.reason === "interrupted";
}

/** Codex posts only a thread id, so the rollout file has to be discovered first.
 *  The discovered path is followable and comes back with the messages. */
export async function readTranscript(opts: TranscriptOpts): Promise<{ msgs: string[]; transcriptPath?: string }> {
  if (!opts.agentSessionId) return { msgs: [] };
  const path = await findCodexRolloutPath(opts.agentSessionId, opts.codexHome);
  if (!path) return { msgs: [] };
  return { msgs: await readLastCodexMessages(path, opts.maxMsgs), transcriptPath: path };
}
