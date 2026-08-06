import type { ResolvedTitle } from "../types";
import { firstMessage, generated, readOrNull } from "../title-read";

/** Extract plain text from a Claude message `content` field (string or parts array).
 *  Returns the FIRST text part — not the same function as ./transcript.ts's
 *  exported `messageText`, which joins every text part. A title wants one line;
 *  a transcript body wants the whole message. Keep them separate. */
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
 *   1. LAST {type:"custom-title", customTitle} — Claude's own conversation
 *      title. It writes this itself (and rewrites it as the topic drifts, so the
 *      last wins); a manual `/rename` lands in the same slot, which is why it
 *      outranks everything else.
 *   2. LAST {type:"summary", summary} — a compaction summary. Effectively dead:
 *      current transcript formats emit none at all.
 *   3. First {type:"user"} message's text.
 *
 * Branch 3 is not rare. Claude only writes custom-title in the INTERACTIVE TUI:
 * across 503 local transcripts, 65% of long real-project sessions have one, but
 * 0 of 78 headless/SDK runs do — which is every chat-mode session. When it does
 * write one it is early (137 of 142 land before the first assistant message), so
 * a missing title means absent, not late. Never throws.
 */
export async function resolveClaudeTranscriptTitle(transcriptPath: string): Promise<ResolvedTitle | null> {
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
  const real = lastCustom ?? lastSummary;
  if (real) return generated(real);
  return firstUser ? firstMessage(firstUser) : null;
}
