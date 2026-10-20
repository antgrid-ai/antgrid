import { join } from "node:path";
import {
  capEventText,
  forEachJsonlLine,
  userEvent,
  type HandoffEventsFn,
} from "../handoff/events";

type Rec = Record<string, unknown>;

const isRec = (value: unknown): value is Rec => typeof value === "object" && value !== null && !Array.isArray(value);
const str = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);

/** Vibe writes `content` as a string, but this has never been seen live, so a
 * parts array is accepted rather than dropping the message. */
function contentText(value: unknown): string {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return "";
  return value.map((part) => (typeof part === "string" ? part : isRec(part) ? (str(part.text) ?? "") : "")).join("");
}

const SUMMARY_OPEN = "<compaction_summary>\n";
const SUMMARY_CLOSE = "\n</compaction_summary>";

/** The record also replays recent user turns before the summary, so only the
 * tagged span is the summary. */
function compactionSummary(content: string): string | undefined {
  const open = content.lastIndexOf(SUMMARY_OPEN);
  if (open === -1) return undefined;
  const start = open + SUMMARY_OPEN.length;
  const close = content.indexOf(SUMMARY_CLOSE, start);
  const text = (close === -1 ? content.slice(start) : content.slice(start, close)).trim();
  return text || undefined;
}

export const vibeEvents: HandoffEventsFn = async (dir, manifest, sink, signal) => {
  const file = join(dir, manifest.primary);
  await forEachJsonlLine(file, (lineNo, value) => {
    if (!isRec(value)) return;
    const at = `${manifest.primary}:${lineNo}`;
    const role = value.role;
    if (role === "user") {
      if (value.context_boundary === "compaction") {
        const summary = compactionSummary(contentText(value.content));
        sink({ kind: "compaction", ...(summary ? { summary: capEventText(summary) } : { note: "Vibe compacted here but its summary was unreadable" }), at });
        return;
      }
      // Injected text (skills, hooks, auto-read files) and `!cmd` shell runs
      // are not something the user said to the agent.
      if (value.injected === true || value.context_boundary !== undefined || value.manual_shell !== undefined) return;
      const text = (str(value.input_text) ?? contentText(value.content)).trim();
      if (!text) return;
      sink(userEvent(text, at));
    } else if (role === "assistant") {
      const text = contentText(value.content).trim();
      if (text) sink({ kind: "assistant", text: capEventText(text), at });
      if (!Array.isArray(value.tool_calls)) return;
      for (const call of value.tool_calls) {
        if (!isRec(call) || !isRec(call.function)) continue;
        sink({ kind: "tool_call", name: str(call.function.name) ?? "tool", input: capEventText(str(call.function.arguments) ?? ""), at });
      }
    } else if (role === "tool") {
      const name = str(value.name);
      sink({ kind: "tool_result", ...(name ? { name } : {}), output: capEventText(contentText(value.content)), at });
    }
  }, signal);
};
