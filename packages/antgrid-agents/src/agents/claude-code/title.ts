import type { ResolvedTitle } from "../types";
import { firstMessage, manualTitle, readOrNull } from "../title-read";

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
 *  nullish, so a `"   "` kept here would be returned as a manual rename and
 *  suppress the first-message fallback that is genuinely present, applying no
 *  name at all. */
function titleField(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value : null;
}

/**
 * Claude transcript title, in precedence order:
 *   1. LAST {type:"custom-title", customTitle} — the name the USER gave the
 *      conversation with `/rename`. `LAST` wins because it can be revised in
 *      place over a long session.
 *   2. First {type:"user"} message's text.
 *
 * Claude's OWN title rides the same file as {type:"ai-title", aiTitle} (and,
 * historically, {type:"summary"}). Both are deliberately not read: we generate
 * our own name now (see agents/title-generate.ts), and reading Claude's meant
 * a session got a good name in the interactive TUI and an echo of the opening
 * prompt in every headless/SDK run — which is every chat-mode session. Note the
 * records COEXIST rather than superseding each other: a renamed conversation
 * restates both every turn, so `custom-title` is a distinct signal from
 * `ai-title` and not a stale copy of it.
 *
 * Branch 2 is the norm, not an edge case, and it exists to hold the slot until
 * the generated name lands rather than to be a title. Never throws.
 */
export async function resolveClaudeTranscriptTitle(transcriptPath: string): Promise<ResolvedTitle | null> {
  const raw = await readOrNull(transcriptPath);
  if (raw === null) return null;
  const lines = raw.split("\n");
  let firstUser: string | null = null;
  let lastCustom: string | null = null;
  for (const line of lines) {
    const t = line.trim();
    if (!t) continue;
    let obj: any;
    try { obj = JSON.parse(t); } catch { continue; }
    if (obj?.type === "custom-title") {
      lastCustom = titleField(obj.customTitle) ?? lastCustom;
    } else if (obj?.type === "user" && firstUser === null) {
      const text = messageText(obj.message?.content);
      if (text) firstUser = text;
    }
  }
  if (lastCustom) return manualTitle(lastCustom);
  return firstUser ? firstMessage(firstUser) : null;
}
