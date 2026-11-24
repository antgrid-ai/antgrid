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

const UNIFIED_HISTORY = "vibe-history.jsonl";
const UNIFIED_CONTEXT = "vibe-context.jsonl";

/** A settled tool effect's result, read against the 3.1.4 projection: a
 * completed one carries `outputText` and the serialized `output`, a failed one an
 * `error`, a skipped or cancelled one a `reason`; a running one has none yet. */
function effectResult(state: Rec): { output: string; isError: boolean } | undefined {
  const status = state.status;
  if (status === "completed") {
    const text = str(state.outputText);
    if (text) return { output: text, isError: false };
    const output = state.output;
    if (!isRec(output)) return { output: "", isError: false };
    const parts = contentText(output.content);
    if (parts) return { output: parts, isError: false };
    const structured = output.structured_content;
    const inner = isRec(structured) ? str(structured.content) : undefined;
    return { output: inner ?? JSON.stringify(structured ?? output), isError: false };
  }
  if (status === "failed") return { output: (isRec(state.error) ? str(state.error.message) : undefined) ?? str(state.outputText) ?? "", isError: true };
  if (status === "skipped" || status === "cancelled") return { output: str(state.reason) ?? "", isError: true };
  return undefined;
}

/** Vibe 3: the projection history, with the summary for its latest compaction
 * taken from the model context, which is the only place Vibe keeps it. */
async function unifiedEvents(dir: string, manifest: Parameters<HandoffEventsFn>[1], sink: Parameters<HandoffEventsFn>[2], signal: AbortSignal): Promise<void> {
  let summary: string | undefined;
  if (manifest.files.some((file) => file.name === UNIFIED_CONTEXT)) {
    await forEachJsonlLine(join(dir, UNIFIED_CONTEXT), (_lineNo, value) => {
      if (!isRec(value) || !isRec(value.message) || value.message.role !== "user") return;
      summary = compactionSummary(contentText(value.message.content)) ?? summary;
    }, signal);
  }
  const file = join(dir, UNIFIED_HISTORY);
  const isCompaction = (value: unknown) => isRec(value) && value.type === "checkpoint" && value.kind === "compaction";
  let lastCompaction = 0;
  await forEachJsonlLine(file, (lineNo, value) => { if (isCompaction(value)) lastCompaction = lineNo; }, signal);
  await forEachJsonlLine(file, (lineNo, value) => {
    if (!isRec(value)) return;
    const at = `${UNIFIED_HISTORY}:${lineNo}`;
    if (isCompaction(value)) {
      const text = lineNo === lastCompaction ? summary : undefined;
      sink({ kind: "compaction", ...(text ? { summary: capEventText(text) } : { note: "Vibe compacted here; only its latest summary is kept" }), at });
    } else if (value.type === "message" && value.role === "user") {
      const text = contentText(value.content).trim();
      if (text) sink(userEvent(text, at));
    } else if (value.type === "message" && value.role === "assistant") {
      const text = contentText(value.content).trim();
      if (text) sink({ kind: "assistant", text: capEventText(text), at });
    } else if (value.type === "effect" && isRec(value.detail) && str(value.detail.toolName)) {
      const name = str(value.detail.toolName)!;
      sink({ kind: "tool_call", name, input: capEventText(JSON.stringify(value.detail.input ?? {})), at });
      const result = isRec(value.state) ? effectResult(value.state) : undefined;
      if (result) sink({ kind: "tool_result", name, output: capEventText(result.output), ...(result.isError ? { isError: true } : {}), at });
    }
  }, signal);
}

export const vibeEvents: HandoffEventsFn = async (dir, manifest, sink, signal) => {
  if (manifest.primary === UNIFIED_HISTORY) return unifiedEvents(dir, manifest, sink, signal);
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
