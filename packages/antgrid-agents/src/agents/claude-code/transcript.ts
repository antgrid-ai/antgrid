import {
  MAX_NOTIFICATION_BODY_LEN,
  closingSentences,
  readTranscriptTail,
} from "../../transcript-tail";
import type { TranscriptOpts } from "../types";

/** Plain text from a Claude message `content` field (string or parts array). */
export function messageText(content: unknown): string | null {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((p): p is { type: string; text: string } => !!p && (p as any).type === "text")
      .map((p) => p.text).join("");
  }
  return null;
}

/**
 * Closing text of the LAST assistant turn, whitespace-collapsed and capped. A
 * turn-end notification answers "does this need me?" and the ask lands at the
 * end of a message, so the body is built from the closing sentence rather than
 * the opening one. Returns null when no assistant turn carries text — a
 * tool-only final turn is not a summary, so the caller falls back to the label.
 * Never throws.
 */
export async function lastAssistantText(
  path: string,
  maxChars: number = MAX_NOTIFICATION_BODY_LEN,
): Promise<string | null> {
  const raw = await readTranscriptTail(path);
  if (!raw) return null;
  let last: string | null = null;
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let obj: any;
    try { obj = JSON.parse(line); } catch { continue; }
    if (obj?.type !== "assistant") continue;
    const text = messageText(obj?.message?.content);
    const collapsed = text ? text.replace(/\s+/g, " ").trim() : "";
    if (collapsed) last = collapsed;
  }
  if (!last) return null;
  return closingSentences(last, maxChars) || null;
}

// Mirrors ./title.ts's JSONL iteration, but collects a rolling window of the
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
