import { createMessage, type AbMessage } from "../../protocol";
import { mapThreadItem } from "./mapping";

// codex times turns, not items: Turn carries startedAt/completedAt as Unix
// SECONDS (codex-rs v2 thread_data.rs). We stamp the user message with the
// turn start (prompt time) and every other item with the turn completion
// (answer time) so the app's per-message timestamps read correctly on resume
// instead of the replay moment. Seconds → ms for the AbMessage envelope.
function turnSecondsToMs(seconds: unknown): number | undefined {
  return typeof seconds === "number" && Number.isFinite(seconds)
    ? seconds * 1000
    : undefined;
}

// Override the envelope timestamp (createMessage stamps Date.now()) with the
// real historical time when we have one; otherwise leave the frame as-is so
// old codex builds without turn times degrade to current behavior.
function stamped(m: AbMessage, at: number | undefined): AbMessage {
  if (at !== undefined) m.timestamp = at;
  return m;
}

// thread/resume returns the rollout history IN THE RESPONSE (thread.turns), not
// as replayed item/started notifications — see codex-rs app-server
// thread_resume.rs::thread_resume_returns_rollout_history. So we synthesize the
// same agent:* frames the live stream would have produced, in order, from the
// response. Historical turns are closed (end_turn); the app renders them as
// completed transcript before the first new prompt.
export function codexResumeReplay(sessionId: string, thread: any): AbMessage[] {
  const out: AbMessage[] = [];
  const turns: any[] = Array.isArray(thread?.turns) ? thread.turns : [];
  for (const turn of turns) {
    const turnId: string = String(turn?.id ?? "");
    const startedMs = turnSecondsToMs(turn?.startedAt);
    const completedMs = turnSecondsToMs(turn?.completedAt) ?? startedMs;
    out.push(stamped(createMessage("agent:turn-start", { sessionId, turnId }), startedMs));
    for (const rawItem of Array.isArray(turn?.items) ? turn.items : []) {
      const item = mapThreadItem(rawItem);
      if (!item) continue;
      const at = item.role === "user" ? startedMs : completedMs;
      out.push(stamped(createMessage("agent:item-added", {
        sessionId,
        turnId,
        itemId: item.itemId,
        parentItemId: item.parentItemId,
        item,
      }), at));
    }
    out.push(stamped(createMessage("agent:turn-end", { sessionId, turnId, stopReason: "end_turn" }), completedMs));
  }
  return out;
}
