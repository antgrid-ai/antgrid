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

/** A title field that would actually name something, else null. Blank is not
 *  nullish, so storing `"   "` would let the `??` chain in the resolver return
 *  it and suppress a lower-precedence title that is genuinely present. One
 *  helper rather than the check repeated per slot: a copy that omits the
 *  `.trim()` fails silently, applying no name and hiding the real one. */
function titleField(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value : null;
}

/**
 * Claude transcript title, in precedence order:
 *   1. LAST {type:"custom-title", customTitle} — the name the user gave the
 *      conversation, so it outranks anything Claude picked for itself.
 *   2. LAST {type:"ai-title", aiTitle} — Claude's own generated title.
 *   3. LAST {type:"summary", summary} — a compaction summary. Effectively dead:
 *      current transcript formats emit none at all.
 *   4. First {type:"user"} message's text.
 *
 * The two title records COEXIST rather than one superseding the other: a
 * renamed conversation restates BOTH on every turn, adjacently. So precedence
 * here is by type and not by file position, neither spelling may be retired as
 * legacy, and `LAST` wins within a type only because a value can be revised in
 * place over a long session.
 *
 * Branch 4 is not rare — most transcripts carry no title record at all, because
 * Claude writes one only in the interactive TUI, never in headless/SDK runs
 * (which is every chat-mode session). That was measured against `custom-title`
 * before `ai-title` existed and has not been re-measured since — worth knowing,
 * because the caller spends a model call on the branch-4 answer (see
 * maybeGenerateTitle). A title that IS written lands early, so a missing one
 * means absent, not late. Never throws.
 */
export async function resolveClaudeTranscriptTitle(transcriptPath: string): Promise<ResolvedTitle | null> {
  const raw = await readOrNull(transcriptPath);
  if (raw === null) return null;
  const lines = raw.split("\n");
  let firstUser: string | null = null;
  let lastSummary: string | null = null;
  let lastAi: string | null = null;
  let lastCustom: string | null = null;
  for (const line of lines) {
    const t = line.trim();
    if (!t) continue;
    let obj: any;
    try { obj = JSON.parse(t); } catch { continue; }
    if (obj?.type === "custom-title") {
      lastCustom = titleField(obj.customTitle) ?? lastCustom;
    } else if (obj?.type === "ai-title") {
      lastAi = titleField(obj.aiTitle) ?? lastAi;
    } else if (obj?.type === "summary") {
      lastSummary = titleField(obj.summary) ?? lastSummary;
    } else if (obj?.type === "user" && firstUser === null) {
      const text = messageText(obj.message?.content);
      if (text) firstUser = text;
    }
  }
  const real = lastCustom ?? lastAi ?? lastSummary;
  if (real) return generated(real);
  return firstUser ? firstMessage(firstUser) : null;
}
