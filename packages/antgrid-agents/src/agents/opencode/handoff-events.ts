import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { capEventText, isAntgridHandoffPrompt, type HandoffEventsFn } from "../handoff/events";

type Rec = Record<string, unknown>;

const isRecord = (value: unknown): value is Rec => typeof value === "object" && value !== null && !Array.isArray(value);

function stringify(value: unknown): string {
  if (typeof value === "string") return value;
  if (value === undefined || value === null) return "";
  try {
    return JSON.stringify(value) ?? "";
  } catch {
    return "";
  }
}

/** Synthetic parts are text opencode injects itself (file-attachment notes, the
 * post-compaction "continue" nudge), and ignored parts are hidden from the
 * model: neither is something the user or the assistant said. */
function visibleText(parts: readonly Rec[]): string {
  return parts
    .filter((part) => part.type === "text" && typeof part.text === "string" && part.synthetic !== true && part.ignored !== true)
    .map((part) => (part.text as string).trim())
    .filter(Boolean)
    .join("\n");
}

/** `info.summary` is a per-turn diff object on user messages and `true` only on
 * a compaction summary, so the role is checked before the flag is trusted. */
function isCompactionSummary(info: Rec): boolean {
  return info.role === "assistant"
    && info.summary === true
    && (info.mode === "compaction" || info.agent === "compaction")
    && !!info.finish
    && !info.error;
}

/**
 * Reads the `opencode export`-shaped session document the snapshot wrote.
 * Shared with Kilo, whose store is the same schema. Compaction is read from the
 * summary message, never from the marker user message that precedes it.
 */
export const opencodeFamilyEvents: HandoffEventsFn = async (dir, manifest, sink, signal) => {
  let doc: unknown;
  try {
    doc = JSON.parse(await readFile(join(dir, manifest.primary), "utf8"));
  } catch {
    return;
  }
  if (signal.aborted) throw new Error("The handoff parse ran past its deadline.");
  const messages = isRecord(doc) && Array.isArray(doc.messages) ? doc.messages : [];
  for (const message of messages) {
    if (!isRecord(message) || !isRecord(message.info)) continue;
    const info = message.info;
    const parts = Array.isArray(message.parts) ? message.parts.filter(isRecord) : [];
    const at = typeof info.id === "string" && info.id ? info.id : manifest.primary;

    if (info.role === "user") {
      const text = visibleText(parts);
      if (text) sink({ kind: "user", text: capEventText(text), genuine: !isAntgridHandoffPrompt(text), at });
      continue;
    }
    if (info.role !== "assistant") continue;

    if (isCompactionSummary(info)) {
      const summary = visibleText(parts);
      if (summary) sink({ kind: "compaction", summary: capEventText(summary), at });
      continue;
    }
    for (const part of parts) {
      if (part.type === "text") {
        const text = visibleText([part]);
        if (text) sink({ kind: "assistant", text: capEventText(text), at });
      } else if (part.type === "tool" && typeof part.tool === "string") {
        const state = isRecord(part.state) ? part.state : {};
        sink({ kind: "tool_call", name: part.tool, input: capEventText(stringify(state.input)), at });
        if (state.status === "error" || state.error !== undefined) {
          sink({ kind: "tool_result", name: part.tool, output: capEventText(stringify(state.error)), isError: true, at });
        } else if (state.output !== undefined) {
          sink({ kind: "tool_result", name: part.tool, output: capEventText(stringify(state.output)), at });
        }
      }
    }
  }
};
