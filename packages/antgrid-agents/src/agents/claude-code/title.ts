import type { ResolvedTitle } from "../types";
import { firstMessage, manualTitle, readOrNull } from "../title-read";
import { isLocalCommandNoise, isNonHumanOrigin } from "./transcript-read";

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

/** A `type:"user"` record the user did not type. Claude Code writes several:
 *  the `<local-command-caveat>` preamble and a prompt command's expanded body
 *  (isMeta), injected inter-session messages (isMeta), the summary a compacted
 *  session restarts from (isCompactSummary), and a slash command's echo and
 *  stdout, which carry no flag at all. A background task's completion
 *  (`<task-notification>`) carries no flag either, only an `origin` whose kind
 *  is not "human"; a session that resumes from a compaction summary can reach
 *  one before anything typed. Taking any of them as the first message names
 *  the session after Claude Code's plumbing. A session opened with a slash
 *  command therefore takes its title from the first prompt typed after it, the
 *  same messages transcript-read.ts keeps for the visible history. */
function isUnauthoredUserRecord(obj: any): boolean {
  return obj.isMeta === true || obj.isCompactSummary === true || obj.isSidechain === true ||
    isNonHumanOrigin(obj) || isLocalCommandNoise(obj);
}

/**
 * Claude transcript title, in precedence order:
 *   1. LAST {type:"custom-title", customTitle} — the name the USER gave the
 *      conversation with `/rename`. `LAST` wins because it can be revised in
 *      place over a long session.
 *   2. First {type:"user"} message's text that the user typed (see
 *      isUnauthoredUserRecord).
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
    } else if (obj?.type === "user" && firstUser === null && !isUnauthoredUserRecord(obj)) {
      const text = messageText(obj.message?.content);
      if (text) firstUser = text;
    }
  }
  if (lastCustom) return manualTitle(lastCustom);
  return firstUser ? firstMessage(firstUser) : null;
}
