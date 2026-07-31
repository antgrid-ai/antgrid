import { messageText, readTranscriptTail } from "../../transcript-tail";
import type { TranscriptOpts } from "../types";

// Mirrors title-resolver.ts JSONL iteration, but collects a rolling window of the
// last N message texts instead of title-specific fields. Every role is included:
// the handler needs conversation context, not just the agent's turn.
export async function readLastClaudeMessages(transcriptPath: string, n: number): Promise<string[]> {
  if (n <= 0) return []; // slice(-0) === slice(0) — the whole array, not none
  const raw = await readTranscriptTail(transcriptPath);
  if (!raw) return [];
  const out: string[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      const obj = JSON.parse(line);
      const text = messageText(obj?.message?.content);
      if (text) out.push(text);
    } catch { /* skip malformed line */ }
  }
  return out.slice(-n);
}

/** The transcript path is the caller's own input echoed back — claude's hook
 *  posts it, so there is nothing to discover and it is always followable. */
export async function readTranscript(opts: TranscriptOpts): Promise<{ msgs: string[]; transcriptPath?: string }> {
  if (!opts.transcriptPath) return { msgs: [] };
  return {
    msgs: await readLastClaudeMessages(opts.transcriptPath, opts.maxMsgs),
    transcriptPath: opts.transcriptPath,
  };
}
